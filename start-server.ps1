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
#   MIRAI_SPARSE=1         sparse reads past the VRAM line (192k decode 11.7 -> 17 tok/s; the line ~5k positions shorter)
#   MIRAI_MMPROJ=file      images (vision projector, encoder on the CPU; MIRAI_MMPROJ_GPU=1 puts it on the card)
#   MIRAI_CTK=q3_0         long-context cache (2.9x the positions in VRAM, 245k decode 3.8x; MIRAI_CTV for a separate V type)
#   MIRAI_SLOT_SAVE_PATH=dir  saved conversations: the layer saves long prompts there and restores them (lc- files, 20 GB cap);
#                          POST /slots/0?action=save|restore {"filename": ...} also works (those files are not removed)
#   MIRAI_SLOT_CACHE_AFTER=1  saved conversations save after the answer, not before the request (opt-in; see docs/agents-layer/SAVED_CONVERSATIONS.md)
$ErrorActionPreference = 'Stop'
# Variables set in this window before the launcher runs. A value left over from an earlier test (MIRAI_SPEC=0 is the
# common one) silently changes the server; the launcher prints them all at start.
$UserEnv = @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(MIRAI_|LLAMA_ARG_|LLAMA_MTP_|GGML_)' } | Sort-Object Name)
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
# q8_0 K/V. Measured on Mirai S (2026-10-09, wikitext, 16k chunks x 4, against f16 K/V; docs/REPORT.md 6f): q8_0
# KL 0.00050, top token the same on 99.64%; q4_0 KL 0.0243, 97.10%, one token at KL 22.6, so MIRAI_CTK=q4_0 is not
# recommended. Tiered KV (--kv-vram-cells N): cells [0, N) in VRAM, the rest in pinned system
# RAM mapped into the same CUDA range, bit-identical output; past N a step reads the RAM tail over PCIe.
$Tier = ($env:MIRAI_TIER -ne '0') -and $HasTier
$Ctx = if ($env:MIRAI_CTX) { [int]$env:MIRAI_CTX } elseif ($Tier) { 262144 } else { 65536 }
$Ctk = if ($env:MIRAI_CTK) { $env:MIRAI_CTK } else { 'q8_0' }
# MIRAI_CTV: the V type when it should differ from K (same-type pairs run the fast tensor-core path; a mixed pair needs an
# engine built with GGML_CUDA_FA_ALL_QUANTS). MIRAI_CTK=q3_0 (engine with patch 0056): 2.9x the positions in VRAM of q8_0,
# 245k decode 9.6 -> 36.9 tok/s, copies and needles at 245k equal to q8_0, HumanEval 157/164; its per-token KL is high
# (0.058), so it is a long-context option, not the default (docs/research/kvtypes-20261015 in the serve repo).
$Ctv = if ($env:MIRAI_CTV) { $env:MIRAI_CTV } else { $Ctk }
$Port = if ($env:MIRAI_PORT) { [int]$env:MIRAI_PORT } else { 8080 }

# Vision projector (optional): MIRAI_MMPROJ=<file in models\ or a full path> (the Qwen3.8-27B projector, for example
# mmproj-Qwen3.8-27B-base-f16.gguf; PrismML's Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf works too, the same vision encoder).
# llama-server's own LLAMA_ARG_MMPROJ is picked up the same way. Default: the encoder runs on the CPU
# (--no-mmproj-offload) and takes no VRAM from the cache. MIRAI_MMPROJ_GPU=1 puts it on the card and counts its file
# size in the VRAM line.
$Mmproj = if ($env:MIRAI_MMPROJ) { $env:MIRAI_MMPROJ } elseif ($env:LLAMA_ARG_MMPROJ) { $env:LLAMA_ARG_MMPROJ } else { $null }
[string[]]$MmprojArgs = @()
$MmprojMiB = 0
$MmprojGpu = $false
if ($Mmproj) {
    if (-not [IO.Path]::IsPathRooted($Mmproj)) { $Mmproj = Join-Path $Root "models\$Mmproj" }
    if (-not (Test-Path $Mmproj)) { throw "vision projector not found: $Mmproj" }
    Remove-Item Env:LLAMA_ARG_MMPROJ -ErrorAction SilentlyContinue   # passed explicitly below
    $MmprojGpu = $env:MIRAI_MMPROJ_GPU -eq '1'
    $MmprojArgs = @('--mmproj', $Mmproj)
    if ($MmprojGpu) { $MmprojMiB = [int]((Get-Item $Mmproj).Length / 1MB) } else { $MmprojArgs += '--no-mmproj-offload' }
}

