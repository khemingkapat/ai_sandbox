import jwt
import time
import os
import httpx
from pathlib import Path
from fastapi import FastAPI, Request, Form, HTTPException, Cookie
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from port_manager import PortManager

app = FastAPI(title="HPC Portal")
templates = Jinja2Templates(directory="templates")

SLURMRESTD_URL = os.getenv("SLURMRESTD_URL", "http://slurmrestd:6820")
JWT_KEY_PATH = os.getenv("JWT_KEY_PATH", "/var/spool/slurmctld/jwt_hs256.key")
TOKEN_LIFESPAN = int(os.getenv("TOKEN_LIFESPAN", "1800"))

# Initialize Port Manager inside the Portal
port_manager = PortManager(
    db_path=os.getenv("PORT_DB_PATH", "/var/lib/portal/leases.db"),
    port_range=(30000, 31000),
    traefik_config_dir=os.getenv("TRAEFIK_CONFIG_DIR", "/etc/traefik/dynamic"),
)

APPS = [
    {
        "id": "jupyterlab",
        "name": "JupyterLab",
        "description": "Interactive Python notebook environment",
        "icon": "⬡",
    }
]

USERS = ["user1", "root"]


def _read_slurm_key() -> str:
    key_path = Path(JWT_KEY_PATH)
    if not key_path.exists():
        raise HTTPException(status_code=500, detail="Slurm JWT key not found.")
    return key_path.read_bytes()


def make_slurm_token(username: str) -> str:
    payload = {
        "sun": username,
        "iat": int(time.time()),
        "exp": int(time.time()) + TOKEN_LIFESPAN,
    }
    return jwt.encode(payload, _read_slurm_key(), algorithm="HS256")


def verify_session_token(token: str) -> str:
    try:
        payload = jwt.decode(token, _read_slurm_key(), algorithms=["HS256"])
        return payload["sun"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid session")


def get_current_user(session: str | None) -> tuple[str, str]:
    if not session:
        raise HTTPException(status_code=401, detail="Not logged in")
    return verify_session_token(session), session


# --- AUTH ROUTES ---
@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    return templates.TemplateResponse(
        "login.html", {"request": request, "users": USERS}
    )


@app.post("/login")
async def login(username: str = Form(...)):
    if username not in USERS:
        raise HTTPException(status_code=400, detail="Unknown user")
    response = RedirectResponse(url="/", status_code=303)
    response.set_cookie(
        key="session",
        value=make_slurm_token(username),
        httponly=True,
        max_age=TOKEN_LIFESPAN,
    )
    return response


@app.get("/logout")
async def logout():
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie("session")
    return response


@app.get("/", response_class=HTMLResponse)
async def index(request: Request, session: str | None = Cookie(default=None)):
    if not session:
        return RedirectResponse(url="/login")
    try:
        username = verify_session_token(session)
        expires_in = jwt.decode(session, _read_slurm_key(), algorithms=["HS256"])[
            "exp"
        ] - int(time.time())
    except Exception:
        return RedirectResponse(url="/login")

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "username": username,
            "apps": APPS,
            "expires_in": expires_in,
        },
    )


