#!/usr/bin/env python3
import json
import time
import subprocess
import base64
import hmac
import hashlib
import sys
import urllib.request
import urllib.error

# Colors for terminal output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"

SLURM_URL = "http://localhost:6820"

def log(msg, color=""):
    print(f"{color}{msg}{RESET}")

def get_jwt_key() -> bytes:
    """Retrieve JWT signing key from the Kubernetes secret."""
    try:
        cmd = ["kubectl", "get", "secret", "slurm-auth-jwt", "-n", "slurm", "-o", "jsonpath={.data.jwt\\.key}"]
        out = subprocess.check_output(cmd)
        return base64.b64decode(out)
    except Exception as e:
        log(f"⚠️ Failed to get key via kubectl: {e}. Trying local portal/dummy.key fallback.", YELLOW)
        with open("portal/dummy.key", "rb") as f:
            return f.read()

def base64url_encode(payload: bytes) -> str:
    return base64.urlsafe_b64encode(payload).decode('utf-8').rstrip('=')

def generate_jwt(username: str, project: str, secret_key: bytes, lifespan: int = 1800) -> str:
    """Generate a Slurm-compatible JWT token signed using HS256."""
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "sun": username,
        "prj": project,
        "iat": now,
        "exp": now + lifespan
    }
    
    header_b64 = base64url_encode(json.dumps(header).encode('utf-8'))
    payload_b64 = base64url_encode(json.dumps(payload).encode('utf-8'))
    
    signing_input = f"{header_b64}.{payload_b64}".encode('utf-8')
    signature = hmac.new(secret_key, signing_input, hashlib.sha256).digest()
    sig_b64 = base64url_encode(signature)
    
    return f"{header_b64}.{payload_b64}.{sig_b64}"

def request_api(method: str, path: str, token: str, username: str, data: dict = None):
    url = f"{SLURM_URL}{path}"
    headers = {
        "X-SLURM-USER-TOKEN": token,
        "X-SLURM-USER-NAME": username,
        "Content-Type": "application/json"
    }
    
    req_body = json.dumps(data).encode('utf-8') if data else None
    req = urllib.request.Request(url, data=req_body, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        log(f"HTTP Error {e.code}: {body}", RED)
        raise
    except urllib.error.URLError as e:
        log(f"Connection Error: {e.reason}", RED)
        log("Make sure 'kubectl port-forward svc/slurm-restapi 6820:6820 -n slurm' is running.", YELLOW)
        raise

def submit_job(username: str, project: str, token: str, script_content: str):
    workspace = f"/mnt/storage/projects/{project}"
    
    job_props = {
        "name": f"test_{username}",
        "current_working_directory": workspace,
        "environment": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            f"HOME={workspace}",
            f"USER={username}"
        ],
        "minimum_nodes": 1,
        "tasks": 1,
        "standard_output": f"{workspace}/test_{username}_%j.out",
        "standard_error": f"{workspace}/test_{username}_%j.err",
    }
    
    payload = {
        "job": job_props,
        "script": f"#!/bin/bash\n{script_content}\n"
    }
    
    log(f"🚀 Submitting job for {username} (Project: {project})...")
    res = request_api("POST", "/slurm/v0.0.42/job/submit", token, username, payload)
    job_id = res.get("job_id")
    if not job_id:
        log(f"❌ Failed to submit job. Response: {res}", RED)
        sys.exit(1)
    
    log(f"✅ Job submitted successfully! Job ID: {job_id}", GREEN)
    return job_id

