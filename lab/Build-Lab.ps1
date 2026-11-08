<#
.SYNOPSIS
  Builds the AD FS 2019 lab: LAB-DC01 (adfslab.test), LAB-ADFS01 + LAB-ADFS02 (WID farm,
  federation service adfs.adfslab.test) and two OIDC application groups.

.DESCRIPTION
  Runs on this PC as a member of "Hyper-V Administrators" (no elevation). Prerequisites:
  lab\Prepare-Host.ps1 has been run and the eval VHD has been downloaded.
  All guest configuration goes through PowerShell Direct (Invoke-Command -VMName), so the
  VMs need no network access from the host for setup. Every phase is idempotent; re-run
  the script (or one -Phase) after a failure.

  Phases: Vms, DC, Adfs01, Adfs02, Apps   (default: all, in order)
#>
[CmdletBinding()]
param(
    [ValidateSet('Vms', 'DC', 'Adfs01', 'Adfs02', 'Apps')]
    [string[]]$Phase = @('Vms', 'DC', 'Adfs01', 'Adfs02', 'Apps')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabConfig.ps1')
New-Item -ItemType Directory -Force $Lab.LogDir | Out-Null
Start-Transcript -Path (Join-Path $Lab.LogDir ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

function Step($m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan }

# --------------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------------
function New-IsoFile([string]$SourceDir, [string]$Path, [string]$Label) {
    if (-not ('LabIsoWriter' -as [type])) {
        $cp = New-Object CodeDom.Compiler.CompilerParameters
        $cp.CompilerOptions = '/unsafe'
        Add-Type -CompilerParameters $cp -TypeDefinition @'
public static class LabIsoWriter {
    public unsafe static void Write(string path, object stream, int blockSize, int totalBlocks) {
        int read = 0; byte[] buf = new byte[blockSize]; var ptr = (System.IntPtr)(&read);
        var input = (System.Runtime.InteropServices.ComTypes.IStream)stream;
        using (var output = System.IO.File.Create(path)) {
            while (totalBlocks-- > 0) { input.Read(buf, blockSize, ptr); output.Write(buf, 0, read); }
        }
    }
}
'@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.VolumeName = $Label
    $fsi.Root.AddTree($SourceDir, $false)
    $img = $fsi.CreateResultImage()
    [LabIsoWriter]::Write($Path, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
}

function New-UnattendIso([string]$VmName) {
    $s = Get-LabSecrets
    $tz = (Get-TimeZone).Id
    $comp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $comp>
      <ComputerName>$VmName</ComputerName>
      <TimeZone>$tz</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $comp>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $comp>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$($s.AdminPassword)</Value><PlainText>true</PlainText></AdministratorPassword>
      </UserAccounts>
      <TimeZone>$tz</TimeZone>
    </component>
  </settings>
</unattend>
"@
    $work = Join-Path $Lab.Root "unattend\$VmName"
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Content -Path (Join-Path $work 'Autounattend.xml') -Value $xml -Encoding UTF8
    Copy-Item (Join-Path $work 'Autounattend.xml') (Join-Path $work 'unattend.xml')
    $iso = Join-Path $Lab.Root "unattend\$VmName.iso"
    if (Test-Path $iso) { Remove-Item $iso -Force }
    New-IsoFile -SourceDir $work -Path $iso -Label 'UNATTEND'
    $iso
}

# An unqualified "Administrator" resolves to the DOMAIN account once a machine has joined
# (even before it reboots), so local accounts are always qualified with the VM name.
function Resolve-LabCred([string]$VmName, [PSCredential]$Credential) {
    if ($Credential.UserName -match '\\') { return $Credential }
    New-Object PSCredential ("$VmName\$($Credential.UserName)", $Credential.Password)
}

function Wait-LabVm([string]$VmName, [PSCredential]$Credential, [int]$TimeoutMinutes = 25) {
    $Credential = Resolve-LabCred $VmName $Credential
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $n = Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ($n -eq $VmName) { return }
        } catch { }
        Start-Sleep -Seconds 15
    }
    throw "$VmName did not become reachable via PowerShell Direct as $($Credential.UserName) within $TimeoutMinutes minutes."
}

function Restart-LabVm([string]$VmName, [PSCredential]$Credential, [PSCredential]$BootCheckCredential = $Credential) {
    $Credential = Resolve-LabCred $VmName $Credential
    $BootCheckCredential = Resolve-LabCred $VmName $BootCheckCredential
    # Graceful reboot through the guest OS. Restart-VM defaults to a HARD reset, which right after
    # Install-ADDSForest prevented the domain's DNS zones from being created.
    $boot = Invoke-Command -VMName $VmName -Credential $BootCheckCredential -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    Restart-VM -Name $VmName -Type Reboot -Force
    $deadline = (Get-Date).AddMinutes(25)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        try {
            $now = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
            if ($now -ne $boot) { return }
        } catch { }
    }
    throw "$VmName did not come back from reboot as $($Credential.UserName) within 25 minutes."
}

function Invoke-Lab([string]$VmName, [PSCredential]$Credential, [scriptblock]$Script, [object[]]$ArgumentList = @()) {
    Invoke-Command -VMName $VmName -Credential (Resolve-LabCred $VmName $Credential) -ScriptBlock $Script -ArgumentList $ArgumentList -ErrorAction Stop
}

function Set-GuestNetwork([string]$VmName, [PSCredential]$Credential, [string]$Ip, [string[]]$Dns) {
    Invoke-Lab $VmName $Credential {
        param($ip, $prefix, $gw, $dns)
        $nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue)) {
            Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
            Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
            Remove-NetRoute -InterfaceIndex $nic.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $dns
        # Lab only: allow ping between nodes.
        Enable-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In' -ErrorAction SilentlyContinue
    } @($Ip, $Lab.PrefixLength, $Lab.Gateway, $Dns)
}

