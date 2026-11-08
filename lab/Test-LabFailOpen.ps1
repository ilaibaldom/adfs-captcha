<#
.SYNOPSIS
  Lab: verifies the fail-open behavior on both AD FS nodes. Expects the adapter installed and
  scoped to ResearchPortal (Deploy-LabAdapter.ps1).

  1. Points the adapter at a photo FILE on each node (Set-PhotoTagCaptchaConfig.ps1, production way).
  2. File present  -> Research shows that photo (captcha);         Control unaffected.
  3. File deleted  -> Research signs in WITHOUT captcha (skip);    event 2000 logged on the node.
  4. File restored -> captcha is back.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabConfig.ps1')
Assert-LabTestApps
$cred = Get-LabCredential
$test = Join-Path $PSScriptRoot 'SignInTest\SignInTest.csproj'
$photoSrc = Join-Path (Split-Path $PSScriptRoot) 'src\PhotoTagCaptcha.Adapter\Assets\photo.jpg'
$nodes = [ordered]@{ 'LAB-ADFS01' = '192.168.77.11'; 'LAB-ADFS02' = '192.168.77.12' }
$photoPath = 'C:\PhotoTagCaptcha\photos\research-001.jpg'
$failures = 0
function Step($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }

function Test-Apps([string]$label, [string]$researchExpect) {
    foreach ($vm in $nodes.Keys) {
        foreach ($t in @(@{ App = 'Research'; Expect = $researchExpect }, @{ App = 'Control'; Expect = 'none' })) {
            $out = & dotnet run --project $test --no-build -- --app $t.App --expect $t.Expect --node $nodes[$vm]
            $photoLine = $out | Where-Object { $_ -match 'PhotoTagCaptcha page shown' }
            Write-Host ("  {0,-16} {1}: {2}{3}" -f $label, $vm, ($out | Select-Object -Last 1), $(if ($photoLine) { "  [$($photoLine.Trim())]" }))
            if ($LASTEXITCODE -ne 0) { $script:failures++ }
        }
    }
}

function Wait-Sync {
    $since = Get-Date
    Step 'Waiting for LAB-ADFS02 config sync'
    do { Start-Sleep 15; $last = Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { (Get-AdfsSyncProperties).LastSyncTime } } until ($last -gt $since)
}

# 1. Photo file on both nodes + config pointing at it
Step "Copying photo to $photoPath on both nodes"
foreach ($vm in $nodes.Keys) {
    $s = New-PSSession -VMName $vm -Credential $cred
    try {
        Invoke-Command -Session $s { New-Item -ItemType Directory -Force C:\PhotoTagCaptcha\photos | Out-Null }
        Copy-Item -ToSession $s $photoSrc $photoPath -Force
    } finally { Remove-PSSession $s }
}
Step 'Set-PhotoTagCaptchaConfig on the primary (photoUrl = file, popup)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ArgumentList $photoPath -ScriptBlock {
    param($p)
    Set-Location C:\PhotoTagCaptcha
    @{ photoUrl = ([Uri]$p).AbsoluteUri; timeoutMs = 3000; displayMode = 'popup' } | ConvertTo-Json | Set-Content .\phototag-config.json -Encoding UTF8
    .\Set-PhotoTagCaptchaConfig.ps1 -ConfigFile .\phototag-config.json
} | Out-Null
Wait-Sync
Step 'LAB-ADFS02: Install -GacOnly (restart to load the new config)'
Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Install-PhotoTagCaptcha.ps1 -GacOnly } | Out-Null
foreach ($vm in $nodes.Keys) {
    Invoke-Command -VMName $vm -Credential $cred -ScriptBlock {
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PhotoTagCaptcha'; Id = 1000 } -MaxEvents 1
        "  $env:COMPUTERNAME active config: " + ($e.Message -replace '^.*Config: ', '')
    }
}

# 2. Photo present
Step 'Photo file present -> expect the captcha with photo research-001'
Test-Apps 'file present' 'captcha'

# 3. Photo missing
Step 'Deleting the photo file on both nodes'
foreach ($vm in $nodes.Keys) { Invoke-Command -VMName $vm -Credential $cred -ArgumentList $photoPath -ScriptBlock { param($p) Remove-Item $p -Force } }
$skipStart = Get-Date
Test-Apps 'file missing' 'skip'
foreach ($vm in $nodes.Keys) {
    Invoke-Command -VMName $vm -Credential $cred -ArgumentList $skipStart -ScriptBlock {
        param($since)
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'PhotoTagCaptcha'; StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in 2000, 2001, 1200, 3001 } | Sort-Object TimeCreated | Select-Object -First 2 |
            ForEach-Object { "  $env:COMPUTERNAME event $($_.Id) [$($_.LevelDisplayName)]: $($_.Message)" }
    }
}

# 4. Photo restored
Step 'Restoring the photo file on both nodes'
foreach ($vm in $nodes.Keys) {
    $s = New-PSSession -VMName $vm -Credential $cred
    try { Copy-Item -ToSession $s $photoSrc $photoPath -Force } finally { Remove-PSSession $s }
}
Test-Apps 'file restored' 'captcha'

foreach ($vm in $nodes.Keys) {
    Invoke-Command -VMName $vm -Credential $cred -ArgumentList $skipStart -ScriptBlock {
        param($since) "  $env:COMPUTERNAME AD FS/Admin errors during test: " + @(Get-WinEvent -FilterHashtable @{ LogName = 'AD FS/Admin'; Level = 2; StartTime = $since.AddMinutes(-15) } -ErrorAction SilentlyContinue).Count
    }
}
if ($failures) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'Fail-open verified on both nodes.' -ForegroundColor Green
