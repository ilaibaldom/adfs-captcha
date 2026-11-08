<#
.SYNOPSIS
  Compares the reference stub with a real Microsoft.IdentityServer.Web.dll copied from an AD FS
  server: every public interface in Microsoft.IdentityServer.Web.Authentication.External, its base
  interfaces and member signatures. Exit code 0 = identical.

.EXAMPLE
  .\tools\Compare-AdfsStub.ps1 -RealDll .\lib\Microsoft.IdentityServer.Web.dll
#>
param(
    [Parameter(Mandatory)][string]$RealDll,
    [string]$StubDll,
    [switch]$DumpOnly   # internal: dump one assembly (both share an identity, so each runs in its own process)
)
# ($PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1)
if (-not $StubDll) { $StubDll = Join-Path $PSScriptRoot '..\src\Microsoft.IdentityServer.Web.Stub\bin\Release\net472\Microsoft.IdentityServer.Web.dll' }

if ($DumpOnly) {
    [AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve({ param($s, $e) try { [Reflection.Assembly]::ReflectionOnlyLoad($e.Name) } catch { $null } })
    $asm = [Reflection.Assembly]::ReflectionOnlyLoad([IO.File]::ReadAllBytes((Resolve-Path $RealDll).Path))
    $types = try { $asm.GetTypes() } catch [Reflection.ReflectionTypeLoadException] { $_.Exception.Types | Where-Object { $_ } }
    $flags = [Reflection.BindingFlags]'Public,Instance,DeclaredOnly'
    foreach ($t in ($types | Where-Object { $_.IsInterface -and $_.IsPublic -and $_.Namespace -eq 'Microsoft.IdentityServer.Web.Authentication.External' })) {
        '{0} : {1}' -f $t.Name, ((@($t.GetInterfaces() | ForEach-Object Name) | Sort-Object) -join ',')
        foreach ($m in $t.GetMembers($flags)) {
            if ($m.MemberType -eq 'Property') {
                '{0}.prop {1} {2}' -f $t.Name, $m.PropertyType.FullName, $m.Name
            } elseif ($m.MemberType -eq 'Method') {
                '{0}.{1} {2}({3})' -f $t.Name, $m.ReturnType.FullName, $m.Name, (($m.GetParameters() | ForEach-Object { $_.ParameterType.FullName }) -join ',')
            }
        }
    }
    return
}

$self = $PSCommandPath
$real = @(powershell -NoProfile -ExecutionPolicy Bypass -File $self -RealDll $RealDll -DumpOnly | Sort-Object)
$stub = @(powershell -NoProfile -ExecutionPolicy Bypass -File $self -RealDll $StubDll -DumpOnly | Sort-Object)
if (-not $real.Count -or -not $stub.Count) { Write-Error "Could not read interfaces (real: $($real.Count), stub: $($stub.Count))."; exit 2 }

"Real: $($real.Count) lines   Stub: $($stub.Count) lines"
$diff = Compare-Object $real $stub
if ($diff) {
    $diff | ForEach-Object { '{0} {1}' -f $(if ($_.SideIndicator -eq '<=') { 'ONLY IN REAL:' } else { 'ONLY IN STUB:' }), $_.InputObject }
    exit 1
}
'IDENTICAL: every public interface, base interface and member signature matches.'
exit 0
