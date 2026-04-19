#!/bin/bash
#SBATCH --job-name=hello_python
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --output=/mnt/storage/users/user1/logs/hello_%j.out
#SBATCH --error=/mnt/storage/users/user1/logs/hello_%j.err

echo "Job started on $(date)"
echo "Running on nodes: $SLURM_NODELIST"
srun python3 /mnt/storage/users/user1/hello.py
echo "Job finished on $(date)"
