#!/bin/bash
# scripts/setup-accounting.sh
# Post-boot script to configure Slurm accounting QoS and TRES limits.
# Must run AFTER slurmctld and slurmdbd are fully operational.

set -e

CTRL_EXEC="kubectl exec -n slurm -c slurmctld slurm-controller-0 --"

echo "📊 Setting up Slurm QoS and TRES limits..."

# Create the default account (required for QoS to function)
$CTRL_EXEC sacctmgr add account default_acct Description="Default account" Organization="AI Sandbox" -i 2>/dev/null || true

# Create partition-specific QoS entries with MaxTRESPerJob limits
# These enforce the resource fencing defined in CAPACITY_PLANNING.md

echo "  → Creating QoS: interactive_qos (cpu=4, mem=16G)"
$CTRL_EXEC sacctmgr add qos interactive_qos \
  MaxTRESPerJob=cpu=4,mem=16384 \
  Priority=200 \
  -i 2>/dev/null || true

echo "  → Creating QoS: batch_cpu_qos (cpu=16, mem=64G)"
$CTRL_EXEC sacctmgr add qos batch_cpu_qos \
  MaxTRESPerJob=cpu=16,mem=65536 \
  Priority=100 \
  -i 2>/dev/null || true

echo "  → Creating QoS: batch_gpu_qos (cpu=16, mem=64G)"
$CTRL_EXEC sacctmgr add qos batch_gpu_qos \
  MaxTRESPerJob=cpu=16,mem=65536 \
  Priority=100 \
  -i 2>/dev/null || true

echo "  → Creating QoS: inference_qos (mem=32G)"
$CTRL_EXEC sacctmgr add qos inference_qos \
  MaxTRESPerJob=mem=32768 \
  Priority=300 \
  -i 2>/dev/null || true

# Associate QoS with partitions
echo "  → Binding QoS to partitions..."
$CTRL_EXEC scontrol update PartitionName=interactive QoS=interactive_qos
$CTRL_EXEC scontrol update PartitionName=batch-cpu QoS=batch_cpu_qos
$CTRL_EXEC scontrol update PartitionName=batch-gpu QoS=batch_gpu_qos
$CTRL_EXEC scontrol update PartitionName=inference QoS=inference_qos

# Add root and slurm users to accounting (needed for sbatch inside slurmctld container)
echo "  → Adding root and slurm users to accounting..."
$CTRL_EXEC sacctmgr add user root account=default_acct -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add user slurm account=default_acct -i 2>/dev/null || true
$CTRL_EXEC sacctmgr modify user root set qos=normal,interactive_qos,batch_cpu_qos,batch_gpu_qos,inference_qos -i 2>/dev/null || true
$CTRL_EXEC sacctmgr modify user slurm set qos=normal,interactive_qos,batch_cpu_qos,batch_gpu_qos,inference_qos -i 2>/dev/null || true

echo "✅ Accounting QoS and TRES limits configured!"

# Verify
echo ""
echo "📋 QoS Summary:"
$CTRL_EXEC sacctmgr show qos format=Name,Priority,MaxTRESPerJob%-40