$secrets  = Get-LabSecrets
$localCred  = Get-LabCredential -Local
$domainCred = Get-LabCredential
$dcIp = $Lab.Vms['LAB-DC01'].Ip

# --------------------------------------------------------------------------------------------
# Phase: VMs
# --------------------------------------------------------------------------------------------
if ($Phase -contains 'Vms') {
    Step 'Checking host prerequisites'
    if (-not (Get-VMSwitch -Name $Lab.Switch -ErrorAction SilentlyContinue)) { throw "Switch '$($Lab.Switch)' missing. Run lab\Prepare-Host.ps1 (elevated) first." }

    if (-not (Test-Path $Lab.BaseVhd)) {
        if (-not (Test-Path $Lab.MediaVhd)) { throw "Base VHD not found at $($Lab.MediaVhd)." }
        Step 'Moving base VHD into lab storage'
        New-Item -ItemType Directory -Force (Split-Path $Lab.BaseVhd) | Out-Null
        Move-Item $Lab.MediaVhd $Lab.BaseVhd
        Set-ItemProperty $Lab.BaseVhd -Name IsReadOnly -Value $true
    }

    foreach ($name in $Lab.Vms.Keys) {
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) { Step "$name exists"; continue }
        $cfg = $Lab.Vms[$name]
        Step "Creating $name"
        $vmDir = Join-Path $Lab.Root $name
        New-Item -ItemType Directory -Force $vmDir | Out-Null
        $disk = Join-Path $vmDir "$name.vhd"
        if (-not (Test-Path $disk)) { New-VHD -Path $disk -ParentPath $Lab.BaseVhd -Differencing | Out-Null }
        $iso = New-UnattendIso $name

        New-VM -Name $name -Generation 1 -MemoryStartupBytes ($cfg.MemoryMB * 1MB) -VHDPath $disk -SwitchName $Lab.Switch -Path $Lab.Root | Out-Null
        Set-VM -Name $name -ProcessorCount $cfg.Cpu -StaticMemory -AutomaticCheckpointsEnabled $false -AutomaticStopAction ShutDown -CheckpointType Standard
        Set-VMDvdDrive -VMName $name -Path $iso
        Enable-VMIntegrationService -VMName $name -Name 'Guest Service Interface'
        Start-VM -Name $name
    }

    foreach ($name in $Lab.Vms.Keys) {
        Step "Waiting for $name first boot (sysprep specialize + OOBE)"
        try { Wait-LabVm $name $localCred -TimeoutMinutes 20 }
        catch {
            # Already domain-joined from a previous run?
            Wait-LabVm $name $domainCred -TimeoutMinutes 2
        }
        Set-VMDvdDrive -VMName $name -Path $null
    }
}

