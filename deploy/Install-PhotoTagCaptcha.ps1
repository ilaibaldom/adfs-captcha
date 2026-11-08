#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs the PhotoTagCaptcha external authentication adapter on an AD FS server.

.DESCRIPTION
  Run on EVERY AD FS farm node (not on WAP / Web Application Proxy servers).
    1. Puts PhotoTagCaptcha.Adapter.dll into the GAC (AD FS only loads adapters from the GAC).
    2. Creates the "PhotoTagCaptcha" event log source used for diagnostics.
    3. On the primary node only: registers the provider with AD FS and adds it to the
       global list of ADDITIONAL authentication providers.
    4. Restarts the AD FS service on this node, so it loads the provider. With -GacOnly the
       restart only happens once this node's (synced) configuration contains the provider;
       before that a restart would not load anything, so it is skipped (no outage).

  Registering and enabling the provider does NOT put it in front of any application yet:
  AD FS only invokes additional providers for applications whose policy requires MFA.
  Use Enable-PhotoTagCaptchaForApp.ps1 to turn it on for one application group.

  Re-running with a rebuilt DLL of the SAME AssemblyVersion updates it in place
  (GAC overwrite + service restart). If AssemblyVersion or the signing key changed,
  run Uninstall-PhotoTagCaptcha.ps1 first.

  ORDER MATTERS (verified on an AD FS 2019 two-node WID farm):
    1. Every secondary:  -GacOnly          -> DLL into the GAC, no restart yet (no outage).
    2. Primary:          full install      -> registers + enables the provider, restarts the primary.
    3. Wait for each secondary to sync the configuration from the primary (WID farms poll every
       5 minutes by default; Get-AdfsSyncProperties shows LastSyncTime).
    4. Every secondary:  -GacOnly again    -> sees the provider in its synced config and restarts
                                              AD FS so it loads it. Drain the node first.
  Registration is farm-wide; a node that loads the configuration without the DLL in its GAC logs
  provider load errors, and a node restarted before the sync simply does not load the provider.

.EXAMPLE
  # 1. Each secondary node (no restart happens yet):
  .\Install-PhotoTagCaptcha.ps1 -GacOnly

.EXAMPLE
  # 2. The primary node (WID farm) or any one node (SQL farm):
  .\Install-PhotoTagCaptcha.ps1

.EXAMPLE
  # 4. Each secondary again, after its configuration has synced (restarts AD FS on that node):
  .\Install-PhotoTagCaptcha.ps1 -GacOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DllPath,
    [string]$ProviderName = 'PhotoTagCaptcha',
    [string]$TypeName = 'PhotoTagCaptcha.PhotoTagAdapter',
    [switch]$GacOnly,
    [switch]$NoRestart,
    # Optional adapter configuration (JSON, see phototag-config.sample.json). Primary only.
    # Stored farm-wide by AD FS; later changes: Set-PhotoTagCaptchaConfig.ps1.
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
# ($PSScriptRoot can be empty inside param() defaults in Windows PowerShell 5.1)
if (-not $DllPath) { $DllPath = Join-Path $PSScriptRoot 'PhotoTagCaptcha.Adapter.dll' }

if (-not (Get-Service adfssrv -ErrorAction SilentlyContinue)) {
    throw 'The AD FS service (adfssrv) is not installed on this machine. Run this on an AD FS farm node.'
}
Import-Module ADFS

