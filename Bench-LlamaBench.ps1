# Benchmark puro con llama-bench: velocidad de prompt-processing (pp) y generacion (tg)
# del modelo base, SIN MTP, para tener una linea base reproducible de hardware+modelo.
$llamaBench = "$env:LOCALAPPDATA\Microsoft\WindowsApps\llama-bench.exe"
$modelRepo = "ggml-org/Qwen3.8-27B-GGUF:Q4_K_M"
$resultsDir = "$PSScriptRoot\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

Write-Host "Corriendo llama-bench (baseline, sin MTP)..." -ForegroundColor Cyan

# Matriz: distintos tamanios de prompt/generacion para ver comportamiento en
# contextos cortos, medios y largos. 3 repeticiones por punto para desviacion estandar.
# Se usa cmd /c para la redireccion: en PowerShell 5.1, "2>" sobre un exe nativo
# envuelve el log normal de stderr (init de CUDA) en un NativeCommandError.
$jsonPath = "$resultsDir\llama-bench-baseline.json"
$mdPath = "$resultsDir\llama-bench-baseline.md"
$argLine = "-hf `"$modelRepo`" -ngl 999 -p 512,2048,4096 -n 128,512 -r 3 -fa on -o json -oe md"
cmd /c "`"$llamaBench`" $argLine 2>`"$mdPath`" 1>`"$jsonPath`""
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host "llama-bench devolvio codigo $exitCode (revisa $mdPath)" -ForegroundColor Yellow
}

Write-Host "Listo. Resultados en $resultsDir\llama-bench-baseline.*" -ForegroundColor Green
