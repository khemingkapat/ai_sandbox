import jwt
import time
import os
import httpx
from pathlib import Path
from fastapi import FastAPI, Request, Form, HTTPException, Cookie
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="HPC Portal")
templates = Jinja2Templates(directory="templates")

SLURMRESTD_URL = os.getenv("SLURMRESTD_URL", "http://slurmrestd:6820")
JWT_KEY_PATH = os.getenv("JWT_KEY_PATH", "/var/spool/slurmctld/jwt_hs256.key")
TOKEN_LIFESPAN = int(os.getenv("TOKEN_LIFESPAN", "1800"))  # seconds, default 30min

APPS = [
    {
        "id": "jupyterlab",
        "name": "JupyterLab",
        "description": "Interactive Python notebook environment",
        "script_path": "/mnt/storage/users/{username}/run_jupyterlab.sh",
        "icon": "⬡",
    }
]

USERS = ["user1", "root"]


# ---------------------------------------------------------------------------
# JWT helpers
# ---------------------------------------------------------------------------


def _read_slurm_key() -> str:
    key_path = Path(JWT_KEY_PATH)
    if not key_path.exists():
        raise HTTPException(
            status_code=500,
            detail=f"Slurm JWT key not found at {JWT_KEY_PATH}. "
            "Check that the slurm_state volume is mounted correctly.",
        )
    # Key may be raw binary or text — read as bytes to handle both
    return key_path.read_bytes()


def make_slurm_token(username: str) -> str:
    """
    Sign a Slurm-compatible JWT using the cluster's own HS256 key.
    The token is valid for TOKEN_LIFESPAN seconds and can be sent
    directly to slurmrestd as X-SLURM-USER-TOKEN — no translation needed.
    """
    key = _read_slurm_key()
    now = int(time.time())
    payload = {
        "sun": username,  # Slurm's username claim
        "iat": now,
        "exp": now + TOKEN_LIFESPAN,
    }
    return jwt.encode(payload, key, algorithm="HS256")


def verify_session_token(token: str) -> str:
    """
    Verify the session cookie and return the username.
    Same key, so one token works for both session validation
    and Slurm API calls — no separate session store needed.
    """
    key = _read_slurm_key()
    try:
        payload = jwt.decode(token, key, algorithms=["HS256"])
        return payload["sun"]
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Session expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid session")


def slurm_headers(token: str, username: str) -> dict:
    return {
        "X-SLURM-USER-TOKEN": token,
        "X-SLURM-USER-NAME": username,
        "Content-Type": "application/json",
    }


def get_current_user(session: str | None) -> tuple[str, str]:
    """Return (username, token) from session cookie or raise 401."""
    if not session:
        raise HTTPException(status_code=401, detail="Not logged in")
    username = verify_session_token(session)
    return username, session  # the session cookie IS the Slurm token


# ---------------------------------------------------------------------------
# Auth routes
# ---------------------------------------------------------------------------


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "users": USERS,
        },
    )


@app.post("/login")
async def login(username: str = Form(...)):
    if username not in USERS:
        raise HTTPException(status_code=400, detail="Unknown user")

    token = make_slurm_token(username)

    response = RedirectResponse(url="/", status_code=303)
    response.set_cookie(
        key="session",
        value=token,
        httponly=True,
        max_age=TOKEN_LIFESPAN,
        samesite="lax",
    )
    return response


@app.get("/logout")
async def logout():
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie("session")
    return response


# ---------------------------------------------------------------------------
# Main portal — requires valid session
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
async def index(request: Request, session: str | None = Cookie(default=None)):
    if not session:
        return RedirectResponse(url="/login")
    try:
        username = verify_session_token(session)
    except HTTPException:
        return RedirectResponse(url="/login")

    key = _read_slurm_key()
    payload = jwt.decode(session, key, algorithms=["HS256"])
    expires_in = payload["exp"] - int(time.time())

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "username": username,
            "apps": APPS,
            "expires_in": expires_in,
        },
    )


# ---------------------------------------------------------------------------
# Job routes
# ---------------------------------------------------------------------------


@app.post("/jobs/submit")
async def submit_job(
    app_id: str = Form(...),
    session: str | None = Cookie(default=None),
):
    username, token = get_current_user(session)

    app_def = next((a for a in APPS if a["id"] == app_id), None)
    if not app_def:
        raise HTTPException(status_code=400, detail="Unknown app")

    # Read script directly from mounted storage — no docker exec needed
    script_path = Path(app_def["script_path"].format(username=username))
    if not script_path.exists():
        raise HTTPException(
            status_code=500,
            detail=f"Script not found at {script_path}. "
            "Ensure the storage volume is mounted.",
        )
    script_content = script_path.read_text()

    home = f"/mnt/storage/users/{username}" if username != "root" else "/root"
    payload = {
        "job": {
            "current_working_directory": home,
            "environment": {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": home,
                "USER": username,
            },
        },
        "script": script_content,
    }

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{SLURMRESTD_URL}/slurm/v0.0.42/job/submit",
            headers=slurm_headers(token, username),
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
            headers=slurm_headers(token, username),
            timeout=10,
        )

    data = resp.json()
    jobs = data.get("jobs", [])
    if not jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    job = jobs[0]
    state = job.get("job_state", ["UNKNOWN"])
    state_str = state[0] if isinstance(state, list) else state
    node = job.get("nodes", "")

    # Read log directly from mounted volume — no docker exec needed
    connect_url = None
    node_ip = None
    if state_str == "RUNNING" and node:
        log_path = Path(f"/mnt/storage/users/{username}/logs/jupyterlab_{job_id}.out")
        if log_path.exists():
            for line in log_path.read_text().splitlines():
                if "Node IP:" in line:
                    node_ip = line.split("Node IP:")[-1].strip()
                    connect_url = f"http://{node_ip}:8888"
                    break

    return JSONResponse(
        {
            "job_id": job_id,
            "state": state_str,
            "node": node,
            "node_ip": node_ip,
            "connect_url": connect_url,
        }
    )


@app.get("/jobs/{job_id}/log")
async def job_log(job_id: int, session: str | None = Cookie(default=None)):
    username, _ = get_current_user(session)
    log_path = Path(f"/mnt/storage/users/{username}/logs/jupyterlab_{job_id}.out")
    content = log_path.read_text() if log_path.exists() else "Log not yet available."
    return JSONResponse({"log": content})
