#!/bin/bash

set -e

# GPU (H100) strong-scaling variant of generate_cases.sh.
# Requires a code_saturne built with the CUDA-enabled stack
# (CFG_code_saturne_8.3.0-h100.sh) to be on PATH, e.g.:
#   module load nvhpc-hpcx
#   module load $CS_INSTALL_PREFIX/saturne/h100/.../code_saturne-<...>

# Test case from open saturne cases
CASE_NAME=F128_04_GPU

# Multiply the mesh to make it go up to 200M cells
# (kept fixed across the node sweep below -> strong scaling)
NTUBES=04

# Change to fit your needs and environment.
# One MPI rank per GPU is the supported Code_Saturne CUDA layout.
GPUS_PER_NODE=8
TASKS_PER_NODE=$GPUS_PER_NODE
CPUS_PER_TASK=12          # host cores reserved per rank/GPU (adjust to node topology)
ROOT_WORK_DIR=$(pwd)
PARTITION=h100

# Load your compiler and MPI environment here if not done before
# e.g.
# module load nvhpc-hpcx

# Create the case folder structure with all scripts needed
echo "NTUBES = $NTUBES"
ddir="$ROOT_WORK_DIR/DATA"
sdir="$ROOT_WORK_DIR/SRC_$NTUBES"
mdir="$ROOT_WORK_DIR/MESH"
rdir="$ROOT_WORK_DIR/${CASE_NAME}"

mkdir -p $rdir/RESU

# Compile the case source
pushd $sdir
code_saturne compile
cp cs_solver $ddir
popd

for nnodes in 08 04 02 01; do
    echo "nnodes = $nnodes"

    cdir="$rdir/RESU/${CASE_NAME}_${TASKS_PER_NODE}_${nnodes}"

    mkdir -p $cdir

    pushd $cdir

    # copy input files
    ln -s $ddir/mesh_input.csm .
    ln -s $ddir/cs_solver
    ln -s $ddir/setup.xml

    # Wrapper: pin each rank to a single GPU based on its node-local rank
    cat > gpu_bind.sh <<'EOF'
#!/bin/bash
export CUDA_VISIBLE_DEVICES=${OMPI_COMM_WORLD_LOCAL_RANK}
exec "$@"
EOF
    chmod +x gpu_bind.sh

    cat > run_solver <<EOF
#!/bin/bash

#SBATCH --nodes=${nnodes}
#SBATCH --time=6:00:00
#SBATCH --job-name="${CASE_NAME}"
#SBATCH --ntasks-per-node=${TASKS_PER_NODE}
#SBATCH --cpus-per-task=${CPUS_PER_TASK}
#SBATCH --gpus-per-node=${GPUS_PER_NODE}
#SBATCH --partition=${PARTITION}
#SBATCH --exclusive
#SBATCH --output=job.out.log
#SBATCH --error=job.err.log

cd \$SLURM_SUBMIT_DIR

export OMP_NUM_THREADS=1

# Load your compiler/MPI environment here
# e.g.
# module load nvhpc-hpcx

# Run solver.
# One rank per GPU, bound via gpu_bind.sh -> CUDA_VISIBLE_DEVICES.
mpirun -n \${SLURM_NPROCS} \\
    --map-by ppr:${GPUS_PER_NODE}:node:PE=${CPUS_PER_TASK} \\
    --bind-to core \\
    --mca mpi_show_mca_params all \\
    ./gpu_bind.sh ./cs_solver --mpi "\$@"
export CS_RET=\$?
exit \$CS_RET
EOF

    popd
done
