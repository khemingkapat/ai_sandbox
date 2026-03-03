#!/bin/bash
#SBATCH --job-name=parallel_python
#SBATCH --nodes=3
#SBATCH --ntasks=6
#SBATCH --output=/data/logs/parallel_%j.out
#SBATCH --error=/data/logs/parallel_%j.err

echo "Job started on $(date)"
echo "Running on nodes: $SLURM_NODELIST"
echo "Total tasks: $SLURM_NTASKS"
srun python3 /data/examples/parallel.py
echo "Job finished on $(date)"
