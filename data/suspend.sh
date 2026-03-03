#!/bin/bash
# Slurm passes node names to be suspended as arguments.

for node in "$@"; do
    nodes_expanded=$(scontrol show hostnames "$node")
    for expanded_node in $nodes_expanded; do
        docker stop "$expanded_node"
    done
done
