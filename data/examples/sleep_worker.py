# data/examples/sleep_worker.py
import time, os, socket

task_id = int(os.environ.get("SLURM_PROCID", "0"))
node = socket.gethostname()

print(f"Task {task_id} on {node}: sleeping 10s...")
time.sleep(10)
print(f"Task {task_id} on {node}: done!")
