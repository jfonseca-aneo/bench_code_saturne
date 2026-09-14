#!/bin/bash
#
# Compiler Environment Setup Script
#
# This script sets up environment variables for various compiler toolchains and performance libraries.
# Supported compiler toolchains:
#   - GCC: GNU Compiler Collection
#   - AMD: AMD Optimizing Compiler (AOCL), generic x86_64 architecture
#   - AMDZEN: AMD Optimizing Compiler (AOCL), Zen4 architecture
#   - INTEL: Intel OneAPI Compiler with MKL
#   - INTELTELEMAC: Intel OneAPI Compiler with MKL for OpenTelemac builds
#   - NVHPC: NVIDIA HPC SDK (nvc/nvc++/nvfortran), for CUDA-enabled (GPU) builds
#
# Usage:
#   Call `set_compiler <COMPILER> <LIB_FLAVOR> <MPI_PATH>` to configure the environment.
#   Example: `set_compiler GCC System /opt/mpi` will set up GCC with system BLAS/LAPACK and MPI.

#------------------------------------------------------------------------------
# Constants defining variable modification policies
#------------------------------------------------------------------------------
readonly APPEND_VARS=("CFLAGS" "CXXFLAGS" "FFLAGS" "LDFLAGS")
readonly SUBSTITUTE_VARS=("CC" "CXX" "FC" "MPI_ROOT_DIR" "PATH")

#------------------------------------------------------------------------------
# Function: modify_vars_by_policy
# Description:
#   Modifies environment variables based on predefined policies.
#   - Appends values to variables in APPEND_VARS.
#   - Substitutes values for variables in SUBSTITUTE_VARS.
#   - Skips and warns for unknown variables.
# Usage:
#   modify_vars_by_policy VAR1="value1" VAR2="value2" ...
#------------------------------------------------------------------------------
modify_vars_by_policy() {
    for arg in "$@"; do
        if [[ "$arg" != *=* ]]; then
            die "Error: Argument '$arg' is not in VAR=VALUE format."
        fi

        echo ARG \"$arg\"

        var_name="${arg%%=*}"
        value="${arg#*=}"

        if [[ -z "$var_name" ]]; then
            die "Error: Empty variable name in argument '$arg'."
        fi

        if [[ " ${APPEND_VARS[*]} " == *" $var_name "* ]]; then
            current_value="${!var_name}"
            eval "$var_name=\"${current_value} ${value}\""
            export "$var_name"
        elif [[ " ${SUBSTITUTE_VARS[*]} " == *" $var_name "* ]]; then
            eval "$var_name=\"$value\""
            export "$var_name"
        else
            warn "'$var_name' not in any policy list. Skipping."
        fi
    done
}

#------------------------------------------------------------------------------
# Function: is_nonempty
# Description:
#   Checks if a variable is defined and non-empty.
# Usage:
#   if is_nonempty VAR_NAME; then ...
# Returns:
#   0 if defined and non-empty, 1 otherwise.
#------------------------------------------------------------------------------
is_nonempty() {
    local var_name="$1"

    if [[ -z "$var_name" ]]; then
        echo "Error: No variable name provided" >&2
        return 2
    fi

    if [[ ${!var_name+x} && -n ${!var_name} ]]; then
        return 0
    else
        return 1
    fi
}

#------------------------------------------------------------------------------
# Function: compiler_GCC
# Description:
#   Sets environment variables for GCC toolchain.
#------------------------------------------------------------------------------
function compiler_GCC {
    export CC="gcc"
    export CXX="g++"
    export FC="gfortran"
    export F77="$FC"
    export F90="$FC"
    export CFLAGS="-O3 -fPIC -fopenmp"
    export CXXFLAGS="-O3 -fPIC -fopenmp"
    export FFLAGS="-O3 -fPIC -fopenmp"

    modify_vars_by_policy "$@"
}

#------------------------------------------------------------------------------
# Function: compiler_AMD
# Description:
#   Sets environment variables for AMD toolchain with AOCL.
#------------------------------------------------------------------------------
function compiler_AMD {
    if ! CC=$(which clang); then
        die "Error: compiler option AMD, no clang in PATH, is it loaded?"
    fi
    export CC

    if ! CXX=$(which clang++); then
        die "Error: compiler option AMD, no clang++ in PATH, is it loaded?"
    fi
    export CXX

    if ! FC=$(which flang); then
        die "Error: compiler option AMD, no flang in PATH, is it loaded?"
    fi
    export FC
    export F77="$FC"
    export F90="$FC"

    export CFLAGS="-O3 -fopenmp -fPIC -Wno-non-literal-null-conversion -Wno-incompatible-function-pointer-types -Wno-int-conversion"
    export CXXFLAGS="$CFLAGS"
    export FFLAGS="$CFLAGS -std=f2008" #-std=fasd003"

    modify_vars_by_policy "$@"
}

