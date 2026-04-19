#!/bin/bash
#SBATCH --job-name=jupyter_server
#SBATCH --output=/mnt/storage/users/user1/logs/jupyterlab_%j.out
#SBATCH --error=/mnt/storage/users/user1/logs/jupyterlab_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=2G
 
# Get the IP of the node where the job is running
NODE_IP=$(hostname -I | awk '{print $1}')
echo "JupyterLab starting on node: $SLURMD_NODENAME"
echo "Node IP: $NODE_IP"
echo "Job ID: $SLURM_JOB_ID"
echo "Connect to: http://${NODE_IP}:8888"
echo ""
 
# Create logs directory if it doesn't exist
mkdir -p /mnt/storage/users/user1/logs
 
# Run JupyterLab in Apptainer container
# Using a wrapper script approach to avoid exec argument parsing issues
apptainer exec --bind /mnt/storage:/mnt/storage \
    /mnt/storage/public/containers/jupyterlab.sif \
    bash -c "jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --allow-root"

