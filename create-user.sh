#!/bin/bash
# create-user.sh - Create a new Slurm user
USERNAME=$1
UID=${2:-1000}
# Default UID is 1000
if [ -z "$USERNAME" ]; then
echo "Usage: ./create-user.sh <username> [uid]"
exit 1
fi
echo "Creating user: $USERNAME (UID: $UID)"
# 1. Create Slurm accounting
docker exec slurmctld bash -c "
sacctmgr -i add account cpe description='CPE Organization' organization='CPE' 2>/dev/nu
sacctmgr -i add account project1 parent=cpe description='Project 1' 2>/dev/null || true
sacctmgr -i add user $USERNAME account=project1 defaultaccount=project1
"
# 2. Create Linux user on all containers
for container in $(docker ps --filter "name=slurmctld" --filter "name=cpu-worker"
echo "Creating $USERNAME on $container..."
docker exec $container useradd -m -u $UID -s /bin/bash $USERNAME 2>/dev/null
done
# 3. Create storage directory
mkdir -p storage/users/$USERNAME
chmod 755 storage/users/$USERNAME
docker exec slurmctld chown -R $UID:$UID /mnt/storage/users/$USERNAME
echo "✓ User $USERNAME created successfully"
