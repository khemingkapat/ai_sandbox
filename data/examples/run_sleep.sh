#!/bin/bash
#SBATCH --job-name=sleep_parallel
#SBATCH --nodes=3
#SBATCH --ntasks=6
#SBATCH --output=/data/logs/sleep_%j.out
#SBATCH --error=/data/logs/sleep_%j.err

echo "Start: $(date)"
srun python3 /data/examples/sleep_worker.py
echo "End: $(date)"
