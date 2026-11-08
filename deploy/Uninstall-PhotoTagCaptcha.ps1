#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Removes the PhotoTagCaptcha adapter from an AD FS server.

.DESCRIPTION
  Primary node: removes the provider from the global additional providers, unregisters it,
  removes it from the GAC and restarts AD FS. Other nodes: run with -GacOnly, but only AFTER they
  have synced the unregistration from the primary (Get-AdfsSyncProperties, WID polls every 5 min);
  otherwise the node restarts with a configuration that still references the removed DLL.
  Run Disable-PhotoTagCaptchaForApp.ps1 first if you want the app's original policy back;
  otherwise the app keeps requiring MFA (with whatever other provider is enabled, if any).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProviderName = 'PhotoTagCaptcha',
    [string]$AssemblyName = 'PhotoTagCaptcha.Adapter',
    [switch]$GacOnly,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
Import-Module ADFS

if (-not $GacOnly -and (Get-AdfsSyncProperties).Role -eq 'SecondaryComputer') {
    Write-Warning 'Secondary WID node: only removing from the GAC.'
    $GacOnly = $true
}

if (-not $GacOnly) {
    $additional = @((Get-AdfsGlobalAuthenticationPolicy).AdditionalAuthenticationProvider | Where-Object { $_ })
    if ($additional -contains $ProviderName -and $PSCmdlet.ShouldProcess($ProviderName, 'Remove from global additional providers')) {
        Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider @($additional | Where-Object { $_ -ne $ProviderName })
    }
    if ((Get-AdfsAuthenticationProvider -Name $ProviderName -ErrorAction SilentlyContinue) -and
        $PSCmdlet.ShouldProcess($ProviderName, 'Unregister-AdfsAuthenticationProvider')) {
        Unregister-AdfsAuthenticationProvider -Name $ProviderName -Confirm:$false
    }
}

# Stop AD FS first so the GAC file is not locked.
if ($PSCmdlet.ShouldProcess('adfssrv', 'Stop AD FS service')) { Stop-Service adfssrv -Force }

$gacRoot = Join-Path $env:WINDIR "Microsoft.NET\assembly\GAC_MSIL\$AssemblyName"
if (Test-Path $gacRoot) {
    Add-Type -AssemblyName System.EnterpriseServices
    $publish = New-Object System.EnterpriseServices.Internal.Publish
    Get-ChildItem $gacRoot -Recurse -Filter "$AssemblyName.dll" | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove from GAC')) {
            $publish.GacRemove($_.FullName)
            Write-Host "Removed $($_.FullName)"
        }
    }
}

if (-not $NoRestart -and $PSCmdlet.ShouldProcess('adfssrv', 'Start AD FS service')) { Start-Service adfssrv }
Write-Host 'Done.'
