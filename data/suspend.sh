#!/bin/bash
nodes=$(echo $1 | tr ',' ' ')
docker stop $nodes
