param(
    [switch]$RunBenchmarks,
    [int]$MinAcceptedVRAMGB = 6,
    [int]$MaxTierVRAMGB = 48,
    [bool]$StrictRejectBelowMinimum = $true,
    [bool]$SkipLikelyOversizedModels = $true,
    [double]$BenchmarkFitHeadroom = 0.85,
    [string]$OutputPath = ".\\gpu_assessment_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToGB {
    param([double]$MiB)
    return [math]::Round($MiB / 1024.0, 2)
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Get-NvidiaSmiRows {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
        return @()
    }

    $query = "index,name,driver_version,memory.total,memory.free,memory.used,utilization.gpu,temperature.gpu,power.draw"
    $raw = & nvidia-smi --query-gpu=$query --format=csv,noheader,nounits 2>$null
    if (-not $raw) {
        return @()
    }

    $rows = @()
    foreach ($line in $raw) {
        $parts = $line.Split(",") | ForEach-Object { $_.Trim() }
        if ($parts.Count -lt 9) {
            continue
        }

        $rows += [pscustomobject]@{
            Index          = [int]$parts[0]
            Name           = $parts[1]
            DriverVersion  = $parts[2]
            MemoryTotalMiB = [double]$parts[3]
            MemoryFreeMiB  = [double]$parts[4]
            MemoryUsedMiB  = [double]$parts[5]
            UtilizationGPU = [double]$parts[6]
            TemperatureC   = [double]$parts[7]
            PowerDrawW     = [double]$parts[8]
        }
    }
    return $rows
}

function Get-VramTier {
    param(
        [double]$TotalGB,
        [int]$MaxTierGB
    )

    if ($TotalGB -lt 6) {
        return "rejected"
    }
    if ($TotalGB -lt 10) {
        return "consumer_entry_6_to_10"
    }
    if ($TotalGB -lt 16) {
        return "consumer_mid_10_to_16"
    }
    if ($TotalGB -lt 24) {
        return "consumer_high_16_to_24"
    }
    if ($TotalGB -lt 36) {
        return "prosumer_24_to_36"
    }
    if ($TotalGB -le $MaxTierGB) {
        return "workstation_36_to_48"
    }
    return "workstation_48_plus"
}

