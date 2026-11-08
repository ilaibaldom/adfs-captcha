<#
.SYNOPSIS
  Shows exactly which applications will be sent to the PhotoTagCaptcha page.

.DESCRIPTION
  AD FS has no "this provider for this app only" switch. Scope comes from two facts:
    * The provider is in the global list of ADDITIONAL authentication providers.
    * AD FS only runs additional authentication for apps whose policy requires MFA.
  So "single application" means: exactly one application requires MFA, and no global
  MFA rule exists. This script reports both, plus other enabled providers that would
  compete with the captcha on the method-choice page.

  The MFA detection for custom access control policies is a best-effort heuristic
  (policy name or definition mentions MFA). Review any policy flagged "custom".
#>
[CmdletBinding()]
param(
    [string]$ProviderName = 'PhotoTagCaptcha',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module ADFS

$mfaRuleClaim = 'http://schemas.microsoft.com/claims/multipleauthn'
$builtInMfaPolicies = @(
    'Permit everyone and require MFA',
    'Permit everyone and require MFA for specific group',
    'Permit everyone and require MFA from extranet access',
    'Permit everyone and require MFA from unauthenticated devices',
    'Permit everyone and require MFA, allow automatic device registration',
    'Permit everyone for intranet access and require MFA for extranet access'
)

function Test-PolicyRequiresMfa([string]$policyName) {
    if (-not $policyName) { return $null }
    if ($builtInMfaPolicies -contains $policyName) { return 'yes' }
    $p = Get-AdfsAccessControlPolicy -Name $policyName -ErrorAction SilentlyContinue
    if ($p -and ($p.PolicyMetadata.Serialized -match 'MultiFactor|Mfa')) { return 'custom (mentions MFA)' }
    return $null
}

function Get-MfaReason($app) {
    $reasons = @()
    $byPolicy = Test-PolicyRequiresMfa $app.AccessControlPolicyName
    if ($byPolicy) { $reasons += "policy '$($app.AccessControlPolicyName)': $byPolicy" }
    if ($app.AdditionalAuthenticationRules -and $app.AdditionalAuthenticationRules -match [regex]::Escape($mfaRuleClaim)) {
        $reasons += 'additional authentication rules'
    }
    $reasons -join '; '
}

Write-Host "== Provider '$ProviderName' =="
$provider = Get-AdfsAuthenticationProvider -Name $ProviderName -ErrorAction SilentlyContinue
$global = Get-AdfsGlobalAuthenticationPolicy
$additional = @($global.AdditionalAuthenticationProvider | Where-Object { $_ })
Write-Host ("  Registered:                       {0}" -f [bool]$provider)
Write-Host ("  Enabled as additional provider:   {0}" -f ($additional -contains $ProviderName))
$others = $additional | Where-Object { $_ -ne $ProviderName }
if ($others) {
    Write-Warning ("  Other additional providers enabled: {0} (users will see a method-choice page)" -f ($others -join ', '))
}

Write-Host ''
Write-Host '== Global MFA rule (applies to EVERY application) =='
$globalRule = Get-AdfsAdditionalAuthenticationRule
if ($globalRule -and $globalRule -match [regex]::Escape($mfaRuleClaim)) {
    Write-Warning '  A global additional authentication rule can require MFA for all applications:'
    Write-Host $globalRule
} else {
    Write-Host '  none'
}

Write-Host ''
Write-Host '== Applications that require MFA (=> will show the photo) =='
$hits = @()
foreach ($rp in Get-AdfsRelyingPartyTrust) {
    $r = Get-MfaReason $rp
    if ($r) { $hits += [pscustomobject]@{ Kind = 'RelyingPartyTrust'; Name = $rp.Name; Group = ''; Reason = $r } }
}
foreach ($api in Get-AdfsWebApiApplication) {
    $r = Get-MfaReason $api
    if ($r) { $hits += [pscustomobject]@{ Kind = 'WebApiApplication'; Name = $api.Name; Group = $api.ApplicationGroupIdentifier; Reason = $r } }
}
if ($hits) { $hits | Format-Table -AutoSize | Out-String | Write-Host } else { Write-Host '  none' }

if ($hits.Count -gt 1) {
    Write-Warning "$($hits.Count) applications require MFA; all of them will offer the captcha. For a single-app POC exactly one should be listed."
}

if ($PassThru) { $hits }
