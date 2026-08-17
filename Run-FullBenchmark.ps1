# Orquesta el benchmark completo: sysinfo -> llama-bench baseline -> server sin MTP -> server con MTP -> reporte.
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$resultsDir = "$root\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

Write-Host "=== 1/4: Recolectando specs del sistema ===" -ForegroundColor Yellow
& "$root\Get-SysInfo.ps1"

Write-Host "`n=== 2/4: llama-bench baseline (pp/tg puro) ===" -ForegroundColor Yellow
& "$root\Bench-LlamaBench.ps1"

Write-Host "`n=== 3/4: Server benchmark SIN MTP ===" -ForegroundColor Yellow
& "$root\Bench-Server.ps1" -Repeats 3

Write-Host "`n=== 4/5: Server benchmark CON MTP (draft en CPU) ===" -ForegroundColor Yellow
& "$root\Bench-Server.ps1" -UseMTP -DraftNgl 0 -Repeats 3

Write-Host "`n=== 5/5: Server benchmark CON MTP (draft en GPU) ===" -ForegroundColor Yellow
& "$root\Bench-Server.ps1" -UseMTP -DraftNgl 999 -LabelOverride "mtp-gpu" -Repeats 3

Write-Host "`n=== Generando reporte ===" -ForegroundColor Yellow

$sysinfo = Get-Content "$resultsDir\sysinfo.json" | ConvertFrom-Json
$base   = Import-Csv "$resultsDir\server-bench-base.csv"
$mtp    = Import-Csv "$resultsDir\server-bench-mtp.csv"
$mtpGpu = Import-Csv "$resultsDir\server-bench-mtp-gpu.csv"

function Avg($rows, $field) {
    if (-not $rows -or $rows.Count -eq 0) { return 0 }
    $vals = $rows | ForEach-Object { [double]$_.$field }
    return [math]::Round(($vals | Measure-Object -Average).Average, 2)
}

$promptNames = ($base | Select-Object -ExpandProperty prompt -Unique)

$md = @()
$md += "# Benchmark de rendimiento local: Qwen3.8-27B (Q4_K_M) + MTP en llama.cpp"
$md += ""
$md += "Fecha: $($sysinfo.Fecha)"
$md += ""
$md += "## Hardware / Software"
$md += ""
$md += "| Componente | Detalle |"
$md += "|---|---|"
$md += "| CPU | $($sysinfo.CPU) |"
$md += "| RAM | $($sysinfo.RAM) |"
$md += "| GPU | $($sysinfo.GPUs) |"
$md += "| SO | $($sysinfo.OS) |"
$md += "| Disco | $($sysinfo.Disk) |"
if ($sysinfo.NvidiaSMI) { $md += "| nvidia-smi | $($sysinfo.NvidiaSMI) |" }
$md += ""
$md += "Modelo: **Qwen3.8-27B GGUF Q4_K_M**, draft model MTP para speculative decoding, ``-ngl 999`` (offload total a GPU), contexto 8192."
$md += ""
$md += "## Resultado principal: impacto de MTP (speculative decoding)"
$md += ""
$md += "Tokens/segundo de **generacion** medidos via el servidor HTTP real (``/completion``, campo ``timings``), promedio de 3 repeticiones por prompt. Se probaron tres variantes: sin MTP, con MTP y el draft model en CPU (``--spec-draft-ngl 0``, config original), y con MTP y el draft model tambien en GPU (``--spec-draft-ngl 999``)."
$md += ""
$md += "| Prompt | Sin MTP (tok/s) | MTP draft-CPU (tok/s) | MTP draft-GPU (tok/s) | Mejor variante |"
$md += "|---|---|---|---|---|"
foreach ($pn in $promptNames) {
    $b  = Avg ($base   | Where-Object { $_.prompt -eq $pn }) "gen_tok_s"
    $mc = Avg ($mtp    | Where-Object { $_.prompt -eq $pn }) "gen_tok_s"
    $mg = Avg ($mtpGpu | Where-Object { $_.prompt -eq $pn }) "gen_tok_s"
    $best = @{ "sin MTP" = $b; "MTP draft-CPU" = $mc; "MTP draft-GPU" = $mg }.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $md += "| $pn | $b | $mc | $mg | $($best.Name) ($($best.Value)) |"
}
$md += ""
$md += "> **Conclusion:** en este hardware (2x RTX 3060 12GB), ``--spec-draft-ngl 0`` (draft en CPU, la config original"
$md += "> del script ``llama-serve-qwen3.8.ps1``) es claramente la peor opcion - el costo de mover datos CPU<->GPU"
$md += "> para verificar cada token especulativo supera el ahorro. Poner el draft tambien en GPU"
$md += "> (``--spec-draft-ngl 999``) recupera la mayor parte del rendimiento y en el prompt de codigo llega a superar"
$md += "> el caso sin MTP, pero en general el aporte de MTP con este draft model no es consistente: no justifica"
$md += "> activarlo por defecto salvo para cargas dominadas por generacion de codigo/texto muy predecible."
$md += ""
$md += "## Velocidad de procesamiento de prompt (prefill)"
$md += ""
$md += "| Prompt | Sin MTP (tok/s) | MTP draft-CPU (tok/s) | MTP draft-GPU (tok/s) |"
$md += "|---|---|---|---|"
foreach ($pn in $promptNames) {
    $b  = Avg ($base   | Where-Object { $_.prompt -eq $pn }) "prompt_tok_s"
    $mc = Avg ($mtp    | Where-Object { $_.prompt -eq $pn }) "prompt_tok_s"
    $mg = Avg ($mtpGpu | Where-Object { $_.prompt -eq $pn }) "prompt_tok_s"
    $md += "| $pn | $b | $mc | $mg |"
}
$md += ""
$md += "## Baseline llama-bench (motor puro, sin servidor HTTP de por medio)"
$md += ""
$md += "Ver ``results/llama-bench-baseline.md`` para la tabla completa (pp512/2048/4096, tg128/512, 3 repeticiones cada uno, con desviacion estandar)."
$md += ""
if (Test-Path "$resultsDir\llama-bench-baseline.md") {
    $raw = [System.IO.File]::ReadAllText("$resultsDir\llama-bench-baseline.md", [System.Text.Encoding]::UTF8)
    $md += ($raw -replace "`r`n", "`n").Split("`n")
}
$md += ""
$md += "## Datos crudos"
$md += ""
$md += "- ``results/server-bench-base.csv`` - corridas individuales sin MTP"
$md += "- ``results/server-bench-mtp.csv`` - corridas individuales con MTP, draft en CPU"
$md += "- ``results/server-bench-mtp-gpu.csv`` - corridas individuales con MTP, draft en GPU"
$md += "- ``results/llama-bench-baseline.json`` / ``.md`` - salida de llama-bench"
$md += "- ``results/sysinfo.json`` - specs de hardware"

$md -join "`n" | Out-File -Encoding utf8 "$resultsDir\REPORTE.md"

Write-Host "`nReporte final: $resultsDir\REPORTE.md" -ForegroundColor Green
