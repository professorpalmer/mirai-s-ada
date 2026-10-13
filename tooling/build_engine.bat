@echo off
rem Build the engine (engine\ = llama.cpp-ada-mirai, branch main) into build\ with Ninja and the pip CUDA 13 toolkit.
rem Usage: tooling\build_engine.bat llama-server [more targets]
rem Then tooling\install_bin.ps1 copies the result and the CUDA runtime DLLs into bin\.
rem   MIRAI_CUDA_ARCH  CUDA architectures (default: native = the GPU in this machine, e.g. 86 on an RTX 3060, 89 on an
rem                    RTX 4070). A list also works, e.g. set MIRAI_CUDA_ARCH=75-real;86-real;89-real
rem   MIRAI_JOBS       parallel compile jobs (default 6; lower it when RAM runs short)
rem   MIRAI_BUILD_DIR  build folder (default build\)
rem Needs Visual Studio 2022 or its Build Tools (any edition) with the C++ workload, and the pip packages in README.md.
setlocal
set ROOT=%~dp0..
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo vswhere.exe not found: install Visual Studio 2022 or its Build Tools with the "Desktop development with C++" workload.
  exit /b 1
)
set VSDIR=
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (
  echo No Visual Studio with the C++ x64 tools found. Add the "Desktop development with C++" workload.
  exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
python "%ROOT%\tooling\find_toolchain.py" env > "%TEMP%\mirai_toolchain.bat" || exit /b 1
call "%TEMP%\mirai_toolchain.bat"
python "%ROOT%\tooling\find_toolchain.py" implibs || exit /b 1
set "CUDAToolkit_ROOT=%CUDA_PATH%"
set "PATH=%CUDA_PATH%\bin;%CUDA_PATH%\bin\x86_64;%CUDA_PATH%\nvvm\bin;%PATH%"
if not defined MIRAI_CUDA_ARCH set MIRAI_CUDA_ARCH=native
if not defined MIRAI_JOBS set MIRAI_JOBS=6
if not defined MIRAI_BUILD_DIR set "MIRAI_BUILD_DIR=%ROOT%\build"
set "SRC=%ROOT%\engine"
if not exist "%SRC%\CMakeLists.txt" (
  echo engine\ is empty: git submodule update --init
  exit /b 1
)
echo CUDA %CUDA_PATH%, architectures %MIRAI_CUDA_ARCH%, build %MIRAI_BUILD_DIR%
if not exist "%MIRAI_BUILD_DIR%\build.ninja" (
  "%CMAKE_EXE%" -S "%SRC%" -B "%MIRAI_BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_MAKE_PROGRAM=%NINJA_EXE%" -DGGML_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=%MIRAI_CUDA_ARCH%" -DGGML_CUDA_GRAPHS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TESTS=ON -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_CURL=OFF -DGGML_RPC=OFF -DGGML_BLAS=OFF -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF "-DCMAKE_CUDA_COMPILER=%CUDA_PATH%\bin\nvcc.exe" "-DCUDAToolkit_ROOT=%CUDA_PATH%"
  if errorlevel 1 exit /b 1
)
"%CMAKE_EXE%" --build "%MIRAI_BUILD_DIR%" --target %* -j %MIRAI_JOBS%
