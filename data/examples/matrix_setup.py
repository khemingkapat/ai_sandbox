import random, os

MATRIX_SIZE = 1000
print(f"Generating {MATRIX_SIZE}x{MATRIX_SIZE} B matrix and saving to disk...")
random.seed(42)
B = [[random.random() for _ in range(MATRIX_SIZE)] for _ in range(MATRIX_SIZE)]

os.makedirs("/data/results", exist_ok=True)
with open("/data/results/B_matrix.txt", "w") as f:
    for row in B:
        f.write(",".join(f"{v:.6f}" for v in row) + "\n")
print("Done — B matrix saved to /data/results/B_matrix.txt")
