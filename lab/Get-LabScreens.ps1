<#
.SYNOPSIS
  Saves a console thumbnail (PNG) of each lab VM, to see what a VM is showing without
  opening Hyper-V Manager. Output: lab\logs\screens\<VM>.png
#>
param([int]$Width = 800, [int]$Height = 600)
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot 'logs\screens'
New-Item -ItemType Directory -Force $out | Out-Null
$svc = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
foreach ($vm in Get-VM -Name 'LAB-*') {
    $sd = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemSettingData -Filter "ConfigurationID='$($vm.Id)' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'"
    $r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $sd; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
    if (-not $r.ImageData) { "{0,-11} {1} (no image)" -f $vm.Name, $vm.State; continue }
    # ImageData is RGB565
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $Width, $Height
    $data = $bmp.LockBits($rect, 'WriteOnly', $bmp.PixelFormat)
    [Runtime.InteropServices.Marshal]::Copy([byte[]]$r.ImageData, 0, $data.Scan0, $r.ImageData.Length)
    $bmp.UnlockBits($data)
    $path = Join-Path $out "$($vm.Name).png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    "{0,-11} {1,-8} uptime {2:hh\:mm\:ss}  -> {3}" -f $vm.Name, $vm.State, $vm.Uptime, $path
}
