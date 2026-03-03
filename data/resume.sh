#!/bin/bash
# Slurm passes node names as $1 (e.g. worker1,worker2)
nodes=$(echo $1 | tr ',' ' ')
docker start $nodes
