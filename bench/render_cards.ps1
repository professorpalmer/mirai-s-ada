# Render the result cards (docs/cards/*.html, 1200x675 CSS pixels) to 2400x1350 PNGs with headless Edge/Chrome.
# Each card keeps its numbers in one DATA object at the top of its HTML: edit DATA, then run this script.
# Usage: bench\render_cards.ps1            (every card)
#        bench\render_cards.ps1 decode     (only the cards whose name matches)
param([string]$Only = '')
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Cards = Join-Path $Root 'docs\cards'
$Browser = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Browser) { throw 'Edge or Chrome is needed for headless rendering' }
# card source, output PNG (repo-relative)
$Jobs = @(
    @('scorecard', 'docs\img\scorecard.png'),
    @('decode',    'docs\speed\img\decode.png'),
    @('prefill',   'docs\speed\img\prefill.png'),
    @('quality',   'docs\quality\img\quality.png'),
    @('agentic',   'docs\agents-layer\img\agentic.png'),
    @('saved',     'docs\agents-layer\img\saved.png')
)
$ErrorActionPreference = 'Continue'   # the browser reports "bytes written" on stderr
$Profile = Join-Path $env:TEMP 'mirai-render-cards'
foreach ($j in $Jobs) {
    if ($Only -and $j[0] -notmatch $Only) { continue }
    $html = Join-Path $Cards "$($j[0]).html"
    $png = Join-Path $Root $j[1]
    New-Item -ItemType Directory -Force (Split-Path $png) | Out-Null
    & $Browser --headless=new --hide-scrollbars --force-device-scale-factor=2 --window-size=1200,675 --virtual-time-budget=6000 `
        --allow-file-access-from-files "--user-data-dir=$Profile" "--screenshot=$png" `
        ("file:///" + ($html -replace '\\', '/')) 2>$null | Out-Null
    Write-Host ("{0,-34} {1,6:N0} KB" -f $j[1], ((Get-Item $png).Length / 1KB))
}
