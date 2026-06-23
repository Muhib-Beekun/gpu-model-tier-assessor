# GPU Model Tier Assessor

PowerShell tool for local AI inference planning and validation across consumer to workstation GPU setups.

## What it does

- Detects NVIDIA GPUs and total VRAM from nvidia-smi.
- Assigns a hardware tier from rejected to 48GB+ workstation.
- Produces tier-aware model recommendations for Ollama and vLLM.
- Optionally runs quick Ollama benchmarks with automatic downscaling by tier.
- Applies safety controls:
  - strict reject mode for below-minimum VRAM
  - oversized-model skip guard based on VRAM headroom
- Exports a JSON assessment report.

## Tiers

- rejected: below minimum accepted VRAM
- consumer_entry_6_to_10
- consumer_mid_10_to_16
- consumer_high_16_to_24
- prosumer_24_to_36
- workstation_36_to_48
- workstation_48_plus

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
  - PowerShell: https://learn.microsoft.com/powershell/
- NVIDIA driver with nvidia-smi on PATH
  - NVIDIA Drivers: https://www.nvidia.com/Download/index.aspx
  - nvidia-smi reference: https://developer.nvidia.com/system-management-interface
- Optional for runtime probes and benchmarks:
  - Ollama: https://ollama.com/download
  - Docker Desktop: https://docs.docker.com/desktop/
  - NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

## Usage

Basic assessment:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1

Run with benchmarks:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1 -RunBenchmarks

Tune acceptance floor and max named tier:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1 -MinAcceptedVRAMGB 8 -MaxTierVRAMGB 48

Disable strict rejection and oversized skip guards:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1 -StrictRejectBelowMinimum:$false -SkipLikelyOversizedModels:$false

Customize report output path:

  powershell -ExecutionPolicy Bypass -File .\gpu-model-tier-assessor.ps1 -OutputPath .\my_assessment.json

## Key parameters

- RunBenchmarks
  - Enables quick model benchmark passes based on detected tier.
- MinAcceptedVRAMGB
  - Minimum total VRAM to classify as accepted.
- StrictRejectBelowMinimum
  - If true and tier is rejected, benchmark runs are skipped.
- SkipLikelyOversizedModels
  - If true, benchmark candidates are filtered with a size-fit heuristic.
- BenchmarkFitHeadroom
  - Fraction of total VRAM reserved as usable budget for fit checks.
- MaxTierVRAMGB
  - Upper bound for naming the 36 to 48 tier before switching to 48+.

## Outputs

The script prints:

- GPU table with health-related telemetry fields
- runtime probe status for Ollama and Docker GPU passthrough
- optional benchmark results
- final tier and recommendation summary

It also saves a JSON report with:

- tier decision
- recommendation and model hints
- benchmark plan and results
- suggested environment values for Ollama
- vLLM launch template

## Suggested env defaults

- OLLAMA_MAX_LOADED_MODELS=1
- OLLAMA_NUM_PARALLEL=1
- OLLAMA_SCHED_SPREAD=1

## Notes

- Benchmarks only run for models installed in local Ollama.
- Size-fit checks are heuristic, not guaranteed. Final fit depends on context length, quantization, KV cache, and runtime overhead.
- Mixed GPU systems can run into sharding bottlenecks on the smaller card.

## License

This project is licensed under the MIT License.
See LICENSE for details.

## Repository Standards

- CONTRIBUTING.md for contribution workflow.
- SECURITY.md for vulnerability reporting.
- .editorconfig for consistent formatting defaults.
- .github/workflows/ci.yml for PowerShell syntax validation on pull requests.
