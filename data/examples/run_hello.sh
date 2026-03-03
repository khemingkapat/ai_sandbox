#!/bin/bash
#SBATCH --job-name=hello_python
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --output=/data/logs/hello_%j.out
#SBATCH --error=/data/logs/hello_%j.err

echo "Job started on $(date)"
echo "Running on nodes: $SLURM_NODELIST"
srun python3 /data/examples/hello.py
echo "Job finished on $(date)"
