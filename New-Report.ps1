param(
    [string]$ResultsDir = "$PSScriptRoot\results",
    [string]$OutFile = ""
)

# Genera results/REPORTE.md a partir de TODOS los server-bench-*.csv que encuentre.
# Es agnostico de variantes a proposito: los barridos (Run-SpeedSweep / Run-ContextSweep)
# producen N variantes y el generador anterior tenia tres columnas fijas.
#
# El numero principal es la MEDIANA, no la media: en los datos historicos una sola repeticion
# lenta (base/codigo/rep3, 28.7s contra ~19.1s) bastaba para invertir la conclusion del reporte.

if (-not $OutFile) { $OutFile = "$ResultsDir\REPORTE.md" }

# --- Helpers ----------------------------------------------------------------------------

# Los CSV viejos no tienen las columnas de configuracion; se leen igual sin romper.
function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $v = $Obj.$Name
    if ($null -eq $v -or "$v" -eq "") { return $Default }
    return $v
}

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] }
    return (($s[[int]($n / 2) - 1] + $s[[int]($n / 2)]) / 2)
}

function Get-Stat {
    param($Rows, [string]$Field)
    $vals = @()
    foreach ($r in $Rows) {
        $v = Get-Prop $r $Field
        if ($null -ne $v) { $vals += [double]$v }
    }
    if ($vals.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Median = [math]::Round((Get-Median $vals), 2)
        Min    = [math]::Round(($vals | Measure-Object -Minimum).Minimum, 2)
        Max    = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 2)
        Mean   = [math]::Round(($vals | Measure-Object -Average).Average, 2)
        N      = $vals.Count
    }
}

function Fmt {
    param($Value, $Fallback = "-")
    if ($null -eq $Value -or "$Value" -eq "") { return $Fallback }
    return $Value
}

# --- Carga ------------------------------------------------------------------------------

$csvs = @(Get-ChildItem -Path "$ResultsDir\server-bench-*.csv" -ErrorAction SilentlyContinue | Sort-Object Name)
if ($csvs.Count -eq 0) {
    Write-Host "No hay server-bench-*.csv en $ResultsDir" -ForegroundColor Red
    exit 1
}

$all = @()
foreach ($f in $csvs) { $all += @(Import-Csv $f.FullName) }

# "base" primero, el resto alfabetico, para que la referencia siempre encabece las tablas.
$variants = @($all | ForEach-Object { Get-Prop $_ "variant" "?" } | Select-Object -Unique |
    Sort-Object @{ Expression = { if ($_ -eq "base") { 0 } else { 1 } } }, @{ Expression = { $_ } })

$okRows = @($all | Where-Object { (Get-Prop $_ "status" "ok") -eq "ok" })
$promptNames = @($okRows | ForEach-Object { $_.prompt } | Select-Object -Unique | Where-Object { $_ -ne "-" })

$sysinfo = $null
if (Test-Path "$ResultsDir\sysinfo.json") { $sysinfo = Get-Content "$ResultsDir\sysinfo.json" -Raw | ConvertFrom-Json }
$modelInfo = $null
if (Test-Path "$ResultsDir\model-info.json") { $modelInfo = Get-Content "$ResultsDir\model-info.json" -Raw | ConvertFrom-Json }

$md = @()
$md += "# Benchmark de rendimiento local: Qwen3.8-27B (Q4_K_M) en llama.cpp"
$md += ""
if ($sysinfo) { $md += "Fecha: $($sysinfo.Fecha)"; $md += "" }

# --- Hardware ---------------------------------------------------------------------------
if ($sysinfo) {
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
}

# --- Resumen por variante ---------------------------------------------------------------
$md += "## Resumen por variante"
$md += ""
$md += "Mediana de ``gen_tok_s`` sobre todas las cargas. Medido via ``/completion`` con ``cache_prompt=false``."
$md += ""
$md += "| Variante | ctx | split | cache K/V | KV en RAM | Mediana gen tok/s | KV MiB | VRAM MiB | Estado |"
$md += "|---|---|---|---|---|---|---|---|---|"

$variantSummary = @{}
foreach ($v in $variants) {
    $rows = @($all | Where-Object { (Get-Prop $_ "variant" "?") -eq $v })
    $ok = @($rows | Where-Object { (Get-Prop $_ "status" "ok") -eq "ok" })
    $first = $rows[0]
    $status = if ($ok.Count -gt 0) { "ok" } else { Get-Prop $first "status" "sin datos" }
    $stat = Get-Stat $ok "gen_tok_s"
    $variantSummary[$v] = $stat
    $md += "| ``$v`` | $(Fmt (Get-Prop $first 'ctx')) | $(Fmt (Get-Prop $first 'split_mode')) | $(Fmt (Get-Prop $first 'cache_k'))/$(Fmt (Get-Prop $first 'cache_v')) | $(Fmt (Get-Prop $first 'nkvo')) | $(if ($stat) { $stat.Median } else { '-' }) | $(Fmt (Get-Prop $first 'kv_size_mib')) | $(Fmt (Get-Prop $first 'vram_used_mib')) | $status |"
}
$md += ""