# --------------------------------------------------------------------------------------------
# Phase: DC
# --------------------------------------------------------------------------------------------
if ($Phase -contains 'DC') {
    $vm = 'LAB-DC01'
    $isDc = $false
    try { $isDc = Invoke-Lab $vm $domainCred { [bool](Get-Service NTDS -ErrorAction SilentlyContinue) } } catch { }

    if (-not $isDc) {
        Step "$vm : network + AD DS role"
        Set-GuestNetwork $vm $localCred $dcIp @('127.0.0.1')
        Invoke-Lab $vm $localCred {
            param($domain, $netbios, $dsrm)
            Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
            Import-Module ADDSDeployment
            Install-ADDSForest -DomainName $domain -DomainNetbiosName $netbios -InstallDns `
                -SafeModeAdministratorPassword (ConvertTo-SecureString $dsrm -AsPlainText -Force) `
                -NoRebootOnCompletion -Force -WarningAction SilentlyContinue | Out-Null
        } @($Lab.Domain, $Lab.NetBios, $secrets.AdminPassword)
        Step "$vm : rebooting into domain controller"
        Restart-LabVm $vm $domainCred $localCred
    }

    Step "$vm : waiting for AD web services"
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $ready = $false
        try {
            $ready = Invoke-Lab $vm $domainCred {
                # The Server 2019 eval VHD ships with AD Web Services DISABLED; the AD cmdlets need it.
                if ((Get-CimInstance Win32_Service -Filter "Name='ADWS'").StartMode -eq 'Disabled') { Set-Service ADWS -StartupType Automatic }
                if ((Get-Service ADWS).Status -ne 'Running') { Start-Service ADWS -ErrorAction SilentlyContinue }
                try { [bool](Get-ADDomain) } catch { $false }
            }
        } catch { }
        if (-not $ready) { Start-Sleep 15 }
    } until ($ready -or (Get-Date) -gt $deadline)
    if (-not $ready) { throw 'AD did not come up on LAB-DC01.' }

    # DNS forwarders: whatever this PC uses, so lab VMs resolve internet names (eval activation).
    $forwarders = @(Get-DnsClientServerAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike 'vEthernet*' -and $_.ServerAddresses } |
        ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
    if (-not $forwarders) { $forwarders = @('1.1.1.1') }

    Step "$vm : DNS records, test users, KDS root key"
    Invoke-Lab $vm $domainCred {
        param($domain, $fsName, $fsIp, $userPwd, $forwarders)
        Import-Module ActiveDirectory, DnsServer
        foreach ($f in $forwarders) {
            if (-not ((Get-DnsServerForwarder).IPAddress.IPAddressToString -contains $f)) { Add-DnsServerForwarder -IPAddress $f -ErrorAction SilentlyContinue }
        }
        $label = $fsName.Split('.')[0]
        if (-not (Get-DnsServerResourceRecord -ZoneName $domain -Name $label -ErrorAction SilentlyContinue)) {
            Add-DnsServerResourceRecordA -ZoneName $domain -Name $label -IPv4Address $fsIp
        }
        $pwd = ConvertTo-SecureString $userPwd -AsPlainText -Force
        foreach ($u in @(@{ s = 'alice'; n = 'Alice Researcher' }, @{ s = 'bob'; n = 'Bob Analyst' })) {
            if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.s)'")) {
                New-ADUser -Name $u.n -DisplayName $u.n -SamAccountName $u.s -UserPrincipalName "$($u.s)@$domain" `
                    -AccountPassword $pwd -Enabled $true -PasswordNeverExpires $true
            }
        }
        if (-not (Get-KdsRootKey)) { Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null }
    } @($Lab.Domain, $Lab.FsName, $Lab.Vms['LAB-ADFS01'].Ip, $secrets.UserPassword, $forwarders)
}

# --------------------------------------------------------------------------------------------
# Domain join (shared by both AD FS nodes)
# --------------------------------------------------------------------------------------------
function Join-LabDomain([string]$vm) {
    # Joined AND rebooted => a DOMAIN logon works. Check whose token we actually got: local and
    # domain Administrator share a password, and Windows falls back to the local account when
    # the machine is not (yet) in the domain.
    $ok = $false
    # Netlogon\JoinDomain exists until the post-join reboot has happened.
    try {
        $ok = Invoke-Lab $vm $domainCred {
            param($nb)
            ((whoami) -like "$nb\*") -and -not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain')
        } @($Lab.NetBios.ToLower())
    } catch { }
    if ($ok) { return }

    # Joined but not rebooted yet (e.g. a previous run stopped in between): just reboot.
    $joined = Invoke-Lab $vm $localCred { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
    if ($joined) {
        Step "$vm : already joined, rebooting"
        Restart-LabVm $vm $domainCred $localCred
        return
    }

    Step "$vm : network + domain join"
    Set-GuestNetwork $vm $localCred $Lab.Vms[$vm].Ip @($dcIp)
    Invoke-Lab $vm $localCred {
        param($domain, $cred)
        # The NIC was reconfigured seconds ago; DC discovery can fail until it settles. Retry.
        for ($i = 1; $i -le 6; $i++) {
            try { Add-Computer -DomainName $domain -Credential $cred -Force -WarningAction SilentlyContinue -ErrorAction Stop; return }
            catch { if ($i -eq 6) { throw }; Clear-DnsClientCache; Start-Sleep -Seconds 15 }
        }
    } @($Lab.Domain, $domainCred)
    Restart-LabVm $vm $domainCred $localCred
}

# --------------------------------------------------------------------------------------------
# Phase: ADFS01 (primary)
# --------------------------------------------------------------------------------------------
if ($Phase -contains 'Adfs01') {
    $vm = 'LAB-ADFS01'
    Join-LabDomain $vm
    Join-LabDomain 'LAB-ADFS02'   # gMSA needs both computer objects

    Step 'LAB-DC01 : group managed service account'
    Invoke-Lab 'LAB-DC01' $domainCred {
        param($gmsa, $fsName)
        if (-not (Get-ADServiceAccount -Filter "Name -eq '$gmsa'")) {
            New-ADServiceAccount -Name $gmsa -DNSHostName $fsName -ServicePrincipalNames "http/$fsName" `
                -PrincipalsAllowedToRetrieveManagedPassword 'LAB-ADFS01$', 'LAB-ADFS02$'
        }
    } @($Lab.Gmsa, $Lab.FsName)

    $installed = Invoke-Lab $vm $domainCred { [bool](Get-Service adfssrv -ErrorAction SilentlyContinue) -and (Get-Service adfssrv).Status -eq 'Running' }
    if (-not $installed) {
        Step "$vm : TLS certificate + AD FS farm"
        Invoke-Lab $vm $domainCred {
            param($fsName, $netbios, $gmsa, $pfxPwd, $cred)
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$fsName" } | Select-Object -First 1
            if (-not $cert) {
                $cert = New-SelfSignedCertificate -DnsName $fsName, "certauth.$fsName" -CertStoreLocation Cert:\LocalMachine\My `
                    -KeyExportPolicy Exportable -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 `
                    -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -NotAfter (Get-Date).AddYears(3)
            }
            New-Item -ItemType Directory -Force C:\Lab | Out-Null
            Export-PfxCertificate -Cert $cert -FilePath C:\Lab\adfs-ssl.pfx -Password (ConvertTo-SecureString $pfxPwd -AsPlainText -Force) | Out-Null
            Export-Certificate -Cert $cert -FilePath C:\Lab\adfs-ssl.cer | Out-Null
            Import-Certificate -FilePath C:\Lab\adfs-ssl.cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

            Install-WindowsFeature ADFS-Federation -IncludeManagementTools | Out-Null
            Import-Module ADFS
            Install-AdfsFarm -CertificateThumbprint $cert.Thumbprint -FederationServiceName $fsName `
                -FederationServiceDisplayName 'AD FS Lab' -GroupServiceAccountIdentifier "$netbios\$gmsa`$" `
                -Credential $cred -OverwriteConfiguration -WarningAction SilentlyContinue | Out-Null

            # Browsers from the host are "intranet" (no WAP): use forms sign-in, not Windows auth prompts.
            Set-AdfsGlobalAuthenticationPolicy -PrimaryIntranetAuthenticationProvider @('FormsAuthentication')
        } @($Lab.FsName, $Lab.NetBios, $Lab.Gmsa, $secrets.PfxPassword, $domainCred)
    }

    # Certificate for the host (test app pins it; optionally import to trust the sign-in page).
    $s = New-PSSession -VMName $vm -Credential $domainCred
    try {
        Copy-Item -FromSession $s -Path C:\Lab\adfs-ssl.cer -Destination (Join-Path $Lab.Root 'adfs-ssl.cer') -Force
        Copy-Item -FromSession $s -Path C:\Lab\adfs-ssl.pfx -Destination (Join-Path $Lab.Root 'adfs-ssl.pfx') -Force
    } finally { Remove-PSSession $s }
}

