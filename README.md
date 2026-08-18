# Qwen3.8-27B Benchmark Suite - llama.cpp + MTP Speculative Decoding

Comprehensive benchmark suite for evaluating the Qwen3.8-27B GGUF model's performance on llama.cpp with and without MTP (Multi-Token Prediction / speculative decoding) on consumer GPUs.

## Overview

This suite contains:

1. **Pure Inference Baseline** (`Bench-LlamaBench.ps1`) - llama-bench motor benchmark
2. **Server Performance** (`Bench-Server.ps1`) - Real HTTP server /completion endpoint testing, fully parameterized
3. **Speed Sweep** (`Run-SpeedSweep.ps1`) - Compares split mode, flash attention and KV quantization
4. **Context Sweep** (`Run-ContextSweep.ps1`) - Scales the context window to 32k and measures the cost
5. **Report Generator** (`New-Report.ps1`) - Builds `REPORTE.md` from whatever variants exist
6. **Full Suite Orchestration** (`Run-FullBenchmark.ps1`) - Complete benchmark workflow

## Quick Start

Run the complete benchmark suite:
```powershell
.\Run-FullBenchmark.ps1
```

MTP is opt-in now (see Results Interpretation for why):
```powershell
.\Run-FullBenchmark.ps1 -IncludeMTP -IncludeSweeps
```

Or run individual benchmarks:
```powershell
.\Get-SysInfo.ps1                           # Collect system specs
.\Bench-LlamaBench.ps1                      # Pure llama-bench baseline
.\Bench-Server.ps1                          # Server, default config
.\Bench-Server.ps1 -DryRun                  # Print the server command line and exit
.\Bench-Server.ps1 -SplitMode row           # Both GPUs on the same layer
.\Bench-Server.ps1 -Ctx 32768 -CacheTypeK q8_0 -CacheTypeV q8_0
.\Bench-Server.ps1 -Ctx 32768 -NoKvOffload  # KV cache in system RAM
.\Run-SpeedSweep.ps1                        # Full speed matrix
.\Run-ContextSweep.ps1                      # Full context matrix
.\New-Report.ps1                            # Regenerate REPORTE.md from existing CSVs
```

Before a long run, confirm your llama.cpp build exposes these flags:
```powershell
llama serve --help | findstr /i "split-mode cache-type kv-offload flash-attn"
```

---

## Benchmark Parameters

### 1. llama-bench Baseline (`Bench-LlamaBench.ps1`)

**Purpose:** Measure pure inference speed (prompt processing + token generation) without HTTP server overhead.

**Key Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Model** | `ggml-org/Qwen3.8-27B-GGUF:Q4_K_M` | Qwen 3.8B quantized to 4-bit with K-means, ~17.66 GiB |
| **GPU Offload** | `-ngl 999` | Offload all layers to GPU (full GPU acceleration) |
| **Flash Attention** | `-fa on` | Enable Flash Attention for optimized attention computation |
| **Prompt Sizes** | `-p 512,2048,4096` | Test prompt processing speeds at 512, 2048, and 4096 tokens |
| **Generation Sizes** | `-n 128,512` | Test generation speeds when producing 128 and 512 tokens |
| **Repetitions** | `-r 3` | Run each configuration 3 times to calculate standard deviation |
| **Output Format** | `-o json -oe md` | Output results in JSON and Markdown formats |

**Metrics Produced:**
- `pp512`, `pp2048`, `pp4096`: Prompt processing speed (tokens/second)
- `tg128`, `tg512`: Token generation speed (tokens/second)
- Standard deviation for each measurement

**Output Files:**
- `results/llama-bench-baseline.json` - Raw JSON results
- `results/llama-bench-baseline.md` - Formatted Markdown table with statistics

---

### 2. Server Benchmark (`Bench-Server.ps1`)

**Purpose:** Measure real-world inference performance via HTTP /completion endpoint, simulating actual usage patterns.

**Parameters:**

#### Base Configuration

