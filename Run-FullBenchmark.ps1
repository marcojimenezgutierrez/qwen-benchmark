param(
    [switch]$IncludeMTP,
    [switch]$IncludeSweeps,
    [int]$Repeats = 3,
    [int]$Port = 8080
)

# Orquesta el benchmark: sysinfo -> llama-bench baseline -> server base -> reporte.
#
# MTP quedo detras de -IncludeMTP. Las corridas de 2026-08-16 lo dejaron claro: con el draft en
# CPU pierde la mitad del rendimiento y con el draft en GPU no gana en ninguna de las tres
# cargas, asi que correrlo siempre gastaba dos tercios del tiempo de la suite en confirmarlo.

$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$resultsDir = "$root\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$steps = @()
$steps += { & "$root\Get-SysInfo.ps1" }
$steps += { & "$root\Bench-LlamaBench.ps1" }
$steps += { & "$root\Bench-Server.ps1" -Repeats $Repeats -Port $Port }
$labels = @("Recolectando specs del sistema", "llama-bench baseline (pp/tg puro)", "Server benchmark base")

if ($IncludeMTP) {
    $steps += { & "$root\Bench-Server.ps1" -UseMTP -DraftNgl 0 -Repeats $Repeats -Port $Port }
    $steps += { & "$root\Bench-Server.ps1" -UseMTP -DraftNgl 999 -LabelOverride "mtp-gpu" -Repeats $Repeats -Port $Port }
    $labels += @("Server con MTP (draft en CPU)", "Server con MTP (draft en GPU)")
}
if ($IncludeSweeps) {
    $steps += { & "$root\Run-SpeedSweep.ps1" -Repeats $Repeats -Port $Port }
    $steps += { & "$root\Run-ContextSweep.ps1" -Repeats $Repeats -Port $Port }
    $labels += @("Barrido de velocidad", "Barrido de contexto")
}

for ($i = 0; $i -lt $steps.Count; $i++) {
    Write-Host "`n=== $($i + 1)/$($steps.Count): $($labels[$i]) ===" -ForegroundColor Yellow
    & $steps[$i]
}

Write-Host "`n=== Generando reporte ===" -ForegroundColor Yellow
& "$root\New-Report.ps1"

if (-not $IncludeMTP) {
    Write-Host "MTP omitido (usa -IncludeMTP para incluirlo)." -ForegroundColor DarkGray
}
if (-not $IncludeSweeps) {
    Write-Host "Barridos omitidos (usa -IncludeSweeps, o corre Run-SpeedSweep.ps1 / Run-ContextSweep.ps1 sueltos)." -ForegroundColor DarkGray
}