# --------------------------------------------------------------------------------------------
# Phase: ADFS02 (secondary)
# --------------------------------------------------------------------------------------------
if ($Phase -contains 'Adfs02') {
    $vm = 'LAB-ADFS02'
    Join-LabDomain $vm
    $installed = Invoke-Lab $vm $domainCred { [bool](Get-Service adfssrv -ErrorAction SilentlyContinue) -and (Get-Service adfssrv).Status -eq 'Running' }
    if (-not $installed) {
        Step "$vm : join the AD FS farm as secondary"
        $s = New-PSSession -VMName $vm -Credential $domainCred
        try {
            Invoke-Command -Session $s { New-Item -ItemType Directory -Force C:\Lab | Out-Null }
            Copy-Item -ToSession $s -Path (Join-Path $Lab.Root 'adfs-ssl.pfx') -Destination C:\Lab\adfs-ssl.pfx -Force
            Copy-Item -ToSession $s -Path (Join-Path $Lab.Root 'adfs-ssl.cer') -Destination C:\Lab\adfs-ssl.cer -Force
            Invoke-Command -Session $s -ArgumentList $secrets.PfxPassword, $Lab.NetBios, $Lab.Gmsa, $Lab.Domain, $domainCred -ScriptBlock {
                param($pfxPwd, $netbios, $gmsa, $domain, $cred)
                $cert = Import-PfxCertificate -FilePath C:\Lab\adfs-ssl.pfx -CertStoreLocation Cert:\LocalMachine\My -Exportable `
                    -Password (ConvertTo-SecureString $pfxPwd -AsPlainText -Force)
                Import-Certificate -FilePath C:\Lab\adfs-ssl.cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
                Install-WindowsFeature ADFS-Federation -IncludeManagementTools | Out-Null
                Import-Module ADFS
                Add-AdfsFarmNode -GroupServiceAccountIdentifier "$netbios\$gmsa`$" -PrimaryComputerName "LAB-ADFS01.$domain" `
                    -CertificateThumbprint $cert.Thumbprint -Credential $cred -OverwriteConfiguration -WarningAction SilentlyContinue | Out-Null
            }
        } finally { Remove-PSSession $s }
    }
}

