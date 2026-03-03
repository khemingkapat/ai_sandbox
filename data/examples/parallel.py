import socket, os, time, random

node = socket.gethostname()
task_id = int(os.environ.get("SLURM_PROCID", "0"))
job_id = os.environ.get("SLURM_JOB_ID", "unknown")

work_duration = random.uniform(1, 3)
print(f"[Job {job_id}] Task {task_id} on {node}: starting ({work_duration:.1f}s)")
time.sleep(work_duration)
result = sum(i * task_id for i in range(100_000))
print(f"[Job {job_id}] Task {task_id} on {node}: done. result={result}")