$ranked = @($variants | Where-Object { $variantSummary[$_] } | Sort-Object { -$variantSummary[$_].Median })
if ($ranked.Count -gt 1) {
    $best = $ranked[0]
    $md += "**Mas rapida: ``$best`` con $($variantSummary[$best].Median) tok/s de mediana.**"
    $md += ""
}

# --- Detalle por prompt -----------------------------------------------------------------
$md += "## Detalle por carga"
$md += ""
$md += "| Variante | Carga | Mediana | Min | Max | Media | n |"
$md += "|---|---|---:|---:|---:|---:|---:|"
foreach ($v in $variants) {
    foreach ($pn in $promptNames) {
        $rows = @($okRows | Where-Object { (Get-Prop $_ "variant" "?") -eq $v -and $_.prompt -eq $pn })
        if ($rows.Count -eq 0) { continue }
        $s = Get-Stat $rows "gen_tok_s"
        # Media y mediana muy separadas = hay un outlier arrastrando el promedio.
        $flag = if ($s.N -ge 3 -and [math]::Abs($s.Mean - $s.Median) -gt (0.05 * $s.Median)) { " ⚠" } else { "" }
        $md += "| ``$v`` | $pn | **$($s.Median)**$flag | $($s.Min) | $($s.Max) | $($s.Mean) | $($s.N) |"
    }
}
$md += ""
$md += "> ⚠ marca los casos donde la media se aparta mas de 5% de la mediana: hay al menos una"
$md += "> repeticion atipica y el promedio no representa la corrida."
$md += ""

# --- Prefill ----------------------------------------------------------------------------
$md += "## Procesamiento de prompt (prefill)"
$md += ""
$md += "| Variante | Carga | Mediana prompt tok/s | prompt_tokens | Valido |"
$md += "|---|---|---:|---|---|"
foreach ($v in $variants) {
    foreach ($pn in $promptNames) {
        $rows = @($okRows | Where-Object { (Get-Prop $_ "variant" "?") -eq $v -and $_.prompt -eq $pn })
        if ($rows.Count -eq 0) { continue }
        $s = Get-Stat $rows "prompt_tok_s"
        $toks = @($rows | ForEach-Object { Get-Prop $_ "prompt_tokens" } | Select-Object -Unique)
        # Si prompt_tokens cambia entre repeticiones, el servidor reuso el prefijo cacheado y
        # la cifra no mide prefill. Es exactamente el defecto de los CSV historicos (23, 4, 4).
        $valid = if ($toks.Count -le 1) { "si" } else { "**no** - cache_prompt activo ($($toks -join ', '))" }
        $md += "| ``$v`` | $pn | $(if ($s) { $s.Median } else { '-' }) | $($toks -join ', ') | $valid |"
    }
}
$md += ""

# --- Contexto y memoria -----------------------------------------------------------------
$ctxRows = @($all | Where-Object { $null -ne (Get-Prop $_ "ctx") })
if ($ctxRows.Count -gt 0) {
    $md += "## Ventana de contexto vs velocidad y memoria"
    $md += ""
    $md += "| Variante | ctx | cache K/V | KV en RAM | Cargo | KV MiB | VRAM MiB | Mediana gen tok/s | vs 8k |"
    $md += "|---|---:|---|---|---|---:|---:|---:|---:|"
    $ref = $null
    # Ordenado por tamanio de contexto para que la tabla se lea como una escalera.
    $ctxIndex = @()
    foreach ($name in @($ctxRows | ForEach-Object { Get-Prop $_ "variant" "?" } | Select-Object -Unique)) {
        $firstRow = @($ctxRows | Where-Object { (Get-Prop $_ "variant" "?") -eq $name })[0]
        $ctxIndex += [pscustomobject]@{ Name = $name; Ctx = [int](Get-Prop $firstRow "ctx" 0) }
    }
    foreach ($entry in @($ctxIndex | Sort-Object Ctx, Name)) {
        $v = $entry.Name
        $rows = @($ctxRows | Where-Object { (Get-Prop $_ "variant" "?") -eq $v })
        $ok = @($rows | Where-Object { (Get-Prop $_ "status" "ok") -eq "ok" })
        $first = $rows[0]
        $s = Get-Stat $ok "gen_tok_s"
        $median = if ($s) { $s.Median } else { $null }
        if ($null -eq $ref -and $median -and [int](Get-Prop $first "ctx" 0) -le 8192) { $ref = $median }
        $delta = if ($median -and $ref) { "$([math]::Round(100 * ($median - $ref) / $ref, 1))%" } else { "-" }
        $loaded = if ($ok.Count -gt 0) { "si" } else { "**no** ($(Get-Prop $first 'status' '?'))" }
        $md += "| ``$v`` | $(Fmt (Get-Prop $first 'ctx')) | $(Fmt (Get-Prop $first 'cache_k'))/$(Fmt (Get-Prop $first 'cache_v')) | $(Fmt (Get-Prop $first 'nkvo')) | $loaded | $(Fmt (Get-Prop $first 'kv_size_mib')) | $(Fmt (Get-Prop $first 'vram_used_mib')) | $(Fmt $median) | $delta |"
    }
    $md += ""
}

