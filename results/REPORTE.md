# Benchmark de rendimiento local: Qwen3.8-27B (Q4_K_M) + MTP en llama.cpp

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

Modelo: **Qwen3.8-27B GGUF Q4_K_M**, draft model MTP para speculative decoding, `-ngl 999` (offload total a GPU), contexto 8192.

## Resultado principal: impacto de MTP (speculative decoding)

Tokens/segundo de **generacion** medidos via el servidor HTTP real (`/completion`, campo `timings`), promedio de 3 repeticiones por prompt. Se probaron tres variantes: sin MTP, con MTP y el draft model en CPU (`--spec-draft-ngl 0`, config original), y con MTP y el draft model tambien en GPU (`--spec-draft-ngl 999`).

| Prompt | Sin MTP (tok/s) | MTP draft-CPU (tok/s) | MTP draft-GPU (tok/s) | Mejor variante |
|---|---|---|---|---|
| corto | 28.07 | 14.17 | 25.38 | sin MTP (28.07) |
| medio | 28.14 | 13.05 | 19.71 | sin MTP (28.14) |
| codigo | 23.7 | 14.1 | 26.3 | MTP draft-GPU (26.3) |

> **Conclusion:** en este hardware (2x RTX 3060 12GB), `--spec-draft-ngl 0` (draft en CPU, la config original
> del script `llama-serve-qwen3.8.ps1`) es claramente la peor opcion - el costo de mover datos CPU<->GPU
> para verificar cada token especulativo supera el ahorro. Poner el draft tambien en GPU
> (`--spec-draft-ngl 999`) recupera la mayor parte del rendimiento y en el prompt de codigo llega a superar
> el caso sin MTP, pero en general el aporte de MTP con este draft model no es consistente: no justifica
> activarlo por defecto salvo para cargas dominadas por generacion de codigo/texto muy predecible.

## Velocidad de procesamiento de prompt (prefill)

| Prompt | Sin MTP (tok/s) | MTP draft-CPU (tok/s) | MTP draft-GPU (tok/s) |
|---|---|---|---|
| corto | 16.49 | 28.06 | 19.34 |
| medio | 30.83 | 23.6 | 29.99 |
| codigo | 35.77 | 28.81 | 34.81 |

## Baseline llama-bench (motor puro, sin servidor HTTP de por medio)

Ver `results/llama-bench-baseline.md` para la tabla completa (pp512/2048/4096, tg128/512, 3 repeticiones cada uno, con desviacion estandar).

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

- `results/server-bench-base.csv` - corridas individuales sin MTP
- `results/server-bench-mtp.csv` - corridas individuales con MTP, draft en CPU
- `results/server-bench-mtp-gpu.csv` - corridas individuales con MTP, draft en GPU
- `results/llama-bench-baseline.json` / `.md` - salida de llama-bench
- `results/sysinfo.json` - specs de hardware
