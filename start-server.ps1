# Mirai S 27B server (LAN + localhost) on a 12 GB card, on our engine, with the Bonsai serving stack.
# STATUS 2026-10-04 (feature tests A/B/C, receipts/mirai-port/feature_tests.log, DECISIONS.md): defaults are the
# measured configuration: the full 262,144-token window with q8_0 K/V (tiered: the first ~32k positions in VRAM,
# the rest in pinned system RAM), MTP drafting on the GGUF's own draft block, -b 2048 -ub 512, harness-proofing,
# the layer. Greedy outputs identical to the stock fork in every arm. Decode with MTP: 77 / 72 / 68 / 65 tok/s at
# 0 / 16k / 32k / 60k in a 64k all-VRAM window; with the 262k window the VRAM line sits at ~41k positions (tail
# draft 2) and decode past it is PCIe-bound: 32 at 60k, 15 at 120k (no draft: 14.6 / 6.2).
# The budget behind that: Mirai keeps 8,220 MiB of weights resident (its F16 token embedding stays in host RAM);
# drafting adds 150 MiB of recurrent-state snapshot per unit of rollback depth plus ~315 MiB for the draft context
# and CUDA overhead, so ~1.8 GB is left for K/V in VRAM with drafting and ~2.7 GB without. MIRAI_SPEC=0 trades the
# 1.85x decode below the line for a line at ~70k positions (long-context mode).
#   MIRAI_SPEC=0|2         draft size (2 = default)        MIRAI_TIER=0        64k all-VRAM window instead
#   MIRAI_CTX=N            window (262144)                  MIRAI_KV_VRAM_CELLS pin the VRAM line
#   MIRAI_VRAM_MARGIN=MiB  headroom (1000 headless / 1300 with the display on this card, from the Bonsai soaks)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bin = Join-Path $Root 'bin'
$Model = if ($env:MIRAI_MODEL) { $env:MIRAI_MODEL } elseif (Test-Path (Join-Path $Root 'models\Qwen3.8-27B-S-mirai-mtpq4.gguf')) { Join-Path $Root 'models\Qwen3.8-27B-S-mirai-mtpq4.gguf' } else { Join-Path $Root 'models\Qwen3.8-27B-S-mirai.gguf' }
# models\Qwen3.8-27B-S-mirai-mtpq4.gguf = the published GGUF with its MTP draft block requantized Q8_0 -> Q4_0 by
# tooling\requant_mtp.py (every other tensor byte-identical): ~200 MiB of VRAM back, outputs identical by construction
if (-not [IO.Path]::IsPathRooted($Model)) { $Model = Join-Path $Root "models\$Model" }
if (-not (Test-Path $Model)) { throw "model not found: $Model" }
if ((Get-Item $Model).Length -lt 10900000000) { throw "incomplete GGUF: $Model" }   # 11.17 GB published, 10.96 GB with the MTP block at Q4_0
$Server = Join-Path $Bin 'llama-server.exe'
if (-not (Test-Path $Server)) { throw "llama-server.exe missing in $Bin (tooling\build_engine.bat llama-server; tooling\install_bin.ps1)" }
$Help = (& $Server --help 2>&1 | Out-String)
$HasTier = $Help -match '--kv-vram-cells'
$HasHarness = $Help -match '--reasoning-effort-allow'
$HasPackedMask = $Help -match '--kq-mask-packed'
# Packed (one-bit) attention mask, on by default (MIRAI_KQ_MASK_PACKED=0 restores f16): identical outputs on long
# prompts, compute buffer 395 -> 155 MiB at a 512 micro-batch (DECISIONS.md 2026-10-05 10:43). With it the prompt
# micro-batch is 1024 (MIRAI_UBATCH overrides): compute 310 MiB, +14% prefill, 44 MiB more at load than the old
# f16/512 pair (10:50 entry).
$Packed = ($env:MIRAI_KQ_MASK_PACKED -ne '0') -and $HasPackedMask
[string[]]$MaskArgs = @()
if ($Packed) { $MaskArgs = @('--kq-mask-packed') }
$UBatch = if ($env:MIRAI_UBATCH) { [int]$env:MIRAI_UBATCH } elseif ($Packed) { 1024 } else { 512 }

