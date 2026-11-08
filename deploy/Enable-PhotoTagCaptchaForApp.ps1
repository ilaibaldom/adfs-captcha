#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Turns the PhotoTagCaptcha page on for ONE application (application group or relying party trust).

.DESCRIPTION
  AD FS runs additional (MFA-stage) providers only for applications whose policy requires MFA.
  This script makes the target application require MFA, which routes its users through the
  captcha after primary sign-in. All other applications are left alone.

  Application group: the policy lives on the group's Web API application(s) (the "resource"
  the client requests a token for). Native / server applications in the group have no policy.

  How the policy is changed, per target:
    * Access control policy "Permit everyone"   -> "Permit everyone and require MFA".
    * Already an MFA policy                      -> nothing to do.
    * Legacy claim rules (no access control policy, e.g. upgraded from AD FS 2012 R2)
                                                 -> appends an MFA trigger rule to
                                                    AdditionalAuthenticationRules; authorization
                                                    rules are untouched.
    * Any other policy (e.g. "Permit specific group") -> refused, because swapping it would
      change WHO may sign in. Create a copy of that policy that also requires MFA in the
      AD FS console, then re-run with -AccessControlPolicyName (and -AccessControlPolicyParameters
      if it is parameterized).

  The previous settings are saved to the state file so Disable-PhotoTagCaptchaForApp.ps1 can
  restore them. Run on the primary node; settings replicate to the farm.

.EXAMPLE
  .\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier 'Research Portal'

.EXAMPLE
  .\Enable-PhotoTagCaptchaForApp.ps1 -RelyingPartyName 'research.contoso.com'

