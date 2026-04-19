#!/bin/bash
#SBATCH --job-name=jupyter_server
#SBATCH --output=/data/logs/jupyterlab_%j.out
#SBATCH --error=/data/logs/jupyterlab_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=2G

# Get the IP of the node where the job is running
echo "JupyterLab starting on node: $SLURMD_NODENAME"
echo "Job ID: $SLURM_JOB_ID"

# Execute the container
# Use --bind to ensure the shared storage is visible inside the container
apptainer exec --bind /mnt/storage:/mnt/storage \
    /mnt/storage/public/containers/jupyterlab.sif \
    jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --allow-root

