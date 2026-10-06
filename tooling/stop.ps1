# Stop every llama-server started from this repo (bin\ or buildin, test launcher or product launcher) and clear PID
# files. Servers started from other folders (for example the Bonsai serve) are left alone.
$Root = Split-Path -Parent $PSScriptRoot
$Bin = ($Root + '').ToLower()
$n = 0
# the product launcher supervises its server (restarts it after an abort); the flag tells it this stop is intended
New-Item -ItemType Directory -Force (Join-Path $Root 'logs') | Out-Null
Set-Content -Path (Join-Path $Root 'logs\product.stop') -Value 'stop' -NoNewline
foreach ($p in (Get-Process llama-server -ErrorAction SilentlyContinue)) {
    $path = ''
    try { $path = $p.Path } catch {}
    if ($path -and -not $path.ToLower().StartsWith($Bin)) { continue }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    try { $p.WaitForExit(15000) | Out-Null } catch {}
    $n++
}
Get-ChildItem (Join-Path $Root 'logs\*.pid') -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
# the layer, if the product launcher started one
foreach ($p in (Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue)) {
    if ($p.CommandLine -and $p.CommandLine -like "*$Root\layer\bonsai_layer.py*") { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $n++ }
}
Start-Sleep -Milliseconds 500
if ($n -eq 0) { Remove-Item (Join-Path $Root 'logs\product.stop') -ErrorAction SilentlyContinue }
Write-Output "stopped $n"