function Get-TierRecommendations {
    param(
        [string]$Tier,
        [double]$TotalGB,
        [int]$MinAcceptedGB
    )

    switch ($Tier) {
        "rejected" {
            return [pscustomobject]@{
                Accepted = $false
                Reason = "Total GPU VRAM $TotalGB GB is below minimum accepted threshold $MinAcceptedGB GB."
                SuggestedModels = @()
                OllamaHints = @(
                    "Use 3B to 7B Q4 models only, or CPU fallback.",
                    "Set OLLAMA_MAX_LOADED_MODELS=1 and OLLAMA_NUM_PARALLEL=1."
                )
                VllmHints = @(
                    "Skip vLLM for local GPU inference at this capacity.",
                    "Use remote inference or quantized tiny models only."
                )
            }
        }
        "consumer_entry_6_to_10" {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "Entry consumer VRAM tier."
                SuggestedModels = @(
                    "llama3.1:8b",
                    "qwen2.5-coder:7b",
                    "mistral:7b"
                )
                OllamaHints = @(
                    "Use Q4 quantization and keep context to 8k-16k.",
                    "Set OLLAMA_MAX_LOADED_MODELS=1 and OLLAMA_NUM_PARALLEL=1."
                )
                VllmHints = @(
                    "Use single-GPU vLLM only if model fully fits.",
                    "Start with max-model-len 8192."
                )
            }
        }
        "consumer_mid_10_to_16" {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "Mid consumer VRAM tier."
                SuggestedModels = @(
                    "qwen2.5-coder:14b",
                    "deepseek-coder-v2:16b",
                    "llama3.1:8b"
                )
                OllamaHints = @(
                    "Run 14B to 16B quantized models comfortably.",
                    "Use context 16k-32k where supported."
                )
                VllmHints = @(
                    "Single-GPU vLLM with AWQ/GPTQ is practical.",
                    "Set gpu-memory-utilization around 0.88 to 0.92."
                )
            }
        }
        "consumer_high_16_to_24" {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "High consumer VRAM tier."
                SuggestedModels = @(
                    "qwen3:30b",
                    "qwen2.5-coder:32b",
                    "deepseek-coder-v2:16b"
                )
                OllamaHints = @(
                    "Large 30B-class quantized models are feasible.",
                    "Keep one heavyweight model loaded at a time."
                )
                VllmHints = @(
                    "Single GPU can host strong AWQ models; multi-GPU only if needed.",
                    "Start with max-model-len 16384 or 32768 based on headroom."
                )
            }
        }
        "prosumer_24_to_36" {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "Prosumer multi-GPU or high-VRAM single-GPU tier."
                SuggestedModels = @(
                    "qwen2.5-coder:32b",
                    "qwen3:30b",
                    "larger 32B to 40B quantized families"
                )
                OllamaHints = @(
                    "Enable sharding across GPUs if runtime chooses it.",
                    "Use OLLAMA_SCHED_SPREAD=1 for better multi-GPU balancing."
                )
                VllmHints = @(
                    "Tensor parallel can help, but mixed GPUs may bottleneck on the smaller card.",
                    "Prefer binding heavy runs to the fastest/largest GPU when possible."
                )
            }
        }
        "workstation_36_to_48" {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "Workstation VRAM tier up to 48 GB."
                SuggestedModels = @(
                    "high-quality 32B to 70B quantized candidates",
                    "specialized coding 30B+ models",
                    "larger-context variants where memory allows"
                )
                OllamaHints = @(
                    "Run larger quantized models with high context settings.",
                    "Use one primary model per workload class for stability."
                )
                VllmHints = @(
                    "Use tensor parallel and tune max-model-len per workload.",
                    "Reserve 8% to 12% VRAM headroom for stability under burst loads."
                )
            }
        }
        default {
            return [pscustomobject]@{
                Accepted = $true
                Reason = "48GB+ workstation tier."
                SuggestedModels = @(
                    "70B-class quantized models",
                    "large coding models with long context",
                    "multi-model serving scenarios"
                )
                OllamaHints = @(
                    "Set explicit concurrency limits to avoid VRAM fragmentation.",
                    "Use model-specific context caps to prevent OOM swings."
                )
                VllmHints = @(
                    "Use tensor parallel and memory profiling before production serving.",
                    "Target max-model-len after validating KV cache pressure."
                )
            }
        }
    }
}

function Get-BenchmarkCandidatesByTier {
    param([string]$Tier)

    switch ($Tier) {
        "rejected" {
            return @()
        }
        "consumer_entry_6_to_10" {
            return @(
                "llama3.1:8b",
                "qwen2.5-coder:7b",
                "mistral:7b"
            )
        }
        "consumer_mid_10_to_16" {
            return @(
                "qwen2.5-coder:14b",
                "deepseek-coder-v2:16b",
                "llama3.1:8b"
            )
        }
        "consumer_high_16_to_24" {
            return @(
                "deepseek-coder-v2:16b",
                "qwen3:30b",
                "qwen2.5-coder:14b"
            )
        }
        "prosumer_24_to_36" {
            return @(
                "qwen3:30b",
                "qwen2.5-coder:32b",
                "deepseek-coder-v2:16b"
            )
        }
        "workstation_36_to_48" {
            return @(
                "qwen2.5-coder:32b",
                "qwen3:30b",
                "deepseek-coder-v2:16b"
            )
        }
        default {
            return @(
                "qwen2.5-coder:32b",
                "qwen3:30b",
                "deepseek-coder-v2:16b"
            )
        }
    }
}

function Get-ApproxModelSizeGB {
    param([string]$ModelName)

    $m = [regex]::Match($ModelName, "(?i)(\\d+(?:\\.\\d+)?)b")
    if (-not $m.Success) {
        return $null
    }

    # Rough estimate for quantized model runtime footprint in GiB.
    $billions = [double]$m.Groups[1].Value
    return [math]::Round($billions * 0.75, 2)
}

function Test-ModelLikelyFits {
    param(
        [string]$ModelName,
        [double]$TotalVRAMGB,
        [double]$Headroom
    )

    $approx = Get-ApproxModelSizeGB -ModelName $ModelName
    if ($null -eq $approx) {
        # Unknown size tag: allow test instead of over-blocking.
        return $true
    }

    $maxUsable = [math]::Round($TotalVRAMGB * $Headroom, 2)
    return ($approx -le $maxUsable)
}

