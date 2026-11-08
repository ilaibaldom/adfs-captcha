# Shared settings for the AD FS 2019 lab. Dot-sourced by the lab scripts.

$Lab = @{
    Root          = 'C:\HyperV\AdfsLab'
    MediaVhd      = 'C:\Users\Ilai\AdfsLab-media\WS2019-Datacenter-Eval.vhd'
    BaseVhd       = 'C:\HyperV\AdfsLab\Base\WS2019-Datacenter-Eval.vhd'
    Switch        = 'AdfsLab'
    Gateway       = '192.168.77.1'
    PrefixLength  = 24

    Domain        = 'adfslab.test'
    NetBios       = 'ADFSLAB'
    FsName        = 'adfs.adfslab.test'          # federation service name
    Gmsa          = 'gmsaAdfs'

    SecretsFile   = Join-Path $PSScriptRoot 'lab-credentials.json'   # gitignored; generated
    LogDir        = Join-Path $PSScriptRoot 'logs'

    Vms = [ordered]@{
        'LAB-DC01'   = @{ Ip = '192.168.77.10'; MemoryMB = 2048; Cpu = 2 }
        'LAB-ADFS01' = @{ Ip = '192.168.77.11'; MemoryMB = 4096; Cpu = 2 }
        'LAB-ADFS02' = @{ Ip = '192.168.77.12'; MemoryMB = 3072; Cpu = 2 }
    }

    # OIDC test apps (run on this PC from lab\TestApp). Research is the one the captcha is scoped to.
    Apps = [ordered]@{
        Research = @{ Group = 'ResearchPortal'; Name = 'Research Portal'; Port = 44301; Resource = 'https://research.adfslab.test/' }
        Control  = @{ Group = 'ControlApp';     Name = 'Control App';     Port = 44302; Resource = 'https://control.adfslab.test/' }
    }
}

function New-LabPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    'Lab!' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + '7a'
}

function Get-LabSecrets {
    if (Test-Path $Lab.SecretsFile) { return Get-Content $Lab.SecretsFile -Raw | ConvertFrom-Json }
    $s = [pscustomobject]@{
        AdminUser     = 'Administrator'
        AdminPassword = New-LabPassword       # local admin = domain admin = DSRM (lab only)
        UserPassword  = New-LabPassword       # alice / bob
        PfxPassword   = New-LabPassword
        Apps          = [pscustomobject]@{}
    }
    $s | ConvertTo-Json -Depth 5 | Set-Content $Lab.SecretsFile -Encoding UTF8
    $s
}

function Save-LabSecrets($s) { $s | ConvertTo-Json -Depth 5 | Set-Content $Lab.SecretsFile -Encoding UTF8 }

function Assert-LabTestApps {
    # The sign-in tests need both test apps; start them if they are not listening.
    $down = @(44301, 44302 | Where-Object {
            try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('localhost', $_); $c.Close(); $false } catch { $true } })
    if ($down) {
        Write-Host "Test apps not running (ports $($down -join ', ')); starting them." -ForegroundColor Yellow
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-TestApps.ps1') | Out-Host
    }
}

function Get-LabCredential([switch]$Local) {
    $s = Get-LabSecrets
    $user = if ($Local) { $s.AdminUser } else { "$($Lab.NetBios)\$($s.AdminUser)" }
    New-Object PSCredential ($user, (ConvertTo-SecureString $s.AdminPassword -AsPlainText -Force))
}
