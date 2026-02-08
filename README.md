# **AI Sandbox Demo**

A reproducible development environment for data science and AI. This setup uses Nix to provide the core tools (Python, JupyterLab, and LSP) and uv to manage your project-specific libraries and Jupyter kernels.

## **Prerequisites**

* Nix: You must have Nix installed.  
* Flakes: Ensure Nix Flakes are enabled on your system.

## **Getting Started**

### **1. Enter the Development Shell**

Run the following command in your terminal to load the environment:  
```
nix develop
```

This will automatically provide:

* Python 3.13 (Stable)  
* uv (Package Manager)  
* JupyterLab (Pre-patched for NixOS)  
* Pyright (LSP for type checking)  
* Black (Formatter)

### **2. Initialize the Project**

If this is a new setup, initialize your Python environment:  
# Install dependencies from pyproject.toml
```
uv sync
```
# Create and register the Jupyter Kernel  
```
uv run ipython kernel install --user --name="ai-sandbox" --display-name "Python (AI Sandbox)"
```

### **3. Launch JupyterLab**

To start working on your notebooks, run:  
```
jupyter-lab
```

**Important:** When you open or create a `.ipynb` file, make sure to select the **Python (AI Sandbox)** kernel in the top-right corner.

## **Managing Libraries with uv**

To add new libraries to your sandbox (e.g., NumPy, Pandas, Matplotlib):  
```
uv add numpy pandas matplotlib
```

After adding a library, you may need to **Restart the Kernel** in JupyterLab to see the changes.

## **Architecture Overview**

This project uses a layered approach to ensure stability on NixOS:

1. **Nix Layer**: Provides the stable Python interpreter and a "patched" JupyterLab server that works perfectly with Nix system libraries.  
2. **uv Layer**: Handles the virtual environment and your specific research libraries.  
3. **Kernel Layer**: Uses ipykernel to bridge the Nix-managed server with your uv-managed environment.

## **Maintenance**

* **Update Tools**: Run nix flake update to get the latest versions of Python and Jupyter from the Nix stable channel.  
* **Reproducibility**: `UV_PYTHON_DOWNLOADS=never` is set to ensure uv always uses the Python binary provided by Nix.
