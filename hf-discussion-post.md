## Benchmark: Qwen3.8-27B Q4_K_M on 2x RTX 3060 (24GB total), llama.cpp + MTP speculative decoding

Sharing local inference numbers in case they're useful for anyone sizing similar dual-GPU consumer setups.

### Hardware
- CPU: AMD Ryzen 9 7900X (12c/24t)
- GPU: 2x NVIDIA RTX 3060 12GB (24GB VRAM total), driver 576.88
- RAM: 64GB
- OS: Windows 11
- llama.cpp build: 3cb7ffb1a (10453)

### Setup
- Model: `ggml-org/Qwen3.8-27B-GGUF:Q4_K_M` (26.90B params, 17.66 GiB), `-ngl 999`, `--flash-attn on`
- Context tested up to 32768 (loads with ~1GB headroom on the tighter GPU); 40960 loads but leaves only ~200MB free (risky); 65536 OOMs.
- MTP draft model tested both with `--spec-draft-ngl 0` (CPU) and `--spec-draft-ngl 999` (GPU).

### llama-bench (pure engine, no MTP)

| Test | tok/s |
|---|---|
| pp512 | 556.20 ± 2.97 |
| pp2048 | 810.20 ± 1.99 |
| pp4096 | 869.84 ± 2.74 |
| tg128 | 16.14 ± 0.07 |
| tg512 | 16.12 ± 0.04 |

### Server generation speed (real `/completion` requests, 3 reps/prompt)

| Prompt | No MTP | MTP draft-CPU | MTP draft-GPU |
|---|---|---|---|
| short factual | 28.1 tok/s | 14.2 tok/s | 25.4 tok/s |
| medium reasoning | 28.1 tok/s | 13.1 tok/s | 19.7 tok/s |
| code generation | 23.7 tok/s | 14.1 tok/s | **26.3 tok/s** |

### Takeaway

On this hardware, MTP with the draft model on CPU (`--spec-draft-ngl 0`) is consistently the *slowest* option — 41-54% slower than not using MTP at all. Moving the draft model to GPU (`--spec-draft-ngl 999`) recovers most of the loss and even beats the no-MTP baseline on code generation, but it's not a consistent win across prompt types. Speculative decoding acceptance rate with this draft model doesn't seem high enough on dual RTX 3060 to pay for itself outside of very predictable (code-heavy) generation.

For general use on this GPU pair, running without MTP gave the most consistent throughput (~28 tok/s). Happy to share raw CSVs/methodology if useful.
