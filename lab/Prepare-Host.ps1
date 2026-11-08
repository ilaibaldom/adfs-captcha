#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time host preparation for the AD FS 2019 lab. Run ONCE from an elevated PowerShell,
  then sign out of Windows and back in (group membership only applies to new logons).

.DESCRIPTION
  Changes made on this PC (all reversible with Remove-LabHost.ps1):
    1. Adds <UserName> to the local "Hyper-V Administrators" group, so lab VMs can be created
       and managed without an elevated session. Grants control over Hyper-V only, not local admin.
    2. Creates an internal Hyper-V switch "AdfsLab" with host address 192.168.77.1/24 and a
       NAT ("AdfsLabNat") so lab VMs reach the internet (Windows evaluation activation)
       but are not reachable from your real network.
    3. Adds hosts-file entries so this PC's browser can reach the lab:
         192.168.77.11  adfs.adfslab.test
    4. Creates C:\HyperV\AdfsLab for VM disks, writable by <UserName>.
#>
[CmdletBinding()]
param(
    [string]$UserName = "$env:COMPUTERNAME\Ilai"
)

$ErrorActionPreference = 'Stop'
$switchName = 'AdfsLab'
$hostIp     = '192.168.77.1'
$prefix     = '192.168.77.0/24'
$natName    = 'AdfsLabNat'
$labRoot    = 'C:\HyperV\AdfsLab'
$hostsFile  = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$hostsLines = @('192.168.77.11  adfs.adfslab.test  # AdfsLab')

# 1. Hyper-V Administrators (well-known SID, name is localized)
$group = Get-LocalGroup -SID 'S-1-5-32-578'
if (-not (Get-LocalGroupMember -Group $group | Where-Object Name -eq $UserName)) {
    Add-LocalGroupMember -Group $group -Member $UserName
    Write-Host "Added $UserName to '$($group.Name)'. Sign out and back in for it to apply." -ForegroundColor Yellow
} else {
    Write-Host "$UserName is already in '$($group.Name)'."
}

# 2. Internal switch + host IP + NAT
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    Write-Host "Created internal switch '$switchName'."
}
$ifAlias = "vEthernet ($switchName)"
if (-not (Get-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $hostIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $hostIp -PrefixLength 24 | Out-Null
    Write-Host "Assigned $hostIp/24 to '$ifAlias'."
}
if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
    Write-Host "Created NAT '$natName' for $prefix."
}

# 3. hosts file
$current = Get-Content $hostsFile -ErrorAction SilentlyContinue
foreach ($line in $hostsLines) {
    $name = ($line -split '\s+')[1]
    if (-not ($current | Where-Object { $_ -match "^\s*[\d\.]+\s+$([regex]::Escape($name))(\s|$)" })) {
        Add-Content -Path $hostsFile -Value $line -Encoding ASCII
        Write-Host "hosts: $line"
    }
}

# 4. VM storage folder
New-Item -ItemType Directory -Force $labRoot | Out-Null
$acl = Get-Acl $labRoot
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($UserName, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $labRoot $acl
Write-Host "VM storage: $labRoot"

Write-Host ''
Write-Host 'Host is ready. Sign out of Windows and back in, then tell Claude to continue.' -ForegroundColor Green