# --------------------------------------------------------------------------------------------
# Phase: Apps (two OIDC application groups; neither requires MFA yet)
# --------------------------------------------------------------------------------------------
if ($Phase -contains 'Apps') {
    $secrets = Get-LabSecrets
    $rules = @'
@RuleTemplate = "LdapClaims"
@RuleName = "UPN and display name"
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/windowsaccountname", Issuer == "AD AUTHORITY"]
 => issue(store = "Active Directory", types = ("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"), query = ";userPrincipalName,displayName;{0}", param = c.Value);

@RuleName = "Authentication methods"
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/authenticationmethod"] => issue(claim = c);

@RuleName = "Authentication method references"
c:[Type == "http://schemas.microsoft.com/claims/authnmethodsreferences"] => issue(claim = c);
'@

    foreach ($key in $Lab.Apps.Keys) {
        $app = $Lab.Apps[$key]
        $existing = $secrets.Apps.PSObject.Properties[$key]
        $clientId = if ($existing) { $existing.Value.ClientId } else { [guid]::NewGuid().ToString() }

        Step "LAB-ADFS01 : application group '$($app.Name)'"
        $secret = Invoke-Lab 'LAB-ADFS01' $domainCred {
            param($groupId, $name, $clientId, $redirect, $resource, $rules)
            Import-Module ADFS
            if (-not (Get-AdfsApplicationGroup -ApplicationGroupIdentifier $groupId -ErrorAction SilentlyContinue)) {
                New-AdfsApplicationGroup -Name $name -ApplicationGroupIdentifier $groupId | Out-Null
            }
            $newSecret = $null
            if (-not (Get-AdfsServerApplication -Identifier $clientId -ErrorAction SilentlyContinue)) {
                $srv = Add-AdfsServerApplication -Name "$name - Web app" -ApplicationGroupIdentifier $groupId -Identifier $clientId `
                    -RedirectUri $redirect -GenerateClientSecret -PassThru
                $newSecret = $srv.ClientSecret
            }
            if (-not (Get-AdfsWebApiApplication -Identifier $resource -ErrorAction SilentlyContinue)) {
                Add-AdfsWebApiApplication -Name "$name - Web API" -ApplicationGroupIdentifier $groupId -Identifier $resource `
                    -AccessControlPolicyName 'Permit everyone' -IssuanceTransformRules $rules | Out-Null
                Grant-AdfsApplicationPermission -ClientRoleIdentifier $clientId -ServerRoleIdentifier $resource -ScopeNames 'openid', 'profile', 'allatclaims' | Out-Null
            }
            $newSecret
        } @($app.Group, $app.Name, $clientId, "https://localhost:$($app.Port)/signin-oidc", $app.Resource, $rules)

        if (-not $existing) {
            # [string]: drop the note properties PowerShell remoting attaches to returned strings.
            $secrets.Apps | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{ ClientId = $clientId; ClientSecret = [string]$secret })
            Save-LabSecrets $secrets
        }
    }
}

Step 'Done.'
Stop-Transcript | Out-Null