#------------------------------------------------------------------------------
# Function: compiler_Intel
# Description:
#   Sets environment variables for Intel OneAPI compiler with MKL.
#------------------------------------------------------------------------------
function compiler_Intel {
    if ! CC=$(which icx); then
        die "Error: compiler option Intel, no icx in PATH, is it loaded?"
    fi
    export CC

    if ! CXX=$(which icpx); then
        die "Error: compiler option Intel, no icpx in PATH, is it loaded?"
    fi
    export CXX

    if ! FC=$(which ifx); then
        die "Error: compiler option Intel, no ifx in PATH, is it loaded?"
    fi
    export FC

    export F77="$FC"
    export F90="$FC"
    export CFLAGS="-O3 -qopenmp -fPIC"
    export CXXFLAGS="$CFLAGS"
    export FCFLAGS="$CFLAGS"

    modify_vars_by_policy "$@"
}

#------------------------------------------------------------------------------
# Function: compiler_NVHPC
# Description:
#   Sets environment variables for the NVIDIA HPC SDK toolchain (nvc/nvc++/
#   nvfortran), used for CUDA-enabled builds (e.g. HYPRE and Code_Saturne on
#   NVIDIA GPUs). Load the nvhpc module (e.g. nvhpc-hpcx) before using this.
#------------------------------------------------------------------------------
function compiler_NVHPC {
    if ! CC=$(which nvc); then
        die "Error: compiler option NVHPC, no nvc in PATH, is it loaded?"
    fi
    export CC

    if ! CXX=$(which nvc++); then
        die "Error: compiler option NVHPC, no nvc++ in PATH, is it loaded?"
    fi
    export CXX

    if ! FC=$(which nvfortran); then
        die "Error: compiler option NVHPC, no nvfortran in PATH, is it loaded?"
    fi
    export FC
    export F77="$FC"
    export F90="$FC"

    export CFLAGS="-O3 -fPIC -mp"
    export CXXFLAGS="$CFLAGS"
    export FFLAGS="$CFLAGS"

    modify_vars_by_policy "$@"
}

#------------------------------------------------------------------------------
# Function: detect_nvhpc_mpi_prefix
# Description:
#   Locates the MPI installation bundled with the NVIDIA HPC SDK (comm_libs),
#   the same way install_sem3d_nvhpc.sh does: find nvc on PATH to get
#   NVHPC_HOME, then search comm_libs for mpicc. Requires nvc/nvfortran and
#   the bundled MPI to already be on PATH/LD_LIBRARY_PATH (e.g. by sourcing
#   /etc/profile.d/nvhpc.sh, as installed by install_sem3d_nvhpc.sh).
# Returns:
#   Prints the MPI prefix (dir containing bin/lib/include) to stdout.
#------------------------------------------------------------------------------
detect_nvhpc_mpi_prefix() {
    local nvc_bin nvhpc_home mpicc_path
    nvc_bin="$(command -v nvc)" || die "Error: mpipath=auto requires 'nvc' on PATH (source /etc/profile.d/nvhpc.sh, or load the nvhpc module, first)"
    # nvc lives at <NVHPC_HOME>/compilers/bin/nvc
    nvhpc_home="$(cd "$(dirname "$nvc_bin")/../.." && pwd)"
    mpicc_path="$(find "$nvhpc_home/comm_libs" -type f -name mpicc 2>/dev/null | sort -V | tail -1)"
    is_nonempty mpicc_path || die "Error: could not locate mpicc under $nvhpc_home/comm_libs"
    dirname "$(dirname "$mpicc_path")"
}

