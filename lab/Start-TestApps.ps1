<#
.SYNOPSIS
  Starts both lab test apps on this PC (in the background) and prints their URLs.
    https://localhost:44301  Research Portal  (captcha scoped here)
    https://localhost:44302  Control App      (no captcha)
  Stop them with: Get-Process TestApp | Stop-Process
#>
$ErrorActionPreference = 'Stop'
$proj = Join-Path $PSScriptRoot 'TestApp\TestApp.csproj'
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) { $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }

& $dotnet build $proj --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'TestApp build failed.' }
$exe = Join-Path $PSScriptRoot 'TestApp\bin\Debug\net8.0\TestApp.exe'
$logs = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null

Get-Process TestApp -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($app in 'Research', 'Control') {
    # Through cmd.exe with shell-execute: the app inherits no handles from this PowerShell, so a
    # caller that captures our output is not kept waiting for the apps to exit.
    $log = Join-Path $logs "testapp-$app.log"
    Start-Process -FilePath cmd.exe -ArgumentList "/c `"`"$exe`" --App $app > `"$log`" 2>&1`"" -WindowStyle Hidden
}

# Wait until both answer.
$deadline = (Get-Date).AddSeconds(30)
foreach ($port in 44301, 44302) {
    do {
        $up = $false
        try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('localhost', $port); $up = $true; $c.Close() } catch { Start-Sleep -Milliseconds 500 }
    } until ($up -or (Get-Date) -gt $deadline)
    if (-not $up) { throw "Test app on port $port did not start; see $logs\testapp-*.log" }
}
Write-Host 'Research Portal: https://localhost:44301  (should show the photo after sign-in)'
Write-Host 'Control App:     https://localhost:44302  (should NOT)'
