#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Restores the policy an application had before Enable-PhotoTagCaptchaForApp.ps1 changed it.

.DESCRIPTION
  Reads the state file written by Enable-PhotoTagCaptchaForApp.ps1 and puts back the previous
  access control policy (or previous AdditionalAuthenticationRules) on each recorded target.
  Without -ApplicationGroupIdentifier / -RelyingPartyName, restores every recorded target.

.EXAMPLE
  .\Disable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier 'Research Portal'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ApplicationGroupIdentifier,
    [string]$RelyingPartyName,
    [string]$StateFile
)

$ErrorActionPreference = 'Stop'
# ($PSScriptRoot can be empty inside param() defaults in Windows PowerShell 5.1)
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot 'phototag-scope-state.json' }
Import-Module ADFS

if (-not (Test-Path $StateFile)) { throw "State file $StateFile not found; nothing recorded to restore." }
$state = @((Get-Content $StateFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })

$names = $null
if ($ApplicationGroupIdentifier) {
    $names = @(Get-AdfsWebApiApplication -ApplicationGroupIdentifier $ApplicationGroupIdentifier | ForEach-Object { $_.Name })
} elseif ($RelyingPartyName) {
    $names = @($RelyingPartyName)
}

$remaining = @()
foreach ($r in $state) {
    if ($names -and $names -notcontains $r.Name) { $remaining += $r; continue }

    if ($r.Kind -eq 'WebApiApplication') {
        $target = Get-AdfsWebApiApplication -Name $r.Name
    } else {
        $target = Get-AdfsRelyingPartyTrust -Name $r.Name
    }
    if (-not $target) { Write-Warning "[$($r.Name)] no longer exists; dropping its record."; continue }

    if ($r.Mode -eq 'AccessControlPolicy') {
        $settings = @{ AccessControlPolicyName = $r.PreviousAccessControlPolicy }
        $action = "access control policy -> '$($r.PreviousAccessControlPolicy)'"
    } else {
        $rules = if ($r.PreviousAdditionalAuthRules) { [string]$r.PreviousAdditionalAuthRules } else { '' }
        $settings = @{ AdditionalAuthenticationRules = $rules }
        $action = 'restore previous AdditionalAuthenticationRules'
    }

    if ($PSCmdlet.ShouldProcess($r.Name, $action)) {
        if ($r.Kind -eq 'WebApiApplication') {
            Set-AdfsWebApiApplication -TargetApplication $target @settings
        } else {
            Set-AdfsRelyingPartyTrust -TargetRelyingParty $target @settings
        }
        Write-Host "[$($r.Name)] $action" -ForegroundColor Green
        if ($r.PreviousPolicyParameters) {
            Write-Warning "[$($r.Name)] the previous policy had parameters; re-apply them in the AD FS console if needed:`n$($r.PreviousPolicyParameters)"
        }
    } else {
        $remaining += $r
    }
}

if (-not $WhatIfPreference) {
    ConvertTo-Json -InputObject @($remaining) -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8
}
