#!/bin/bash
# setup-users.sh - Automates the creation of the 4 test users for the sandbox

# Make sure create-user.sh is executable
chmod +x create-user.sh

echo "Initializing Root Organizations in Slurm..."
docker exec slurmctld bash -c "sacctmgr -i add account cpe description='CPE Organization' organization='CPE' 2>/dev/null"
docker exec slurmctld bash -c "sacctmgr -i add account other_org description='Other Organization' organization='Other' 2>/dev/null"
echo ""

# The syntax is: ./create-user.sh <username> <project> <org> <uid> <gid>
# GID maps the project. user1 and user2 share project1 (GID 2001).

# User 1 & 2 in the SAME project
./create-user.sh user1 project1 cpe 1001 2001
./create-user.sh user2 project1 cpe 1002 2001

# User 3 in the SAME org, DIFFERENT project
./create-user.sh user3 project2 cpe 1003 2002

# User 4 in a DIFFERENT org, DIFFERENT project
./create-user.sh user4 project3 other_org 1004 2003

echo "All sandbox users initialized successfully!"