# Sparse host-tail reads (Bonsai patch 0055, engine 784986b41 on): a decode attention op past the VRAM line reads only the
# host pages whose int8 bounds score highest (at least 12,288 cells or 1/8 of the host tail, plus the last 1,024 cells)
# instead of the whole host tail. Mirai S, RTX 4070 (docs/research/sparse-20261014): 192k decode 11.7 -> 16.2 tok/s;
# exact copies and needles equal to dense at 160k / 200k / 245k (1/16 of the tail missed a needle at 245k, N04). Opt-in:
# MIRAI_SPARSE=1 with an engine that has it. The page-bound tables take VRAM for the whole window (514 B per host cell at
# page 64, plus 64 MiB), counted in the line below. Prompt batches of 32+ tokens keep the packed mask and the dense read.
$CudaDllPath = Join-Path $Bin 'ggml-cuda.dll'
$CudaDll = if (Test-Path $CudaDllPath) { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($CudaDllPath)) } else { '' }
$SparseAvail = $CudaDll.Contains('GGML_CUDA_FA_SPARSE_MIN_HOST')
if ($Tier -and $env:MIRAI_SPARSE -eq '1' -and -not $env:GGML_CUDA_FA_SPARSE) {
    if (-not $SparseAvail) { Write-Warning "MIRAI_SPARSE=1: this engine has no sparse host-tail reads; dense" }
    else {
        $env:GGML_CUDA_FA_SPARSE = '12288,64,1024'
        if (-not $env:GGML_CUDA_FA_SPARSE_FRAC) { $env:GGML_CUDA_FA_SPARSE_FRAC = '0.125' }   # N04 / N04b: 1/16 missed a needle at 245k
        if (-not $env:GGML_CUDA_FA_SPARSE_FAST) { $env:GGML_CUDA_FA_SPARSE_FAST = '1' }
        if (-not $env:GGML_CUDA_KV_TIER_STAGE_MIN_Q) { $env:GGML_CUDA_KV_TIER_STAGE_MIN_Q = '9' }
        if (-not $env:GGML_CUDA_FA_SPARSE_MIN_HOST) { $env:GGML_CUDA_FA_SPARSE_MIN_HOST = '32768' }
    }
}
$SparsePage = 0
if ($env:GGML_CUDA_FA_SPARSE) {
    $SparseParts = $env:GGML_CUDA_FA_SPARSE -split ','
    if ([int]$SparseParts[0] -gt 0) { $SparsePage = if ($SparseParts.Count -gt 1 -and [int]$SparseParts[1] -gt 0) { [int]$SparseParts[1] } else { 64 } }
}
# bytes of page bounds per host cell: 16 attention layers x 4 KV heads x (int8 max + min per dim, 2 x 256, + one f16 scale)
$SparseCellBytes = if ($SparsePage) { 16 * 4 * (2 * 256 + 2) / $SparsePage } else { 0 }

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
# Replay rollback (an engine with LLAMA_RS_REPLAY; on by default, MIRAI_RS_REPLAY=0 turns it off): the recurrent state keeps
# one plane instead of one 150 MiB snapshot per rollback token; each rollback token then costs ~8 MiB (its conv snapshot and
# its inputs). The output is byte-identical; the freed VRAM goes to the KV cache (receipts/replay M1-M5).
$LlamaDll = ''
try { $LlamaDll = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes((Join-Path $Bin 'llama.dll'))) } catch { }
$Replay = $Spec -gt 0 -and $env:MIRAI_RS_REPLAY -ne '0' -and $LlamaDll.Contains('LLAMA_RS_REPLAY')
if ($Replay) { $env:LLAMA_RS_REPLAY = '1' }
elseif ($env:MIRAI_RS_REPLAY -eq '1') { Write-Host "note   MIRAI_RS_REPLAY=1 is off: $(if ($Spec -le 0) { 'drafting is off' } else { 'this engine has no replay rollback' })" }
$SnapMiB = if ($Replay) { 8 } else { 150 }   # VRAM per rollback token
# With replay a tail token costs ~8 MiB, so the tail is 4 (receipts/tail4, 2026-10-19: decode +18.8 % at 128k and +23.5 %
# at 200k against tail 2, the line 512 positions lower); without replay tail 2 (each token a 150 MiB snapshot).
$SpecDeep = if ($env:MIRAI_SPEC_DEEP) { [int]$env:MIRAI_SPEC_DEEP } elseif ($Replay) { 4 } else { 2 }
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
    # MIRAI_LOOKUP: a lookup drafter (for example ngram-mod) in front of the model drafter. It drafts text that is
    # already in the context; the model drafter drafts when it finds no match. MIRAI_SPEC_ARGS: extra drafter flags,
    # space-separated (for example "--spec-lookup-n-max 32").
    # Default (MTP drafter, engine with --spec-lookup-n-max): ngram-mod in front, lookup limit 32. Measured on Mirai S
    # (receipts/lookup_ab_mirai.jsonl in the notebook, same text in every arm): file rewrites 86.5 -> 265.6 tok/s, edit
    # calls 85.1 -> 103.8, plain text unchanged. MIRAI_LOOKUP=0 turns it off; not tested with the DFlash drafter.
    $LookupN = if ($env:MIRAI_LOOKUP_N) { [int]$env:MIRAI_LOOKUP_N } else { 32 }
    $LookupDefault = ($Help -match '--spec-lookup-n-max') -and $SpecType -ne 'dflash' -and $LookupN -gt 0
    $LookupName = if ($env:MIRAI_LOOKUP -eq '0') { '' } elseif ($env:MIRAI_LOOKUP) { $env:MIRAI_LOOKUP } elseif ($LookupDefault) { 'ngram-mod' } else { '' }
    $Lookup = if ($LookupName) { "$LookupName," } else { '' }
    if ($SpecType -eq 'dflash') {
        $SpecArgs = @('--spec-type', "${Lookup}draft-dflash", '-md', $Drafter, '--spec-draft-n-max', "$Spec", '-ctkd', $Ctk, '-ctvd', $Ctk)
    } else {
        $SpecArgs = @('--spec-type', "${Lookup}draft-mtp", '--spec-draft-n-max', "$Spec", '-ctkd', $Ctk, '-ctvd', $Ctk)
    }
    if ($LookupName -and ($Help -match '--spec-lookup-n-max') -and -not ($env:MIRAI_SPEC_ARGS -match 'spec-lookup-n-max')) {
        $SpecArgs += @('--spec-lookup-n-max', "$LookupN")
    }
    if ($env:MIRAI_SPEC_ARGS) { $SpecArgs += @($env:MIRAI_SPEC_ARGS -split '\s+' | Where-Object { $_ }) }
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
    $HalfBytes = @{ 'q8_0' = 17408; 'q5_1' = 12288; 'q5_0' = 11264; 'q4_0' = 9216; 'q3_0' = 7168; 'f16' = 32768 }   # one of K or V per cell
    $CellBytes = $(if ($HalfBytes.ContainsKey($Ctk)) { $HalfBytes[$Ctk] } else { 17408 }) + $(if ($HalfBytes.ContainsKey($Ctv)) { $HalfBytes[$Ctv] } else { 17408 })
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
        $FixedMiB = if ($env:MIRAI_FIXED_MIB) { [int]$env:MIRAI_FIXED_MIB } elseif ($Spec -gt 0 -and $SpecType -eq 'dflash') { $DflashFixed + $SnapMiB * $Depth + $UBatchMiB + $LevelsExtraMiB + $PoolMiB } elseif ($Spec -gt 0) { $WeightsMiB + $SnapMiB * $Depth + 664 + $UBatchMiB + $LevelsExtraMiB + $PoolMiB } else { $WeightsMiB + $UBatchMiB + $LevelsExtraMiB + $PoolMiB }
        $FixedMiB += $MmprojMiB
        if ($SparsePage) { $FixedMiB += 64 }   # first-fill buffer and table headroom (Bonsai VRAM trace at 245k, docs/receipts/vram245_*.csv there)
        $Budget = ($FreeMiB - $Margin - $FixedMiB) * 1MB - $Ctx * $CellBytes / 16 - $Ctx * $SparseCellBytes
        $TierCells = [int]([math]::Floor($Budget / ($CellBytes * 15 / 16 - $SparseCellBytes) / 256) * 256)
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

