# data/examples/matrix_worker.py
import os, time, random, socket

task_id = int(os.environ.get("SLURM_PROCID", "0"))
num_tasks = int(os.environ.get("SLURM_NTASKS", "1"))
job_id = os.environ.get("SLURM_JOB_ID", "local")
node = socket.gethostname()

MATRIX_SIZE = 1000
rows_per_task = MATRIX_SIZE // num_tasks
row_start = task_id * rows_per_task
row_end = row_start + rows_per_task

print(
    f"[Job {job_id}] Task {task_id}/{num_tasks} on {node}: rows {row_start}-{row_end}"
)
start = time.time()

# Read shared B from disk — generated once by setup script
with open("/data/results/B_matrix.txt") as f:
    B = [[float(v) for v in line.strip().split(",")] for line in f]

# Generate only this task's rows of A
random.seed(task_id * 1000)
A_chunk = [[random.random() for _ in range(MATRIX_SIZE)] for _ in range(rows_per_task)]

# Compute A_chunk x B
result_rows = []
for row_a in A_chunk:
    row = [
        sum(row_a[k] * B[k][j] for k in range(MATRIX_SIZE)) for j in range(MATRIX_SIZE)
    ]
    result_rows.append(row)

elapsed = time.time() - start
print(f"[Job {job_id}] Task {task_id}/{num_tasks} on {node}: done in {elapsed:.2f}s")

os.makedirs("/data/results", exist_ok=True)
with open(f"/data/results/chunk_{task_id}.txt", "w") as f:
    f.write(f"task={task_id} rows={row_start}-{row_end} time={elapsed:.2f}s\n")
    for row in result_rows:
        f.write(f"{row[0]:.6f}\n")
