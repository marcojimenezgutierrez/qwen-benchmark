param(
    [switch]$UseMTP,
    [int]$Repeats = 3,
    [int]$Port = 8080,
    [int]$DraftNgl = 0,
    [string]$LabelOverride = "",

    # --- Configuracion del servidor (todo parametrizable para poder barrer variantes) ---
    [int]$Ctx = 8192,
    [int]$Ngl = 999,
    [ValidateSet("layer", "row", "none")][string]$SplitMode = "layer",
    [string]$CacheTypeK = "f16",
    [string]$CacheTypeV = "f16",
    [int]$Parallel = 1,
    [switch]$NoKvOffload,
    [ValidateSet("on", "off", "auto")][string]$FlashAttn = "on",
    [string]$TensorSplit = "",

    [switch]$DryRun
)

# Benchmark "real": levanta el server con la configuracion pedida y mide tokens/seg reales
# via el campo "timings" que devuelve /completion (prompt_per_second, predicted_per_second).
#
# Todos los defaults reproducen la configuracion historica del repo salvo -fa on, que ahora se
# pasa explicitamente para que el servidor sea comparable con Bench-LlamaBench.ps1 (ver README).

$llama = "$env:LOCALAPPDATA\Microsoft\WindowsApps\llama.exe"
$modelRepo = "ggml-org/Qwen3.8-27B-GGUF:Q4_K_M"
$draftModel = "$env:USERPROFILE\.cache\huggingface\hub\models--ggml-org--Qwen3.8-27B-GGUF\snapshots\0669b98607d47046c7c2b3f801011d54a08cfccf\mtp-Qwen3.8-27B-Q4_0.gguf"
$resultsDir = "$PSScriptRoot\results"
$logsDir = "$resultsDir\logs"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

# --- Etiqueta ---------------------------------------------------------------------------
# Se construye a partir de lo que difiere del default, para que las variantes de un barrido no
# se pisen el CSV entre si y para que "base"/"mtp"/"mtp-gpu" sigan llamandose igual que antes.
function New-VariantLabel {
    $parts = @()
    if ($UseMTP) { $parts += $(if ($DraftNgl -gt 0) { "mtp-gpu" } else { "mtp" }) } else { $parts += "base" }
    if ($Ctx -ne 8192)      { $parts += "ctx$([math]::Round($Ctx / 1024))k" }
    if ($SplitMode -ne "layer") { $parts += "sm$SplitMode" }
    if ($CacheTypeK -ne "f16" -or $CacheTypeV -ne "f16") {
        $ck = $CacheTypeK.Replace("_", "")
        $cv = $CacheTypeV.Replace("_", "")
        $parts += $(if ($ck -eq $cv) { "kv$ck" } else { "k$ck-v$cv" })
    }
    if ($NoKvOffload)       { $parts += "ram" }
    if ($Parallel -ne 1)    { $parts += "np$Parallel" }
    if ($FlashAttn -ne "on"){ $parts += "fa$FlashAttn" }
    if ($Ngl -ne 999)       { $parts += "ngl$Ngl" }
    return ($parts -join "-")
}

$label = if ($LabelOverride) { $LabelOverride } else { New-VariantLabel }
$baseUrl = "http://127.0.0.1:$Port"

# --- Argumentos del servidor ------------------------------------------------------------
$serverArgs = @(
    "serve", "-hf", $modelRepo,
    "-ngl", "$Ngl", "-c", "$Ctx", "-np", "$Parallel",
    "-sm", $SplitMode,
    "-fa", $FlashAttn,
    "--cache-type-k", $CacheTypeK,
    "--cache-type-v", $CacheTypeV,
    "--no-mmproj", "--port", "$Port"
)
if ($NoKvOffload) { $serverArgs += "-nkvo" }
if ($TensorSplit) { $serverArgs += @("-ts", $TensorSplit) }
if ($UseMTP) {
    $serverArgs += @("--spec-draft-model", $draftModel, "--spec-type", "draft-mtp", "--spec-draft-ngl", "$DraftNgl")
}

if ($DryRun) {
    Write-Host "variante : $label" -ForegroundColor Cyan
    Write-Host "comando  : $llama $($serverArgs -join ' ')" -ForegroundColor Gray
    exit 0
}

# --- Helpers ----------------------------------------------------------------------------

