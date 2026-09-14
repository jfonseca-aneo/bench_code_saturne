#!/bin/bash
#
# Code_Saturne Build Script
#
# This script automates the build and installation of several packages required for Code_Saturne, 
# including HDF5, CGNS, MED, HYPRE, and Code_Saturne itself, using
#
# Usage:
#   ./build_script.sh STACK_CONFIG OPENMPI_PREFIX INSTALL_PREFIX [SOURCES_DIR] [TEMP_DIR]
#
# Arguments:
#
#   STACK_CONFIG    - file that will be sourced and that should define the following variables:
#                     HDF5_VER, CGNS_VER=4.5.0, MED_VER=5.0.0, HYPRE_VER=2.33.0, CODE_SATURNE_VER, ARCH_PATH
#   OPENMPI_PREFIX  - Path to the OpenMPI installation, or "auto" (see below)
#   INSTALL_PREFIX  - Target installation prefix
#   SOURCES_DIR     - Optional cache dir for downloaded source tarballs
#                     (defaults to INSTALL_PREFIX/sources; tarballs are fetched
#                     on demand, so there's normally no need to point this at
#                     a pre-populated directory)
#   TEMP_DIR        - Optional temporary build directory (defaults to /tmp if not provided)

set -ex  # Exit immediately on error

# Resolve script directory and source common functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/build_common.sh"
source "$SCRIPT_DIR/compilers-config.sh"

# Display usage help
show_help() {
    cat >&2 <<EOF

Usage: $(basename "$0") STACK_CONFIG OPENMPI_PREFIX INSTALL_PREFIX [SOURCES_DIR] [TEMP_DIR]

    STACK_CONFIG    - file that will be sourced and that should define the following variables:
                      HDF5_VER, CGNS_VER, MED_VER, HYPRE_VER, CODE_SATURNE_VER, ARCH_PATH
    OPENMPI_PREFIX  - base dir of openmpi, or "auto" (see below)
    INSTALL_PREFIX  - the installation prefix
    [SOURCES_DIR]   - cache dir for downloaded source tarballs (default:
                      INSTALL_PREFIX/sources; created and populated on demand)
    [TEMP_DIR]      - temporary directory for the build, can be e.g. /dev/shm. If not provided, one will be created in /tmp/

Requires AMD Optimizing compiler to be loaded when COMPILER=AMD
Requires AOCL_ROOT to be defined when COMPILER=AMD - AMD Optimizing CPU Libraries

Optional GPU (CUDA) build - set in STACK_CONFIG:
    CUDA_ENABLED     - "yes" to enable CUDA support (default: no)
    CUDA_ARCH_NUM    - target compute capability, e.g. 90 for H100, 80 for A100
                        (required if CUDA_ENABLED=yes)
    CUDA_PATH        - CUDA toolkit root (default: derived from 'nvcc' on PATH,
                        e.g. after 'module load nvhpc-hpcx', or after sourcing
                        /etc/profile.d/nvhpc.sh as installed by install_sem3d_nvhpc.sh)
    TPL_BLAS_LIBRARIES, TPL_LAPACK_LIBRARIES
                     - BLAS/LAPACK lib dirs used to build HYPRE (default: \$AOCL_ROOT/lib)
    CS_BLAS_ARGS     - bash array of --with-blas* configure args for Code_Saturne
                        (default: AOCL blis/flame; set to an empty array to let
                        configure auto-detect, as recommended for NVHPC builds)
    HDF5_PREBUILT_ROOT
                     - path to an already-built HDF5 install (e.g. the one
                        produced by install_sem3d_nvhpc.sh) to link CGNS/MED/
                        Code_Saturne against, skipping this script's own HDF5
                        build entirely. When set, HDF5_VER is not required.

OPENMPI_PREFIX may be "auto" instead of a path when COMPILER=NVHPC in
STACK_CONFIG: the MPI bundled with the NVIDIA HPC SDK is then located
automatically (requires nvc/nvfortran and that MPI on PATH already, e.g. by
sourcing /etc/profile.d/nvhpc.sh as installed by install_sem3d_nvhpc.sh).
EOF
}