# Checkpoints inside long messages (engine 75eaee882 and later). A prompt that changes inside one long message (an edited
# tool result, a file sent again) then restores the nearest checkpoint instead of reading the whole prompt again: at 32k
# 34.6-36.5 s -> 4.5-6.6 s, text identical (docs/REPORT.md 6g). It costs no VRAM, and it does not raise the server's
# limit of 32 checkpoints per slot (~150 MiB of system RAM each), which a long session already fills with checkpoints
# at the ends of requests; it only places some inside long messages too. Long prompts that need no restore take about
# 1 s longer. MIRAI_CKPT_EVERY=0 turns it off; a number sets the spacing in tokens.
$CkptNote = ''
if ($Help -match '--checkpoint-every-nt' -and -not $env:LLAMA_ARG_CHECKPOINT_EVERY_NT) {
    if ($env:MIRAI_CKPT_EVERY -eq '0') {
        $CkptNote = 'only at user messages and prompt ends (MIRAI_CKPT_EVERY=0)'
    } else {
        $env:LLAMA_ARG_CHECKPOINT_EVERY_NT = if ($env:MIRAI_CKPT_EVERY) { $env:MIRAI_CKPT_EVERY } else { '8192' }
        $CkptNote = "also every $($env:LLAMA_ARG_CHECKPOINT_EVERY_NT) tokens inside long messages (MIRAI_CKPT_EVERY=0 turns it off)"
    }
}

