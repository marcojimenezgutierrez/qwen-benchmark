# Benchmark de rendimiento local: Qwen3.8-27B (Q4_K_M) en llama.cpp

Fecha: 2026-08-16 19:28

## Hardware / Software

| Componente | Detalle |
|---|---|
| CPU | AMD Ryzen 9 7900X 12-Core Processor             (12 cores / 24 threads) |
| RAM | 63.2 GB |
| GPU | NVIDIA GeForce RTX 3060 - 4 GB VRAM (driver 32.0.15.7688); NVIDIA GeForce RTX 3060 - 4 GB VRAM (driver 32.0.15.7688) |
| SO | Microsoft Windows 11 Enterprise (Build 26200) |
| Disco | ADATA LEGEND 900 (954 GB) |
| nvidia-smi | NVIDIA GeForce RTX 3060, 12288 MiB, 576.88, 8.6; NVIDIA GeForce RTX 3060, 12288 MiB, 576.88, 8.6 |

## Resultados finales (2026-08-18)

Estos hallazgos no vienen de `Bench-Server.ps1` (algunos requirieron pruebas puntuales fuera del
barrido automatico) y son los que definen la configuracion de produccion en
`C:\Users\Marco\Desktop\llama-serve-qwen3.8.ps1`.

### Config ganadora: MTP self-referenciado sobre el gguf de unsloth

`unsloth/Qwen3.8-27B-GGUF` trae los tensores de MTP incluidos en el propio archivo, a diferencia
de `ggml-org/Qwen3.8-27B-GGUF` que requeria un gguf de draft model aparte. Se activa con
`--spec-type draft-mtp` solo, sin `--spec-draft-model`: el log de arranque confirma
`creating MTP draft context against the target model` referenciando el mismo gguf principal.

| Config | gen tok/s medido |
|---|---:|
| ggml-org, sin MTP (`spd-layer` / `ctx*-f16`) | ~15.4-15.8 |
| unsloth, sin MTP (`unsloth-reff-*`) | ~17.5-17.8 |
| **unsloth, MTP self-referenciado** | **~24.4 - 26.8** |

El salto grande (+41-73% sobre la config vieja del script de produccion) lo da el MTP, no el
cambio de quant en si. Confirmado con dos pruebas independientes (24.43 tok/s y 26.78 tok/s,
mismo prompt de codigo, corridas separadas) y verificado end-to-end corriendo
`llama-serve-qwen3.8.ps1` actualizado: el servidor carga, responde `/health` y sirve
`/completion` con normalidad. Esta prueba puntual no quedo en un CSV del barrido (no paso por
`Bench-Server.ps1`), asi que no aparece en las tablas de abajo.

**Nota sobre la fila `base` de la tabla de resumen**: sus 27.65 tok/s son de la corrida del
2026-08-16, anterior al fix de `cache_prompt=false` (ver `## Procesamiento de prompt` mas abajo,
donde queda marcada como invalida por reusar el prefijo cacheado). No es comparable contra el
resto de filas ni contra el MTP self-referenciado; se deja en la tabla por trazabilidad historica
del repo, no como referencia de velocidad.

### `reasoning_effort`: no es una palanca de velocidad, y el ahorro de tokens es inconsistente

Confirmado a nivel de plantilla (via `/apply-template`) que `--chat-template-kwargs
{"reasoning_effort":"..."}` si inyecta el system prompt correcto (`xhigh` es el default real del
modelo). Con 3 repeticiones, tope de contexto ampliado y sin truncar `n_predict`:

| Prompt | tokens xhigh | tokens low | Efecto |
|---|---:|---:|---|
| corto | 164 | 207 | low usa **mas** tokens |
| medio | **13,018** (natural, ver abajo) | 3,657 | low usa **72% menos** |
| codigo | 662 | 1,226 | low usa **casi el doble** |

`gen_tok_s` no cambia entre `xhigh` y `low` (~17.5-17.8 en ambos) - el efecto es puramente sobre
cuantos tokens genera el modelo, no la velocidad por token, y ese efecto solo es favorable en
tareas de razonamiento largo. En prompts cortos o de codigo, bajar el esfuerzo no ahorra nada y
puede generar mas tokens.