| Parameter | Default | Script param | Description |
|-----------|---------|--------------|-------------|
| **Model** | `ggml-org/Qwen3.8-27B-GGUF:Q4_K_M` | - | Same quantized model as baseline |
| **Context Window** | `-c 8192` | `-Ctx` | Maximum context size |
| **Parallel Requests** | `-np 1` | `-Parallel` | Number of parallel slots (1 = sequential) |
| **GPU Offload** | `-ngl 999` | `-Ngl` | Full GPU acceleration |
| **Split Mode** | `-sm layer` | `-SplitMode` | `layer` = GPUs in sequence, `row` = GPUs in parallel on the same layer |
| **Flash Attention** | `-fa on` | `-FlashAttn` | `on`/`off`/`auto`. **Changed:** previously not passed at all, which left it at llama.cpp's `auto` |
| **KV Cache Type** | `--cache-type-k/v f16` | `-CacheTypeK` / `-CacheTypeV` | `q8_0` halves KV memory, `q4_0` quarters it. Requires flash attention on CUDA |
| **KV Offload** | (enabled) | `-NoKvOffload` | Passes `-nkvo`: keeps the KV cache in system RAM instead of VRAM |
| **Tensor Split** | (auto) | `-TensorSplit` | Passes `-ts`, e.g. `1,1` to force an even split |
| **Port** | `--port 8080` | `-Port` | HTTP server port |
| **No MMProj** | `--no-mmproj` | - | Disable multimodal projections |

> **`-fa on` is now passed explicitly.** `Bench-LlamaBench.ps1` always passed it and the server
> never did, which made the two benchmarks not directly comparable. This changes the meaning of
> the `base` variant relative to the historical CSVs in `results/`.

#### MTP (Speculative Decoding) Configuration

| Parameter | Default | When Used | Description |
|-----------|---------|-----------|-------------|
| **Draft Model** | Qwen3.8-27B MTP | When `-UseMTP` | Smaller model for speculative token prediction |
| **Draft GPU Offload** | `--spec-draft-ngl 0` | CPU mode | Draft model runs on CPU (original config) |
| **Draft GPU Offload** | `--spec-draft-ngl 999` | GPU mode | Draft model runs on GPU (optimized) |
| **Spec Type** | `--spec-type draft-mtp` | Always with MTP | Speculative decoding strategy |

#### Request Parameters

For each test prompt:

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Temperature** | `0.2` | Low randomness for consistent, factual responses |
| **n_predict** | 64/256/512 | Max tokens to generate (varies by prompt) |
| **stream** | `false` | Get full response at once (not streaming) |
| **cache_prompt** | `false` | **Required.** With llama.cpp's default (`true`) repetitions 2..N reuse the cached prefix and `prompt_tok_s` stops measuring prefill |

A discarded warm-up request runs before the measured repetitions, so repetition 1 no longer
absorbs CUDA and buffer initialization cost.

#### Test Prompts

Three representative prompts test different workloads:

| Prompt Type | Spanish Prompt | n_predict | Characteristics |
|-------------|----------------|-----------|-----------------|
| **short** | "Cual es la capital de Francia..." | 64 | Factual, short response, prompt-bound |
| **medium** | "Explica paso a paso como funciona..." | 256 | Reasoning, moderate generation |
| **codigo** | "Escribe en Python una funcion..." | 512 | Code generation, longest output, context-heavy |

#### Script Parameters

```powershell
.\Bench-Server.ps1 `
    -UseMTP                    # Enable MTP speculative decoding [switch, default: off]
    -Repeats 3                 # Number of times to repeat each prompt [int, default: 3]
    -Port 8080                 # HTTP server port [int, default: 8080]
    -DraftNgl 0                # Draft model GPU layers (0=CPU, 999=GPU) [int, default: 0]
    -LabelOverride "mtp-gpu"   # Custom label for CSV output [string, default: auto]
    -Ctx 8192                  # Context window [int, default: 8192]
    -Ngl 999                   # Model GPU layers [int, default: 999]
    -SplitMode layer           # layer|row|none [string, default: layer]
    -CacheTypeK f16            # KV cache K type [string, default: f16]
    -CacheTypeV f16            # KV cache V type [string, default: f16]
    -Parallel 1                # Server slots, -np [int, default: 1]
    -NoKvOffload               # Keep KV cache in system RAM [switch, default: off]
    -FlashAttn on              # on|off|auto [string, default: on]
    -TensorSplit "1,1"         # Tensor split across GPUs [string, default: auto]
    -DryRun                    # Print the command line and exit without loading the model