$ApiKeyFile = Join-Path $Root 'artifacts\api_key.txt'
if (-not (Test-Path $ApiKeyFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ApiKeyFile) | Out-Null
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    Set-Content -Path $ApiKeyFile -Value (-join ($bytes | ForEach-Object { $_.ToString('x2') })) -NoNewline
}
$ApiKey = (Get-Content -Path $ApiKeyFile -Raw).Trim()

# ---- Context and KV precision ------------------------------------------------------------------------
# q8_0 K/V as on Bonsai (1 flipped top token in 160 at depth vs 1 in 48 for q4_0, measured there; the KL-by-position
# sweep is still to be run on Mirai). Tiered KV (--kv-vram-cells N): cells [0, N) in VRAM, the rest in pinned system
# RAM mapped into the same CUDA range, bit-identical output; past N a step reads the RAM tail over PCIe.
$Tier = ($env:MIRAI_TIER -ne '0') -and $HasTier
$Ctx = if ($env:MIRAI_CTX) { [int]$env:MIRAI_CTX } elseif ($Tier) { 262144 } else { 65536 }
$Ctk = if ($env:MIRAI_CTK) { $env:MIRAI_CTK } else { 'q8_0' }
$Port = if ($env:MIRAI_PORT) { [int]$env:MIRAI_PORT } else { 8080 }

# ---- Reasoning ------------------------------------------------------------------------------------------
# templates\bonsai-template.jinja: the template every measurement here used, on both models (reasoning_effort,
# enable_thinking). Medium with a 20k thinking budget was tuned on Bonsai; on Mirai it is the starting point, not a
# measured optimum (DECISIONS.md will say when it is). Passed through the environment, not the command line:
# PowerShell 5.1 and 7.3+ quote embedded double quotes differently for native programs.
$Effort = if ($env:MIRAI_EFFORT) { $env:MIRAI_EFFORT } else { 'medium' }
$Think = $env:MIRAI_THINK -ne '0'
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = if ($Think) { '{"reasoning_effort":"' + $Effort + '"}' } else { '{"reasoning_effort":"' + $Effort + '","enable_thinking":false}' }
$ThinkBudget = if ($env:MIRAI_THINK_BUDGET) { [int]$env:MIRAI_THINK_BUDGET } else { 20480 }
$ThinkBudgetMsg = if ($null -ne $env:MIRAI_THINK_BUDGET_MSG) { $env:MIRAI_THINK_BUDGET_MSG } else { 'Now produce the complete answer.' }
[string[]]$BudgetMsgArgs = @()
if ($ThinkBudget -ge 0 -and $ThinkBudgetMsg) { $BudgetMsgArgs = @('--reasoning-budget-message', $ThinkBudgetMsg) }

# Harness-proofing (MIRAI_HARNESS_PROOF=0 turns it off): every effort word except the allowed set becomes medium
# instead of an HTTP 500 from the template; with thinking on, a client output cap below budget + 4096 is raised.
[string[]]$HarnessArgs = @()
if ($env:MIRAI_HARNESS_PROOF -ne '0' -and $HasHarness) {
    $Allow = if ($env:MIRAI_EFFORT_ALLOWED) { $env:MIRAI_EFFORT_ALLOWED } else { 'medium' }
    if ((",$Allow,") -notlike "*,$Effort,*") { $Allow += ",$Effort" }
    $HarnessArgs = @('--reasoning-effort-allow', $Allow, '--reasoning-effort-fallback', 'medium')
    if ($ThinkBudget -ge 0) { $HarnessArgs += @('--reasoning-max-tokens-floor', "$($ThinkBudget + 4096)") }
}

# GPU-side sampling (MIRAI_BS=0 disables); requests with a grammar fall back to CPU sampling automatically.
[string[]]$BsArgs = @()
if ($env:MIRAI_BS -ne '0') { $BsArgs += '--backend-sampling' }