El prompt "medio" con `xhigh` parecia no terminar nunca con `-c 8192` (`gen_tokens=8117` en 2 de
3 repeticiones, exactamente `8192 - 75 tokens de prompt`): no era un loop del modelo, era el
servidor quedandose sin contexto. Con `-c 32768` y presupuesto de 30000 tokens, el mismo prompt
termino solo (`finish_reason=stop`) en 13,018 tokens tras ~13.4 minutos. Esto confirma que
`-c 8192` es insuficiente para medir "tokens hasta terminar" en modo `xhigh`, y motivo subir el
contexto default de `Bench-Server.ps1` de 8192 a 16384.

### Limitaciones de hardware confirmadas

- `-sm row` no carga en estas 2x RTX 3060 ("device CUDA0 does not support split buffers"):
  `-sm layer` es la unica opcion viable.
- `-nkvo` (KV cache en RAM del sistema) cae a ~2.9 tok/s (~5.4x mas lento): el ancho de banda
  PCIe es el cuello de botella real cuando el KV no esta en VRAM. Evitar salvo necesidad real de
  contexto que no entre en VRAM.
- KV cache `f16` vs `q8_0` no cambia `gen_tok_s` en ningun escenario probado (8k-32k de ctx).

## Resumen por variante

Mediana de `gen_tok_s` sobre todas las cargas. Medido via `/completion` con `cache_prompt=false`.

| Variante | ctx | split | cache K/V | KV en RAM | Mediana gen tok/s | KV MiB | VRAM MiB | Estado |
|---|---|---|---|---|---|---|---|---|
| `base` | - | - | -/- | - | 27.65 | - | - | ok |
| `ctx16k-f16` | 16384 | layer | f16/f16 | False | 15.51 | - | 20626 | ok |
| `ctx16k-q8` | 16384 | layer | q8_0/q8_0 | False | 15.99 | - | 20318 | ok |
| `ctx32k-f16` | 32768 | layer | f16/f16 | False | 9.43 | - | 21761 | ok |
| `ctx32k-q8` | 32768 | layer | q8_0/q8_0 | False | 15.95 | - | 21106 | ok |
| `ctx32k-ram` | 32768 | layer | f16/f16 | True | 2.91 | - | 19821 | ok |
| `ctx8k-f16` | 8192 | layer | f16/f16 | False | 15.72 | - | 19924 | ok |
| `mtp` | - | - | -/- | - | 13.78 | - | - | ok |
| `mtp-gpu` | - | - | -/- | - | 24.1 | - | - | ok |
| `reff-low` | 8192 | layer | f16/f16 | False | 15.33 | - | 20397 | ok |
| `reff-low-notrunc` | 8192 | layer | f16/f16 | False | 15.93 | - | 20462 | ok |
| `reff-xhigh-notrunc` | 8192 | layer | f16/f16 | False | 15.23 | - | 20398 | ok |
| `spd-layer` | 8192 | layer | f16/f16 | False | 15.73 | - | 19960 | ok |
| `spd-layer-faoff` | 8192 | layer | f16/f16 | False | 15.64 | - | 20349 | ok |
| `spd-layer-q8` | 8192 | layer | q8_0/q8_0 | False | 15.96 | - | 19747 | ok |
| `spd-row` | 8192 | row | f16/f16 | False | - | - | - | load-failed |
| `spd-row-q8` | 8192 | row | q8_0/q8_0 | False | - | - | - | load-failed |
| `unsloth-reff-low` | 8192 | layer | f16/f16 | False | 17.64 | - | 18205 | ok |
| `unsloth-reff-xhigh` | 8192 | layer | f16/f16 | False | 17.6 | - | 18050 | ok |

**Mas rapida: `base` con 27.65 tok/s de mediana.**

## Detalle por carga

