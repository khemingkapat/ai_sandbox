#!/bin/bash
# scripts/seed-demo-users.sh
# Seed demo student accounts and users into SlurmDBD and extrausers.
# Run this when you want to provision the standard sandbox test users (user1..user4).

set -eo pipefail

CTRL_EXEC="kubectl exec -n slurm -c slurmctld slurm-controller-0 --"

echo "👤 Seeding demo student accounts and users into Slurm..."

# 1. Create project accounts
echo "  → Creating project accounts: project1, project2, project3..."
$CTRL_EXEC sacctmgr add account project1 Description="Student Project 1" Organization="AI Sandbox" -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add account project2 Description="Student Project 2" Organization="AI Sandbox" -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add account project3 Description="Student Project 3" Organization="AI Sandbox" -i 2>/dev/null || true

# 2. Add student users mapped to project accounts
echo "  → Registering student users..."
$CTRL_EXEC sacctmgr add user user1 account=project1 -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add user user2 account=project1,project2 -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add user user3 account=project2 -i 2>/dev/null || true
$CTRL_EXEC sacctmgr add user user4 account=project3 -i 2>/dev/null || true

# 3. Grant QoS permissions across all partitions
echo "  → Granting QoS permissions to users..."
$CTRL_EXEC sacctmgr -i modify user where name=user1,user2,user3,user4 set QOS=interactive_qos,batch_cpu_qos,batch_gpu_qos,inference_qos

# 4. Provision Linux extrausers on shared storage if not present
echo "  → Ensuring extrausers entries on shared storage..."
mkdir -p storage/common/etc storage/projects/project1 storage/projects/project2 storage/projects/project3

append_passwd_if_missing() {
  local user=$1
  local uid=$2
  local gid=$3
  local prj=$4
  local entry="${user}:x:${uid}:${gid}::/mnt/storage/projects/${prj}:/bin/bash"
  if ! grep -q "^${user}:" storage/common/etc/passwd 2>/dev/null; then
    echo "$entry" >> storage/common/etc/passwd
  fi
}

append_group_if_missing() {
  local user=$1
  local gid=$2
  local entry="${user}:x:${gid}:"
  if ! grep -q "^${user}:" storage/common/etc/group 2>/dev/null; then
    echo "$entry" >> storage/common/etc/group
  fi
}

append_passwd_if_missing user1 1001 1001 project1
append_passwd_if_missing user2 1002 1002 project1
append_passwd_if_missing user3 1003 1003 project2
append_passwd_if_missing user4 1004 1004 project3

append_group_if_missing user1 1001
append_group_if_missing user2 1002
append_group_if_missing user3 1003
append_group_if_missing user4 1004

echo "✅ Demo users and project accounts seeded successfully!"
echo ""
echo "📋 Active Slurm Associations:"
$CTRL_EXEC sacctmgr show association format=Cluster,Account,User,QOS%-40
