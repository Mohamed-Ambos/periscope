"""Session session manager — starts and destroys one disposable session per customer.

Deliberately thin. Its only jobs are: know the customers, call Docker, and
record what happened. Everything security-relevant (who may click, which
credentials exist) belongs outside it.
"""
import os
import json
import subprocess
import time
from datetime import datetime, timezone

import yaml
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse

PROJECT = os.environ.get("PROJECT_DIR", "/project")
DOMAIN = os.environ.get("LAB_DOMAIN", "localhost")
PORT = os.environ.get("TRAEFIK_HTTP_PORT", "8088")
PREFIX = "psc-"
SUFFIX = "-vpn"
AUDIT = os.path.join(PROJECT, "session-manager", "audit.log")

app = FastAPI(title="Session Manager")


def customers():
    with open(os.path.join(PROJECT, "session-manager", "customers.yml")) as fh:
        return yaml.safe_load(fh)["customers"]


def audit(action, cid, ok):
    line = f'{datetime.now(timezone.utc).isoformat()}\t{action}\t{cid}\t{"ok" if ok else "FAILED"}\n'
    with open(AUDIT, "a") as fh:
        fh.write(line)


def run(script, cid):
    """Sessions are started by the same scripts a human would run."""
    return subprocess.run(
        [os.path.join(PROJECT, "scripts", script), cid],
        cwd=PROJECT, capture_output=True, text=True, timeout=600,
    )


def live():
    """Which sessions exist right now. Docker is the source of truth."""
    names = subprocess.run(
        ["docker", "ps", "--filter", "name=-vpn", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    ).stdout.split()
    names = [n for n in names if n.startswith(PREFIX) and n.endswith(SUFFIX)]
    if not names:
        return {}
    out = subprocess.run(
        ["docker", "inspect", "-f", "{{.Name}}|{{.State.StartedAt}}", *names],
        capture_output=True, text=True,
    ).stdout
    sessions = {}
    for line in out.strip().splitlines():
        name, _, started = line.strip().lstrip("/").partition("|")
        if name.startswith(PREFIX) and name.endswith(SUFFIX):
            # Derive the id by name, not by offset: a hardcoded slice silently
            # returns the wrong key the moment the prefix changes length.
            cid = name.removeprefix(PREFIX).removesuffix(SUFFIX)
            sessions[cid] = {"started": started}
    return sessions


def audit_tail(n=14):
    """Recent activity, newest first. Evidence outlives the session itself."""
    try:
        with open(AUDIT) as fh:
            lines = fh.read().strip().splitlines()[-n:]
    except FileNotFoundError:
        return []
    events = []
    for line in reversed(lines):
        parts = line.split("\t")
        if len(parts) >= 4:
            events.append({"at": parts[0], "action": parts[1],
                           "customer": parts[2], "result": parts[3]})
    return events


@app.get("/api/sessions")
def api_sessions():
    return JSONResponse({"live": live()})


@app.post("/api/sessions/{cid}")
def api_start(cid: str):
    if cid not in {c["id"] for c in customers()}:
        raise HTTPException(404, "unknown customer")
    r = run("session-up.sh", cid)
    audit("start", cid, r.returncode == 0)
    if r.returncode != 0:
        raise HTTPException(500, r.stderr[-800:])
    return {"ok": True, "url": f"http://{cid}.{DOMAIN}:{PORT}/"}


@app.delete("/api/sessions/{cid}")
def api_stop(cid: str):
    r = run("session-down.sh", cid)
    audit("stop", cid, r.returncode == 0)
    return {"ok": r.returncode == 0}


@app.get("/api/state")
def api_state():
    """Everything the console draws, in one call. No server-side rendering."""
    return JSONResponse({
        "customers": customers(),
        "live": live(),
        "audit": audit_tail(),
        "domain": DOMAIN,
        "port": PORT,
    })


@app.get("/", response_class=HTMLResponse)
def index():
    # Read from the project mount rather than the image, so the console can be
    # restyled without rebuilding the container.
    with open(os.path.join(PROJECT, "session-manager", "console.html")) as fh:
        return fh.read()
