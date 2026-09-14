#!/bin/bash

set -e

# Test case from open saturne cases
CASE_NAME=F128_04

# Multiply the mesh to make it go up to 200M cells
NTUBES=04

# Change to fit your needs and environment
TASKS_PER_NODE=96
BIND_TO=core
MAP_BY=l3cache
ROOT_WORK_DIR=$(pwd)
PARTITION=hpc7a-96

# Load your compiler and MPI environment here if not done before
# e.g.
# . /opt/rh/gcc-toolset-12/enable

# Create the case folder structure with all scripts needed
echo "NTUBES = $NTUBES"
ddir="$ROOT_WORK_DIR/DATA"
sdir="$ROOT_WORK_DIR/SRC_$NTUBES"
mdir="$ROOT_WORK_DIR/MESH"
rdir="$ROOT_WORK_DIR/F128_${NTUBES}"

mkdir -p $rdir/RESU

# Compile the case source
pushd $sdir 
code_saturne compile 
cp cs_solver $ddir 
popd

for nnodes in 32 24 16 12 08 04 02 01; do
    echo "nnodes = $nnodes"

    cdir="$rdir/RESU/${CASE_NAME}_${TASKS_PER_NODE}_${BIND_TO}_${MAP_BY}_${nnodes}"

    mkdir -p $cdir

    pushd $cdir
    
    # copy input files
    ln -s $ddir/mesh_input.csm .
    ln -s $ddir/cs_solver
    ln -s $ddir/setup.xml

    cat > run_solver <<EOF
#!/bin/bash

#SBATCH --nodes=${nnodes}
#SBATCH --time=6:00:00
#SBATCH --job-name="${CASE_NAME}"
#SBATCH --ntasks-per-node=${TASKS_PER_NODE}
#SBATCH --cpus-per-task=1
#SBATCH --partition=${PARTITION}
#SBATCH --exclusive
#SBATCH --output=job.out.log
#SBATCH --error=job.err.log

cd \$SLURM_SUBMIT_DIR

export OMP_NUM_THREADS=1

# Load your compiler here
# e.g.
# . /opt/rh/gcc-toolset-12/enable


# Run solver.
# Setup mpi options
mpirun -n \${SLURM_NPROCS} \\
    --bind-to $BIND_TO \\
    --map-by $MAP_BY \\
    --mca pml cm \\
    --mca mtl ofi \\
    --mca mpi_show_mca_params all \\
    --mca btl_base_verbose 5 \\
    --mca mtl_base_verbose 5 \\
    --mca mtl_ofi_verbose 1 \\
    -x FI_PROVIDER=efa \\
    -x FI_EFA_USE_DEVICE_RDMA=1 \\
    -x FI_EFA_ENABLE_SHM_TRANSFER=1 \\
    ./cs_solver --mpi "\$@"
export CS_RET=\$?
exit \$CS_RET
EOF

    popd
done
