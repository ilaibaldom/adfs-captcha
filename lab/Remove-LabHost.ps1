#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Undoes Prepare-Host.ps1: removes lab VMs, the AdfsLab switch/NAT, hosts entries,
  C:\HyperV\AdfsLab, and (with -RemoveGroupMembership) the Hyper-V Administrators membership.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$UserName = "$env:COMPUTERNAME\Ilai",
    [switch]$RemoveGroupMembership
)

$ErrorActionPreference = 'Stop'

Get-VM -Name 'LAB-*' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($PSCmdlet.ShouldProcess($_.Name, 'Remove VM')) {
        Stop-VM $_ -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM $_ -Force
    }
}
if ((Get-NetNat -Name 'AdfsLabNat' -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('AdfsLabNat', 'Remove NAT')) {
    Remove-NetNat -Name 'AdfsLabNat' -Confirm:$false
}
if ((Get-VMSwitch -Name 'AdfsLab' -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('AdfsLab', 'Remove switch')) {
    Remove-VMSwitch -Name 'AdfsLab' -Force
}

$hostsFile = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$kept = Get-Content $hostsFile | Where-Object { $_ -notmatch '#\s*AdfsLab\s*$' }
if ($PSCmdlet.ShouldProcess($hostsFile, 'Remove AdfsLab entries')) { Set-Content $hostsFile $kept -Encoding ASCII }

if ((Test-Path 'C:\HyperV\AdfsLab') -and $PSCmdlet.ShouldProcess('C:\HyperV\AdfsLab', 'Delete VM storage')) {
    Remove-Item 'C:\HyperV\AdfsLab' -Recurse -Force
}

if ($RemoveGroupMembership -and $PSCmdlet.ShouldProcess($UserName, 'Remove from Hyper-V Administrators')) {
    Remove-LocalGroupMember -SID 'S-1-5-32-578' -Member $UserName -ErrorAction SilentlyContinue
}
Write-Host 'Lab removed from this host.'
