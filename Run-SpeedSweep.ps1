param(
    [int]$Repeats = 3,
    [int]$Port = 8080
)

# Barrido de configuraciones que afectan tokens/segundo, a contexto fijo (8192) y un solo
# usuario (-np 1). Cada variante levanta y tumba su propio servidor.
#
# Hipotesis principal: -sm row. Con el default (-sm layer) las dos RTX 3060 procesan sus capas
# en secuencia, nunca a la vez, asi que se paga por dos GPUs y se usa el ancho de banda de una.
# Con -sm row ambas trabajan sobre la misma capa y el ancho de banda se suma. El riesgo es que
# el trafico entre GPUs por PCIe se coma la ganancia, y por eso hay que medirlo.

$root = $PSScriptRoot
$ErrorActionPreference = "Continue"

$variants = @(
    @{ Label = "spd-layer";      Args = @{ SplitMode = "layer" };                                   Nota = "referencia actual (-fa on)" },
    @{ Label = "spd-layer-faoff";Args = @{ SplitMode = "layer"; FlashAttn = "auto" };               Nota = "sin -fa explicito: reproduce la config historica" },
    @{ Label = "spd-row";        Args = @{ SplitMode = "row" };                                     Nota = "hipotesis principal: GPUs en paralelo" },
    @{ Label = "spd-layer-q8";   Args = @{ SplitMode = "layer"; CacheTypeK = "q8_0"; CacheTypeV = "q8_0" }; Nota = "KV cuantizado: verifica que no cueste velocidad" },
    @{ Label = "spd-row-q8";     Args = @{ SplitMode = "row";   CacheTypeK = "q8_0"; CacheTypeV = "q8_0" }; Nota = "combinacion de las dos anteriores" }
)

Write-Host "=== Barrido de velocidad: $($variants.Count) variantes ===" -ForegroundColor Yellow
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
