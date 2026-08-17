param(
    [switch]$UseMTP,
    [int]$Repeats = 3,
    [int]$Port = 8080,
    [int]$DraftNgl = 0,
    [string]$LabelOverride = ""
)

# Benchmark "real": levanta el server (igual que llama-serve-qwen3.8.ps1) con o sin
# MTP (speculative decoding con draft model), y mide tokens/seg reales via el campo
# "timings" que devuelve /completion (prompt_per_second, predicted_per_second).

$llama = "$env:LOCALAPPDATA\Microsoft\WindowsApps\llama.exe"
$modelRepo = "ggml-org/Qwen3.8-27B-GGUF:Q4_K_M"
$draftModel = "$env:USERPROFILE\.cache\huggingface\hub\models--ggml-org--Qwen3.8-27B-GGUF\snapshots\0669b98607d47046c7c2b3f801011d54a08cfccf\mtp-Qwen3.8-27B-Q4_0.gguf"
$resultsDir = "$PSScriptRoot\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$label = if ($LabelOverride) { $LabelOverride } elseif ($UseMTP) { "mtp" } else { "base" }
$baseUrl = "http://127.0.0.1:$Port"

$serverArgs = @(
    "serve", "-hf", $modelRepo,
    "-ngl", "999", "-c", "8192", "-np", "1",
    "--no-mmproj", "--port", "$Port"
)
if ($UseMTP) {
    $serverArgs += @("--spec-draft-model", $draftModel, "--spec-type", "draft-mtp", "--spec-draft-ngl", "$DraftNgl")
}

Write-Host "Iniciando servidor ($label)..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $llama -ArgumentList $serverArgs -PassThru -WindowStyle Minimized

# Esperar a que el server responda /health (timeout 180s, el modelo es grande)
$ready = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    try {
        $h = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq "ok") { $ready = $true; break }
    } catch {}
}
if (-not $ready) {
    Write-Host "El servidor no respondio a tiempo." -ForegroundColor Red
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "Servidor listo. Corriendo prompts de prueba..." -ForegroundColor Green

# Prompts representativos: corto/factual, medio/razonamiento, largo/generacion de codigo.
$prompts = @(
    @{ name = "corto";  text = "Cual es la capital de Francia y por que es importante historicamente? Responde en 2 oraciones."; n_predict = 64 },
    @{ name = "medio";  text = "Explica paso a paso como funciona el mecanismo de atencion en los transformers, con un ejemplo numerico simple."; n_predict = 256 },
    @{ name = "codigo"; text = "Escribe en Python una funcion que implemente quicksort, con comentarios explicando cada paso, y luego una funcion de test con 5 casos."; n_predict = 512 }
)

$rows = @()
foreach ($p in $prompts) {
    for ($r = 1; $r -le $Repeats; $r++) {
        $body = @{
            prompt     = $p.text
            n_predict  = $p.n_predict
            temperature = 0.2
            stream     = $false
        } | ConvertTo-Json

        $t0 = Get-Date
        try {
            $resp = Invoke-RestMethod -Uri "$baseUrl/completion" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300
        } catch {
            Write-Host "Fallo request $($p.name) rep $r : $_" -ForegroundColor Red
            continue
        }
        $wallMs = ((Get-Date) - $t0).TotalMilliseconds

        $t = $resp.timings
        $rows += [pscustomobject]@{
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
        }
        Write-Host ("  {0}/{1} rep{2}: gen {3} tok/s, prompt {4} tok/s" -f $p.name, $label, $r, [math]::Round($t.predicted_per_second,1), [math]::Round($t.prompt_per_second,1))
    }
}

$csvPath = "$resultsDir\server-bench-$label.csv"
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
Write-Host "Resultados guardados en $csvPath" -ForegroundColor Green

Write-Host "Deteniendo servidor..." -ForegroundColor Cyan
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
# Por si el proceso real quedo en un hijo (llama.exe serve puede lanzar el server como subproceso)
Get-Process | Where-Object { $_.Path -eq $llama } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