# Parse and validate input arguments
STACK_CONFIG="$1"
if [[ "$2" == "auto" ]]; then
    OPENMPI_PREFIX="auto"
else
    OPENMPI_PREFIX="$(realpath $2)"
fi
INSTALL_PREFIX=$3
SOURCES_DIR="$4"
TEMP_DIR="$5"

is_nonempty STACK_CONFIG || (show_help; die "STACK_CONFIG undefined" )
is_nonempty INSTALL_PREFIX || (show_help; die "INSTALL_PREFIX undefined" )
is_nonempty OPENMPI_PREFIX || (show_help; die "OPENMPI_PREFIX undefined" )

# Guard against a leaked HDF5_ROOT/CMAKE_PREFIX_PATH from the calling shell
# (e.g. a previous 'source install_sem3d_nvhpc.sh', which exports HDF5_ROOT)
# silently overriding the -DHDF5_ROOT_DIR/-D*_DIR hints this script passes:
# CMake's find_package() honors <Package>_ROOT env vars automatically
# (CMP0074), with higher priority than an explicit PATHS hint.
unset HDF5_ROOT CMAKE_PREFIX_PATH

if [[ -z "$SOURCES_DIR" ]]; then
    SOURCES_DIR="$INSTALL_PREFIX/sources"
fi
mkdir -p "$SOURCES_DIR"
SOURCES_DIR="$(realpath "$SOURCES_DIR")"

# Load stack config
source "$STACK_CONFIG"

if [[ -z "${HDF5_PREBUILT_ROOT:-}" ]]; then
    is_nonempty HDF5_VER || die "Error: HDF5_VER undefined in STACK_CONFIG"
fi
is_nonempty CGNS_VER || die "Error: CGNS_VER undefined in STACK_CONFIG"
is_nonempty HYPRE_VER || die "Error: HYPRE_VER undefined in STACK_CONFIG"
is_nonempty MED_VER || die "Error: MED_VER undefined in STACK_CONFIG"
is_nonempty CODE_SATURNE_VER || die "Error: CODE_SATURNE_VER undefined in STACK_CONFIG"
is_nonempty ARCH_PATH || die "Error: ARCH_PATH undefined in STACK_CONFIG"
is_nonempty COMPILER || die "Error: COMPILER undefined in STACK_CONFIG"
is_nonempty PERFORMANCE_LIBS || die "Error: PERFORMANCE_LIBS undefined in STACK_CONFIG"

if [[ -z "${HDF5_PREBUILT_ROOT:-}" ]]; then
    readonly HDF5_VER_S=${HDF5_VER%.*}
fi
readonly CGNS_VER_S=${CGNS_VER%.*}
readonly CODE_SATURNE_VER_S=$(extract_short_version $CODE_SATURNE_VER)
readonly HYPRE_VER_S=${HYPRE_VER%.*}
readonly MED_VER_S=${MED_VER%.*}