# Config de la corrida, se adjunta a cada fila del CSV para que el archivo sea autodescriptivo.
$cfg = [ordered]@{
    ctx         = $Ctx
    ngl         = $Ngl
    split_mode  = $SplitMode
    cache_k     = $CacheTypeK
    cache_v     = $CacheTypeV
    parallel    = $Parallel
    nkvo        = [bool]$NoKvOffload
    flash_attn  = $FlashAttn
}

# [ordered] no soporta el operador + como si lo hace [hashtable], asi que se fusiona a mano
# para poder adjuntar $cfg a cada fila conservando el orden de columnas.
function Join-Ordered {
    param($A, $B)
    $out = [ordered]@{}
    foreach ($k in $A.Keys) { $out[$k] = $A[$k] }
    foreach ($k in $B.Keys) { $out[$k] = $B[$k] }
    return $out
}

function Get-VramUsedMiB {
    try {
        $used = nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
        if ($used) { return (($used | ForEach-Object { [int]$_ }) | Measure-Object -Sum).Sum }
    } catch {}
    return $null
}

# Extrae del log de carga lo necesario para (a) saber si el modelo es denso o MoE y (b) medir
# cuanta memoria se lleva el KV cache en cada configuracion de contexto.
function Get-LogFacts {
    param([string[]]$LogPaths)
    $facts = [ordered]@{}
    $text = ""
    foreach ($p in $LogPaths) {
        if (Test-Path $p) { $text += [System.IO.File]::ReadAllText($p) + "`n" }
    }
    if (-not $text) { return $facts }

    foreach ($key in @("n_expert", "n_expert_used", "n_layer", "n_embd", "n_head_kv", "n_ctx_train")) {
        $m = [regex]::Match($text, "$key\s*=\s*(\d+)")
        if ($m.Success) { $facts[$key] = [int]$m.Groups[1].Value }
    }

    # "KV self size = 1234.00 MiB" o, en builds recientes, "CUDAn KV buffer size = ... MiB"
    $kv = [regex]::Match($text, "KV self size\s*=\s*([\d\.]+)\s*MiB")
    if ($kv.Success) {
        $facts["kv_size_mib"] = [math]::Round([double]$kv.Groups[1].Value, 1)
    } else {
        $bufs = [regex]::Matches($text, "KV buffer size\s*=\s*([\d\.]+)\s*MiB")
        if ($bufs.Count -gt 0) {
            $facts["kv_size_mib"] = [math]::Round((($bufs | ForEach-Object { [double]$_.Groups[1].Value }) | Measure-Object -Sum).Sum, 1)
        }
    }

    $comp = [regex]::Matches($text, "compute buffer size\s*=\s*([\d\.]+)\s*MiB")
    if ($comp.Count -gt 0) {
        $facts["compute_buffer_mib"] = [math]::Round((($comp | ForEach-Object { [double]$_.Groups[1].Value }) | Measure-Object -Sum).Sum, 1)
    }
    return $facts
}

# Fila de fallo: en un barrido de contexto un OOM es el resultado buscado, no un error fatal.
# Se registra y el script sale con 0 para que el barrido siga con la siguiente config.
function Write-FailureRow {
    param([string]$Status, [string]$Detail)
    $row = [pscustomobject](Join-Ordered ([ordered]@{
        variant = $label; prompt = "-"; rep = 0
        prompt_tokens = $null; prompt_ms = $null; prompt_tok_s = $null
        gen_tokens = $null; gen_ms = $null; gen_tok_s = $null; wall_ms = $null
        status = $Status; detail = $Detail
        kv_size_mib = $null; vram_used_mib = $null
    }) $cfg)
    $row | Export-Csv -Path "$resultsDir\server-bench-$label.csv" -NoTypeInformation -Encoding utf8
    Write-Host "[$label] $Status - $Detail" -ForegroundColor Red
    Write-Host "Registrado en server-bench-$label.csv; continuando." -ForegroundColor Yellow
}

# --- Arranque del servidor --------------------------------------------------------------
$outLog = "$logsDir\server-$label.out.log"
$errLog = "$logsDir\server-$label.err.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