| Variante | Carga | Mediana | Min | Max | Media | n |
|---|---|---:|---:|---:|---:|---:|
| `base` | corto | **27.77** | 27.3 | 29.14 | 28.07 | 3 |
| `base` | medio | **27.71** | 27.65 | 29.06 | 28.14 | 3 |
| `base` | codigo | **26.56** âš  | 17.82 | 26.73 | 23.7 | 3 |
| `ctx16k-f16` | corto | **15.43** | 15.39 | 15.44 | 15.42 | 3 |
| `ctx16k-f16` | medio | **15.51** | 15.46 | 15.51 | 15.49 | 3 |
| `ctx16k-f16` | codigo | **15.84** | 15.74 | 15.87 | 15.82 | 3 |
| `ctx16k-q8` | corto | **15.99** | 15.98 | 16 | 15.99 | 3 |
| `ctx16k-q8` | medio | **16.01** | 16.01 | 16.01 | 16.01 | 3 |
| `ctx16k-q8` | codigo | **15.84** | 15.78 | 15.99 | 15.87 | 3 |
| `ctx32k-f16` | corto | **3.57** | 3.26 | 3.95 | 3.59 | 3 |
| `ctx32k-f16` | medio | **9.43** | 4.22 | 15.91 | 9.85 | 3 |
| `ctx32k-f16` | codigo | **15.91** âš  | 13.32 | 15.93 | 15.05 | 3 |
| `ctx32k-q8` | corto | **15.93** | 15.79 | 15.93 | 15.88 | 3 |
| `ctx32k-q8` | medio | **15.98** | 15.5 | 15.99 | 15.82 | 3 |
| `ctx32k-q8` | codigo | **15.97** | 15.95 | 15.98 | 15.97 | 3 |
| `ctx32k-ram` | corto | **2.94** | 2.93 | 2.97 | 2.95 | 3 |
| `ctx32k-ram` | medio | **2.91** | 2.91 | 2.91 | 2.91 | 3 |
| `ctx32k-ram` | codigo | **2.86** | 2.86 | 2.86 | 2.86 | 3 |
| `ctx8k-f16` | corto | **15.79** | 15.61 | 15.81 | 15.74 | 3 |
| `ctx8k-f16` | medio | **15.55** | 15.28 | 15.83 | 15.55 | 3 |
| `ctx8k-f16` | codigo | **15.72** | 15.53 | 15.8 | 15.68 | 3 |
| `mtp` | corto | **13.78** | 13.69 | 15.05 | 14.17 | 3 |
| `mtp` | medio | **13.2** | 12.35 | 13.59 | 13.05 | 3 |
| `mtp` | codigo | **14.07** | 13.97 | 14.26 | 14.1 | 3 |
| `mtp-gpu` | corto | **24.1** âš  | 23.99 | 28.05 | 25.38 | 3 |
| `mtp-gpu` | medio | **20.06** | 17.64 | 21.42 | 19.71 | 3 |
| `mtp-gpu` | codigo | **25.23** | 24.23 | 29.44 | 26.3 | 3 |
| `reff-low` | corto | **15.22** | 15.2 | 15.24 | 15.22 | 3 |
| `reff-low` | medio | **15.33** | 15.25 | 15.59 | 15.39 | 3 |
| `reff-low` | codigo | **15.75** | 15.59 | 15.78 | 15.71 | 3 |
| `reff-low-notrunc` | corto | **16.13** | 16.13 | 16.13 | 16.13 | 1 |
| `reff-low-notrunc` | medio | **15.02** | 15.02 | 15.02 | 15.02 | 1 |
| `reff-low-notrunc` | codigo | **15.93** | 15.93 | 15.93 | 15.93 | 1 |
| `reff-xhigh-notrunc` | corto | **15.05** | 15.05 | 15.05 | 15.05 | 1 |
| `reff-xhigh-notrunc` | medio | **15.23** | 15.23 | 15.23 | 15.23 | 1 |
| `reff-xhigh-notrunc` | codigo | **16.07** | 16.07 | 16.07 | 16.07 | 1 |
| `spd-layer` | corto | **15.76** | 15.73 | 15.77 | 15.75 | 3 |
| `spd-layer` | medio | **15.75** | 15.69 | 15.84 | 15.76 | 3 |
| `spd-layer` | codigo | **15.66** | 15.41 | 15.72 | 15.6 | 3 |
| `spd-layer-faoff` | corto | **15.46** | 14.95 | 15.46 | 15.29 | 3 |
| `spd-layer-faoff` | medio | **15.64** | 15.54 | 15.84 | 15.67 | 3 |
| `spd-layer-faoff` | codigo | **15.7** | 15.64 | 16.09 | 15.81 | 3 |
| `spd-layer-q8` | corto | **15.99** | 15.96 | 16 | 15.98 | 3 |
| `spd-layer-q8` | medio | **15.93** | 15.69 | 15.97 | 15.86 | 3 |
| `spd-layer-q8` | codigo | **15.86** | 15.81 | 15.96 | 15.88 | 3 |
| `unsloth-reff-low` | corto | **17.66** | 17.64 | 17.66 | 17.65 | 3 |
| `unsloth-reff-low` | medio | **17.54** | 17.53 | 17.55 | 17.54 | 3 |
| `unsloth-reff-low` | codigo | **17.82** | 16.35 | 17.83 | 17.33 | 3 |
| `unsloth-reff-xhigh` | corto | **17.67** âš  | 14.05 | 17.78 | 16.5 | 3 |
| `unsloth-reff-xhigh` | medio | **16.52** | 16.45 | 17.4 | 16.79 | 3 |
| `unsloth-reff-xhigh` | codigo | **17.63** | 17.6 | 17.63 | 17.62 | 3 |