# --- Optional GPU (CUDA) support ---------------------------------------------
CUDA_ENABLED="${CUDA_ENABLED:-no}"
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    is_nonempty CUDA_ARCH_NUM || die "Error: CUDA_ARCH_NUM undefined in STACK_CONFIG (required when CUDA_ENABLED=yes)"
    if [[ -z "$CUDA_PATH" ]]; then
        command -v nvcc >/dev/null 2>&1 || die "Error: CUDA_ENABLED=yes but nvcc not found on PATH (load the NVIDIA HPC SDK module first, or set CUDA_PATH)"
        CUDA_PATH="$(dirname "$(dirname "$(command -v nvcc)")")"
    fi

    # NVHPC splits nvcc (under $CUDA_PATH/bin) from the actual CUDA runtime
    # headers/libs (driver_types.h, cuda_runtime_api.h, libcudart, ...),
    # which live under a separate cuda/<ver>/targets/<arch>/{include,lib}
    # tree. cublas_api.h (and CUDA-aware Code_Saturne sources later) need
    # both on the include path, or compiles fail with e.g. "cannot open
    # source file driver_types.h" even with cuBLAS's own include dir set.
    NVHPC_HOME_FOR_CUDA_TOOLKIT="$(dirname "$CUDA_PATH")"
    DRIVER_TYPES_H="$(find "$NVHPC_HOME_FOR_CUDA_TOOLKIT/cuda" -name 'driver_types.h' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$DRIVER_TYPES_H" ]] || die "Error: could not locate driver_types.h under $NVHPC_HOME_FOR_CUDA_TOOLKIT/cuda"
    CUDA_TOOLKIT_INCLUDE_DIR="$(dirname "$DRIVER_TYPES_H")"
    CUDA_TOOLKIT_LIB_DIR="$(dirname "$CUDA_TOOLKIT_INCLUDE_DIR")/lib"
fi

# BLAS/LAPACK used to build HYPRE (kept as separate TPL_* libs since HYPRE's
# own BLAS/LAPACK are disabled below). Defaults to AOCL for backward
# compatibility; override in STACK_CONFIG for non-AMD (e.g. NVHPC) builds.
if [[ -z "$TPL_BLAS_LIBRARIES" && -n "$AOCL_ROOT" ]]; then
    TPL_BLAS_LIBRARIES="${AOCL_ROOT}/lib"
fi
if [[ -z "$TPL_LAPACK_LIBRARIES" && -n "$AOCL_ROOT" ]]; then
    TPL_LAPACK_LIBRARIES="${AOCL_ROOT}/lib"
fi
is_nonempty TPL_BLAS_LIBRARIES || die "Error: TPL_BLAS_LIBRARIES undefined (set AOCL_ROOT, or define TPL_BLAS_LIBRARIES in STACK_CONFIG)"
is_nonempty TPL_LAPACK_LIBRARIES || die "Error: TPL_LAPACK_LIBRARIES undefined (set AOCL_ROOT, or define TPL_LAPACK_LIBRARIES in STACK_CONFIG)"

# --with-blas* args for Code_Saturne's configure. Defaults to AOCL blis/flame
# for backward compatibility; override (e.g. to an empty array) in STACK_CONFIG.
if [[ -z "${CS_BLAS_ARGS+x}" ]]; then
    CS_BLAS_ARGS=(--with-blas --with-blas-type=BLAS --with-blas-libs="-lblis -lflame")
fi

if [[ -z "${TEMP_DIR}" ]]; then
  TEMP_DIR="$(mktemp -d -t build-ompi-XXXXXX)"
else
  TEMP_DIR="$(readlink -f -- "${TEMP_DIR}")" || true
  mkdir -p -- "${TEMP_DIR}"
fi

# Switch to AMD compiler for HYPRE and Code_Saturne, optimize for Epyc 4 processors
set_compiler "$COMPILER" "$PERFORMANCE_LIBS" "$OPENMPI_PREFIX" #"CFLAGS=-march=znver4"