$DllPath = (Resolve-Path $DllPath).Path
$asmName = [Reflection.AssemblyName]::GetAssemblyName($DllPath)
$token = ($asmName.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') }) -join ''
if (-not $token) { throw "$DllPath is not strong-named." }
$fullTypeName = "$TypeName, $($asmName.FullName)"
Write-Host "Adapter: $fullTypeName"

# --- Farm role -------------------------------------------------------------------------------
$role = (Get-AdfsSyncProperties).Role
if (-not $GacOnly -and $role -eq 'SecondaryComputer') {
    Write-Warning 'This is a secondary node of a WID farm; only installing into the GAC. Run without -GacOnly on the primary node.'
    $GacOnly = $true
}

# --- 1. GAC ----------------------------------------------------------------------------------
# gacutil.exe is not present on servers; System.EnterpriseServices.Internal.Publish is.
if ($PSCmdlet.ShouldProcess($DllPath, 'Install into GAC')) {
    Add-Type -AssemblyName System.EnterpriseServices
    (New-Object System.EnterpriseServices.Internal.Publish).GacInstall($DllPath)

    $gacDir = Join-Path $env:WINDIR ("Microsoft.NET\assembly\GAC_MSIL\{0}\v4.0_{1}__{2}" -f $asmName.Name, $asmName.Version, $token)
    $gacFile = Join-Path $gacDir ($asmName.Name + '.dll')
    if (-not (Test-Path $gacFile)) { throw "GAC install failed: $gacFile not found." }
    if ((Get-FileHash $gacFile).Hash -ne (Get-FileHash $DllPath).Hash) {
        throw "GAC copy at $gacFile differs from $DllPath (file locked?). Stop adfssrv and retry."
    }
    Write-Host "GAC: $gacFile" -ForegroundColor Green
}

# --- 2. Event log source ---------------------------------------------------------------------
if (-not [Diagnostics.EventLog]::SourceExists('PhotoTagCaptcha')) {
    if ($PSCmdlet.ShouldProcess('Application log', 'Create event source PhotoTagCaptcha')) {
        New-EventLog -LogName Application -Source 'PhotoTagCaptcha'
    }
}

# --- 3. Register + enable as additional provider (primary only) -------------------------------
if (-not $GacOnly) {
    $existing = Get-AdfsAuthenticationProvider -Name $ProviderName -ErrorAction SilentlyContinue
    if ($ConfigFile) { $ConfigFile = (Resolve-Path $ConfigFile).Path; Get-Content $ConfigFile -Raw | ConvertFrom-Json | Out-Null }  # fail early on bad JSON
    if ($existing) {
        Write-Host "Provider '$ProviderName' is already registered; GAC copy updated." -ForegroundColor Yellow
        if ($ConfigFile -and $PSCmdlet.ShouldProcess($ProviderName, "Import configuration $ConfigFile")) {
            Import-AdfsAuthenticationProviderConfigurationData -Name $ProviderName -FilePath $ConfigFile
            Write-Host "Configuration updated from $ConfigFile." -ForegroundColor Green
        }
    } elseif ($PSCmdlet.ShouldProcess($ProviderName, 'Register-AdfsAuthenticationProvider')) {
        $reg = @{ TypeName = $fullTypeName; Name = $ProviderName }
        if ($ConfigFile) { $reg.ConfigurationFilePath = $ConfigFile }
        Register-AdfsAuthenticationProvider @reg | Out-Null
        Write-Host "Registered provider '$ProviderName'$(if ($ConfigFile) { " with configuration $ConfigFile" })." -ForegroundColor Green
    }

    $global = Get-AdfsGlobalAuthenticationPolicy
    $additional = @($global.AdditionalAuthenticationProvider | Where-Object { $_ })
    if ($additional -notcontains $ProviderName) {
        if ($PSCmdlet.ShouldProcess($ProviderName, 'Add to global additional authentication providers')) {
            Set-AdfsGlobalAuthenticationPolicy -AdditionalAuthenticationProvider ($additional + $ProviderName)
            Write-Host "Added '$ProviderName' to the global additional authentication providers." -ForegroundColor Green
        }
    }
    $others = $additional | Where-Object { $_ -ne $ProviderName }
    if ($others) {
        Write-Warning ("Other additional providers are enabled too: {0}. Users of an app that requires MFA will get a 'choose a method' page instead of going straight to the photo." -f ($others -join ', '))
    }
}

# --- 4. Restart -------------------------------------------------------------------------------
# A secondary only loads the provider once its synced configuration contains the registration.
# Get-AdfsAuthenticationProvider reads the local (synced) store, also on a WID secondary.
$registeredHere = [bool](Get-AdfsAuthenticationProvider -Name $ProviderName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
$restart = -not $NoRestart -and ($registeredHere -or -not $GacOnly)

if ($restart -and $PSCmdlet.ShouldProcess('adfssrv', 'Restart AD FS service')) {
    Restart-Service adfssrv -Force
    Write-Host 'AD FS service restarted.' -ForegroundColor Green
}

Write-Host ''
if ($GacOnly -and -not $registeredHere) {
    Write-Host 'Done: DLL is in the GAC; AD FS was NOT restarted (nothing to load yet).'
    Write-Host 'Next: run the full install on the primary, wait for this node to sync (Get-AdfsSyncProperties),'
    Write-Host 'then run this script with -GacOnly again on this node to restart AD FS and load the provider.'
} elseif ($GacOnly) {
    Write-Host "Done: this node's configuration has '$ProviderName'; AD FS restarted to load it." -ForegroundColor Green
    Write-Host "Check: Application log, source PhotoTagCaptcha, shows 'Pipeline loaded.'"
} else {
    Write-Host 'Done on the primary. On every secondary: wait for its config sync, then run -GacOnly again.'
    Write-Host 'Then scope it to your app:'
    Write-Host "  .\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier '<your application group>'"
}
