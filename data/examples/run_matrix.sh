#!/bin/bash
#SBATCH --job-name=matrix_parallel
#SBATCH --nodes=3
#SBATCH --ntasks=6
#SBATCH --output=/data/logs/matrix_%j.out
#SBATCH --error=/data/logs/matrix_%j.err

echo "Nodes: $SLURM_NODELIST | Tasks: $SLURM_NTASKS | Start: $(date)"
rm -f /data/results/chunk_*.txt
mkdir -p /data/results

START=$(date +%s)
srun python3 /data/examples/matrix_worker.py
END=$(date +%s)

echo "Wall-clock time: $((END - START))s across $SLURM_NTASKS parallel tasks"
echo "End: $(date)"
