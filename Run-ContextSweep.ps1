param(
    [int]$Repeats = 3,
    [int]$Port = 8080
)

# Barrido de ventana de contexto hasta 32k, midiendo tres cosas por escalon: si el servidor
# llega a cargar, cuanta memoria se lleva el KV cache, y a cuantos tok/s genera.
#
# Las variantes f16 en 16k/32k pueden hacer OOM: eso ES el resultado, no un fallo. Bench-Server
# registra la fila con status=oom y el barrido continua.
#
# ctx32k-ram usa -nkvo para dejar el KV cache en RAM del sistema en vez de VRAM. Es la unica
# forma de tener contexto grande sin cuantizar, y el costo en tok/s es justamente lo que esta
# tabla existe para cuantificar: cada token generado tiene que traer el KV por PCIe (~25-30 GB/s)
# en vez de leerlo de VRAM (~360 GB/s).

$root = $PSScriptRoot
$ErrorActionPreference = "Continue"

$variants = @(
    @{ Label = "ctx8k-f16";  Args = @{ Ctx = 8192 };                                                   Nota = "referencia" },
    @{ Label = "ctx16k-f16"; Args = @{ Ctx = 16384 };                                                  Nota = "escalado sin cuantizar" },
    @{ Label = "ctx32k-f16"; Args = @{ Ctx = 32768 };                                                  Nota = "escalado sin cuantizar (posible OOM)" },
    @{ Label = "ctx16k-q8";  Args = @{ Ctx = 16384; CacheTypeK = "q8_0"; CacheTypeV = "q8_0" };        Nota = "KV a la mitad, sigue en VRAM" },
    @{ Label = "ctx32k-q8";  Args = @{ Ctx = 32768; CacheTypeK = "q8_0"; CacheTypeV = "q8_0" };        Nota = "KV a la mitad, sigue en VRAM" },
    @{ Label = "ctx32k-ram"; Args = @{ Ctx = 32768; NoKvOffload = $true };                             Nota = "KV en RAM del sistema (-nkvo)" }
)

Write-Host "=== Barrido de contexto: $($variants.Count) variantes ===" -ForegroundColor Yellow
$n = 0
foreach ($v in $variants) {
    $n++
    Write-Host "`n--- [$n/$($variants.Count)] $($v.Label): $($v.Nota) ---" -ForegroundColor Yellow
    # El splatting exige una variable hashtable (@vars), no una subexpresion.
    $vars = $v.Args
    & "$root\Bench-Server.ps1" @vars -Repeats $Repeats -Port $Port -LabelOverride $v.Label
}

Write-Host "`n=== Generando reporte ===" -ForegroundColor Yellow
& "$root\New-Report.ps1"
