# Recolecta especificaciones de hardware/software relevantes para el reporte de benchmark.
$out = [ordered]@{}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$out.CPU = "$($cpu.Name) ($($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads)"

$ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$out.RAM = "{0:N1} GB" -f ($ramBytes / 1GB)

$os = Get-CimInstance Win32_OperatingSystem
$out.OS = "$($os.Caption) (Build $($os.BuildNumber))"

$gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" }
$gpuList = @()
foreach ($g in $gpus) {
    $gpuList += "$($g.Name) - $([math]::Round($g.AdapterRAM/1GB,1)) GB VRAM (driver $($g.DriverVersion))"
}
$out.GPUs = $gpuList -join "; "

try {
    $nvsmi = nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader 2>$null
    if ($nvsmi) { $out.NvidiaSMI = ($nvsmi -join "; ") }
} catch {}

try {
    $llamaVer = & "$env:LOCALAPPDATA\Microsoft\WindowsApps\llama-bench.exe" --list-devices 2>&1 | Select-String "CUDA devices|Device"
    $out.CUDADevices = ($llamaVer -join " | ")
} catch {}

$disk = Get-CimInstance Win32_DiskDrive | Select-Object -First 1
$out.Disk = "$($disk.Model) ($([math]::Round($disk.Size/1GB,0)) GB)"

$out.Fecha = (Get-Date -Format "yyyy-MM-dd HH:mm")

$out | ConvertTo-Json | Out-File -Encoding utf8 "$PSScriptRoot\results\sysinfo.json"
$out.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key): $($_.Value)" }
