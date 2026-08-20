"""Session session manager — starts and destroys one disposable session per customer.

Deliberately thin. Its only jobs are: know the customers, call Docker, and
record what happened. Everything security-relevant (who may click, which
credentials exist) belongs outside it.
"""
import os
import subprocess
import time
from datetime import datetime, timezone

import yaml
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse

PROJECT = os.environ.get("PROJECT_DIR", "/project")
DOMAIN = os.environ.get("LAB_DOMAIN", "localhost")
PORT = os.environ.get("TRAEFIK_HTTP_PORT", "8088")
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
    out = subprocess.run(
        ["docker", "ps", "--filter", "name=-vpn", "--format", "{{.Names}}\t{{.Status}}"],
        capture_output=True, text=True,
    ).stdout
    sessions = {}
    for line in out.strip().splitlines():
        if not line.strip():
            continue
        name, _, status = line.partition("\t")
        if name.startswith("sb-") and name.endswith("-vpn"):
            sessions[name[3:-4]] = status
    return sessions


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


@app.get("/", response_class=HTMLResponse)
def index():
    running = live()
    rows = []
    for c in customers():
        on = c["id"] in running
        state = ('<span class="live">● live</span>' if on
                 else '<span class="off">○ stopped</span>')
        btn = (f'<button class="stop" onclick="act(\'{c["id"]}\',\'DELETE\')">Stop</button>'
               f'<a class="open" href="http://{c["id"]}.{DOMAIN}:{PORT}/" target="_blank">Open</a>'
               if on else
               f'<button onclick="act(\'{c["id"]}\',\'POST\')">Connect</button>')
        rows.append(
            f'<tr><td><strong>{c["name"]}</strong><br><span class="sub">{c["site"]} · '
            f'{c["devices"]} devices · {c["vpn"]}</span></td>'
            f'<td>{state}</td><td class="act">{btn}</td></tr>')
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>Session Manager</title><style>
body{{font:15px/1.6 system-ui,sans-serif;background:#0f1519;color:#e2e9ef;margin:0;padding:40px 24px}}
.wrap{{max-width:760px;margin:0 auto}}
h1{{font-size:22px;margin:0 0 4px}} .lede{{color:#8496a4;margin:0 0 28px;font-size:14px}}
table{{width:100%;border-collapse:collapse}}
td{{padding:14px 10px;border-bottom:1px solid #22303a;vertical-align:middle}}
.sub{{color:#7e919f;font-size:12.5px}}
.live{{color:#4cbb80;font-weight:600}} .off{{color:#6d7f8c}}
.act{{text-align:right;white-space:nowrap}}
button,a.open{{font:inherit;font-size:13.5px;padding:7px 14px;border-radius:6px;cursor:pointer;
  border:1px solid #2f6f9c;background:#173044;color:#cfe6f5;text-decoration:none;display:inline-block}}
button.stop{{border-color:#7a4a2a;background:#3a2416;color:#f0d6c2;margin-right:8px}}
#msg{{margin-top:18px;color:#8496a4;font-size:13px;min-height:20px}}
</style></head><body><div class="wrap">
<h1>Session Manager</h1>
<p class="lede">One disposable session per customer. Nothing is connected until you connect it.</p>
<table>{''.join(rows)}</table>
<div id="msg"></div>
<script>
async function act(id, method) {{
  document.getElementById('msg').textContent =
    (method === 'POST' ? 'Starting ' : 'Stopping ') + id + '…';
  const r = await fetch('/api/sessions/' + id, {{method}});
  const j = await r.json().catch(() => ({{}}));
  document.getElementById('msg').textContent = r.ok ? 'Done.' : ('Failed: ' + (j.detail || r.status));
  setTimeout(() => location.reload(), 900);
}}
</script></div></body></html>"""