# --- JOB SUBMISSION (WITH DYNAMIC PORT INJECTION) ---
@app.post("/jobs/submit")
async def submit_job(
    app_id: str = Form(...), session: str | None = Cookie(default=None)
):
    username, token = get_current_user(session)
    home = f"/mnt/storage/users/{username}" if username != "root" else "/root"

    # --- THIS IS THE FULL, UPDATED SCRIPT TEMPLATE ---
    script_template = """#!/bin/bash
#SBATCH --job-name=jupyter_server
#SBATCH --output={home}/logs/jupyterlab_%j.out
#SBATCH --error={home}/logs/jupyterlab_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=2G

mkdir -p {home}/logs
NODE_IP=$(hostname -I | awk '{{print $1}}')
NODE_HOSTNAME=$(hostname)

echo "Requesting port from Portal..."
# Call the portal's internal API to get a port
RESPONSE=$(curl -s -X POST http://portal:8080/api/internal/allocate-port \\
    -H "Content-Type: application/json" \\
    -d '{{"job_id": "'$SLURM_JOB_ID'", "username": "{username}", "node_hostname": "'$NODE_HOSTNAME'", "node_ip": "'$NODE_IP'"}}')

# Extract port securely using python
ALLOCATED_PORT=$(python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('port', ''))" <<< "$RESPONSE")

if [ -z "$ALLOCATED_PORT" ]; then
    echo "ERROR: Failed to allocate port. $RESPONSE"
    exit 1
fi

echo "Allocated port: $ALLOCATED_PORT"

# Tell JupyterLab its exact base URL so it works behind the proxy
BASE_URL="/{username}/jupyter/$SLURM_JOB_ID"

apptainer exec --bind /mnt/storage:/mnt/storage \\
    /mnt/storage/public/containers/jupyterlab.sif \\
    bash -c "jupyter lab --ip=0.0.0.0 --port=$ALLOCATED_PORT --no-browser --ServerApp.base_url=$BASE_URL --ServerApp.token='' --allow-root"

echo "Releasing port..."
curl -s -X POST http://portal:8080/api/internal/release-port \\
    -H "Content-Type: application/json" \\
    -d '{{"job_id": "'$SLURM_JOB_ID'"}}'
"""
    # --- END OF SCRIPT TEMPLATE ---

    payload = {
        "job": {
            "current_working_directory": home,
            "environment": {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": home,
                "USER": username,
            },
        },
        "script": script_template.format(home=home, username=username),
    }

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{SLURMRESTD_URL}/slurm/v0.0.42/job/submit",
            headers={
                "X-SLURM-USER-TOKEN": token,
                "X-SLURM-USER-NAME": username,
                "Content-Type": "application/json",
            },
            json=payload,
            timeout=15,
        )

    data = resp.json()
    if resp.status_code != 200 or data.get("errors"):
        raise HTTPException(
            status_code=500, detail=str(data.get("errors", "Unknown error"))
        )

    return JSONResponse({"job_id": data["job_id"]})


@app.get("/jobs/{job_id}")
async def job_status(job_id: int, session: str | None = Cookie(default=None)):
    username, token = get_current_user(session)

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{SLURMRESTD_URL}/slurm/v0.0.42/job/{job_id}",
            headers={
                "X-SLURM-USER-TOKEN": token,
                "X-SLURM-USER-NAME": username,
                "Content-Type": "application/json",
            },
            timeout=10,
        )

    jobs = resp.json().get("jobs", [])
    if not jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    state_str = jobs[0].get("job_state", ["UNKNOWN"])[0]

    # Get Traefik Proxy URL from our Port Manager database
    proxy_url = None
    if state_str == "RUNNING":
        lease = port_manager.get_lease_by_job(job_id)
        if lease:
            # Pointing to Traefik on port 8000
            proxy_url = f"http://localhost:8000/{lease.username}/jupyter/{lease.job_id}"

    return JSONResponse({"job_id": job_id, "state": state_str, "proxy_url": proxy_url})


@app.get("/jobs/{job_id}/log")
async def job_log(job_id: int, session: str | None = Cookie(default=None)):
    username, _ = get_current_user(session)
    log_path = Path(f"/mnt/storage/users/{username}/logs/jupyterlab_{job_id}.out")
    content = log_path.read_text() if log_path.exists() else "Log not yet available."
    return JSONResponse({"log": content})


# --- INTERNAL API FOR THE COMPUTE NODES ---
@app.post("/api/internal/allocate-port")
async def allocate_port(request: dict):
    port = port_manager.allocate_port(
        int(request["job_id"]),
        request["username"],
        request["node_hostname"],
        request["node_ip"],
    )
    return JSONResponse({"port": port})


@app.post("/api/internal/release-port")
async def release_port(request: dict):
    port_manager.release_port(int(request["job_id"]))
    return JSONResponse({"status": "released"})
