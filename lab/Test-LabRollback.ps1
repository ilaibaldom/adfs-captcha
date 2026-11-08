<#
.SYNOPSIS
  Lab: rolls the captcha back with the production scripts and checks both apps on both nodes
  after each step. Expects the adapter to be installed and scoped to ResearchPortal.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabConfig.ps1')
Assert-LabTestApps
$cred = Get-LabCredential
$test = Join-Path $PSScriptRoot 'SignInTest\SignInTest.csproj'
$failures = 0
$started = Get-Date
function Step($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }

function Wait-Sync {
    $since = Get-Date
    Step 'Waiting for LAB-ADFS02 to sync from the primary'
    do {
        Start-Sleep 15
        $last = Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { (Get-AdfsSyncProperties).LastSyncTime }
    } until ($last -gt $since)
    Step "LAB-ADFS02 synced at $($last.ToString('HH:mm:ss'))"
}

function Test-BothApps([string]$label) {
    foreach ($node in '192.168.77.11', '192.168.77.12') {
        foreach ($app in 'Research', 'Control') {
            $out = & dotnet run --project $test --no-build -- --app $app --expect none --node $node
            $line = $out | Select-Object -Last 1
            Write-Host ("  {0,-26} node {1}: {2}" -f $label, $node, $line)
            if ($LASTEXITCODE -ne 0) { $script:failures++ }
        }
    }
}

Step 'Disable-PhotoTagCaptchaForApp -ApplicationGroupIdentifier ResearchPortal (primary)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Disable-PhotoTagCaptchaForApp.ps1 -ApplicationGroupIdentifier ResearchPortal }
Wait-Sync
Test-BothApps 'after Disable'

Step 'Uninstall-PhotoTagCaptcha (primary: unregister + GAC remove)'
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Uninstall-PhotoTagCaptcha.ps1 }
Wait-Sync
Step 'Uninstall-PhotoTagCaptcha -GacOnly (secondary, after its sync)'
Invoke-Command -VMName LAB-ADFS02 -Credential $cred -ScriptBlock { Set-Location C:\PhotoTagCaptcha; .\Uninstall-PhotoTagCaptcha.ps1 -GacOnly }
Test-BothApps 'after Uninstall'

Step 'State on both nodes'
foreach ($vm in 'LAB-ADFS01', 'LAB-ADFS02') {
    Invoke-Command -VMName $vm -Credential $cred -ArgumentList $started -ScriptBlock {
        param($since)
        # Count DLL files: Windows leaves the empty assembly folder behind after GacRemove.
        '{0}: adfssrv={1} DLL-in-GAC={2} provider-in-config={3} AD FS/Admin errors during rollback={4}' -f $env:COMPUTERNAME, (Get-Service adfssrv).Status,
            [bool](Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\PhotoTagCaptcha.Adapter" -Recurse -Filter *.dll -ErrorAction SilentlyContinue),
            [bool](Get-AdfsAuthenticationProvider -Name PhotoTagCaptcha -WarningAction SilentlyContinue -ErrorAction SilentlyContinue),
            @(Get-WinEvent -FilterHashtable @{ LogName = 'AD FS/Admin'; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue).Count
    }
}
Invoke-Command -VMName LAB-ADFS01 -Credential $cred -ScriptBlock {
    "Research Portal Web API policy: " + (Get-AdfsWebApiApplication -Name 'Research Portal - Web API').AccessControlPolicyName
    "Additional providers: '" + (((Get-AdfsGlobalAuthenticationPolicy).AdditionalAuthenticationProvider) -join ',') + "'"
}
if ($failures) { Write-Host "$failures sign-in check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'Rollback verified: both apps back to baseline on both nodes.' -ForegroundColor Green
