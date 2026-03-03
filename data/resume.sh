#!/bin/bash
# Slurm passes node names (e.g., worker1 worker2) as arguments.
# This loop ensures each node is started individually.

for node in "$@"; do
    # Expand brackets if Slurm passes names like worker[1-2]
    nodes_expanded=$(scontrol show hostnames "$node")
    for expanded_node in $nodes_expanded; do
        docker start "$expanded_node"
    done
done
