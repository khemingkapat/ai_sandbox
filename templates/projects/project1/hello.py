import socket
import os

node = socket.gethostname()
task_id = os.environ.get("SLURM_PROCID", "0")
job_id = os.environ.get("SLURM_JOB_ID", "unknown")
num_tasks = os.environ.get("SLURM_NTASKS", "1")

print(f"[Job {job_id}] Task {task_id}/{num_tasks} running on node: {node}")
