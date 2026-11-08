<#
.SYNOPSIS
  Deploys the adapter to the lab farm exactly as you would in production, and scopes it to
  the "ResearchPortal" application group.

.DESCRIPTION
  1. Copies the REAL Microsoft.IdentityServer.Web.dll from LAB-ADFS01 into lib\ and rebuilds,
     so the adapter is compiled against AD FS 2019 itself (validates the reference stub).
  2. Copies dist\ to C:\PhotoTagCaptcha on both nodes.
  3. LAB-ADFS02 (secondary): Install-PhotoTagCaptcha.ps1 -GacOnly   (GAC only, no restart)
  4. LAB-ADFS01 (primary):   Install-PhotoTagCaptcha.ps1           (register + enable + restart)
     LAB-ADFS02:             wait for config sync, then -GacOnly again (restart -> loads provider)
  5. LAB-ADFS01:             Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier ResearchPortal
#>
[CmdletBinding()]
param(
    [string]$ApplicationGroupIdentifier = 'ResearchPortal',
    [switch]$SkipEnable
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabConfig.ps1')
$repo = Split-Path $PSScriptRoot
$domainCred = Get-LabCredential
function Step($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }

# 1. Build against the real AD FS assembly
Step 'Fetching Microsoft.IdentityServer.Web.dll from LAB-ADFS01'
New-Item -ItemType Directory -Force (Join-Path $repo 'lib') | Out-Null
$s = New-PSSession -VMName 'LAB-ADFS01' -Credential $domainCred
try {
    Copy-Item -FromSession $s -Path 'C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll' -Destination (Join-Path $repo 'lib') -Force
} finally { Remove-PSSession $s }
$real = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $repo 'lib\Microsoft.IdentityServer.Web.dll'))
Write-Host "  $($real.FullName)"

Step 'Rebuilding the adapter against the real assembly'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Build against the real AD FS assembly failed.' }

# 2-4. Deploy: secondary first (GAC only), then primary (GAC + register + enable globally)
foreach ($node in @(@{ Vm = 'LAB-ADFS02'; GacOnly = $true }, @{ Vm = 'LAB-ADFS01'; GacOnly = $false })) {
    Step "$($node.Vm): copying dist\ and installing (GacOnly=$($node.GacOnly))"
    $s = New-PSSession -VMName $node.Vm -Credential $domainCred
    try {
        Invoke-Command -Session $s { New-Item -ItemType Directory -Force C:\PhotoTagCaptcha | Out-Null }
        Get-ChildItem (Join-Path $repo 'dist') -File | ForEach-Object {
            Copy-Item -ToSession $s -Path $_.FullName -Destination "C:\PhotoTagCaptcha\$($_.Name)" -Force
        }
        Invoke-Command -Session $s -ArgumentList $node.GacOnly -ScriptBlock {
            param($gacOnly)
            Set-Location C:\PhotoTagCaptcha
            if ($gacOnly) { .\Install-PhotoTagCaptcha.ps1 -GacOnly } else { .\Install-PhotoTagCaptcha.ps1 }
        }
    } finally { Remove-PSSession $s }
}

# 4b. Secondary: wait for its WID config sync, then -GacOnly again (restarts AD FS to load the provider)
Step 'LAB-ADFS02: waiting for configuration sync from the primary (WID polls every 5 min)'
$deadline = (Get-Date).AddMinutes(12)
do {
    $synced = Invoke-Command -VMName 'LAB-ADFS02' -Credential $domainCred -ScriptBlock {
        [bool](Get-AdfsAuthenticationProvider -Name PhotoTagCaptcha -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
    }
    if (-not $synced) { Start-Sleep -Seconds 20 }
} until ($synced -or (Get-Date) -gt $deadline)
if (-not $synced) { throw 'LAB-ADFS02 did not sync the provider registration within 12 minutes.' }
Invoke-Command -VMName 'LAB-ADFS02' -Credential $domainCred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Install-PhotoTagCaptcha.ps1 -GacOnly }

# 5. Scope to one application group
if (-not $SkipEnable) {
    Step "LAB-ADFS01: enabling the captcha for application group '$ApplicationGroupIdentifier'"
    Invoke-Command -VMName 'LAB-ADFS01' -Credential $domainCred -ArgumentList $ApplicationGroupIdentifier -ScriptBlock {
        param($group)
        Set-Location C:\PhotoTagCaptcha
        .\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier $group
    }
}

Step 'Provider status on both nodes'
foreach ($vm in 'LAB-ADFS01', 'LAB-ADFS02') {
    Invoke-Command -VMName $vm -Credential $domainCred -ScriptBlock {
        $svc = (Get-Service adfssrv).Status
        $gac = Test-Path "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\PhotoTagCaptcha.Adapter"
        $errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'AD FS/Admin'; Level = 2; StartTime = (Get-Date).AddMinutes(-15) } -ErrorAction SilentlyContinue)
        "{0}: adfssrv={1} GAC={2} AD FS/Admin errors (15 min)={3}" -f $env:COMPUTERNAME, $svc, $gac, $errs.Count
        $errs | Select-Object -First 3 | ForEach-Object { "   [$($_.Id)] " + ($_.Message -split "`n")[0] }
    }
}