```

When `-LabelOverride` is omitted the label is derived from whatever differs from the defaults
(`base`, `base-ctx32k-kvq80`, `base-smrow-ram`, ...), so sweep variants never overwrite each
other's CSV.

**Metrics Collected:**

For each request:

| Metric | Description |
|--------|-------------|
| `variant` | Test variant (base/mtp/mtp-gpu) |
| `prompt` | Prompt type (corto/medio/codigo) |
| `rep` | Repetition number (1-3) |
| `prompt_tokens` | Number of tokens in the prompt |
| `prompt_ms` | Time to process prompt (milliseconds) |
| `prompt_tok_s` | Prompt processing speed (tokens/second) |
| `gen_tokens` | Tokens actually generated |
| `gen_ms` | Time to generate tokens (milliseconds) |
| `gen_tok_s` | **Generation speed (tokens/second)** - main metric |
| `wall_ms` | Total wall-clock time including overhead |
| `status` | `ok`, `oom`, `load-failed` or `no-data`. A config that cannot load is recorded as a row, not an abort |
| `kv_size_mib` | KV cache size parsed from the server load log |
| `vram_used_mib` | Total VRAM in use while the server was up, via `nvidia-smi` |
| `ctx`, `ngl`, `split_mode`, `cache_k`, `cache_v`, `parallel`, `nkvo`, `flash_attn` | The configuration that produced the row, so the CSV is self-describing |

Server load logs are kept per variant in `results/logs/server-<label>.{out,err}.log`, and the
model's architecture (`n_expert`, `n_layer`, `n_head_kv`, KV size) is extracted once into
`results/model-info.json`.

**Output Files:**
- `results/server-bench-base.csv` - Without MTP
- `results/server-bench-mtp.csv` - With MTP, draft on CPU
- `results/server-bench-mtp-gpu.csv` - With MTP, draft on GPU

---

### 3. Full Benchmark Suite (`Run-FullBenchmark.ps1`)

**Workflow (default):**

```
1. Get-SysInfo.ps1        -> results/sysinfo.json
2. Bench-LlamaBench.ps1   -> results/llama-bench-baseline.{json,md}
3. Bench-Server.ps1       -> results/server-bench-base.csv
4. New-Report.ps1         -> results/REPORTE.md
```

`-IncludeMTP` adds the two MTP variants. `-IncludeSweeps` adds `Run-SpeedSweep.ps1` and
`Run-ContextSweep.ps1`. Both are off by default: MTP because the measurements below show it
never wins, sweeps because they take considerably longer than the base run.

`New-Report.ps1` discovers every `results/server-bench-*.csv` by glob and pivots them
dynamically, so any variant you run shows up without touching the generator. It reports the
**median** as the headline number, with min/max/mean alongside — see Results Interpretation for
why the mean was actively misleading here. It generates:

- Hardware/software summary
- Per-variant summary ranked by median generation speed
- Per-load detail with an outlier flag when mean and median diverge by more than 5%
- Prefill speeds, with an automatic validity check on `prompt_tokens`
- Context vs speed and memory, including configs that failed to load
- Model architecture and an implied-bandwidth cross-check between llama-bench and the server
- Full llama-bench results and raw data references

---

## Hardware & Environment

### Test System (Included Results)

| Component | Details |
|-----------|---------|
| **CPU** | AMD Ryzen 9 7900X (12c/24t) |
| **GPU** | 2x NVIDIA RTX 3060 12GB (24GB total VRAM) |
| **RAM** | 64GB |
| **Driver** | NVIDIA 576.88 |
| **OS** | Windows 11 |
| **llama.cpp** | Build 3cb7ffb1a (10453) |

### Dependencies

- **llama.exe** - llama.cpp CLI, typically at `%LOCALAPPDATA%\Microsoft\WindowsApps\llama.exe`
- **llama-bench.exe** - Benchmarking utility, typically at `%LOCALAPPDATA%\Microsoft\WindowsApps\llama-bench.exe`
- **Hugging Face Hub** - Model cached at `%USERPROFILE%\.cache\huggingface\hub\`
- **PowerShell 5.1** or higher

### Model Files

**Main Model:**
```
ggml-org/Qwen3.8-27B-GGUF:Q4_K_M
├─ Format: GGUF (quantized)
├─ Quantization: Q4_K_M (4-bit, K-means)
├─ Size: ~17.66 GiB
└─ Parameters: 26.90B
```

**Draft Model (MTP):**
```
mtp-Qwen3.8-27B-Q4_0.gguf
├─ Purpose: Speculative decoding predictions
├─ Can run on CPU or GPU via --spec-draft-ngl
└─ Located: %USERPROFILE%\.cache\huggingface\hub\...
```

---

## Results Interpretation

### Key Findings (Test System Example)

**Generation Speed Comparison** (median of 3 repetitions, from the CSVs in `results/`):

| Prompt | No MTP | MTP (CPU) | MTP (GPU) | Best |
|--------|--------|-----------|-----------|------|
| Short factual | **27.77 tok/s** | 13.78 tok/s | 24.10 tok/s | No MTP |
| Medium reasoning | **27.71 tok/s** | 13.20 tok/s | 20.06 tok/s | No MTP |
| Code generation | **26.56 tok/s** | 14.07 tok/s | 25.23 tok/s | No MTP |

> **Correction.** Earlier versions of this table and of `REPORTE.md` used the mean and concluded
> that MTP-on-GPU was the best option for code generation (26.3 vs 23.7 tok/s). That was an
> artifact of a single outlier: `base/codigo/rep3` took 28.7 s against ~19.1 s for the other two
> repetitions, dragging the mean from 26.6 down to 23.7. Using the median, **no-MTP wins all
> three loads** and there is no case in this data where MTP helps. The report generator now
> reports medians and flags any group whose mean diverges from its median by more than 5%.

**Insights:**

- **MTP with draft on CPU (`--spec-draft-ngl 0`)**: loses half the throughput to CPU↔GPU data movement. Unambiguously the worst option.
- **MTP with draft on GPU (`--spec-draft-ngl 999`)**: recovers most of it but still never beats the baseline, and is far noisier (24.23-29.44 tok/s within a single load).
- **Best for all three loads**: no MTP. This is why MTP is opt-in.

**Two caveats on the historical numbers above:**

1. They were collected with `cache_prompt` at its default of `true`, so `prompt_tokens` runs
   `23, 4, 4` across repetitions and the prefill figures measure cache hits, not prefill. The
   older "prefill" table in `REPORTE.md` (10-12 tok/s) should be ignored; `llama-bench` measures
   556-869 tok/s on the same work. Fixed in the current script.
2. The server reports ~28 tok/s while `llama-bench` reports tg128 = 16.14 ± 0.07 tok/s on the
   same model and hardware — a 74% gap that is not yet explained. The model is 18.96 GB, so
   28 tok/s implies reading 531 GB/s; one RTX 3060 has ~360 GB/s and `-sm layer` runs the GPUs
   in sequence rather than in parallel. If the model is dense that figure is not physically
   possible and one of the two measurements is wrong; if it is MoE, only a fraction of the
   weights is read per token and both can be valid. `New-Report.ps1` now prints this
   cross-check, and `results/model-info.json` records `n_expert` to settle it. **Resolve this
   before drawing conclusions from either number.**

### Metrics Explained

| Metric | Meaning | What Affects It |
|--------|---------|-----------------|
| **pp X** | Prompt Processing speed at X tokens | Batch size, prompt length, GPU capacity |
| **tg X** | Token Generation speed when generating X tokens | Model size, batch size, speculative acceptance rate |
| **prompt_tok_s** | Prefill throughput (parallel processing of input) | GPU efficiency, context window, batch size |
| **gen_tok_s** | Decoding throughput (sequential token generation) | **Main metric for real-world latency** |

---

## Customization

### Running Custom Configurations

**Test a specific prompt with different parameters:**
```powershell
# More repetitions (the median gets more reliable with 5+)
.\Bench-Server.ps1 -Repeats 5