function Get-OllamaInfo {
    $exists = [bool](Get-Command ollama -ErrorAction SilentlyContinue)
    if (-not $exists) {
        return [pscustomobject]@{
            Installed = $false
            Version = $null
            Models = @()
        }
    }

    $version = (& ollama --version 2>$null) -join " "
    $modelLines = & ollama list 2>$null
    $models = @()
    if ($modelLines) {
        foreach ($line in $modelLines | Select-Object -Skip 1) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $name = ($line -split "\s+")[0]
            if ($name -and $name -ne "NAME") {
                $models += $name
            }
        }
    }

    return [pscustomobject]@{
        Installed = $true
        Version = $version
        Models = $models
    }
}

function Get-DockerGpuSupport {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Installed = $false
            GpuPassthrough = $false
            Note = "Docker not installed"
        }
    }

    $probe = & docker run --rm --gpus all nvidia/cuda:12.4.1-runtime-ubuntu22.04 nvidia-smi --query-gpu=index,name --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) {
        return [pscustomobject]@{
            Installed = $true
            GpuPassthrough = $true
            Note = "Docker GPU passthrough is working"
        }
    }

    return [pscustomobject]@{
        Installed = $true
        GpuPassthrough = $false
        Note = "Docker installed but GPU passthrough probe failed"
    }
}

function Invoke-QuickBenchmarks {
    param(
        [string[]]$ModelCandidates,
        [double]$TotalVRAMGB,
        [bool]$SkipOversized,
        [double]$Headroom
    )

    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        return @([pscustomobject]@{
            Model = "n/a"
            Success = $false
            Error = "Ollama not installed"
        })
    }

    $existing = @{}
    foreach ($m in (& ollama list 2>$null | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($m)) { continue }
        $k = ($m -split "\s+")[0]
        if ($k) { $existing[$k] = $true }
    }

    $prompt = "In exactly 5 bullet points, propose a local AI coding stack for Windows with Docker and Ollama."
    $results = @()
    foreach ($model in $ModelCandidates) {
        if ($SkipOversized -and -not (Test-ModelLikelyFits -ModelName $model -TotalVRAMGB $TotalVRAMGB -Headroom $Headroom)) {
            $results += [pscustomobject]@{
                Model = $model
                Success = $false
                Error = "Skipped: likely oversized for current VRAM budget"
            }
            continue
        }

        if (-not $existing.ContainsKey($model)) {
            $results += [pscustomobject]@{
                Model = $model
                Success = $false
                Error = "Model not installed"
            }
            continue
        }

        $body = @{
            model = $model
            prompt = $prompt
            stream = $false
            options = @{
                temperature = 0.2
                num_predict = 160
            }
        } | ConvertTo-Json -Depth 6

        try {
            $elapsed = Measure-Command {
                $resp = Invoke-RestMethod -Method Post -Uri "http://localhost:11434/api/generate" -ContentType "application/json" -Body $body -TimeoutSec 180
            }

            $evalSeconds = if ($resp.eval_duration) { [double]$resp.eval_duration / 1e9 } else { 0 }
            $tps = if ($evalSeconds -gt 0) { [math]::Round([double]$resp.eval_count / $evalSeconds, 2) } else { 0 }

            $results += [pscustomobject]@{
                Model = $model
                Success = $true
                ElapsedSec = [math]::Round($elapsed.TotalSeconds, 2)
                EvalTokens = [int]$resp.eval_count
                TokensPerSec = $tps
            }
        }
        catch {
            $results += [pscustomobject]@{
                Model = $model
                Success = $false
                Error = $_.Exception.Message
            }
        }
    }

    return $results
}

Write-Section "GPU Detection"
$gpuRows = Get-NvidiaSmiRows
if ($gpuRows.Count -eq 0) {
    Write-Host "No NVIDIA GPUs detected via nvidia-smi." -ForegroundColor Yellow
}
else {
    $gpuRows | Format-Table Index, Name, DriverVersion, MemoryTotalMiB, MemoryUsedMiB, MemoryFreeMiB, UtilizationGPU, TemperatureC, PowerDrawW -AutoSize
}