Write-Host "Iniciando servidor ($label): -c $Ctx -sm $SplitMode -fa $FlashAttn --cache-type-k $CacheTypeK$(if ($NoKvOffload) { ' -nkvo' })" -ForegroundColor Cyan
$proc = Start-Process -FilePath $llama -ArgumentList $serverArgs -PassThru -NoNewWindow `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog

# Esperar a que el server responda /health (timeout 180s, el modelo es grande)
$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { break }
    try {
        $h = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq "ok") { $ready = $true; break }
    } catch {}
}

if (-not $ready) {
    $tail = ""
    if (Test-Path $errLog) { $tail = (Get-Content $errLog -Tail 5) -join " | " }
    $status = if ($tail -match "(?i)out of memory|failed to allocate|cudaMalloc") { "oom" } else { "load-failed" }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process | Where-Object { $_.Path -eq $llama } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-FailureRow -Status $status -Detail $tail
    exit 0
}

$facts = Get-LogFacts -LogPaths @($errLog, $outLog)
$vram = Get-VramUsedMiB
Write-Host "Servidor listo. KV: $($facts.kv_size_mib) MiB | VRAM en uso: $vram MiB" -ForegroundColor Green

# El modelo se identifica una sola vez; decide si tiene sentido hablar de expertos en CPU y
# permite contrastar el tg del servidor contra el techo de ancho de banda en el reporte.
if ($facts.Contains("n_layer")) {
    $facts | ConvertTo-Json | Out-File -Encoding utf8 "$resultsDir\model-info.json"
}

# --- Prompts ----------------------------------------------------------------------------
# Prompts representativos: corto/factual, medio/razonamiento, largo/generacion de codigo.
$prompts = @(
    @{ name = "corto";  text = "Cual es la capital de Francia y por que es importante historicamente? Responde en 2 oraciones."; n_predict = 64 },
    @{ name = "medio";  text = "Explica paso a paso como funciona el mecanismo de atencion en los transformers, con un ejemplo numerico simple."; n_predict = 256 },
    @{ name = "codigo"; text = "Escribe en Python una funcion que implemente quicksort, con comentarios explicando cada paso, y luego una funcion de test con 5 casos."; n_predict = 512 }
)

function Invoke-Completion {
    param([string]$Text, [int]$NPredict)
    # cache_prompt=false es obligatorio: con el default (true) las repeticiones 2..N reusan el
    # prefijo cacheado y prompt_tok_s deja de medir prefill.
    $body = @{
        prompt       = $Text
        n_predict    = $NPredict
        temperature  = 0.2
        stream       = $false
        cache_prompt = $false
    } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$baseUrl/completion" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 600
}

# Calentamiento descartado: la primera peticion paga inicializacion de CUDA y buffers.
Write-Host "  calentando..." -ForegroundColor DarkGray
try { Invoke-Completion -Text $prompts[0].text -NPredict 16 | Out-Null } catch {}

$rows = @()
foreach ($p in $prompts) {
    for ($r = 1; $r -le $Repeats; $r++) {
        $t0 = Get-Date
        try {
            $resp = Invoke-Completion -Text $p.text -NPredict $p.n_predict
        } catch {
            Write-Host "Fallo request $($p.name) rep $r : $_" -ForegroundColor Red
            continue
        }
        $wallMs = ((Get-Date) - $t0).TotalMilliseconds

        $t = $resp.timings
        $rows += [pscustomobject](Join-Ordered ([ordered]@{
            variant            = $label
            prompt             = $p.name
            rep                = $r
            prompt_tokens      = $t.prompt_n
            prompt_ms          = [math]::Round($t.prompt_ms, 1)
            prompt_tok_s       = [math]::Round($t.prompt_per_second, 2)
            gen_tokens         = $t.predicted_n
            gen_ms             = [math]::Round($t.predicted_ms, 1)
            gen_tok_s          = [math]::Round($t.predicted_per_second, 2)
            wall_ms            = [math]::Round($wallMs, 1)
            status             = "ok"
            detail             = ""
            kv_size_mib        = $facts.kv_size_mib
            vram_used_mib      = $vram
        }) $cfg)
        Write-Host ("  {0}/{1} rep{2}: gen {3} tok/s, prompt {4} tok/s" -f $p.name, $label, $r, [math]::Round($t.predicted_per_second,1), [math]::Round($t.prompt_per_second,1))
    }
}

$csvPath = "$resultsDir\server-bench-$label.csv"
if ($rows.Count -gt 0) {
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    Write-Host "Resultados guardados en $csvPath" -ForegroundColor Green
} else {
    Write-FailureRow -Status "no-data" -Detail "el servidor cargo pero ninguna peticion tuvo exito"
}

Write-Host "Deteniendo servidor..." -ForegroundColor Cyan
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
# Por si el proceso real quedo en un hijo (llama.exe serve puede lanzar el server como subproceso)
Get-Process | Where-Object { $_.Path -eq $llama } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