# ---- Speculative decoding (the GGUF's own MTP block, blk.64 in Q8_0) ------------------------------------
# MIRAI_SPEC = draft size (0 = off). Feature test A: draft 2 gives 1.85x decode at every depth of a 64k window with
# outputs identical to the stock fork. Drafting at every depth: the draft context keeps the last MIRAI_DRAFT_WINDOW
# rows; past the tiered-KV line the draft size is MIRAI_SPEC_DEEP (a PCIe-bound step makes extra verify columns
# nearly free). GGML_CUDA_BATCH_INVARIANT=1 keeps per-column mat-vec arithmetic independent of the batch width.
$Spec = if ($env:MIRAI_SPEC) { [int]$env:MIRAI_SPEC } elseif ($env:MIRAI_SPEC_TYPE -and $env:MIRAI_SPEC_TYPE.ToLower() -eq 'dflash') { 3 } else { 2 }
# Tail draft past the VRAM line: every unit of rollback depth keeps one 150 MiB snapshot of the recurrent state
# (~4.5k K/V positions). Measured 2026-10-05 (receipts/mirai-port/tail_draft.log) at 60k / 120k: tail 2 32.2 / 15.1,
# tail 3 37.0 / 17.8, tail 4 38.8 / 19.3 tok/s against 14.6 / 6.2 with no draft. Tail 2 costs nothing beyond what
# drafting below the line already needs and moves the line up ~9k positions; MIRAI_SPEC_DEEP=4 buys +20% past it.
$SpecDeep = if ($env:MIRAI_SPEC_DEEP) { [int]$env:MIRAI_SPEC_DEEP } else { 2 }
$DraftWindow = if ($env:MIRAI_DRAFT_WINDOW) { [int]$env:MIRAI_DRAFT_WINDOW } else { 16384 }
# MIRAI_SPEC_TYPE: mtp (default: the GGUF's own draft block, draft 2) or dflash (ggml-org's dflash-Qwen3.8-27B drafter,
# draft 3). Measured 2026-10-06 (E22): dflash draft 3 decodes +13% at depth 0 and +8.5% at 16k (86 / 78 vs 76 / 72 tok/s),
# outputs identical, for ~590 MiB more VRAM (~17k fewer positions on the line); drafts of 4+ lose acceptance and VRAM.
# A mode for short-context speed; the default keeps the positions. MIRAI_DRAFTER = drafter path (Q4_0 recommended).
$SpecType = if ($env:MIRAI_SPEC_TYPE) { $env:MIRAI_SPEC_TYPE.ToLower() } else { 'mtp' }
$Drafter = if ($env:MIRAI_DRAFTER) { $env:MIRAI_DRAFTER } else { Join-Path $Root 'models\dflash-Qwen3.8-27B-Q4_0.gguf' }
if ($SpecType -eq 'dflash' -and -not (Test-Path $Drafter)) { Write-Host "drafter not found: $Drafter (download dflash-Qwen3.8-27B-Q4_0.gguf from ggml-org/Qwen3.8-27B-GGUF into models\); using the MTP block"; $SpecType = 'mtp' }
[string[]]$SpecArgs = @()
$DraftCells = 0
if ($Spec -gt 0) {
    if ($SpecType -eq 'dflash') {
        $SpecArgs = @('--spec-type', 'draft-dflash', '-md', $Drafter, '--spec-draft-n-max', "$Spec", '-ctkd', $Ctk, '-ctvd', $Ctk)
    } else {
        $SpecArgs = @('--spec-type', 'draft-mtp', '--spec-draft-n-max', "$Spec", '-ctkd', $Ctk, '-ctvd', $Ctk)
    }
    if ($HasTier) {
        if ($SpecType -ne 'dflash') { $SpecArgs += @('--spec-draft-window', "$DraftWindow") }
        $DraftCells = $DraftWindow + 2 * 2048 + 256
    }
}
$env:GGML_CUDA_BATCH_INVARIANT = '1'
# One transient CUDA pool for the target and draft contexts, and a 256-token micro-batch for the draft context: 62 MiB
# back on 10-05 (vram_split.log G4 vs G1), 188 MiB against the product flags (E23, mtp_q4_probe.log: 11,151 vs 11,339 at equal
# cells), identity 3/3, decode and acceptance unchanged. MIRAI_SHARED_POOL=0 reverts.
if ($env:MIRAI_SHARED_POOL -ne '0') { $env:GGML_CUDA_SHARED_POOL = '1'; if (-not $env:LLAMA_MTP_DRAFT_UBATCH) { $env:LLAMA_MTP_DRAFT_UBATCH = '256' } }

