#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Changes the PhotoTagCaptcha configuration (photo source, timeout, display mode).

.DESCRIPTION
  Run on the PRIMARY node. AD FS stores the configuration farm-wide and hands it to the adapter
  when the AD FS service starts, so after this:
    * the primary is restarted by this script (unless -NoRestart);
    * each secondary: wait for its config sync (Get-AdfsSyncProperties, WID polls every 5 min),
      then run  .\Install-PhotoTagCaptcha.ps1 -GacOnly  (restarts AD FS there).
  The adapter logs the active configuration in event 1000 ("Pipeline loaded") on every node.

  Settings (all optional; see phototag-config.sample.json):
    photoUrl     http(s):// or file:/// source of the photo; empty = sample embedded in the DLL
    timeoutMs    max time to fetch the photo (default 3000). Slower => user continues WITHOUT captcha
    maxBytes     max photo size (default 2 MB). Larger => user continues WITHOUT captcha
    displayMode  "popup" (default; dialog over the AD FS page) or "page" (inline)
    allowedApplications  identifiers of the ONLY apps the captcha may complete for (guard):
                 app group Web API identifier, RP identifier, or client_id. Empty = guard off.
    allowUnidentified    guard on + app not identifiable from the request: false (default) = refuse
    diagnostics  log what AD FS passes to the adapter (event 1900); troubleshooting only

.EXAMPLE
  .\Set-PhotoTagCaptchaConfig.ps1 -ConfigFile .\phototag-config.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$ProviderName = 'PhotoTagCaptcha',
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
Import-Module ADFS

if ((Get-AdfsSyncProperties).Role -eq 'SecondaryComputer') { throw 'Run this on the primary node.' }
if (-not (Get-AdfsAuthenticationProvider -Name $ProviderName -ErrorAction SilentlyContinue)) { throw "Provider '$ProviderName' is not registered." }

$ConfigFile = (Resolve-Path $ConfigFile).Path
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json   # fail early on bad JSON
Write-Host "New configuration:"; $cfg | Format-List | Out-String | Write-Host

if ($PSCmdlet.ShouldProcess($ProviderName, "Import configuration $ConfigFile")) {
    Import-AdfsAuthenticationProviderConfigurationData -Name $ProviderName -FilePath $ConfigFile
    Write-Host 'Configuration stored.' -ForegroundColor Green
}
if (-not $NoRestart -and $PSCmdlet.ShouldProcess('adfssrv', 'Restart AD FS service')) {
    Restart-Service adfssrv -Force
    Write-Host 'AD FS restarted on the primary.' -ForegroundColor Green
}
Write-Host 'Secondaries: after their next config sync, run .\Install-PhotoTagCaptcha.ps1 -GacOnly on each (restarts AD FS).'