.EXAMPLE
  .\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier 'Research Portal' `
      -AccessControlPolicyName 'Permit Researchers and require MFA'
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'AppGroup')]
param(
    [Parameter(Mandatory, ParameterSetName = 'AppGroup')]
    [string]$ApplicationGroupIdentifier,

    [Parameter(Mandatory, ParameterSetName = 'RelyingParty')]
    [string]$RelyingPartyName,

    [string]$AccessControlPolicyName,
    [hashtable]$AccessControlPolicyParameters,

    [string]$ProviderName = 'PhotoTagCaptcha',
    [string]$StateFile
)

$ErrorActionPreference = 'Stop'
# ($PSScriptRoot can be empty inside param() defaults in Windows PowerShell 5.1)
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot 'phototag-scope-state.json' }
Import-Module ADFS

$MfaPolicy = 'Permit everyone and require MFA'
$RuleName = 'PhotoTagCaptcha: require additional authentication'
$MfaRule = @"
@RuleName = "$RuleName"
 => issue(Type = "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod", Value = "http://schemas.microsoft.com/claims/multipleauthn");
"@

# --- Preconditions ----------------------------------------------------------------------------
if (-not (Get-AdfsAuthenticationProvider -Name $ProviderName -ErrorAction SilentlyContinue)) {
    throw "Provider '$ProviderName' is not registered. Run Install-PhotoTagCaptcha.ps1 first."
}
$additional = @((Get-AdfsGlobalAuthenticationPolicy).AdditionalAuthenticationProvider)
if ($additional -notcontains $ProviderName) {
    throw "Provider '$ProviderName' is not in the global additional authentication providers. Run Install-PhotoTagCaptcha.ps1 first."
}

# --- Resolve targets --------------------------------------------------------------------------
$targets = @()
if ($PSCmdlet.ParameterSetName -eq 'AppGroup') {
    if (-not (Get-AdfsApplicationGroup -ApplicationGroupIdentifier $ApplicationGroupIdentifier -ErrorAction SilentlyContinue)) {
        throw "Application group '$ApplicationGroupIdentifier' not found. Get-AdfsApplicationGroup lists them."
    }
    $apis = @(Get-AdfsWebApiApplication -ApplicationGroupIdentifier $ApplicationGroupIdentifier)
    if (-not $apis) {
        throw "Application group '$ApplicationGroupIdentifier' has no Web API application, so it has no access policy to change. Add a Web API (the resource your app requests) to the group, or use a relying party trust."
    }
    foreach ($a in $apis) { $targets += [pscustomobject]@{ Kind = 'WebApiApplication'; Name = $a.Name; Object = $a } }
} else {
    $rp = Get-AdfsRelyingPartyTrust -Name $RelyingPartyName
    if (-not $rp) { throw "Relying party trust '$RelyingPartyName' not found." }
    $targets += [pscustomobject]@{ Kind = 'RelyingPartyTrust'; Name = $rp.Name; Object = $rp }
}

function Set-Target($target, [hashtable]$settings) {
    if ($target.Kind -eq 'WebApiApplication') {
        Set-AdfsWebApiApplication -TargetApplication $target.Object @settings
    } else {
        Set-AdfsRelyingPartyTrust -TargetRelyingParty $target.Object @settings
    }
}

# --- Load state -------------------------------------------------------------------------------
$state = @()
# (ConvertFrom-Json in Windows PowerShell 5.1 emits an array as ONE object; ForEach-Object unrolls it.)
if (Test-Path $StateFile) { $state = @((Get-Content $StateFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }

# --- Apply ------------------------------------------------------------------------------------
foreach ($t in $targets) {
    $o = $t.Object
    $currentAcp = $o.AccessControlPolicyName
    $currentRules = $o.AdditionalAuthenticationRules
    $hadParams = [bool]$o.AccessControlPolicyParameters

    $record = [pscustomobject]@{
        Kind                          = $t.Kind
        Name                          = $t.Name
        ChangedOn                     = (Get-Date).ToString('s')
        Mode                          = $null
        PreviousAccessControlPolicy   = $currentAcp
        PreviousPolicyParameters      = if ($hadParams) { ($o.AccessControlPolicyParameters | Out-String).Trim() } else { $null }
        PreviousAdditionalAuthRules   = $currentRules
    }

    if ($AccessControlPolicyName) {
        if ($currentAcp -eq $AccessControlPolicyName) { Write-Host "[$($t.Name)] already uses '$AccessControlPolicyName'."; continue }
        $settings = @{ AccessControlPolicyName = $AccessControlPolicyName }
        if ($AccessControlPolicyParameters) { $settings.AccessControlPolicyParameters = $AccessControlPolicyParameters }
        $record.Mode = 'AccessControlPolicy'
        $action = "access control policy '$currentAcp' -> '$AccessControlPolicyName'"
    }
    elseif ($currentAcp -eq 'Permit everyone') {
        $settings = @{ AccessControlPolicyName = $MfaPolicy }
        $record.Mode = 'AccessControlPolicy'
        $action = "access control policy 'Permit everyone' -> '$MfaPolicy'"
    }
    elseif ($currentAcp -match 'require MFA') {
        Write-Host "[$($t.Name)] already requires MFA via '$currentAcp'; the captcha will be offered. Nothing changed." -ForegroundColor Yellow
        continue
    }
    elseif (-not $currentAcp) {
        if ($currentRules -and $currentRules -match [regex]::Escape($RuleName)) {
            Write-Host "[$($t.Name)] MFA trigger rule already present." -ForegroundColor Yellow
            continue
        }
        $newRules = if ($currentRules) { $currentRules.TrimEnd() + "`r`n`r`n" + $MfaRule } else { $MfaRule }
        $settings = @{ AdditionalAuthenticationRules = $newRules }
        $record.Mode = 'AdditionalAuthenticationRules'
        $action = 'append MFA trigger rule to AdditionalAuthenticationRules'
    }
    else {
        throw ("[$($t.Name)] uses access control policy '$currentAcp'. Replacing it with '$MfaPolicy' would change who is allowed to sign in. " +
               "Create a policy equivalent to '$currentAcp' that also requires MFA (AD FS console > Access Control Policies), then re-run with -AccessControlPolicyName '<that policy>'.")
    }

    if ($PSCmdlet.ShouldProcess($t.Name, $action)) {
        Set-Target $t $settings
        Write-Host "[$($t.Name)] $action" -ForegroundColor Green
        # Keep the oldest record per target so Disable restores the original settings.
        if (-not ($state | Where-Object { $_.Kind -eq $record.Kind -and $_.Name -eq $record.Name })) {
            $state += $record
        }
    }
}

if (-not $WhatIfPreference) {
    ConvertTo-Json -InputObject @($state) -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
    Write-Host "Saved previous settings to $StateFile (keep it for Disable-PhotoTagCaptchaForApp.ps1)."
}

Write-Host ''
& (Join-Path $PSScriptRoot 'Get-PhotoTagCaptchaScope.ps1') -ProviderName $ProviderName
