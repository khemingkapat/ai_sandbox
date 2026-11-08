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
        log("🔑 Fetching JWT key from Kubernetes secret slurm-auth-jwt...", YELLOW)
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
    """Perform HTTP request to the Slurm REST API."""
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
    """Submit a Slurm job using the REST API."""
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
    """Wait for the job to complete and fetch its status."""
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
    
    log("⏰ Timeout waiting for job to complete.", RED)
    return "TIMEOUT"

def get_job_output(job_id: int, project: str, suffix="out"):
    """Read output/error file from worker via kubectl."""
    file_path = f"/mnt/storage/projects/{project}/test_user*_{job_id}.{suffix}"
    cmd = ["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "bash", "-c", f"cat {file_path}"]
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8').strip()
    except Exception:
        return None

def register_user_nss(username: str, uid: int, gid: int, project: str):
    passwd_path = "storage/common/etc/passwd"
    group_path = "storage/common/etc/group"
    
    # Register in passwd
    passwd_entry = f"{username}:x:{uid}:{gid}::/mnt/storage/projects/{project}:/bin/bash\n"
    exists = False
    try:
        with open(passwd_path, "r") as f:
            if f"{username}:" in f.read():
                exists = True
    except FileNotFoundError:
        pass
        
    if not exists:
        with open(passwd_path, "a") as f:
            f.write(passwd_entry)
            
    # Register in group
    group_entry = f"{username}:x:{gid}:\n"
    exists = False
    try:
        with open(group_path, "r") as f:
            if f"{username}:" in f.read():
                exists = True
    except FileNotFoundError:
        pass
        
    if not exists:
        with open(group_path, "a") as f:
            f.write(group_entry)

def run_test():
    secret_key = get_jwt_key()
    
    # Register test users in NSS extrausers database
    register_user_nss("user1", 1001, 1001, "project1")
    register_user_nss("user2", 1002, 1002, "project2")
    
    # Generate tokens for user1 (project1) and user2 (project2)
    token1 = generate_jwt("user1", "project1", secret_key)
    token2 = generate_jwt("user2", "project2", secret_key)
    
    # Setup test directories and users via kubectl first
    log("🔧 Re-asserting test user ownerships and directory setup...", YELLOW)
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "mkdir", "-p", "/mnt/storage/projects/project1", "/mnt/storage/projects/project2"])
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "chown", "-R", "1001:1001", "/mnt/storage/projects/project1"])
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "chmod", "700", "/mnt/storage/projects/project1"])
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "chown", "-R", "1002:1002", "/mnt/storage/projects/project2"])
    subprocess.run(["kubectl", "exec", "-n", "slurm", "-c", "slurmd", "slurm-worker-slinky-0", "--", "chmod", "700", "/mnt/storage/projects/project2"])
    
    # Define test job script for user1
    # 1. Write to project1 (Should succeed)
    # 2. Try to read/write to project2 (Should fail)
    script_user1 = """
echo "=== User 1 Job Execution ==="
id
echo "Writing to project1 (self)..."
echo "hello from user1" > /mnt/storage/projects/project1/user1_shared.txt
cat /mnt/storage/projects/project1/user1_shared.txt

echo "Attempting to write to project2..."
echo "user1 hack" > /mnt/storage/projects/project2/hack.txt 2>&1
if [ $? -ne 0 ]; then
    echo "SUCCESS: Write to project2 blocked."
else
    echo "FAILURE: Write to project2 succeeded!"
fi
"""

    job1 = submit_job("user1", "project1", token1, script_user1)
    state1 = wait_for_job("user1", token1, job1)
    
    # Define test job script for user2
    # 1. Write to project2 (Should succeed)
    # 2. Try to read/write to project1 (Should fail)
    script_user2 = """
echo "=== User 2 Job Execution ==="
id
echo "Writing to project2 (self)..."
echo "hello from user2" > /mnt/storage/projects/project2/user2_shared.txt
cat /mnt/storage/projects/project2/user2_shared.txt

echo "Attempting to write to project1..."
echo "user2 hack" > /mnt/storage/projects/project1/hack.txt 2>&1
if [ $? -ne 0 ]; then
    echo "SUCCESS: Write to project1 blocked."
else
    echo "FAILURE: Write to project1 succeeded!"
fi
"""

    job2 = submit_job("user2", "project2", token2, script_user2)
    state2 = wait_for_job("user2", token2, job2)
    
    # Retrieve and print outputs
    log("\n📊 Verification Results:", YELLOW)
    
    out1 = get_job_output(job1, "project1")
    if out1:
        log(f"\n--- User 1 Job Output (Job {job1}) ---", GREEN if "SUCCESS:" in out1 else RED)
        print(out1)
    else:
        log(f"⚠️ Could not retrieve output for Job {job1}", RED)
        
    out2 = get_job_output(job2, "project2")
    if out2:
        log(f"\n--- User 2 Job Output (Job {job2}) ---", GREEN if "SUCCESS:" in out2 else RED)
        print(out2)
    else:
        log(f"⚠️ Could not retrieve output for Job {job2}", RED)
        
    if out1 and "SUCCESS:" in out1 and out2 and "SUCCESS:" in out2:
        log("\n🎉 ALL ISOLATION TESTS PASSED!", GREEN)
    else:
        log("\n❌ SOME ISOLATION TESTS FAILED!", RED)

if __name__ == "__main__":
    run_test()
