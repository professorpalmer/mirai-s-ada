# Copy a finished build (build\bin, or $env:MIRAI_BUILD_DIR\bin) into bin\, with the CUDA runtime DLLs that
# ggml-cuda.dll loads (cuBLAS, cudart, nvJitLink, nvvm) from the pip wheels the build used. Without those DLLs next to
# llama-server.exe the server exits at once with 0xC0000135 (STATUS_DLL_NOT_FOUND). Prints the server's version.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Build = if ($env:MIRAI_BUILD_DIR) { $env:MIRAI_BUILD_DIR } else { Join-Path $Root 'build' }
$From = Join-Path $Build 'bin'
$To = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force $To | Out-Null
Get-ChildItem $From -Include *.exe, *.dll -Recurse | ForEach-Object { Copy-Item $_.FullName $To -Force }
& python (Join-Path $PSScriptRoot 'find_toolchain.py') dlls $To
if ($LASTEXITCODE -ne 0) { throw 'copying the CUDA runtime DLLs failed (see above)' }
# (no 2>&1: Windows PowerShell 5.1 wraps a native program's stderr lines in error records)
& (Join-Path $To 'llama-server.exe') --version