# ---- Prefill numerics ----------------------------------------------------------------------------------------
# One activation plane for the FFN matmuls of prompt-sized batches (384+ tokens): +18% prefill at KL 0.00028 against
# the exact two-plane path, top-token agreement 99.19%, no suite pair lost (DECISIONS.md 2026-10-05 10:25 / 10:40).
# MIRAI_PREFILL_PLANES=2 restores the exact path; =1 is one plane for every matmul (+26%, KL 0.00075, 98.86%).
$env:GGML_MIRAI_PREFILL_PLANES = if ($env:MIRAI_PREFILL_PLANES) { $env:MIRAI_PREFILL_PLANES } else { 'ffn' }
# Level-decode chunk: prompt-sized batches decode the trellis weights to int8 levels in chunks and run one GEMM per
# chunk; this bounds a chunk's buffers (levels + int32 products) in MiB. Larger = fewer, bigger GEMMs; 64 / 128 / 256 =
# 1038 / 1089 / 1086 tok/s on the 16.8k prompt (DECISIONS.md 2026-10-05 18:30); 128 is the knee and the engine default.
$LevelsMiB = if ($env:MIRAI_LEVELS_MIB) { [int]$env:MIRAI_LEVELS_MIB } else { 128 }
$env:GGML_MIRAI_LEVELS_MIB = "$LevelsMiB"
$LevelsExtraMiB = [int](0.66 * ($LevelsMiB - 128))   # measured at load: 11,455 MiB at 64, 11,497 at 128 (the 8,220 fixed cost was taken at ~this footprint)

