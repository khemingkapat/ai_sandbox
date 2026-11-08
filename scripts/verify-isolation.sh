#!/bin/bash
# scripts/verify-isolation.sh
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "====================================================="
echo "🧪 Starting Unix Permissions Isolation Verification"
echo "====================================================="

STORAGE_ROOT="/mnt/storage"
PROJECT1="$STORAGE_ROOT/projects/project1"
PROJECT2="$STORAGE_ROOT/projects/project2"
COMMON="$STORAGE_ROOT/common"

# Pre-requisite: ensure we have at least one file to read in common
sudo mkdir -p "$COMMON"
echo "common_data" | sudo tee "$COMMON/common_file.txt" > /dev/null
sudo chmod 644 "$COMMON/common_file.txt"

# Helper function to assert success
assert_success() {
  local user_id=$1
  local cmd=$2
  local msg=$3

  echo -n "Checking: [UID $user_id] $msg... "
  if sudo -u "#$user_id" bash -c "$cmd" > /dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
  else
    echo -e "${RED}FAIL${NC}"
    echo "Command failed: $cmd"
    exit 1
  fi
}

# Helper function to assert failure (Permission Denied)
assert_failure() {
  local user_id=$1
  local cmd=$2
  local msg=$3

  echo -n "Checking: [UID $user_id] $msg... "
  if ! sudo -u "#$user_id" bash -c "$cmd" > /dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC} (Blocked as expected)"
  else
    echo -e "${RED}FAIL${NC}"
    echo "Command succeeded but should have failed: $cmd"
    exit 1
  fi
}

# --- UID 1001 TESTS ---
echo ""
echo "👤 Testing as UID 1001 (User 1)"
echo "-----------------------------------------------------"

# Create a file for reading test
echo "project1_secret" | sudo -u "#1001" tee "$PROJECT1/secret.txt" > /dev/null

# Success on project1
assert_success 1001 "ls $PROJECT1" "List project1 directory"
assert_success 1001 "cat $PROJECT1/secret.txt" "Read file in project1"
assert_success 1001 "touch $PROJECT1/test_1001.tmp && rm $PROJECT1/test_1001.tmp" "Write/Delete in project1"

# Failure on project2
assert_failure 1001 "ls $PROJECT2" "List project2 directory"
assert_failure 1001 "touch $PROJECT2/test_1001.tmp" "Write to project2"

# Common access
assert_success 1001 "ls $COMMON" "List common directory"
assert_success 1001 "cat $COMMON/common_file.txt" "Read file in common"
assert_failure 1001 "touch $COMMON/test_1001.tmp" "Write to common"


# --- UID 1002 TESTS ---
echo ""
echo "👤 Testing as UID 1002 (User 2)"
echo "-----------------------------------------------------"

# Create a file for reading test
echo "project2_secret" | sudo -u "#1002" tee "$PROJECT2/secret.txt" > /dev/null

# Success on project2
assert_success 1002 "ls $PROJECT2" "List project2 directory"
assert_success 1002 "cat $PROJECT2/secret.txt" "Read file in project2"
assert_success 1002 "touch $PROJECT2/test_1002.tmp && rm $PROJECT2/test_1002.tmp" "Write/Delete in project2"

# Failure on project1
assert_failure 1002 "ls $PROJECT1" "List project1 directory"
assert_failure 1002 "cat $PROJECT1/secret.txt" "Read file in project1"
assert_failure 1002 "touch $PROJECT1/test_1002.tmp" "Write to project1"

# Common access
assert_success 1002 "ls $COMMON" "List common directory"
assert_success 1002 "cat $COMMON/common_file.txt" "Read file in common"
assert_failure 1002 "touch $COMMON/test_1002.tmp" "Write to common"

# --- CLEANUP ---
echo ""
echo "🧹 Cleaning up test files..."
sudo rm -f "$PROJECT1/secret.txt"
sudo rm -f "$PROJECT2/secret.txt"
sudo rm -f "$COMMON/common_file.txt"

echo ""
echo "====================================================="
echo -e "🎉 ${GREEN}SUCCESS: All isolation checks passed!${NC}"
echo "====================================================="
exit 0