#------------------------------------------------------------------------------
# Function: set_compiler
# Description:
#   Main entry point to configure compiler and performance libraries.
# Arguments:
#   $1 - Compiler prefix (e.g., GCC, AMD, INTEL)
#   $2 - Performance library flavor (AOCL, MKL, System)
#   $3 - MPI installation path, or "auto" to auto-detect the MPI bundled
#        with the NVIDIA HPC SDK (only valid when $1 is NVHPC), or empty
#        if not used
#   $@ - Additional environment overrides in VAR=VALUE format
#------------------------------------------------------------------------------
set_compiler() {
    local compiler="$1"
    local lib_flavor="$2"
    local mpipath="$3"

    if [[ "$mpipath" == "auto" ]]; then
        [[ "$compiler" == "NVHPC" ]] || die "Error: mpipath=auto is only supported with COMPILER=NVHPC"
        mpipath="$(detect_nvhpc_mpi_prefix)"
        log "Auto-detected NVHPC MPI prefix: $mpipath"
    fi

    # NVHPC's bundled HPC-X MPI (UCX/HCOLL/SHARP-based) doesn't have the flat
    # lib/include layout a self-built OpenMPI stack does, so the manual
    # -I/-L/-lmpi flags built below for that case would guess the wrong
    # paths. Use the mpicc/mpifort wrappers themselves as CC/FC instead --
    # they already embed the right flags -- the same approach
    # install_sem3d_nvhpc.sh uses.
    local nvhpc_mpi_cc_override=()
    if [[ "$compiler" == "NVHPC" && -n "$mpipath" ]]; then
        [[ -x "$mpipath/bin/mpicc" ]] || die "Error: no mpicc under $mpipath/bin"
        [[ -x "$mpipath/bin/mpifort" ]] || die "Error: no mpifort under $mpipath/bin"
        nvhpc_mpi_cc_override=("CC=$mpipath/bin/mpicc" "FC=$mpipath/bin/mpifort")
        if [[ -x "$mpipath/bin/mpicxx" ]]; then
            nvhpc_mpi_cc_override+=("CXX=$mpipath/bin/mpicxx")
        fi
    fi

    # Setup MPI environment
    local mpi_loaded="no"
    if [[ -n "$mpipath" ]]; then
        for file in $mpipath/etc/modulefiles/ompi*; do
            if [ -e "$file" ]; then
                module load "$file"
                mpi_loaded=yes
            fi
        done
        if [[ $mpi_loaded == "no" ]]; then
            export MPI_HOME=$mpipath
        fi

        if [[ "$compiler" != "NVHPC" ]]; then
            CFLAGS="-I${MPI_HOME}/include"
            CXXFLAGS="-I${MPI_HOME}/include"
            FFLAGS="-I${MPI_HOME}/include"
            LDFLAGS="-L${MPI_HOME}/lib -Wl,-rpath,${MPI_HOME}/lib -lmpi -lmpi_mpifh"
        fi
        PATH="${MPI_HOME}/bin:$PATH"
        export MPI_ROOT_DIR="$MPI_HOME"
    fi

    # Setup performance libraries
    case $lib_flavor in
        AOCL)
            if [[ -z "$AOCL_ROOT" ]]; then
                die "To use AMD AOCL libraries AOCL_ROOT needs to be defined"
            fi
            CLANG_BIN="$(which clang)"
            if [[ -z "$CLANG_BIN" ]]; then
                die "To use AMD AOCL libraries, AMD Optimizing Compiler needs to be loaded."
            fi
            CLANG_ROOT="$(dirname $CLANG_BIN)/.."
            LDFLAGS="$LDFLAGS -L${AOCL_ROOT}/lib -L${CLANG_ROOT}/lib -Wl,-rpath,${AOCL_ROOT}/lib -Wl,-rpath,${CLANG_ROOT}/lib -lblis -lflame -lamdlibm -lomp"
            ;;
        MKL)
            if [[ -z "$MKLROOT" ]]; then
                die "To use Intel MKL libraries MKLROOT needs to be defined"
            fi
            LDFLAGS="$LDFLAGS -L${MKLROOT}/lib -Wl,-rpath,${MKLROOT}/lib -lmkl_scalapack_lp64 -lmkl_intel_lp64 -lmkl_intel_thread -lmkl_core -lmkl_blacs_openmpi_lp64 -liomp5 -lpthread -ldl"
            ;;
        System)
            LDFLAGS="$LDFLAGS -llapack -lblas"
            ;;
        *)
            warn "Not linking against performance libraries. Available flavors: AOCL, MKL, System"
            ;;
    esac

    shift 3
    fn=compiler_$compiler
    $fn "PATH=$PATH" "LDFLAGS=$LDFLAGS" "CFLAGS=$CFLAGS" "CXXFLAGS=$CXXFLAGS" "FFLAGS=$FFLAGS" "${nvhpc_mpi_cc_override[@]}" "$@"
}