# ---- Tiered KV sizing -----------------------------------------------------------------------------------
# Bytes per KV cell (16 attention layers x K+V x 4 heads x 256 dims, same architecture as Bonsai 2 27B); the
# per-layer staging buffer for the host tail is 1/16 of that. Fixed cost = everything but the K/V head and staging,
# measured against nvidia-smi's free VRAM on 2026-10-04 (feature tests B and C, -b 2048 -ub 512, 262k window):
# 8,220 MiB without drafting; with drafting add 150 MiB per unit of rollback depth (max of draft and tail sizes:
# the recurrent-state snapshots) plus 664 MiB for the second context (draft K/V 43, compute 118, pool 14, and
# ~490 of CUDA-side overhead): 9,184 at tail 2 (T2: 11,024 at load), 9,434-9,484 at tail 4 (C/T4: 11,314-11,324),
# run-to-run noise ~50. With the 1,000 MiB headless margin that gives ~39.7k cells in VRAM at tail 2, ~31.5k at
# tail 4, ~70k without drafting. MIRAI_FIXED_MIB overrides.
$TierCells = 0
[string[]]$TierArgs = @()
$Margin = 0
if ($Tier) {
    $CellBytes = switch ($Ctk) { 'q8_0' { 34816 } 'q4_0' { 18432 } 'f16' { 65536 } default { 34816 } }
    if ($env:MIRAI_KV_VRAM_CELLS) {
        $TierCells = [int]$env:MIRAI_KV_VRAM_CELLS
    } else {
        $FreeMiB = [int]((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1).Trim())
        $Headless = ((& nvidia-smi --query-gpu=display_active --format=csv,noheader | Select-Object -First 1).Trim()) -eq 'Disabled'
        # Headless margin measured on Mirai 2026-10-05 (receipts/mirai-port/margin_soak.log): 10-minute soaks at
        # 4k/16k/32k, 800 MiB held twice (worst decode 67.3 / 67.4 tok/s, no demotion) and 600 also held once; the
        # pre-declared gate adopted 800 (~45.8k positions in VRAM). 1300 with the display on this card (Bonsai soak).
        $Margin = if ($env:MIRAI_VRAM_MARGIN) { [int]$env:MIRAI_VRAM_MARGIN } elseif ($Headless) { 800 } else { 1300 }
        $Depth = [math]::Max($Spec, $(if ($Spec -gt 0) { $SpecDeep } else { 0 }))
        # 664 = draft context 175 + CUDA-side overhead of a second context ~490, measured as the remainder of the
        # T2/T4/C launches (9,184 at depth 2, 9,434-9,484 at depth 4) after weights, snapshots, head and staging
        # packed mask + 1024 micro-batch: +44 MiB at load over the f16/512 pair (MP1024 11,368 vs M16 11,324)
        # 2048 micro-batch (MIRAI_UBATCH=2048, packed mask): measured at load 11,595 MiB with 31,600 cells vs 11,339 with 40,960 at
        # 1024 (ub2048_probe.log), i.e. +567 MiB of activation buffers for +5.6% prefill: a mode, not the default
        $UBatchMiB = if ($Packed -and $UBatch -ge 2048) { 611 } elseif ($Packed -and $UBatch -ge 1024) { 44 } elseif (-not $Packed -and $UBatch -ge 1024) { 395 } else { 0 }
        # dflash: resident weights without the MTP block plus the drafter and its context; MIRAI_DFLASH_FIXED_MIB is the
        # measured "everything but K/V and snapshots" of the dflash launch (set from receipts/mirai-port/dflash_probe.log)
        # measured 2026-10-06 (dflash_probe.log, DF3 at 40,960 cells): 11,925 MiB at load = 1,360 K/V + 544 staging + 450 snapshots
        # + 44 micro-batch + 9,527 of weights (MTP block skipped) + drafter layers + contexts; the MTP serve is 8,884 on the same terms
        $DflashFixed = if ($env:MIRAI_DFLASH_FIXED_MIB) { [int]$env:MIRAI_DFLASH_FIXED_MIB } else { 9530 }
        $PoolMiB = if ($env:MIRAI_SHARED_POOL -ne '0') { -188 } else { 0 }   # E23 (mtp_q4_probe.log): POOL 11,151 vs BASE 11,339 at 40,960 cells
        # the mtpq4 file keeps 204 MiB less of weights resident (E23 POOLQ4 10,947): weights term 8,016 instead of 8,220
        $WeightsMiB = if ((Split-Path $Model -Leaf) -ieq 'Qwen3.8-27B-S-mirai-mtpq4.gguf') { 8016 } else { 8220 }
        $FixedMiB = if ($env:MIRAI_FIXED_MIB) { [int]$env:MIRAI_FIXED_MIB } elseif ($Spec -gt 0 -and $SpecType -eq 'dflash') { $DflashFixed + 150 * $Depth + $UBatchMiB + $LevelsExtraMiB + $PoolMiB } elseif ($Spec -gt 0) { $WeightsMiB + 150 * $Depth + 664 + $UBatchMiB + $LevelsExtraMiB + $PoolMiB } else { $WeightsMiB + $UBatchMiB + $LevelsExtraMiB + $PoolMiB }
        $Budget = ($FreeMiB - $Margin - $FixedMiB) * 1MB - $Ctx * $CellBytes / 16
        $TierCells = [int]([math]::Floor($Budget / ($CellBytes * 15 / 16) / 256) * 256)
    }
    if ($TierCells -ge $Ctx) {
        $TierCells = 0
    } elseif ($TierCells -lt 8192) {
        throw "Tiered KV: only $TierCells cells fit in VRAM. Free VRAM, lower MIRAI_CTX, or set MIRAI_KV_VRAM_CELLS."
    }
    if ($TierCells -gt 0) {
        $TierArgs = @('--kv-vram-cells', "$TierCells")
        if ($Spec -gt 0) { $SpecArgs += @('--spec-draft-n-max-tail', "$SpecDeep") }
    }
}

Write-Host "model  $(Split-Path $Model -Leaf)  (Mirai S, trellis 2.4b, on engine $(if (Test-Path (Join-Path $Root 'engine\.git')) { (git -C (Join-Path $Root 'engine') rev-parse --short HEAD) } else { '?' }))"
Write-Host "window $Ctx / $Ctk"
if ($TierCells -gt 0) { Write-Host "kv     tiered: cells 0..$TierCells in VRAM, $TierCells..$Ctx in system RAM (VRAM margin $Margin MiB)" }
Write-Host "spec   $SpecType draft $Spec$(if ($TierCells -gt 0 -and $Spec -gt 0) { " ($SpecDeep past the VRAM line)" })$(if ($HasTier -and $Spec -gt 0 -and $SpecType -ne 'dflash') { ", draft window $DraftWindow" })"
Write-Host "listen 0.0.0.0:$Port  think=$Think effort=$Effort budget=$ThinkBudget  harness-proofing=$($HarnessArgs.Count -gt 0)  backend-sampling=$($BsArgs.Count -gt 0)"
Write-Host "prefill ubatch $UBatch  mask=$(if ($Packed) { 'packed 1-bit' } else { 'f16' })  planes=$($env:GGML_MIRAI_PREFILL_PLANES)  level chunk $LevelsMiB MiB"
Write-Host "api    Authorization: Bearer <artifacts/api_key.txt>"

