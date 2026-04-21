#!/bin/bash
# create-user.sh - Create a new Slurm user with group-based project directories

USERNAME=$1
ACCOUNT=$2
ORGANIZATION=$3
USER_ID=$4
GROUP_ID=$5

if [ -z "$GROUP_ID" ]; then
    echo "Usage: ./create-user.sh <username> <account_project> <organization> <uid> <gid>"
    echo "Example: ./create-user.sh user1 project1 cpe 1001 2001"
    exit 1
fi

echo "Setting up User: $USERNAME | Project: $ACCOUNT | Org: $ORGANIZATION"

# 1. Create Slurm accounting
docker exec slurmctld bash -c "
sacctmgr -i add account $ACCOUNT description='$ACCOUNT' organization='$ORGANIZATION' 2>/dev/null || true
sacctmgr -i add user $USERNAME account=$ACCOUNT defaultaccount=$ACCOUNT 2>/dev/null
"

# 2. Create Linux Group and User on all nodes
for container in $(docker ps --filter "name=slurmctld" --filter "name=cpu-worker" --format "{{.Names}}"); do
    echo " -> Provisioning Linux identity on $container..."
    # Create the group (suppress error if it already exists from another user)
    docker exec -u root "$container" bash -c "groupadd -g $GROUP_ID $ACCOUNT 2>/dev/null || true"
    
    # Create the user assigned to the project group
    docker exec -u root "$container" bash -c "useradd -m -u $USER_ID -g $GROUP_ID -s /bin/bash $USERNAME 2>/dev/null || true"
done

# 3. Initialize Project Directory with SetGID for sharing
echo " -> Configuring Project Directory: /mnt/storage/projects/$ACCOUNT"
docker exec -u root slurmctld bash -c "
mkdir -p /mnt/storage/projects/$ACCOUNT
chown root:$ACCOUNT /mnt/storage/projects/$ACCOUNT
# 2770 = SetGID bit (2), full access for Owner (7) and Group (7), no access for Others (0)
chmod 2770 /mnt/storage/projects/$ACCOUNT
"

echo "✓ User $USERNAME setup complete."
echo "---------------------------------------------------"
