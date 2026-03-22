#!/bin/bash
#SBATCH --job-name=sleep_test
#SBATCH --output=/data/sleep_test_%j.out
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:01:00

echo "Job started at $(date)"
echo "Running on nodes: $SLURM_NODELIST"

srun bash -c "echo Task on $(hostname) at $(date) && sleep 10 && echo Done on $(hostname)"