> âš  marca los casos donde la media se aparta mas de 5% de la mediana: hay al menos una
> repeticion atipica y el promedio no representa la corrida.

## Procesamiento de prompt (prefill)

| Variante | Carga | Mediana prompt tok/s | prompt_tokens | Valido |
|---|---|---:|---|---|
| `base` | corto | 12.41 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `base` | medio | 12.24 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `base` | codigo | 12.05 | 30, 4 | **no** - cache_prompt activo (30, 4) |
| `ctx16k-f16` | corto | 72.11 | 23 | si |
| `ctx16k-f16` | medio | 72.59 | 23 | si |
| `ctx16k-f16` | codigo | 94.31 | 30 | si |
| `ctx16k-q8` | corto | 73.36 | 23 | si |
| `ctx16k-q8` | medio | 73.39 | 23 | si |
| `ctx16k-q8` | codigo | 93.43 | 30 | si |
| `ctx32k-f16` | corto | 33.97 | 23 | si |
| `ctx32k-f16` | medio | 48.77 | 23 | si |
| `ctx32k-f16` | codigo | 93.46 | 30 | si |
| `ctx32k-q8` | corto | 71.91 | 23 | si |
| `ctx32k-q8` | medio | 72.92 | 23 | si |
| `ctx32k-q8` | codigo | 93.04 | 30 | si |
| `ctx32k-ram` | corto | 25.51 | 23 | si |
| `ctx32k-ram` | medio | 24.25 | 23 | si |
| `ctx32k-ram` | codigo | 32.73 | 30 | si |
| `ctx8k-f16` | corto | 73.09 | 23 | si |
| `ctx8k-f16` | medio | 72 | 23 | si |
| `ctx8k-f16` | codigo | 91.07 | 30 | si |
| `mtp` | corto | 10.88 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `mtp` | medio | 10.97 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `mtp` | codigo | 10.7 | 30, 4 | **no** - cache_prompt activo (30, 4) |
| `mtp-gpu` | corto | 11.98 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `mtp-gpu` | medio | 11.81 | 23, 4 | **no** - cache_prompt activo (23, 4) |
| `mtp-gpu` | codigo | 12.11 | 30, 4 | **no** - cache_prompt activo (30, 4) |
| `reff-low` | corto | 111.19 | 63 | si |
| `reff-low` | medio | 109.71 | 63 | si |
| `reff-low` | codigo | 121.41 | 70 | si |
| `reff-low-notrunc` | corto | 117.52 | 63 | si |
| `reff-low-notrunc` | medio | 116.62 | 63 | si |
| `reff-low-notrunc` | codigo | 125.1 | 70 | si |
| `reff-xhigh-notrunc` | corto | 126.59 | 75 | si |
| `reff-xhigh-notrunc` | medio | 126.49 | 75 | si |
| `reff-xhigh-notrunc` | codigo | 142.37 | 82 | si |
| `spd-layer` | corto | 73.42 | 23 | si |
| `spd-layer` | medio | 73.83 | 23 | si |
| `spd-layer` | codigo | 93.18 | 30 | si |
| `spd-layer-faoff` | corto | 71.07 | 23 | si |
| `spd-layer-faoff` | medio | 73.04 | 23 | si |
| `spd-layer-faoff` | codigo | 90.81 | 30 | si |
| `spd-layer-q8` | corto | 73.91 | 23 | si |
| `spd-layer-q8` | medio | 73.09 | 23 | si |
| `spd-layer-q8` | codigo | 94.26 | 30 | si |
| `unsloth-reff-low` | corto | 117.75 | 63 | si |
| `unsloth-reff-low` | medio | 117.47 | 63 | si |
| `unsloth-reff-low` | codigo | 127.01 | 70 | si |
| `unsloth-reff-xhigh` | corto | 132.72 | 75 | si |
| `unsloth-reff-xhigh` | medio | 128.84 | 75 | si |
| `unsloth-reff-xhigh` | codigo | 142.92 | 82 | si |

