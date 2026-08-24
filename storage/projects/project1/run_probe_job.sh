#!/bin/bash
#SBATCH --job-name=security_probe
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --output=/mnt/storage/projects/project1/logs/probe_%j.out
#SBATCH --error=/mnt/storage/projects/project1/logs/probe_%j.err

echo "Job started on $(date)"
echo "Running on nodes: $SLURM_NODELIST"

srun apptainer exec \
    --bind /mnt/storage/projects/project1:/mnt/storage/projects/project1 \
    --bind /mnt/storage/common:/mnt/storage/common:ro \
    /mnt/storage/projects/project1/software/security_probe/security_probe.sif \
    bash /mnt/storage/projects/project1/run_probe.sh

echo "Job finished on $(date)"