# Test on different port (useful for multiple instances)
.\Bench-Server.ps1 -Port 8081

# Enable MTP with GPU draft, 5 repetitions, custom label
.\Bench-Server.ps1 -UseMTP -DraftNgl 999 -Repeats 5 -LabelOverride "custom-test"

# 32k context with a quantized KV cache, both GPUs on the same layer
.\Bench-Server.ps1 -Ctx 32768 -CacheTypeK q8_0 -CacheTypeV q8_0 -SplitMode row
```

**Editing a sweep:** both sweep scripts hold their matrix in a `$variants` array of
`@{ Label; Args; Nota }` entries, where `Args` is splatted into `Bench-Server.ps1`. Adding a
configuration is one line, and `New-Report.ps1` picks it up with no changes.

### Modifying llama-bench Parameters

Edit `Bench-LlamaBench.ps1`:
```powershell
# Change prompt sizes (line with -p parameter)
$argLine = "-hf `"$modelRepo`" -ngl 999 -p 128,1024,2048 -n 64,256 -r 5 -fa on -o json -oe md"

# To test different prompt/generation combinations
# -p: comma-separated prompt sizes
# -n: comma-separated generation sizes
# -r: number of repetitions
```

### Modifying Server Test Prompts

Edit `Bench-Server.ps1`, modify `$prompts` array:
```powershell
$prompts = @(
    @{ name = "yourtest"; text = "Your custom prompt..."; n_predict = 256 },
    # Add more prompts as needed
)
```

