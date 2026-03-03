import time

TASKS = 6
SLEEP = 10

print(f"Running {TASKS} tasks sequentially, {SLEEP}s each...")
start = time.time()

for i in range(TASKS):
    print(f"  Task {i+1}/{TASKS} sleeping for {SLEEP}s...")
    time.sleep(SLEEP)
    print(f"  Task {i+1}/{TASKS} done")

total = time.time() - start
print(f"\n✓ Sequential total: {total:.1f}s (expected ~{TASKS * SLEEP}s)")
