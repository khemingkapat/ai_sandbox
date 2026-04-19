import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

print("Initializing analysis...")
data = pd.DataFrame(
    {"x": np.linspace(0, 10, 100), "y": np.sin(np.linspace(0, 10, 100))}
)

print(f"Data Sample:\n{data.head()}")
print(f"Container environment is healthy.")
