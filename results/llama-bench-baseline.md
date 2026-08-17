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
