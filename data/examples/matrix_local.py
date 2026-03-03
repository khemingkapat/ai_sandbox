import time, random

MATRIX_SIZE = 1000
print(f"Computing full {MATRIX_SIZE}x{MATRIX_SIZE} matrix (single process)...")

random.seed(42)
B = [[random.random() for _ in range(MATRIX_SIZE)] for _ in range(MATRIX_SIZE)]

random.seed(0)
A = [[random.random() for _ in range(MATRIX_SIZE)] for _ in range(MATRIX_SIZE)]

start = time.time()
result = []
for i in range(MATRIX_SIZE):
    row = [
        sum(A[i][k] * B[k][j] for k in range(MATRIX_SIZE)) for j in range(MATRIX_SIZE)
    ]
    result.append(row)
    if (i + 1) % 100 == 0:
        print(f"  {i+1}/1000 rows — {time.time()-start:.1f}s elapsed")

print(f"\n✓ Single-process finished in {time.time()-start:.2f}s")
