# Qwen3.8-27B Benchmark Suite - llama.cpp + MTP Speculative Decoding

Comprehensive benchmark suite for evaluating the Qwen3.8-27B GGUF model's performance on llama.cpp with and without MTP (Multi-Token Prediction / speculative decoding) on consumer GPUs.

## Overview

This suite contains three main benchmarking approaches:

1. **Pure Inference Baseline** (`Bench-LlamaBench.ps1`) - llama-bench motor benchmark
2. **Server Performance** (`Bench-Server.ps1`) - Real HTTP server /completion endpoint testing
3. **Full Suite Orchestration** (`Run-FullBenchmark.ps1`) - Complete benchmark workflow

## Quick Start

Run the complete benchmark suite:
```powershell
.\Run-FullBenchmark.ps1
```

Or run individual benchmarks:
```powershell
.\Get-SysInfo.ps1                           # Collect system specs
.\Bench-LlamaBench.ps1                      # Pure llama-bench baseline
.\Bench-Server.ps1                          # Server without MTP
.\Bench-Server.ps1 -UseMTP -DraftNgl 0      # Server with MTP, draft on CPU
.\Bench-Server.ps1 -UseMTP -DraftNgl 999    # Server with MTP, draft on GPU
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

| Parameter | Default | Description |
|-----------|---------|-------------|
| **Model** | `ggml-org/Qwen3.8-27B-GGUF:Q4_K_M` | Same quantized model as baseline |
| **Context Window** | `-c 8192` | Maximum context size (8192 tokens) |
| **Parallel Requests** | `-np 1` | Number of parallel requests (1 = sequential) |
| **GPU Offload** | `-ngl 999` | Full GPU acceleration |
| **Port** | `--port 8080` | HTTP server port (customizable via `-Port` param) |
| **No MMProj** | `--no-mmproj` | Disable multimodal projections |

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
    -UseMTP $true              # Enable MTP speculative decoding [bool, default: false]
    -Repeats 3                 # Number of times to repeat each prompt [int, default: 3]
    -Port 8080                 # HTTP server port [int, default: 8080]
    -DraftNgl 0                # Draft model GPU layers (0=CPU, 999=GPU) [int, default: 0]
    -LabelOverride "mtp-gpu"   # Custom label for CSV output [string, default: auto]
```

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

**Output Files:**
- `results/server-bench-base.csv` - Without MTP
- `results/server-bench-mtp.csv` - With MTP, draft on CPU
- `results/server-bench-mtp-gpu.csv` - With MTP, draft on GPU

---

### 3. Full Benchmark Suite (`Run-FullBenchmark.ps1`)

**Workflow:**

```
1. Get-SysInfo.ps1
   ├─ Collects CPU, RAM, GPU, OS, disk info
   └─ Outputs: results/sysinfo.json

2. Bench-LlamaBench.ps1
   └─ Outputs: results/llama-bench-baseline.{json,md}

3. Bench-Server.ps1 (no args)
   └─ Outputs: results/server-bench-base.csv

4. Bench-Server.ps1 -UseMTP -DraftNgl 0
   └─ Outputs: results/server-bench-mtp.csv

5. Bench-Server.ps1 -UseMTP -DraftNgl 999 -LabelOverride "mtp-gpu"
   └─ Outputs: results/server-bench-mtp-gpu.csv

6. Generate report
   └─ Outputs: results/REPORTE.md
```

Generates consolidated `REPORTE.md` with:
- Hardware/software summary
- Comparison table: generation speed (tok/s) across all variants
- Prompt processing speeds (prefill performance)
- Full llama-bench results
- Raw data file references

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

**Generation Speed Comparison:**

| Prompt | No MTP | MTP (CPU) | MTP (GPU) | Best |
|--------|--------|-----------|-----------|------|
| Short factual | 28.1 tok/s | 14.2 tok/s ⚠️ | 25.4 tok/s | No MTP |
| Medium reasoning | 28.1 tok/s | 13.1 tok/s ⚠️ | 19.7 tok/s | No MTP |
| Code generation | 23.7 tok/s | 14.1 tok/s ⚠️ | **26.3 tok/s** ✓ | MTP (GPU) |

**Insights:**

- **MTP with draft on CPU (`--spec-draft-ngl 0`)**: Consistently slower due to CPU↔GPU data movement overhead
- **MTP with draft on GPU (`--spec-draft-ngl 999`)**: Recovers performance; sometimes exceeds no-MTP baseline
- **Best for general use**: No MTP (~28 tok/s average) provides most consistent throughput
- **Best for code**: MTP with draft on GPU can achieve marginally higher speeds on predictable generation

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
# Increase context window
.\Bench-Server.ps1 -Repeats 5

# Test on different port (useful for multiple instances)
.\Bench-Server.ps1 -Port 8081

# Enable MTP with GPU draft, 5 repetitions, custom label
.\Bench-Server.ps1 -UseMTP -DraftNgl 999 -Repeats 5 -LabelOverride "custom-test"
```

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
| `server-bench-base.csv` | Server benchmark without MTP | CSV (one row per request) |
| `server-bench-mtp.csv` | Server benchmark with MTP (CPU draft) | CSV |
| `server-bench-mtp-gpu.csv` | Server benchmark with MTP (GPU draft) | CSV |
| `REPORTE.md` | Consolidated report | Markdown with tables & summary |

---

## Performance Tuning Tips

1. **Increase parallel requests** (modify `-np` in `Bench-Server.ps1`): Better GPU utilization
2. **Increase context window** (modify `-c` parameter): May affect performance
3. **Test different quantizations**: Replace model in parameters to test Q3_K, Q5_K_M, etc.
4. **Adjust temperature**: Lower = faster but more deterministic; higher = slower but more creative
5. **Monitor GPU memory**: Use `nvidia-smi -l 1` during benchmarks

---

## License & Attribution

- **Model**: Qwen3.8-27B by Alibaba (Apache 2.0)
- **Engine**: llama.cpp by ggerganov
- **Benchmarks**: Custom suite for local evaluation

---

## Version Info

- **Suite Version**: 1.0
- **Model**: Qwen3.8-27B GGUF Q4_K_M
- **Tested on**: Windows 11, llama.cpp 3cb7ffb1a

Last updated: 2026-01-17