if [[ "$CUDA_ENABLED" == "yes" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${CUDA_PATH}/include -I${CUDA_TOOLKIT_INCLUDE_DIR}"
    export LDFLAGS="${LDFLAGS:-} -L${CUDA_PATH}/lib64 -L${CUDA_TOOLKIT_LIB_DIR}"
fi

# Fetch upstream release tarballs on demand into SOURCES_DIR instead of
# shipping them alongside the scripts. Re-run-safe: skipped if already cached.
if [[ -z "${HDF5_PREBUILT_ROOT:-}" ]]; then
    ensure_source_tarball "$SOURCES_DIR" "hdf5-${HDF5_VER}.tar.gz" \
        "https://github.com/HDFGroup/hdf5/archive/refs/tags/hdf5-${HDF5_VER//./_}.tar.gz"
fi
ensure_source_tarball "$SOURCES_DIR" "CGNS-${CGNS_VER}.tar.gz" \
    "https://github.com/CGNS/CGNS/archive/refs/tags/v${CGNS_VER}.tar.gz"
ensure_source_tarball "$SOURCES_DIR" "med-${MED_VER}.tar.bz2" \
    "https://files.salome-platform.org/Salome/medfile/med-${MED_VER}.tar.bz2"
ensure_source_tarball "$SOURCES_DIR" "hypre-${HYPRE_VER}.tar.gz" \
    "https://github.com/hypre-space/hypre/archive/refs/tags/v${HYPRE_VER}.tar.gz"

# Install HDF5, or reuse an already-built one (e.g. from install_sem3d_nvhpc.sh)
if [[ -n "${HDF5_PREBUILT_ROOT:-}" ]]; then
    [[ -d "$HDF5_PREBUILT_ROOT" ]] || die "Error: HDF5_PREBUILT_ROOT=$HDF5_PREBUILT_ROOT does not exist"
    HDF5_INSTALL_PATH="$(realpath "$HDF5_PREBUILT_ROOT")"
    log "Reusing prebuilt HDF5 at $HDF5_INSTALL_PATH (skipping HDF5 build)"
else
    HDF5_INSTALL_PATH="$INSTALL_PREFIX/opt/hdf5-$HDF5_VER_S/arch/$ARCH_PATH"
    install_mpi_cmake_package "$SOURCES_DIR" hdf5 $HDF5_VER none "$HDF5_INSTALL_PATH" \
        -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -DHDF5_BUILD_FORTRAN=ON -DHDF5_ENABLE_PARALLEL=ON
fi

# HDF5_ROOT (the CMake-standard <PackageName>_ROOT variable, CMP0074) is
# honored automatically, at the HIGHEST priority, by every find_package(HDF5
# ...) call -- including MED's own two internal ones and CGNS's plain one --
# regardless of any PATHS hint they pass themselves. Without it, a
# find_package(HDF5) whose own hints don't resolve (e.g. MED's, which
# hardcodes an outdated "share/cmake/hdf5" config layout) silently falls
# through to CMake's built-in system path list, which includes bare "/opt"
# and glob-matches ANY unrelated "/opt/hdf5*" install found there (e.g. the
# SEM3D one from install_sem3d_nvhpc.sh) instead of failing loudly.

# Install CGNS
install_mpi_cmake_package "$SOURCES_DIR" CGNS $CGNS_VER none "$INSTALL_PREFIX/opt/cgns-$CGNS_VER_S/arch/$ARCH_PATH" \
    -DHDF5_ROOT="$HDF5_INSTALL_PATH"

# Install MED
install_mpi_cmake_package "$SOURCES_DIR" med $MED_VER none "$INSTALL_PREFIX/opt/med-$MED_VER_S/arch/$ARCH_PATH" \
    -DHDF5_ROOT="$HDF5_INSTALL_PATH" -DHDF5_ROOT_DIR="$HDF5_INSTALL_PATH"


# HYPRE 2.33.0 predates CUDA 13 / CCCL 3.0 in a couple of spots. Upstream has
# since fixed both on its default branch, but no tagged release with either
# fix exists yet, so backport them here:
#
#  1. cudaMemPrefetchAsync() called with the pre-CUDA-13 signature (a plain
#     int device id); CUDA 13's headers require a cudaMemLocation struct
#     instead (utilities/memory.c).
#  2. The classic "adaptable function object" library (identity,
#     unary_function, binary_function, not1, not2), removed wholesale in
#     CCCL 3.0 (bundled with CUDA 13) the way C++17/20 removed the
#     equivalent std:: names it mirrored. HYPRE's device code uses these
#     unconditionally in dozens of places across the codebase. Rather than
#     react file by file as each one surfaces (fragile, and every call site
#     has slightly different syntax: direct predicate argument, named
#     variable, wrapped in not1/HYPRE_THRUST_NOT, base-class inheritance
#     with template args that can themselves contain nested <...>/commas),
#     define the whole removed family back, verbatim, directly into
#     namespace thrust -- so no call site needs touching at all, now or if
#     more turn up later. Prepended to every file found to reference any of
#     these names, discovered dynamically rather than hardcoded.
patch_hypre_cuda13_compat() {
    python3 - <<'PYEOF'
import os
import sys

def patch_file(path, replacements):
    with open(path) as f:
        content = f.read()
    for old, new, label in replacements:
        n = content.count(old)
        if n != 1:
            sys.exit(f"hypre CUDA-13 compat patch: '{label}' pattern found {n} times "
                      f"in {path}, expected 1 -- HYPRE source may have changed, adjust the patch")
        content = content.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(content)
    print(f"Patched {path} for CUDA >= 13.0 / CCCL 3.0")

# 1. cudaMemPrefetchAsync()
old_device = """      HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, hypre_HandleDevice(hypre_handle()),
                                            hypre_HandleComputeStream(hypre_handle())) );"""
new_device = """#if CUDART_VERSION >= 13000
      { cudaMemLocation hypre__loc = {cudaMemLocationTypeDevice, hypre_HandleDevice(hypre_handle())};
        HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, hypre__loc, 0,
                                            hypre_HandleComputeStream(hypre_handle())) ); }
#else
      HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, hypre_HandleDevice(hypre_handle()),
                                            hypre_HandleComputeStream(hypre_handle())) );
#endif"""

old_host = """      HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, cudaCpuDeviceId,
                                            hypre_HandleComputeStream(hypre_handle())) );"""
new_host = """#if CUDART_VERSION >= 13000
      { cudaMemLocation hypre__loc = {cudaMemLocationTypeHost, cudaCpuDeviceId};
        HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, hypre__loc, 0,
                                            hypre_HandleComputeStream(hypre_handle())) ); }
#else
      HYPRE_CUDA_CALL( cudaMemPrefetchAsync(ptr, size, cudaCpuDeviceId,
                                            hypre_HandleComputeStream(hypre_handle())) );
#endif"""

patch_file("utilities/memory.c", [
    (old_device, new_device, "device prefetch"),
    (old_host, new_host, "host prefetch"),
])

# 2. Restore the whole removed family, verbatim, into namespace thrust.
classic_adaptors_shim = """#ifndef HYPRE_CUDA13_THRUST_CLASSIC_ADAPTORS_SHIM
#define HYPRE_CUDA13_THRUST_CLASSIC_ADAPTORS_SHIM
// Restore thrust::{identity,unary_function,binary_function,not1,not2},
// removed wholesale in CCCL 3.0 / CUDA 13.
namespace thrust {

template <typename Arg, typename Result>
struct unary_function
{
   typedef Arg argument_type;
   typedef Result result_type;
};

template <typename Arg1, typename Arg2, typename Result>
struct binary_function
{
   typedef Arg1 first_argument_type;
   typedef Arg2 second_argument_type;
   typedef Result result_type;
};

template <typename T>
struct identity : public unary_function<T, T>
{
   __host__ __device__ T operator()(const T &x) const { return x; }
};

template <typename Predicate>
class unary_negate : public unary_function<typename Predicate::argument_type, bool>
{
public:
   __host__ __device__ explicit unary_negate(Predicate p) : pred(p) {}
   __host__ __device__ bool operator()(const typename Predicate::argument_type &x) const { return !pred(x); }
private:
   Predicate pred;
};

template <typename Predicate>
__host__ __device__ inline unary_negate<Predicate> not1(const Predicate &pred)
{
   return unary_negate<Predicate>(pred);
}

template <typename Predicate>
class binary_negate : public binary_function<typename Predicate::first_argument_type,
                                              typename Predicate::second_argument_type, bool>
{
public:
   __host__ __device__ explicit binary_negate(Predicate p) : pred(p) {}
   __host__ __device__ bool operator()(const typename Predicate::first_argument_type &x,
                                        const typename Predicate::second_argument_type &y) const
   {
      return !pred(x, y);
   }
private:
   Predicate pred;
};

template <typename Predicate>
__host__ __device__ inline binary_negate<Predicate> not2(const Predicate &pred)
{
   return binary_negate<Predicate>(pred);
}

} // namespace thrust
#endif
"""

classic_adaptor_names = (
    "thrust::identity", "thrust::unary_function", "thrust::binary_function",
    "thrust::not1", "thrust::not2",
)

patched = []
for root, _dirs, files in os.walk("."):
    for name in files:
        if not name.endswith((".c", ".cpp", ".cu", ".h", ".hpp")):
            continue
        path = os.path.join(root, name)
        with open(path) as f:
            content = f.read()
        if not any(sym in content for sym in classic_adaptor_names):
            continue
        content = classic_adaptors_shim + content
        with open(path, "w") as f:
            f.write(content)
        patched.append(path)

if not patched:
    sys.exit("hypre CUDA-13 compat patch: no file uses any removed thrust classic-adaptor symbol -- "
              "HYPRE source may have changed, this patch may no longer be needed")
print(f"Patched {len(patched)} file(s) for removed thrust classic function adaptors: "
      f"{', '.join(sorted(patched))}")
PYEOF
}

# Prepare HYPRE source
prepare_hypre_source() {
    local source_dir="$1"
    local package_name="$2"
    local version="$3"
    local tarball
    tarball=$(ls "$source_dir/${package_name}-${version}"*)
    extract_tarball "$tarball"
    pushd "${package_name}-${version}/src" || die "Error: Directory ${package_name}-${version}/src not found"
    if [[ "$CUDA_ENABLED" == "yes" ]]; then
        patch_hypre_cuda13_compat
    fi
}

# Install HYPRE
HYPRE_CUDA_ARGS=()
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    # Don't pass -DCMAKE_CUDA_COMPILER here: a bare "nvcc" (no path) set via
    # -D wins over (and breaks) the correctly-resolved absolute path that
    # HYPRE_SetupCUDAToolkit.cmake computes itself from CUDA_PATH below
    # (cache variables set via -D take priority over a project's own
    # non-FORCE set(... CACHE ...) call).
    HYPRE_CUDA_ARGS=(
        -DHYPRE_ENABLE_CUDA=ON
        -DHYPRE_CUDA_SM="$CUDA_ARCH_NUM"
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH_NUM"
        -DCUDA_PATH="$CUDA_PATH"
    )

    # HYPRE 2.33.0's Thrust detection only looks directly under the CUDA
    # Toolkit's include dir (or an adjacent "cuda-thrust" dir), but CUDA 12+
    # ships Thrust/CUB nested under a "cccl" subdirectory instead -- so on
    # newer toolkits (e.g. CUDA 13.x bundled with recent NVHPC releases)
    # that search comes up empty and HYPRE's configure fails outright.
    # Locate it ourselves and pre-set the cache variable so HYPRE's own
    # (broken, for this toolkit) find_path is skipped.
    NVHPC_HOME_FOR_THRUST="$(dirname "$CUDA_PATH")"
    THRUST_VERSION_H="$(find "$NVHPC_HOME_FOR_THRUST/cuda" -path '*/cccl/thrust/version.h' 2>/dev/null | head -1)"
    if [[ -n "$THRUST_VERSION_H" ]]; then
        HYPRE_CUDA_ARGS+=(-DTHRUST_INCLUDE_DIR="$(dirname "$(dirname "$THRUST_VERSION_H")")")
    fi

    # HYPRE only bumps CMAKE_CXX_STANDARD (and, derived from it,
    # CMAKE_CUDA_STANDARD) up to a *minimum* of 14 for CUDA builds
    # (HYPRE_SetupGPUToolkit.cmake), but the CCCL/Thrust bundled with CUDA
    # 12+ hard-requires C++17. Force it explicitly.
    HYPRE_CUDA_ARGS+=(-DCMAKE_CXX_STANDARD=17)
fi

install_mpi_cmake_package "$SOURCES_DIR" hypre $HYPRE_VER prepare_hypre_source "$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH" \
    -DHYPRE_ENABLE_HYPRE_LAPACK=OFF -DHYPRE_ENABLE_HYPRE_BLAS=OFF \
    -DTPL_LAPACK_LIBRARIES="$TPL_LAPACK_LIBRARIES" -DTPL_BLAS_LIBRARIES="$TPL_BLAS_LIBRARIES" \
    "${HYPRE_CUDA_ARGS[@]}"

# Prepare Code_Saturne source
prepare_cs_source() {
    prepare_package_source $1 none $2 $3
    if [ ! -f "configure" ]; then
        ./sbin/bootstrap
    fi

    # Patch Fortran files to avoid syntax issues
    find . -type f -name "*.f90" -exec sed -i 's/\s*procedure\s*()\s*::/!procedure() :: /g' {} \;
}

# Install Code_Saturne
CS_CUDA_ARGS=()
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    # cs_cuda.m4's --with-cublas/--with-cusparse=PATH assumes a flat
    # PATH/include + PATH/lib64 layout, but NVHPC splits nvcc (under
    # $CUDA_PATH/bin) from the actual cuBLAS/cuSPARSE headers+libs, which
    # live under a separate math_libs/<ver>/targets/<arch>/{include,lib}
    # tree (note: "lib", not "lib64"). Locate it and use the more specific
    # --with-*-include/--with-*-lib flags instead of --with-cublas=PATH.
    NVHPC_HOME_FOR_MATHLIBS="$(dirname "$CUDA_PATH")"
    CUBLAS_HEADER="$(find "$NVHPC_HOME_FOR_MATHLIBS/math_libs" -name 'cublas_v2.h' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$CUBLAS_HEADER" ]] || die "Error: could not locate cublas_v2.h under $NVHPC_HOME_FOR_MATHLIBS/math_libs"
    CUBLAS_INCLUDE_DIR="$(dirname "$CUBLAS_HEADER")"
    CUBLAS_LIB_DIR="$(dirname "$CUBLAS_INCLUDE_DIR")/lib"

    CS_CUDA_ARGS=(
        --enable-cuda
        --with-cublas-include="$CUBLAS_INCLUDE_DIR"
        --with-cublas-lib="$CUBLAS_LIB_DIR"
        --with-cusparse-include="$CUBLAS_INCLUDE_DIR"
        --with-cusparse-lib="$CUBLAS_LIB_DIR"
        "CUDA_ARCH_NUM=$CUDA_ARCH_NUM"
    )
fi

install_auto_package "$SOURCES_DIR" code_saturne $CODE_SATURNE_VER prepare_cs_source "$INSTALL_PREFIX/code_saturne/$CODE_SATURNE_VER_S/arch/$ARCH_PATH" \
    --disable-gui \
    --with-mpi="$OPENMPI_PREFIX" \
    "${CS_BLAS_ARGS[@]}" \
    --with-hdf5="$HDF5_INSTALL_PATH" \
    --without-metis --without-scotch \
    --with-med="$INSTALL_PREFIX/opt/med-$MED_VER_S/arch/$ARCH_PATH" \
    --with-cgns="$INSTALL_PREFIX/opt/cgns-$CGNS_VER_S/arch/$ARCH_PATH" \
    --with-hypre="$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH" \
    --with-hypre-lib="$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH/lib64" \
    "${CS_CUDA_ARGS[@]}"
