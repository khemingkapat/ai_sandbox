#!/usr/bin/env python3
"""
scripts/mock-lms.py — Local-machine-only makeshift LMS demo server for WP12-B.

Simulates an external University LMS landing page running on http://localhost:9090
that mints HS256 dev JWTs for preset personas (student1, instructor1, admin1)
and redirects straight into the AI Sandbox SSO bridge:
  <PORTAL_URL>/api/auth/sso?token=<JWT>&redirect=/launch?lab=<relpath>

NEVER deploy this script into Kubernetes.
"""

import argparse
import base64
import hashlib
import hmac
import html
import json
import os
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PERSONAS = [
    {"id": "user1", "label": "Student (user1)", "role": "student", "desc": "Read-only labs/ mount; clone to my_labs/ to edit"},
    {"id": "instructor1", "label": "Instructor (instructor1)", "role": "instructor", "desc": "Read-write labs/ mount (GID 2999) for authoring"},
    {"id": "admin1", "label": "Admin (admin1)", "role": "admin", "desc": "Full cluster admin + read-write labs/ mount"},
]


def mint_hs256_jwt(sub: str, role: str, secret: str, ttl: int = 1800) -> str:
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")
    now = int(time.time())
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps({
        "iss": "university-sso",
        "sub": sub,
        "aud": "cpe-ai-sandbox",
        "role": role,
        "iat": now,
        "exp": now + ttl,
    }, separators=(",", ":")).encode())
    sig = b64(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"


def discover_labs(labs_dir: Path) -> list[str]:
    if not labs_dir.is_dir():
        return []
    found = []
    for p in sorted(labs_dir.rglob("*.ipynb")):
        if any(part.startswith(".") for part in p.relative_to(labs_dir).parts):
            continue
        found.append(p.relative_to(labs_dir).as_posix())
    return found


def make_handler(portal_url: str, jwt_secret: str, labs_dir: Path):
    portal_url = portal_url.rstrip("/")

    class MockLMSHandler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            print(f"[mock-lms] {self.address_string()} - {fmt % args}")

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parsed.query)
            selected = qs.get("persona", ["user1"])[0]
            persona = next((p for p in PERSONAS if p["id"] == selected), PERSONAS[0])

            token = mint_hs256_jwt(persona["id"], persona["role"], jwt_secret)
            labs = discover_labs(labs_dir)

            dashboard_url = f"{portal_url}/api/auth/sso?token={urllib.parse.quote(token)}&redirect=/"

            persona_btns = []
            for p in PERSONAS:
                active = "border:#38bdf8;background:#0c4a6e;" if p["id"] == persona["id"] else "border:#334155;background:#1e293b;"
                persona_btns.append(
                    f'<a href="/?persona={urllib.parse.quote(p["id"])}" '
                    f'style="display:block;padding:12px 16px;border-radius:8px;border:1px solid;{active}color:#f8fafc;text-decoration:none;flex:1;min-width:180px;">'
                    f'<div style="font-weight:700;">{html.escape(p["label"])}</div>'
                    f'<div style="font-size:12px;color:#94a3b8;margin-top:4px;">{html.escape(p["desc"])}</div>'
                    f'</a>'
                )

            lab_cards = []
            for rel in labs:
                redirect = f"/launch?lab={rel}"
                sso_launch = f"{portal_url}/api/auth/sso?token={urllib.parse.quote(token)}&redirect={urllib.parse.quote(redirect)}"
                title = Path(rel).stem.replace("_", " ").replace("-", " ")
                lab_cards.append(
                    f'<div style="display:flex;justify-content:space-between;align-items:center;padding:14px 18px;border:1px solid #334155;border-radius:8px;background:#1e293b;margin-bottom:10px;gap:12px;flex-wrap:wrap;">'
                    f'<div><div style="font-weight:600;color:#f8fafc;">{html.escape(title)}</div>'
                    f'<div style="font-size:12px;color:#94a3b8;font-family:monospace;">{html.escape(rel)}</div></div>'
                    f'<a href="{html.escape(sso_launch)}" target="_blank" rel="noopener" '
                    f'style="padding:8px 14px;border-radius:6px;background:#0ea5e9;color:#0f172a;font-weight:700;text-decoration:none;">'
                    f'One-Click Launch →</a>'
                    f'</div>'
                )

            if not lab_cards:
                lab_cards.append(
                    f'<div style="padding:16px;color:#94a3b8;">No .ipynb files found in <code>{html.escape(str(labs_dir))}</code>.</div>'
                )

            page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Mock University LMS — AI Sandbox SSO Demo</title>
</head>
<body style="margin:0;padding:32px;background:#0f172a;color:#e2e8f0;font-family:system-ui,-apple-system,sans-serif;line-height:1.5;">
  <div style="max-width:860px;margin:0 auto;">
    <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;margin-bottom:24px;">
      <div>
        <div style="font-size:12px;letter-spacing:.08em;color:#38bdf8;font-weight:700;">LOCAL DEV MOCK LMS (NEVER DEPLOY TO K8S)</div>
        <h1 style="margin:4px 0 0;font-size:24px;">CPE AI Engineering — Course Portal</h1>
      </div>
      <a href="{html.escape(dashboard_url)}" target="_blank" rel="noopener"
         style="padding:10px 16px;border-radius:6px;border:1px solid #38bdf8;color:#38bdf8;text-decoration:none;font-weight:600;">
        Open Sandbox Dashboard (Browse &amp; Clone) ↗
      </a>
    </div>

    <div style="margin-bottom:24px;">
      <div style="font-size:13px;color:#94a3b8;margin-bottom:8px;">1. Select SSO Persona (mints HS256 JWT targeting <code>{html.escape(portal_url)}</code>):</div>
      <div style="display:flex;gap:12px;flex-wrap:wrap;">
        {''.join(persona_btns)}
      </div>
    </div>

    <div>
      <div style="font-size:13px;color:#94a3b8;margin-bottom:8px;">2. Launch a Lab Directly (SSO → /launch?lab=... → JupyterLab):</div>
      {''.join(lab_cards)}
    </div>
  </div>
</body>
</html>"""
            body = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return MockLMSHandler


def main():
    repo_root = Path(__file__).resolve().parent.parent
    default_labs = repo_root / "templates" / "projects" / "project1" / "starter_labs"

    parser = argparse.ArgumentParser(description="Local makeshift LMS for WP12-B SSO + /launch demos")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MOCK_LMS_PORT", "9090")))
    parser.add_argument("--portal-url", default=os.environ.get("PORTAL_URL", "http://localhost:8080"))
    parser.add_argument("--secret", default=os.environ.get("UNIVERSITY_JWT_SECRET", "mock-university-jwt-secret-shared-with-portal"))
    parser.add_argument("--labs-dir", default=os.environ.get("LABS_DIR", str(default_labs)))
    args = parser.parse_args()

    handler = make_handler(args.portal_url, args.secret, Path(args.labs_dir))
    server = HTTPServer(("127.0.0.1", args.port), handler)
    print(f"Mock LMS running at http://127.0.0.1:{args.port} -> Portal: {args.portal_url}")
    print(f"Scanning labs from: {args.labs_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Mock LMS.")


if __name__ == "__main__":
    main()