# System RAM. The server's commit charge is the VRAM it holds (Windows charges that to the process as well), plus the
# pinned K/V tail past the VRAM line, plus the prompt cache (default limit 8 GiB; one entry of a 26k-token prompt is
# ~2 GB with its checkpoint copies), plus the checkpoints (up to 32, ~150 MiB each). With the defaults, 7 sequential
# thinking requests with 26k-token prompts took the server to 22.1 GB on a 32 GB machine (the page file grew); on a
# 16 GB machine the same engine stopped with "bad allocation" and then exited (a user report). With a 4096 MiB cache:
# 17.8 GB. So: under 24 GB of RAM, a 1024 MiB prompt cache and 8 checkpoints; under 48 GB, a 4096 MiB
# cache (checkpoints stay at 32: they make agent turns fast); 48 GB and more, the server defaults.
# LLAMA_ARG_CACHE_RAM / LLAMA_ARG_CTX_CHECKPOINTS set by hand win.
$RamArgs = @()
$RamNote = ''
$RamShort = $false
try {
    $RamGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $CacheMiB = if ($RamGiB -lt 24) { 1024 } elseif ($RamGiB -lt 48) { 4096 } else { 8192 }
    $Ckpts = if ($RamGiB -lt 24) { 8 } else { 32 }
    if ($env:LLAMA_ARG_CACHE_RAM) { $CacheMiB = $env:LLAMA_ARG_CACHE_RAM } elseif ($RamGiB -lt 48) { $RamArgs += @('--cache-ram', "$CacheMiB") }
    if ($env:LLAMA_ARG_CTX_CHECKPOINTS) { $Ckpts = $env:LLAMA_ARG_CTX_CHECKPOINTS } elseif ($RamGiB -lt 24) { $RamArgs += @('--ctx-checkpoints', "$Ckpts") }
    # what the server commits at load and at most, against what is free now (RAM + page file)
    $FreeCommitMiB = [int]((Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory / 1KB)
    $VramMiB = if ($FreeMiB) { $FreeMiB } else { 12288 }
    $TailMiB = if ($TierCells -gt 0) { [int](($Ctx - $TierCells) * $CellBytes / 1MB) } else { 0 }
    $NeedMiB = $VramMiB + $TailMiB + 2048 + [int]$CacheMiB + [int]$Ckpts * 150
    # a system-managed page file grows by a few GB without trouble (32 GB test machine: 40.7 -> 43.8 GiB limit)
    $RamShort = $NeedMiB -gt $FreeCommitMiB + $(if ($RamGiB -lt 24) { 0 } else { 4096 })
    $RamNote = "$RamGiB GB: prompt cache $CacheMiB MiB, checkpoints $Ckpts; the server can commit ~$NeedMiB MiB (VRAM $VramMiB, K/V tail $TailMiB), $FreeCommitMiB MiB free now"
} catch { }

Write-Host "model  $(Split-Path $Model -Leaf)  (Mirai S, trellis 2.4b, on engine $(if (Test-Path (Join-Path $Root 'engine\.git')) { (git -C (Join-Path $Root 'engine') rev-parse --short HEAD) } else { '?' }))"
Write-Host "window $Ctx / $Ctk"
if ($TierCells -gt 0) { Write-Host "kv     tiered: cells 0..$TierCells in VRAM, $TierCells..$Ctx in system RAM (VRAM margin $Margin MiB)" }
if ($Mmproj) { Write-Host "vision $(Split-Path $Mmproj -Leaf) on the $(if ($MmprojGpu) { "GPU ($MmprojMiB MiB counted in the VRAM line)" } else { "CPU (no VRAM; MIRAI_MMPROJ_GPU=1 to offload)" })" }
if ($TierCells -gt 0 -and $SparsePage) { Write-Host "kv     sparse host-tail reads: $($env:GGML_CUDA_FA_SPARSE) (B,P,R), FRAC $(if ($env:GGML_CUDA_FA_SPARSE_FRAC) { $env:GGML_CUDA_FA_SPARSE_FRAC } else { 0.0625 }), from $(if ($env:GGML_CUDA_FA_SPARSE_MIN_HOST) { $env:GGML_CUDA_FA_SPARSE_MIN_HOST } else { 0 }) host cells on; $([int](($Ctx - $TierCells) * $SparseCellBytes / 1MB) + 64) MiB of page bounds counted" }
if ($CkptNote) { Write-Host "ckpt   $CkptNote" }
if ($RamNote) {
    Write-Host "ram    $RamNote"
    if ($RamShort) {
        Write-Host "       Less is free than the server can use. Windows can grow a system-managed page file; if it cannot, the"
        Write-Host "       server stops with 'bad allocation'. Close other programs, enlarge the page file, or use a smaller window"
        Write-Host "       (MIRAI_CTX=131072 keeps most of the K/V in VRAM)."
    }
}
if ($TierCells -gt 0 -and $FreeMiB) {
    # The VRAM line is set from the free VRAM at start. Show it, so a low line has a visible cause (other programs that
    # hold VRAM when the server starts move the line down; a user report had 2.3 GB held at one start).
    $TotalMiB = [int]((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1).Trim())
    $OtherMiB = $TotalMiB - $FreeMiB
    $CellsPerGiB = [int](1GB / ($CellBytes * 15 / 16) / 1000)
    Write-Host "vram   $FreeMiB of $TotalMiB MiB free at start (other programs: $OtherMiB MiB); each GiB more free moves the line by about ${CellsPerGiB}k cells"
    if ($OtherMiB -gt $(if ($Headless) { 768 } else { 2048 })) {
        Write-Host "       Other programs hold much VRAM now (Task Manager > Performance > GPU > Dedicated GPU memory)."
        Write-Host "       Close them, or wait until an old server has stopped, then start again for a higher VRAM line."
    }
}
if ($Spec -gt 0) {
    Write-Host "spec   $SpecType draft $Spec$(if ($TierCells -gt 0) { " ($SpecDeep past the VRAM line)" })$(if ($HasTier -and $SpecType -ne 'dflash') { ", draft window $DraftWindow" }) (drafting on)$(if ($LookupName) { "; lookup $LookupName up to $LookupN (MIRAI_LOOKUP=0 turns it off)" })"
} else {
    Write-Host "spec   draft 0: drafting is OFF because MIRAI_SPEC=$($env:MIRAI_SPEC) is set in this window. Decode is slower:"
    Write-Host "       draft 2 gives 1.85x decode at every depth of a 64k window (feature test A)."
    Write-Host "       To turn it on: Remove-Item Env:MIRAI_SPEC (or open a new window), then start again."
}
# the launcher sets these itself, and they stay in the window after a run: not the user's settings
$Own = @('BONSAI_LAYER_KEY', 'BONSAI_SLOT_SAVE_PATH', 'LLAMA_ARG_CHAT_TEMPLATE_KWARGS', 'LLAMA_ARG_CHECKPOINT_EVERY_NT', 'GGML_CUDA_BATCH_INVARIANT', 'GGML_CUDA_SHARED_POOL',
         'LLAMA_MTP_DRAFT_UBATCH', 'GGML_MIRAI_PREFILL_PLANES', 'GGML_MIRAI_LEVELS_MIB', 'LLAMA_RS_REPLAY')
$Listed = @($UserEnv | Where-Object { $_.Name -notin $Own -and $_.Value })
if ($Listed.Count -gt 0) {
    Write-Host ("env    set in this window, these change the defaults: " + (($Listed | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  '))
    Write-Host "       A new PowerShell window starts without them. Remove-Item Env:NAME removes one."
}
Write-Host "listen 0.0.0.0:$Port  think=$Think effort=$Effort budget=$ThinkBudget  harness-proofing=$($HarnessArgs.Count -gt 0)  backend-sampling=$($BsArgs.Count -gt 0)"
Write-Host "prefill ubatch $UBatch  mask=$(if ($Packed) { 'packed 1-bit' } else { 'f16' })  planes=$($env:GGML_MIRAI_PREFILL_PLANES)  level chunk $LevelsMiB MiB"
Write-Host "api    Authorization: Bearer <artifacts/api_key.txt>"

# Saved conversations: an absolute folder, because the server starts in $Bin and would read a relative one from there.
# A restored conversation that continues reads only its new turn. Resolve it before the layer
# starts: the layer (layer\slot_cache.py) and the server must use the same folder.
[string[]]$SlotArgs = @(); $SlotDir = $null
if ($env:MIRAI_SLOT_SAVE_PATH) {
    $SlotDir = (New-Item -ItemType Directory -Force -Path $env:MIRAI_SLOT_SAVE_PATH).FullName
    $SlotArgs = @('--slot-save-path', $SlotDir)
}

# ---- The layer (MIRAI_LAYER=0 turns it off) -----------------------------------------------------------------
# API cards, API check and the sandboxed Python tool in front of llama-server on the same port clients use.
# Measured on Mirai S: suite 13 -> 30 of 37, 17 rescues, 0 losses (docs/REPORT.md). Needs layer\fetch_runtime.ps1 once.
$LayerDir = Join-Path $Root 'layer'
$Layer = $env:MIRAI_LAYER -ne '0'
if ($Layer) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    $rt = Test-Path (Join-Path $LayerDir 'runtime\bin\python-3.12.0.wasm')
    $wt = $false
    # Probe only when the layer can run. Under $ErrorActionPreference = 'Stop', Windows PowerShell 5.1 makes the
    # traceback on python's stderr a terminating NativeCommandError, so a missing wasmtime stopped the launcher.
    if ($py -and $rt) {
        try { & python -c "import wasmtime" 2>$null; $wt = ($LASTEXITCODE -eq 0) } catch { $wt = $false }
    }
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
    # Saved conversations: the layer reads BONSAI_SLOT_SAVE_PATH (as BONSAI_LAYER_KEY). Set it from MIRAI_SLOT_SAVE_PATH
    # for the layer process only; a value left in this window from a Bonsai run must not turn the cache on.
    $PrevSlotEnv = $env:BONSAI_SLOT_SAVE_PATH
    if ($SlotDir) { $env:BONSAI_SLOT_SAVE_PATH = $SlotDir } else { Remove-Item Env:BONSAI_SLOT_SAVE_PATH -ErrorAction SilentlyContinue }
    $PrevAfterEnv = $env:BONSAI_SLOT_CACHE_AFTER
    $env:BONSAI_SLOT_CACHE_AFTER = $(if ($env:MIRAI_SLOT_CACHE_AFTER -eq '1') { '1' } else { '0' })   # explicit: the layer's own default is 1
    # MIRAI_ROUND_NOTE=1: the E19 round countdown on tool results (off until measured; DECISIONS 2026-10-06 00:40)
    [string[]]$LayerFlags = @(); if ($env:MIRAI_ROUND_NOTE -eq '1') { $LayerFlags += '--round-note' }
    $LayerProc = Start-Process python -PassThru -WindowStyle Hidden -ArgumentList (@(
        ('"' + (Join-Path $LayerDir 'bonsai_layer.py') + '"'), '--host', '0.0.0.0', '--port', "$Port",
        '--upstream', "http://127.0.0.1:$InnerPort") + $LayerFlags)
    Remove-Item Env:BONSAI_LAYER_KEY
    if ($PrevSlotEnv) { $env:BONSAI_SLOT_SAVE_PATH = $PrevSlotEnv } else { Remove-Item Env:BONSAI_SLOT_SAVE_PATH -ErrorAction SilentlyContinue }
    if ($PrevAfterEnv) { $env:BONSAI_SLOT_CACHE_AFTER = $PrevAfterEnv } else { Remove-Item Env:BONSAI_SLOT_CACHE_AFTER -ErrorAction SilentlyContinue }
    Write-Host "layer  on: clients use :$Port (API cards, API check, sandboxed Python); llama-server on 127.0.0.1:$InnerPort"
}
if ($SlotDir) {
    if ($Layer) {
        Write-Host "slots  saved conversations in $SlotDir (the layer saves prompts of 16k+ tokens and restores them; lc- files, oldest removed past 20 GB)"
    } else {
        Write-Host "slots  save / restore folder: $SlotDir (POST /slots/0?action=save|restore; files are not removed automatically)"
    }
}
# MIRAI_LOG_FILE=path: the server also writes its log there (for hidden/background launches; the console still gets it)
[string[]]$LogArgs = @()
if ($env:MIRAI_LOG_FILE) {
    $lf = if ([IO.Path]::IsPathRooted($env:MIRAI_LOG_FILE)) { $env:MIRAI_LOG_FILE } else { Join-Path $Root $env:MIRAI_LOG_FILE }
    New-Item -ItemType Directory -Force (Split-Path $lf) | Out-Null
    $LogArgs = @('--log-file', $lf)
}
# Another app busy on this GPU (rendering or computing on the card) slows the server even when it uses no VRAM:
# Windows time-slices the GPU between them, and MTP drafting (many short kernels per token) loses the most. Measured
# by Milor123 (issue #4): 56 -> 83 tok/s at 16k after moving kdeconnect-app.exe to the iGPU. Warn, never block.
try {
    $Busy = 0
    foreach ($i in 1..6) {
        $u = [int]((& nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1).Trim())
        if ($u -gt $Busy) { $Busy = $u }
        Start-Sleep -Milliseconds 250
    }
    if ($Busy -ge 10) {
        $Apps = (& nvidia-smi) | Select-String '^\|\s+\d+\s+\S+\s+\S+\s+\d+\s+(C\+G|G|C)\s+(\S+)' | ForEach-Object { Split-Path $_.Matches[0].Groups[2].Value -Leaf } | Where-Object { $_ -ne 'llama-server.exe' } | Sort-Object -Unique
        Write-Host ("warn   the GPU is {0}% busy before the server starts: one of these apps is working on this card: {1}. Drafting slows when the GPU is shared;" -f $Busy, ($Apps -join ', '))
        Write-Host "       close it or set it to the integrated GPU (Settings > System > Display > Graphics), then restart."
    }
} catch { }
Set-Location $Bin
# Everything after this line is the server's command line, as one array (printed into the stderr file for receipts).
# The launcher sizes the GPU memory itself (the VRAM line). The engine's own automatic fit has nothing to adjust with
# every layer set, and it only printed "failed to fit params to free device memory ... abort". Turn it off.
[string[]]$FitArgs = if ($Help -match '--fit ') { @('--fit', 'off') } else { @() }
[string[]]$ServerArgs = @() + $SlotArgs + $TierArgs + $RamArgs + $SpecArgs + $BsArgs + $BudgetMsgArgs + $HarnessArgs + $LogArgs + $MaskArgs + $FitArgs + $MmprojArgs + @(
    '--reasoning-budget', "$ThinkBudget",
    '-n', '24576',
    '-m', $Model,
    '--chat-template-file', (Join-Path $Root 'templates\bonsai-template.jinja'),
    '-ngl', '99', '-fa', 'on', '-c', "$Ctx", '-np', '1', '-b', '2048', '-ub', "$UBatch", '-ctk', $Ctk, '-ctv', $Ctv,
    '--host', $ListenHost, '--port', "$ListenPort", '--alias', 'mirai-s-27b', '--jinja',
    '--prio', '2', '--poll', '100', '--metrics', '--api-key', $ApiKey,
    '--temp', '1.0', '--top-p', '0.95', '--top-k', '20')
# MIRAI_STDERR_FILE=path: keep the server's raw stderr (GGML_ASSERT text and CUDA errors bypass the log file). The
# server then runs under cmd.exe so the file handle has a parent for its whole life (a PowerShell redirect of a native
# command's stderr wraps every line in an error record and, with ErrorActionPreference Stop, aborts on the first one).
$StdErrFile = if ($env:MIRAI_STDERR_FILE) { if ([IO.Path]::IsPathRooted($env:MIRAI_STDERR_FILE)) { $env:MIRAI_STDERR_FILE } else { Join-Path $Root $env:MIRAI_STDERR_FILE } } else { $null }
# Supervision: an aborted server (an assert, a CUDA error) is restarted up to MIRAI_RESTARTS times (default 3) within a
# 10-minute window; a server that ran longer than that resets the count. tooling\stop.ps1 writes logs\product.stop
# before killing the server, which ends the loop instead of restarting it.
$StopFlag = Join-Path $Root 'logs\product.stop'
New-Item -ItemType Directory -Force (Join-Path $Root 'logs') | Out-Null
Remove-Item $StopFlag -ErrorAction SilentlyContinue
$MaxRestarts = if ($env:MIRAI_RESTARTS) { [int]$env:MIRAI_RESTARTS } else { 3 }
$Restarts = 0
try {
while ($true) {
    $Started = Get-Date
    if ($StdErrFile) {
        New-Item -ItemType Directory -Force (Split-Path $StdErrFile) | Out-Null
        $Quoted = $ServerArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
        $CmdLine = '"' + (Join-Path $Bin 'llama-server.exe') + '" ' + ($Quoted -join ' ') + ' 2>> "' + $StdErrFile + '"'
        Add-Content -Path $StdErrFile -Value ("=== {0:yyyy-MM-dd HH:mm:ss} start: {1}" -f $Started, ($Quoted -join ' ' -replace $ApiKey, '<key>'))
        # cmd /s /c "...": the outer quotes are stripped as a pair and everything inside is passed as written
        $Proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/s', '/c', ('"' + $CmdLine + '"')) -WorkingDirectory $Bin -NoNewWindow -Wait -PassThru
        $Code = $Proc.ExitCode
    } else {
        & .\llama-server.exe @ServerArgs
        $Code = $LASTEXITCODE
    }
    $Ran = ((Get-Date) - $Started).TotalSeconds
    if (Test-Path $StopFlag) { Remove-Item $StopFlag -ErrorAction SilentlyContinue; break }   # tooling\stop.ps1
    if ($Code -eq 0) { break }
    if ($Ran -gt 600) { $Restarts = 0 }
    $Restarts++
    $Msg = ("{0:HH:mm:ss} llama-server exited with code {1} after {2:N0} s" -f (Get-Date), $Code, $Ran)
    if ($Restarts -gt $MaxRestarts) { Write-Host "$Msg; restart limit ($MaxRestarts) reached, giving up"; break }
    Write-Host "$Msg; restarting ($Restarts of $MaxRestarts)"
    Start-Sleep -Seconds 3
}
} finally {
    if ($LayerProc -and -not $LayerProc.HasExited) { Stop-Process -Id $LayerProc.Id -Force -ErrorAction SilentlyContinue }
}
