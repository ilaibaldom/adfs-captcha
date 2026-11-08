<#
.SYNOPSIS
  Lab: demonstrates the MFA-bypass risk and verifies the application guard on both nodes.
  Expects the adapter installed and scoped to ResearchPortal, with the guard OFF (no
  allowedApplications) at the start.

  1. Control App is made to require MFA too (as "another MFA app" in production would).
     Guard OFF -> Control users get the photo and can pass MFA with one click   (the risk).
  2. Guard ON (allowedApplications = Research Web API, diagnostics on).
     Research -> photo (allowed);  Control -> refused, no claim               (the fix).
     Research with the photo missing -> still fail-open.
  3. Control back to 'Permit everyone' -> password only again.
  4. Diagnostics off again; prints what AD FS passed the adapter (event 1900).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabConfig.ps1')
Assert-LabTestApps
$cred = Get-LabCredential
$test = Join-Path $PSScriptRoot 'SignInTest\SignInTest.csproj'
$nodes = [ordered]@{ 'LAB-ADFS01' = '192.168.77.11'; 'LAB-ADFS02' = '192.168.77.12' }
$photoPath = 'C:\PhotoTagCaptcha\photos\research-001.jpg'
$researchApi = $Lab.Apps['Research'].Resource
$failures = 0
function Step($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }

function Run([string]$label, [string]$app, [string]$expect) {
    foreach ($vm in $nodes.Keys) {
        $out = & dotnet run --project $test --no-build -- --app $app --expect $expect --node $nodes[$vm]
        Write-Host ("  {0,-28} {1}: {2}" -f $label, $vm, ($out | Select-Object -Last 1))
        if ($LASTEXITCODE -ne 0) { $script:failures++ }
    }
}

function Wait-Sync {
    $since = Get-Date
    Step 'Waiting for LAB-ADFS02 config sync'
    do { Start-Sleep 15; $last = Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { (Get-AdfsSyncProperties).LastSyncTime } } until ($last -gt $since)
}

function Set-Config([hashtable]$cfg) {
    Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ArgumentList ($cfg | ConvertTo-Json) -ScriptBlock {
        param($json)
        Set-Location C:\PhotoTagCaptcha
        Set-Content .\phototag-config.json $json -Encoding UTF8      # with BOM, on purpose
        .\Set-PhotoTagCaptchaConfig.ps1 -ConfigFile .\phototag-config.json
    } | Out-Null
    Wait-Sync
    Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Install-PhotoTagCaptcha.ps1 -GacOnly } | Out-Null
    foreach ($vm in $nodes.Keys) {
        Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
            $e = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PhotoTagCaptcha'; Id = 1000 } -MaxEvents 1
            "  $env:COMPUTERNAME config: " + ($e.Message -replace '^.*Config: ', '')
        }
    }
}

$photoUrl = ([Uri]$photoPath).AbsoluteUri

# 0. Known starting point: guard OFF
Step 'Starting point: guard OFF (no allowedApplications)'
Set-Config @{ photoUrl = $photoUrl; displayMode = 'popup' }

# 1. The risk
Step 'Making Control App require MFA too (Enable-PhotoTagCaptchaForApp -ApplicationGroupIdentifier ControlApp)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Enable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier ControlApp } | Out-Null
Wait-Sync
Step 'Guard OFF: Control App users are offered the photo (one click instead of real MFA)'
Run 'guard OFF, Control+MFA' 'Control' 'captcha'

# 2. The fix
Step "Guard ON: allowedApplications = $researchApi (diagnostics on)"
Set-Config @{ photoUrl = $photoUrl; displayMode = 'popup'; allowedApplications = @($researchApi); diagnostics = $true }
$guardStart = Get-Date
Run 'guard ON, Research' 'Research' 'captcha'
Run 'guard ON, Control+MFA' 'Control' 'blocked'

Step 'Guard ON + photo missing: Research still fails open, Control still refused'
foreach ($vm in $nodes.Keys) { Invoke-Command -VMName $vm -Credential $cred -ArgumentList $photoPath -ScriptBlock { param($p) Rename-Item $p "$p.away" } }
Run 'photo missing, Research' 'Research' 'skip'
Run 'photo missing, Control+MFA' 'Control' 'blocked'
foreach ($vm in $nodes.Keys) { Invoke-Command -VMName $vm -Credential $cred -ArgumentList $photoPath -ScriptBlock { param($p) Rename-Item "$p.away" $p } }

foreach ($vm in $nodes.Keys) {
    Invoke-Command -VMName $vm -Credential $cred -ArgumentList $guardStart -ScriptBlock {
        param($since)
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PhotoTagCaptcha'; Id = 2200; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue |
            ForEach-Object { "  $env:COMPUTERNAME event 2200 [$($_.LevelDisplayName)]: $($_.Message)" }
    }
}
Step 'What AD FS passes the adapter (event 1900, LAB-ADFS01)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ArgumentList $guardStart -ScriptBlock {
    param($since)
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PhotoTagCaptcha'; Id = 1900; StartTime = $since } -ErrorAction SilentlyContinue | Sort-Object TimeCreated
    $ev | Where-Object { $_.Message -like 'IsAvailableForUser*' } | Select-Object -First 1 | ForEach-Object { $_.Message }
    $ev | Where-Object { $_.Message -like 'BeginAuthentication*' } | Select-Object -First 1 | ForEach-Object { $_.Message }
}

# 3. Control back to normal
Step 'Restoring Control App policy (Disable-PhotoTagCaptchaForApp -ApplicationGroupIdentifier ControlApp)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Disable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier ControlApp } | Out-Null
Step 'Diagnostics off'
Set-Config @{ photoUrl = $photoUrl; displayMode = 'popup'; allowedApplications = @($researchApi) }
Run 'final, Research' 'Research' 'captcha'
Run 'final, Control' 'Control' 'none'

foreach ($vm in $nodes.Keys) {
    Invoke-Command -VMName $vm -Credential $cred -ArgumentList $guardStart -ScriptBlock {
        param($since) "  $env:COMPUTERNAME AD FS/Admin errors during test: " + @(Get-WinEvent -FilterHashtable @{ LogName = 'AD FS/Admin'; Level = 2; StartTime = $since.AddMinutes(-12) } -ErrorAction SilentlyContinue).Count
    }
}
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock { & C:\PhotoTagCaptcha\Get-PhotoTagCaptchaScope.ps1 | Out-Null }
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'Guard verified on both nodes.' -ForegroundColor Green