# --- Modelo y coherencia de las mediciones ----------------------------------------------
$md += "## Modelo y coherencia de las mediciones"
$md += ""

$benchJson = $null
if (Test-Path "$ResultsDir\llama-bench-baseline.json") {
    try { $benchJson = Get-Content "$ResultsDir\llama-bench-baseline.json" -Raw | ConvertFrom-Json } catch {}
}

if ($modelInfo) {
    $nExpert = [int](Get-Prop $modelInfo "n_expert" 0)
    $arch = if ($nExpert -gt 0) { "**MoE** ($nExpert expertos, $(Get-Prop $modelInfo 'n_expert_used' '?') activos por token)" } else { "**denso** (n_expert = 0)" }
    $md += "Arquitectura detectada en el log de carga: $arch."
    $md += ""
    $md += "| Campo | Valor |"
    $md += "|---|---|"
    foreach ($k in $modelInfo.PSObject.Properties.Name) { $md += "| $k | $($modelInfo.$k) |" }
    $md += ""
} else {
    $md += "> No hay ``model-info.json``. Se genera solo al correr ``Bench-Server.ps1`` con la version"
    $md += "> actual del script, que captura el log de carga del servidor."
    $md += ""
}

if ($benchJson) {
    $tg = @($benchJson | Where-Object { $_.n_gen -gt 0 })
    $modelBytes = [double]($benchJson[0].model_size)
    $modelGB = [math]::Round($modelBytes / 1e9, 2)
    $md += "Tamanio del modelo en memoria: **$modelGB GB**. Un modelo denso lee todos sus pesos una vez"
    $md += "por token generado, asi que ``tok/s x $modelGB GB`` da el ancho de banda implicito. Con"
    $md += "``--split-mode layer`` las GPUs trabajan en secuencia, de modo que ese numero no puede superar"
    $md += "el ancho de banda de **una sola** GPU."
    $md += ""
    $md += "| Fuente | Prueba | tok/s | Ancho de banda implicito |"
    $md += "|---|---|---:|---:|"
    foreach ($t in $tg) {
        $md += "| llama-bench | tg$($t.n_gen) | $([math]::Round($t.avg_ts, 2)) | $([math]::Round($t.avg_ts * $modelGB, 0)) GB/s |"
    }
    foreach ($v in $variants) {
        $s = $variantSummary[$v]
        if ($s) { $md += "| servidor | ``$v`` | $($s.Median) | $([math]::Round($s.Median * $modelGB, 0)) GB/s |" }
    }
    $md += ""
    $md += "> Si el modelo es denso y alguna fila del servidor implica mas ancho de banda del que tiene"
    $md += "> una GPU, esa medicion esta mal y hay que resolverlo antes de optimizar nada. Si el modelo"
    $md += "> es MoE, solo se lee una fraccion de los pesos por token y la comparacion no aplica."
    $md += ""
}

# --- Baseline llama-bench ---------------------------------------------------------------
$md += "## Baseline llama-bench (motor puro, sin servidor HTTP de por medio)"
$md += ""
if (Test-Path "$ResultsDir\llama-bench-baseline.md") {
    $raw = [System.IO.File]::ReadAllText("$ResultsDir\llama-bench-baseline.md", [System.Text.Encoding]::UTF8)
    $md += ($raw -replace "`r`n", "`n").Split("`n")
}
$md += ""

# --- Datos crudos -----------------------------------------------------------------------
$md += "## Datos crudos"
$md += ""
foreach ($f in $csvs) { $md += "- ``results/$($f.Name)``" }
$md += "- ``results/llama-bench-baseline.json`` / ``.md`` - salida de llama-bench"
$md += "- ``results/sysinfo.json`` - specs de hardware"
if ($modelInfo) { $md += "- ``results/model-info.json`` - arquitectura del modelo leida del log de carga" }
$md += "- ``results/logs/`` - logs de arranque del servidor por variante"

$md -join "`n" | Out-File -Encoding utf8 $OutFile
Write-Host "Reporte generado: $OutFile ($($variants.Count) variantes)" -ForegroundColor Green