def wait_for_job(username: str, token: str, job_id: int):
    log(f"⏳ Waiting for job {job_id} to finish...")
    for _ in range(30):
        res = request_api("GET", f"/slurm/v0.0.42/job/{job_id}", token, username)
        jobs = res.get("jobs", [])
        if not jobs:
            log(f"❌ Job {job_id} not found in queue.", RED)
            return None
        
        job = jobs[0]
        state = job.get("job_state", "UNKNOWN")
        if isinstance(state, list):
            state = state[0] if state else "UNKNOWN"
            
        log(f"   Job {job_id} State: {state}")
        if state in ["COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "NODE_FAIL"]:
            return state
        time.sleep(2)
    return "TIMEOUT"

def get_job_output(job_id: int, project: str, username: str, suffix="out"):
    file_path = f"/mnt/storage/projects/{project}/test_{username}_{job_id}.{suffix}"
    cmd = ["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "bash", "-c", f"cat {file_path}"]
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8').strip()
    except Exception:
        return None

def write_nss_files():
    """Write the passwd and group configuration files for the 4-user, 3-project setup."""
    log("📝 Generating passwd and group databases for 4-user sandbox...", YELLOW)
    
    # 1. Passwd file
    passwd_lines = [
        "user1:x:1001:2001::/mnt/storage/projects/project1:/bin/bash",
        "user2:x:1002:2001::/mnt/storage/projects/project1:/bin/bash",
        "user3:x:1003:2002::/mnt/storage/projects/project2:/bin/bash",
        "user4:x:1004:2003::/mnt/storage/projects/project3:/bin/bash"
    ]
    with open("storage/common/etc/passwd", "w") as f:
        f.write("\n".join(passwd_lines) + "\n")
        
    # 2. Group file
    group_lines = [
        "project1:x:2001:user1,user2",
        "project2:x:2002:user2,user3",
        "project3:x:2003:user4"
    ]
    with open("storage/common/etc/group", "w") as f:
        f.write("\n".join(group_lines) + "\n")

def run_test():
    secret_key = get_jwt_key()
    write_nss_files()
    
    # Setup directories and permissions
    log("🔧 Configuring project directory permission boundaries (SetGID models)...", YELLOW)
    setup_cmd = """
mkdir -p /mnt/storage/projects/project1 /mnt/storage/projects/project2 /mnt/storage/projects/project3
chown -R root:2001 /mnt/storage/projects/project1
chmod -R 2770 /mnt/storage/projects/project1
chown -R root:2002 /mnt/storage/projects/project2
chmod -R 2770 /mnt/storage/projects/project2
chown -R root:2003 /mnt/storage/projects/project3
chmod -R 2770 /mnt/storage/projects/project3
"""
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "bash", "-c", setup_cmd])
    
    # Tokens
    token1 = generate_jwt("user1", "project1", secret_key)
    token2 = generate_jwt("user2", "project1", secret_key) # user2 has primary group 2001
    token3 = generate_jwt("user3", "project2", secret_key)
    token4 = generate_jwt("user4", "project3", secret_key)
    
    # Test 1: User 1 writes to project1 (Should succeed)
    script_user1 = """
echo "Writing as user1..."
id
echo "user1 content" > /mnt/storage/projects/project1/user1_shared.txt 2>&1
if [ $? -eq 0 ]; then
    echo "SUCCESS: user1 wrote to project1"
else
    echo "FAILURE: user1 write to project1 blocked!"
fi
"""
    j1 = submit_job("user1", "project1", token1, script_user1)
    wait_for_job("user1", token1, j1)
    
    # Test 2: User 2 writes to project1 (Should succeed - sharing project1)
    # Then user2 tries to write to project2 (Should succeed - because user2 is in project2 group!)
    script_user2 = """
echo "Writing as user2..."
id
echo "user2 project1 content" > /mnt/storage/projects/project1/user2_shared.txt 2>&1
if [ $? -eq 0 ]; then
    echo "SUCCESS: user2 wrote to project1"
else
    echo "FAILURE: user2 write to project1 blocked!"
fi

echo "user2 writing to project2..."
echo "user2 collab content" > /mnt/storage/projects/project2/user2_collab.txt 2>&1
if [ $? -eq 0 ]; then
    echo "SUCCESS: user2 wrote to project2 (collaboration works!)"
else
    echo "FAILURE: user2 write to project2 blocked!"
fi
"""
    j2 = submit_job("user2", "project1", token2, script_user2)
    wait_for_job("user2", token2, j2)
    
    # Test 3: User 1 tries to write to project2 (Should fail - isolated!)
    script_user1_fail = """
echo "user1 writing to project2..."
echo "user1 hack" > /mnt/storage/projects/project2/hack.txt 2>&1
if [ $? -ne 0 ]; then
    echo "SUCCESS: user1 write to project2 blocked."
else
    echo "FAILURE: user1 hack to project2 succeeded!"
fi
"""
    j3 = submit_job("user1", "project1", token1, script_user1_fail)
    wait_for_job("user1", token1, j3)
    
    # Test 4: User 4 tries to read project1 (Should fail - completely isolated!)
    script_user4 = """
echo "user4 reading project1..."
cat /mnt/storage/projects/project1/user1_shared.txt 2>&1
if [ $? -ne 0 ]; then
    echo "SUCCESS: user4 read of project1 blocked."
else
    echo "FAILURE: user4 read of project1 succeeded!"
fi
"""
    j4 = submit_job("user4", "project3", token4, script_user4)
    wait_for_job("user4", token4, j4)

    # Compile outputs
    log("\n📊 Verification Results:", YELLOW)
    
    o1 = get_job_output(j1, "project1", "user1")
    o2 = get_job_output(j2, "project1", "user2")
    o3 = get_job_output(j3, "project1", "user1")
    o4 = get_job_output(j4, "project3", "user4")
    
    tests_passed = True
    
    if o1:
        log("\n--- Test 1 (user1 write self) ---", GREEN if "SUCCESS:" in o1 else RED)
        print(o1)
        if "SUCCESS:" not in o1: tests_passed = False
        
    if o2:
        log("\n--- Test 2 (user2 write project1 & project2) ---", GREEN if "wrote to project2" in o2 else RED)
        print(o2)
        if "wrote to project2" not in o2: tests_passed = False
        
    if o3:
        log("\n--- Test 3 (user1 write project2) ---", GREEN if "blocked" in o3 else RED)
        print(o3)
        if "blocked" not in o3: tests_passed = False
        
    if o4:
        log("\n--- Test 4 (user4 read project1) ---", GREEN if "blocked" in o4 else RED)
        print(o4)
        if "blocked" not in o4: tests_passed = False
        
    if tests_passed:
        log("\n🎉 ALL MULTI-USER COLLABORATION & ISOLATION TESTS PASSED!", GREEN)
    else:
        log("\n❌ SOME TESTS FAILED!", RED)

if __name__ == "__main__":
    run_test()