# ---- The layer (MIRAI_LAYER=0 turns it off) -----------------------------------------------------------------
# API cards, API check and the sandboxed Python tool in front of llama-server on the same port clients use.
# Measured on Mirai S: suite 13 -> 30 of 37, 17 rescues, 0 losses (docs/REPORT.md). Needs layer\fetch_runtime.ps1 once.
$LayerDir = Join-Path $Root 'layer'
$Layer = $env:MIRAI_LAYER -ne '0'
if ($Layer) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    $rt = Test-Path (Join-Path $LayerDir 'runtime\bin\python-3.12.0.wasm')
    $wt = $false
    if ($py) { & python -c "import wasmtime" 2>$null; $wt = ($LASTEXITCODE -eq 0) }
    if (-not ($py -and $rt -and $wt)) {
        Write-Host "layer  off: run layer\fetch_runtime.ps1 once to enable it (python=$([bool]$py) runtime=$rt wasmtime=$wt)"
        $Layer = $false
    }
}
$ListenHost = '0.0.0.0'; $ListenPort = $Port; $LayerProc = $null
if ($Layer) {
    $InnerPort = if ($env:MIRAI_INNER_PORT) { [int]$env:MIRAI_INNER_PORT } else { $Port + 10000 }
    $ListenHost = '127.0.0.1'; $ListenPort = $InnerPort
    $env:BONSAI_LAYER_KEY = $ApiKey
    # MIRAI_ROUND_NOTE=1: the E19 round countdown on tool results (off until measured; DECISIONS 2026-10-06 00:40)
    [string[]]$LayerFlags = @(); if ($env:MIRAI_ROUND_NOTE -eq '1') { $LayerFlags += '--round-note' }
    $LayerProc = Start-Process python -PassThru -WindowStyle Hidden -ArgumentList (@(
        ('"' + (Join-Path $LayerDir 'bonsai_layer.py') + '"'), '--host', '0.0.0.0', '--port', "$Port",
        '--upstream', "http://127.0.0.1:$InnerPort") + $LayerFlags)
    Remove-Item Env:BONSAI_LAYER_KEY
    Write-Host "layer  on: clients use :$Port (API cards, API check, sandboxed Python); llama-server on 127.0.0.1:$InnerPort"
}
# MIRAI_LOG_FILE=path: the server also writes its log there (for hidden/background launches; the console still gets it)
[string[]]$LogArgs = @()
if ($env:MIRAI_LOG_FILE) {
    $lf = if ([IO.Path]::IsPathRooted($env:MIRAI_LOG_FILE)) { $env:MIRAI_LOG_FILE } else { Join-Path $Root $env:MIRAI_LOG_FILE }
    New-Item -ItemType Directory -Force (Split-Path $lf) | Out-Null
    $LogArgs = @('--log-file', $lf)
}
Set-Location $Bin
try {
& .\llama-server.exe @TierArgs @SpecArgs @BsArgs @BudgetMsgArgs @HarnessArgs @LogArgs @MaskArgs `
    --reasoning-budget $ThinkBudget `
    -n 24576 `
    -m $Model `
    --chat-template-file (Join-Path $Root 'templates\bonsai-template.jinja') `
    -ngl 99 `
    -fa on `
    -c $Ctx `
    -np 1 `
    -b 2048 `
    -ub $UBatch `
    -ctk $Ctk `
    -ctv $Ctk `
    --host $ListenHost `
    --port $ListenPort `
    --alias mirai-s-27b `
    --jinja `
    --prio 2 `
    --poll 100 `
    --metrics `
    --api-key $ApiKey `
    --temp 1.0 `
    --top-p 0.95 `
    --top-k 20
} finally {
    if ($LayerProc -and -not $LayerProc.HasExited) { Stop-Process -Id $LayerProc.Id -Force -ErrorAction SilentlyContinue }
}