## Ventana de contexto vs velocidad y memoria

| Variante | ctx | cache K/V | KV en RAM | Cargo | KV MiB | VRAM MiB | Mediana gen tok/s | vs 8k |
|---|---:|---|---|---|---:|---:|---:|---:|
| `ctx8k-f16` | 8192 | f16/f16 | False | si | - | 19924 | 15.72 | 0% |
| `reff-low` | 8192 | f16/f16 | False | si | - | 20397 | 15.33 | -2.5% |
| `reff-low-notrunc` | 8192 | f16/f16 | False | si | - | 20462 | 15.93 | 1.3% |
| `reff-xhigh-notrunc` | 8192 | f16/f16 | False | si | - | 20398 | 15.23 | -3.1% |
| `spd-layer` | 8192 | f16/f16 | False | si | - | 19960 | 15.73 | 0.1% |
| `spd-layer-faoff` | 8192 | f16/f16 | False | si | - | 20349 | 15.64 | -0.5% |
| `spd-layer-q8` | 8192 | q8_0/q8_0 | False | si | - | 19747 | 15.96 | 1.5% |
| `spd-row` | 8192 | f16/f16 | False | **no** (load-failed) | - | - | - | - |
| `spd-row-q8` | 8192 | q8_0/q8_0 | False | **no** (load-failed) | - | - | - | - |
| `unsloth-reff-low` | 8192 | f16/f16 | False | si | - | 18205 | 17.64 | 12.2% |
| `unsloth-reff-xhigh` | 8192 | f16/f16 | False | si | - | 18050 | 17.6 | 12% |
| `ctx16k-f16` | 16384 | f16/f16 | False | si | - | 20626 | 15.51 | -1.3% |
| `ctx16k-q8` | 16384 | q8_0/q8_0 | False | si | - | 20318 | 15.99 | 1.7% |
| `ctx32k-f16` | 32768 | f16/f16 | False | si | - | 21761 | 9.43 | -40% |
| `ctx32k-q8` | 32768 | q8_0/q8_0 | False | si | - | 21106 | 15.95 | 1.5% |
| `ctx32k-ram` | 32768 | f16/f16 | True | si | - | 19821 | 2.91 | -81.5% |

## Modelo y coherencia de las mediciones

> No hay `model-info.json`. Se genera solo al correr `Bench-Server.ps1` con la version
> actual del script, que captura el log de carga del servidor.

Tamanio del modelo en memoria: **18.96 GB**. Un modelo denso lee todos sus pesos una vez
por token generado, asi que `tok/s x 18.96 GB` da el ancho de banda implicito. Con
`--split-mode layer` las GPUs trabajan en secuencia, de modo que ese numero no puede superar
el ancho de banda de **una sola** GPU.