---

## Troubleshooting

### "Server did not respond to health check"

- Increase timeout (model is large, GPU loading takes time)
- Ensure port is available
- Check if llama.exe is in PATH

### CSV files not generated

- Server may have crashed; check if process is still running
- Verify model paths and permissions
- Check PowerShell logs for error details

### MTP draft model not found

- Verify Hugging Face cache path
- Ensure model was downloaded: `huggingface-hub download ggml-org/Qwen3.8-27B-GGUF`
- Adjust `$draftModel` path in `Bench-Server.ps1`

### Lower-than-expected speeds

- Check GPU utilization (nvidia-smi)
- Verify `-ngl 999` is being used
- Ensure no other processes consuming GPU memory
- Check thermal throttling

---

## Output Files Reference

| File | Purpose | Format |
|------|---------|--------|
| `sysinfo.json` | Hardware/OS specs | JSON |
| `llama-bench-baseline.json` | Pure inference results | JSON |
| `llama-bench-baseline.md` | Baseline formatted results | Markdown table |
| `server-bench-<label>.csv` | One file per variant, one row per request, self-describing | CSV |
| `model-info.json` | Model architecture parsed from the server load log | JSON |
| `logs/server-<label>.{out,err}.log` | Raw server startup logs per variant | Text |
| `REPORTE.md` | Consolidated report | Markdown with tables & summary |

The pre-existing `server-bench-base.csv`, `server-bench-mtp.csv` and `server-bench-mtp-gpu.csv`
were collected before the `cache_prompt` fix and lack the configuration columns. They still load
in `New-Report.ps1` and show `-` in those columns, which marks them as older data.

---

## Performance Tuning Tips

Ordered by expected payoff on this 2x RTX 3060 system:

1. **`-SplitMode row`** - the largest untested lever. With `layer` (the default) GPU 0 processes
   its layers and *then* GPU 1 processes its own; they never work at the same time, so you pay
   for two cards and get the memory bandwidth of one. With `row` both work on the same layer and
   the bandwidth adds up. The risk is that inter-GPU traffic over PCIe eats the gain, which is
   exactly what `Run-SpeedSweep.ps1` exists to measure.
2. **Quantize the KV cache** (`-CacheTypeK q8_0 -CacheTypeV q8_0`) - roughly halves KV memory at
   negligible quality cost, which buys context without touching RAM. Requires flash attention.
3. **Lighter model quantization** (IQ4_XS, Q4_K_S) - if generation is bandwidth-bound, tok/s
   scales almost linearly with bytes read per token. IQ4_XS is ~12% smaller than Q4_K_M. Not
   covered by the sweeps because it needs a different model download.
4. **`-Parallel 4`** - only helps *aggregate* throughput across concurrent clients, not
   single-request latency. This suite measures single-user latency, so the flag is exposed but
   the sweeps do not use it.
5. **KV cache in RAM** (`-NoKvOffload`) - the way to get a large context when VRAM runs out, but
   every generated token then pulls the KV cache over PCIe (~25-30 GB/s) instead of reading it
   from VRAM (~360 GB/s). `Run-ContextSweep.ps1` quantifies the cost.
6. **Monitor GPU memory**: `nvidia-smi -l 1` during benchmarks.

**Avoid the Windows CUDA Sysmem Fallback** (NVIDIA Control Panel -> Manage 3D Settings) for
benchmarking. It spills VRAM into RAM implicitly, the driver decides what to evict, and results
become inconsistent between runs. Set it to "Prefer No Sysmem Fallback" so an OOM is a visible
OOM instead of a silent performance collapse — `Bench-Server.ps1` records OOM as a data point.

---

## License & Attribution

- **Model**: Qwen3.8-27B by Alibaba (Apache 2.0)
- **Engine**: llama.cpp by ggerganov
- **Benchmarks**: Custom suite for local evaluation

---

## Version Info

- **Suite Version**: 2.0 (parameterized server config, sweeps, median-based reporting)
- **Model**: Qwen3.8-27B GGUF Q4_K_M
- **Tested on**: Windows 11, llama.cpp 3cb7ffb1a

Last updated: 2026-08-18