$totalVramGB = 0
if ($gpuRows.Count -gt 0) {
    $totalMiB = ($gpuRows | Measure-Object -Property MemoryTotalMiB -Sum).Sum
    $totalVramGB = Convert-ToGB -MiB $totalMiB
}

$tier = Get-VramTier -TotalGB $totalVramGB -MaxTierGB $MaxTierVRAMGB
$recommendation = Get-TierRecommendations -Tier $tier -TotalGB $totalVramGB -MinAcceptedGB $MinAcceptedVRAMGB
$benchCandidates = Get-BenchmarkCandidatesByTier -Tier $tier

Write-Section "Runtime Probes"
$ollamaInfo = Get-OllamaInfo
$dockerInfo = Get-DockerGpuSupport

Write-Host ("Ollama Installed: {0}" -f $ollamaInfo.Installed)
if ($ollamaInfo.Installed) {
    Write-Host ("Ollama Version: {0}" -f $ollamaInfo.Version)
    if ($ollamaInfo.Models.Count -gt 0) {
        Write-Host ("Installed Models: {0}" -f ($ollamaInfo.Models -join ", "))
    }
}

Write-Host ("Docker Installed: {0}" -f $dockerInfo.Installed)
Write-Host ("Docker GPU Passthrough: {0}" -f $dockerInfo.GpuPassthrough)
Write-Host ("Docker Note: {0}" -f $dockerInfo.Note)

$benchmarks = @()
if ($RunBenchmarks) {
    Write-Section "Quick Benchmarks"
    if ($tier -eq "rejected" -and $StrictRejectBelowMinimum) {
        Write-Host "Strict reject mode is active. Benchmarks skipped due to insufficient VRAM." -ForegroundColor Yellow
        $benchmarks = @([pscustomobject]@{
            Model = "n/a"
            Success = $false
            Error = "Benchmarks skipped by strict reject mode"
        })
    }
    else {
        $benchmarks = Invoke-QuickBenchmarks -ModelCandidates $benchCandidates -TotalVRAMGB $totalVramGB -SkipOversized $SkipLikelyOversizedModels -Headroom $BenchmarkFitHeadroom
        $benchmarks | Format-Table -AutoSize
    }
}

$summary = [pscustomobject]@{
    Timestamp = (Get-Date).ToString("s")
    TotalVRAMGB = $totalVramGB
    Tier = $tier
    BenchmarkCandidates = $benchCandidates
    Accepted = [bool]$recommendation.Accepted
    MinAcceptedVRAMGB = $MinAcceptedVRAMGB
    StrictRejectBelowMinimum = $StrictRejectBelowMinimum
    SkipLikelyOversizedModels = $SkipLikelyOversizedModels
    BenchmarkFitHeadroom = $BenchmarkFitHeadroom
    GPUs = $gpuRows
    Recommendation = $recommendation
    Ollama = $ollamaInfo
    Docker = $dockerInfo
    Benchmarks = $benchmarks
    SuggestedEnv = @{
        OLLAMA_MAX_LOADED_MODELS = "1"
        OLLAMA_NUM_PARALLEL = "1"
        OLLAMA_SCHED_SPREAD = "1"
    }
    SuggestedVllmTemplate = "docker run --rm --gpus all -e CUDA_DEVICE_ORDER=PCI_BUS_ID -p 8000:8000 vllm/vllm-openai:latest serve Qwen/Qwen2.5-14B-Instruct-AWQ --quantization awq --gpu-memory-utilization 0.92 --max-model-len 16384"
}

Write-Section "Assessment"
Write-Host ("Total VRAM (GB): {0}" -f $summary.TotalVRAMGB)
Write-Host ("Tier: {0}" -f $summary.Tier)
Write-Host ("Accepted: {0}" -f $summary.Accepted)
Write-Host ("Reason: {0}" -f $summary.Recommendation.Reason)
Write-Host "Suggested Models:"
$summary.Recommendation.SuggestedModels | ForEach-Object { Write-Host (" - {0}" -f $_) }

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host ""
Write-Host ("Saved report: {0}" -f (Resolve-Path $OutputPath)) -ForegroundColor Green
