"""Find the build toolchain that the pip packages installed for this Python, for build_engine.bat and install_bin.ps1.

  python tooling\\find_toolchain.py env          'set NAME=VALUE' lines: CUDA_PATH (nvidia\\cu13), CMAKE_EXE, NINJA_EXE
  python tooling\\find_toolchain.py implibs      make lib\\x64\\cublas.lib and cublasLt.lib from the DLLs when the
                                                cuBLAS wheel ships none (CUDA 13 wheels); needs dumpbin and lib on PATH,
                                                so run it after vcvars64.bat
  python tooling\\find_toolchain.py dlls <dir>   copy the CUDA runtime DLLs that ggml-cuda.dll loads into <dir>

Works with python.org and Microsoft Store Python, and with user (--user) or system pip installs.
"""
import glob
import os
import re
import shutil
import subprocess
import sys

PIP_LINE = ("python -m pip install cmake ninja nvidia-cuda-nvcc nvidia-cuda-runtime nvidia-cublas "
            "nvidia-cuda-nvrtc nvidia-cuda-cccl")


def die(msg):
    sys.stderr.write("find_toolchain: " + msg + "\n")
    sys.exit(1)


def cuda_path():
    try:
        import nvidia
    except ImportError:
        die("no NVIDIA pip packages for this Python (" + sys.executable + "). Install them with:\n  " + PIP_LINE)
    for base in list(nvidia.__path__):
        c = os.path.join(base, "cu13")
        if os.path.isfile(os.path.join(c, "bin", "nvcc.exe")):
            if not os.path.isdir(os.path.join(c, "include", "cccl")):
                die("the CUDA headers lack CUB/Thrust (include\\cccl): python -m pip install nvidia-cuda-cccl")
            return c
    die("nvcc.exe not found under any nvidia\\cu13 of this Python. Install the toolkit wheels with:\n  " + PIP_LINE)


def cmake_exe():
    try:
        import cmake
    except ImportError:
        die("cmake is not installed for this Python: python -m pip install cmake")
    exe = os.path.join(cmake.CMAKE_BIN_DIR, "cmake.exe")
    if not os.path.isfile(exe):
        die("cmake.exe not found in " + cmake.CMAKE_BIN_DIR)
    return exe


def ninja_exe():
    try:
        import ninja
    except ImportError:
        die("ninja is not installed for this Python: python -m pip install ninja")
    exe = os.path.join(ninja.BIN_DIR, "ninja.exe")
    if not os.path.isfile(exe):
        die("ninja.exe not found in " + ninja.BIN_DIR)
    return exe


def find_dll(cuda, pattern):
    for sub in (os.path.join("bin", "x86_64"), "bin", os.path.join("nvvm", "bin")):
        hits = sorted(glob.glob(os.path.join(cuda, sub, pattern)))
        if hits:
            return hits[-1]
    return None


def implibs(out_dir=None):
    cuda = cuda_path()
    out_dir = out_dir or os.path.join(cuda, "lib", "x64")
    os.makedirs(out_dir, exist_ok=True)
    for dll_glob, lib_name in (("cublas64_*.dll", "cublas.lib"), ("cublasLt64_*.dll", "cublasLt.lib")):
        target = os.path.join(out_dir, lib_name)
        if os.path.isfile(target):
            continue
        dll = find_dll(cuda, dll_glob)
        if not dll:
            die("no " + dll_glob + " in the cuBLAS wheel: python -m pip install nvidia-cublas")
        try:
            out = subprocess.run(["dumpbin", "/exports", dll], capture_output=True, text=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError) as e:
            die("dumpbin failed (" + str(e) + "); run this after vcvars64.bat")
        # export table rows: ordinal hint RVA name
        names = re.findall(r"^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)", out, re.M)
        if not names:
            die("no exports read from " + dll)
        def_path = os.path.splitext(target)[0] + ".def"
        with open(def_path, "w") as f:
            f.write("LIBRARY " + os.path.basename(dll) + "\nEXPORTS\n" + "".join("    " + n + "\n" for n in names))
        subprocess.run(["lib", "/nologo", "/def:" + def_path, "/out:" + target, "/machine:x64"], check=True)
        print("made " + target + " (" + str(len(names)) + " exports of " + os.path.basename(dll) + ")")


def copy_dlls(dest):
    cuda = cuda_path()
    os.makedirs(dest, exist_ok=True)
    for pattern in ("cublas64_*.dll", "cublasLt64_*.dll", "cudart64_*.dll", "nvJitLink_*.dll", "nvvm64_*.dll"):
        dll = find_dll(cuda, pattern)
        if not dll:
            die("no " + pattern + " in the CUDA wheels. Install them with:\n  " + PIP_LINE)
        shutil.copy2(dll, dest)
        print("copied " + os.path.basename(dll))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "env":
        print("set CUDA_PATH=" + cuda_path())
        print("set CMAKE_EXE=" + cmake_exe())
        print("set NINJA_EXE=" + ninja_exe())
    elif cmd == "implibs":
        implibs(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "dlls" and len(sys.argv) > 2:
        copy_dlls(sys.argv[2])
    else:
        die(__doc__)


if __name__ == "__main__":
    main()
