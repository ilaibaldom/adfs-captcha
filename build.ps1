<#
.SYNOPSIS
  Builds the PhotoTagCaptcha AD FS adapter, runs the local smoke tests, and stages dist\.

.DESCRIPTION
  Output: dist\  -> copy this whole folder to each AD FS server.
    PhotoTagCaptcha.Adapter.dll
    Install-PhotoTagCaptcha.ps1, Enable-PhotoTagCaptchaForApp.ps1,
    Disable-PhotoTagCaptchaForApp.ps1, Uninstall-PhotoTagCaptcha.ps1

  Compiles against lib\Microsoft.IdentityServer.Web.dll if present (copy it from
  C:\Windows\ADFS on an AD FS server), otherwise against the reference stub in src\.
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Get-Dotnet {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'))) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw 'The .NET SDK was not found. Install it with: winget install Microsoft.DotNet.SDK.8'
}

function Initialize-Keys {
    $keys = Join-Path $root 'keys'
    New-Item -ItemType Directory -Force $keys | Out-Null

    $snk = Join-Path $keys 'PhotoTagCaptcha.snk'
    if (-not (Test-Path $snk)) {
        Write-Warning "Creating a new strong-name key at $snk. Keep this file: AD FS registers the adapter by its public key token."
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 1024
        [IO.File]::WriteAllBytes($snk, $rsa.ExportCspBlob($true))
    }

    $msKey = Join-Path $keys 'ms-31bf3856ad364e35.publickey'
    if (-not (Test-Path $msKey)) {
        # Any .NET Framework assembly with token 31bf3856ad364e35 carries the same public key.
        $src = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.Web.Extensions.dll'
        $pk = [Reflection.AssemblyName]::GetAssemblyName($src).GetPublicKey()
        [IO.File]::WriteAllBytes($msKey, $pk)
    }
}

$dotnet = Get-Dotnet
Initialize-Keys

$realAdfs = Join-Path $root 'lib\Microsoft.IdentityServer.Web.dll'
if (Test-Path $realAdfs) {
    Write-Host "Compiling against the real AD FS assembly: $realAdfs" -ForegroundColor Cyan
} else {
    Write-Host 'Compiling against the reference stub (lib\Microsoft.IdentityServer.Web.dll not found).' -ForegroundColor Cyan
}

& $dotnet build (Join-Path $root 'src\PhotoTagCaptcha.Adapter\PhotoTagCaptcha.Adapter.csproj') -c $Configuration --nologo -v minimal
if ($LASTEXITCODE -ne 0) { throw 'Adapter build failed.' }

# Keep the stub honest: when the real assembly is available, it must match the stub exactly
# (the stub is what everyone without server access compiles against).
if (Test-Path $realAdfs) {
    & $dotnet build (Join-Path $root 'src\Microsoft.IdentityServer.Web.Stub\Microsoft.IdentityServer.Web.Stub.csproj') -c Release --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw 'Stub build failed.' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Compare-AdfsStub.ps1') -RealDll $realAdfs
    if ($LASTEXITCODE -ne 0) { throw 'The reference stub does not match the real AD FS assembly. Fix src\Microsoft.IdentityServer.Web.Stub before shipping a stub-built DLL.' }
}

$dll = Join-Path $root "src\PhotoTagCaptcha.Adapter\bin\$Configuration\net472\PhotoTagCaptcha.Adapter.dll"

# Verify identity + the AD FS reference that will be bound at runtime.
$name = [Reflection.AssemblyName]::GetAssemblyName($dll)
$token = ($name.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') }) -join ''
if (-not $token) { throw 'Adapter is not strong-named; AD FS cannot load it from the GAC.' }

$asm = [Reflection.Assembly]::ReflectionOnlyLoad([IO.File]::ReadAllBytes($dll))
$adfsRef = $asm.GetReferencedAssemblies() | Where-Object Name -eq 'Microsoft.IdentityServer.Web'
if (-not $adfsRef) { throw 'Adapter has no reference to Microsoft.IdentityServer.Web.' }
$refToken = ($adfsRef.GetPublicKeyToken() | ForEach-Object { $_.ToString('x2') }) -join ''
if ($refToken -ne '31bf3856ad364e35') { throw "Unexpected AD FS reference token '$refToken'." }

Write-Host ''
Write-Host "Adapter : $($name.FullName)"
Write-Host "AD FS   : $($adfsRef.FullName)"
Write-Host "TypeName: PhotoTagCaptcha.PhotoTagAdapter, $($name.FullName)"

if (-not $SkipTests) {
    Write-Host ''
    Write-Host 'Running local smoke tests...' -ForegroundColor Cyan
    $harness = Join-Path $root 'tools\PreviewHarness\PreviewHarness.csproj'
    & $dotnet build $harness -c $Configuration --nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw 'Preview harness build failed.' }
    & $dotnet run --project $harness -c $Configuration --no-build -- (Join-Path $root 'out')
    if ($LASTEXITCODE -ne 0) { throw 'Smoke tests failed.' }
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Copy-Item $dll $dist -Force
Copy-Item (Join-Path $root 'deploy\*.ps1') $dist -Force
Copy-Item (Join-Path $root 'deploy\*.json') $dist -Force

Write-Host ''
Write-Host "Staged to $dist" -ForegroundColor Green
Get-ChildItem $dist | ForEach-Object { Write-Host "  $($_.Name)" }