| Fuente | Prueba | tok/s | Ancho de banda implicito |
|---|---|---:|---:|
| llama-bench | tg128 | 16.14 | 306 GB/s |
| llama-bench | tg512 | 16.12 | 306 GB/s |
| servidor | `base` | 27.65 | 524 GB/s |
| servidor | `ctx16k-f16` | 15.51 | 294 GB/s |
| servidor | `ctx16k-q8` | 15.99 | 303 GB/s |
| servidor | `ctx32k-f16` | 9.43 | 179 GB/s |
| servidor | `ctx32k-q8` | 15.95 | 302 GB/s |
| servidor | `ctx32k-ram` | 2.91 | 55 GB/s |
| servidor | `ctx8k-f16` | 15.72 | 298 GB/s |
| servidor | `mtp` | 13.78 | 261 GB/s |
| servidor | `mtp-gpu` | 24.1 | 457 GB/s |
| servidor | `reff-low` | 15.33 | 291 GB/s |
| servidor | `reff-low-notrunc` | 15.93 | 302 GB/s |
| servidor | `reff-xhigh-notrunc` | 15.23 | 289 GB/s |
| servidor | `spd-layer` | 15.73 | 298 GB/s |
| servidor | `spd-layer-faoff` | 15.64 | 297 GB/s |
| servidor | `spd-layer-q8` | 15.96 | 303 GB/s |
| servidor | `unsloth-reff-low` | 17.64 | 334 GB/s |
| servidor | `unsloth-reff-xhigh` | 17.6 | 334 GB/s |

> Si el modelo es denso y alguna fila del servidor implica mas ancho de banda del que tiene
> una GPU, esa medicion esta mal y hay que resolverlo antes de optimizar nada. Si el modelo
> es MoE, solo se lee una fraccion de los pesos por token y la comparacion no aplica.

## Baseline llama-bench (motor puro, sin servidor HTTP de por medio)

ggml_cuda_init: found 2 CUDA devices (Total VRAM: 24575 MiB):
  Device 0: NVIDIA GeForce RTX 3060, compute capability 8.6, VMM: yes, VRAM: 12287 MiB
  Device 1: NVIDIA GeForce RTX 3060, compute capability 8.6, VMM: yes, VRAM: 12287 MiB
load_backend: loaded CUDA backend from C:\Users\Marco\AppData\Local\Microsoft\WindowsApps\ggml-cuda.dll
load_backend: loaded RPC backend from C:\Users\Marco\AppData\Local\Microsoft\WindowsApps\ggml-rpc.dll
load_backend: loaded CPU backend from C:\Users\Marco\AppData\Local\Microsoft\WindowsApps\ggml-cpu-zen4.dll
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35 27B Q4_K - Medium       |  17.66 GiB |    26.90 B | CUDA       | 999 |   1 |           pp512 |        556.20 ± 2.97 |
| qwen35 27B Q4_K - Medium       |  17.66 GiB |    26.90 B | CUDA       | 999 |   1 |          pp2048 |        810.20 ± 1.99 |
| qwen35 27B Q4_K - Medium       |  17.66 GiB |    26.90 B | CUDA       | 999 |   1 |          pp4096 |        869.84 ± 2.74 |
| qwen35 27B Q4_K - Medium       |  17.66 GiB |    26.90 B | CUDA       | 999 |   1 |           tg128 |         16.14 ± 0.07 |
| qwen35 27B Q4_K - Medium       |  17.66 GiB |    26.90 B | CUDA       | 999 |   1 |           tg512 |         16.12 ± 0.04 |

build: 3cb7ffb1a (10453)


## Datos crudos

- `results/server-bench-base.csv`
- `results/server-bench-ctx16k-f16.csv`
- `results/server-bench-ctx16k-q8.csv`
- `results/server-bench-ctx32k-f16.csv`
- `results/server-bench-ctx32k-q8.csv`
- `results/server-bench-ctx32k-ram.csv`
- `results/server-bench-ctx8k-f16.csv`
- `results/server-bench-mtp.csv`
- `results/server-bench-mtp-gpu.csv`
- `results/server-bench-reff-low.csv`
- `results/server-bench-reff-low-notrunc.csv`
- `results/server-bench-reff-xhigh-notrunc.csv`
- `results/server-bench-spd-layer.csv`
- `results/server-bench-spd-layer-faoff.csv`
- `results/server-bench-spd-layer-q8.csv`
- `results/server-bench-spd-row.csv`
- `results/server-bench-spd-row-q8.csv`
- `results/server-bench-unsloth-reff-low.csv`
- `results/server-bench-unsloth-reff-xhigh.csv`
- `results/llama-bench-baseline.json` / `.md` - salida de llama-bench
- `results/sysinfo.json` - specs de hardware
- `results/logs/` - logs de arranque del servidor por variante
