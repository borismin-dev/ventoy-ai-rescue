#!/usr/bin/env python3
"""rescue-agent - AI-Rescue-PE maintenance agent API.

Lets OTHER agents (e.g. a Muse-class agent on the LAN) drive this rescue
system for maintenance work. Listens on 0.0.0.0:8734 (HTTP JSON).

Endpoints:
  GET  /health          no auth - liveness only
  GET  /info            token - system information JSON
  GET|POST /diagnose    token - runs `ai-debug diagnose`, returns report JSON
                        (POST JSON {"llm": true} also asks the LLM if configured)
  POST /exec            token - {"cmd": "...", "timeout": 120} -> stdout/stderr/exitCode

Auth: a one-time token is generated at every boot (secrets.token_urlsafe),
stored ONLY in tmpfs at /run/rescue-token, shown ONLY on the local console
banner (with a QR code). The same token is set as the `rescue` user's SSH
password by rescue-boot. It is never baked into the ISO, never written to
persistent storage, never sent anywhere by this program.
Token transport: header `X-Rescue-Token: <token>`, or
`Authorization: Bearer <token>`, or `?token=<token>` query parameter.

Config: at startup the agent looks for rescue-config/agent.conf on the boot
USB (scan of removable partitions + the live medium). Recognised keys:
  AI_API_BASE, AI_API_KEY, AI_MODEL   - forwarded to ai-debug's LLM mode
  TUNNEL_HOST/USER/PORT/...           - used by rescue-boot for the ssh -R tunnel
The config file itself lives on the user's own USB stick; nothing in the ISO
contains any server, account, or key.
"""
import json, os, secrets, subprocess, sys, time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = 8734
TOKEN_PATH = "/run/rescue-token"
CONF_ENV_PATH = "/run/rescue-config.env"
VERSION = "1.0"

def find_agent_conf():
    """Return path of rescue-config/agent.conf found on a local partition, or None."""
    candidates = []
    # live medium first (the Ventoy partition when booted via Ventoy chainload,
    # or the ISO mount); then scan partitions
    for base in ("/run/live/medium", "/lib/live/mount/medium"):
        p = os.path.join(base, "rescue-config", "agent.conf")
        if os.path.isfile(p):
            return p
    try:
        out = subprocess.run(["lsblk", "-rno", "NAME,TYPE"], capture_output=True, text=True, timeout=10).stdout
        parts = [l.split()[0] for l in out.splitlines() if l.strip().endswith("part")]
    except Exception:
        parts = []
    import tempfile
    for part in parts:
        dev = f"/dev/{part}"
        mnt = tempfile.mkdtemp(prefix="cfgprobe-")
        try:
            r = subprocess.run(["mount", "-o", "ro", dev, mnt], capture_output=True, timeout=15)
            if r.returncode == 0:
                p = os.path.join(mnt, "rescue-config", "agent.conf")
                if os.path.isfile(p):
                    with open(p) as f:
                        data = f.read()
                    # copy content to tmpfs so we can unmount
                    with open("/run/agent.conf.from-usb", "w") as f:
                        f.write(data)
                    os.chmod("/run/agent.conf.from-usb", 0o600)
                    candidates.append("/run/agent.conf.from-usb")
                subprocess.run(["umount", mnt], capture_output=True, timeout=10)
        except Exception:
            pass
        try: os.rmdir(mnt)
        except Exception: pass
        if candidates:
            return candidates[0]
    return None

def load_config():
    env = {}
    path = find_agent_conf()
    if path:
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
            with open(CONF_ENV_PATH, "w") as f:
                for k, v in env.items():
                    f.write(f"{k}={v}\n")
            os.chmod(CONF_ENV_PATH, 0o600)
            print(f"[rescue-agent] loaded config from {path}: keys={sorted(env.keys())}", flush=True)
        except Exception as e:
            print(f"[rescue-agent] config load failed: {e}", flush=True)
    # process environment (systemd EnvironmentFile etc.) also counts
    for k in ("AI_API_BASE", "AI_API_KEY", "AI_MODEL"):
        if k in os.environ and k not in env:
            env[k] = os.environ[k]
    return env

CONFIG = {}
TOKEN = None

def get_token():
    global TOKEN
    if TOKEN:
        return TOKEN
    if os.path.exists(TOKEN_PATH):
        with open(TOKEN_PATH) as f:
            TOKEN = f.read().strip()
    else:
        TOKEN = secrets.token_urlsafe(18)
        with open(TOKEN_PATH, "w") as f:
            f.write(TOKEN + "\n")
        os.chmod(TOKEN_PATH, 0o600)
    return TOKEN

def run(cmd, timeout=120, extra_env=None):
    env = dict(os.environ)
    for k in ("AI_API_BASE", "AI_API_KEY", "AI_MODEL"):
        if k in CONFIG:
            env[k] = CONFIG[k]
    if extra_env:
        env.update(extra_env)
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout, env=env)
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        return (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), f"timeout after {timeout}s", 124

def sys_info():
    out, _, _ = run("hostname; uname -r; uptime", timeout=10)
    ips, _, _ = run("ip -brief -4 a | grep -v '^lo'", timeout=10)
    lsblk, _, _ = run("lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null", timeout=10)
    try:
        disks = json.loads(lsblk) if lsblk.strip() else {}
    except Exception:
        disks = {"raw": lsblk}
    tunnel = "off"
    if os.path.exists("/run/tunnel.status"):
        with open("/run/tunnel.status") as f:
            tunnel = f.read().strip()
    return {
        "hostname": "ai-rescue",
        "mdns": "ai-rescue.local",
        "agent_version": VERSION,
        "time": datetime.now().isoformat(),
        "system": out.strip().splitlines(),
        "ipv4": [l.strip() for l in ips.splitlines() if l.strip()],
        "disks": disks,
        "llm_configured": bool(CONFIG.get("AI_API_KEY")),
        "llm_model": CONFIG.get("AI_MODEL") if CONFIG.get("AI_API_KEY") else None,
        "tunnel": tunnel,
        "api_port": PORT,
        "ssh": "ssh rescue@ai-rescue.local  (password = boot token shown on console)",
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[rescue-agent] %s %s\n" % (self.address_string(), fmt % args))

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        tok = get_token()
        given = (self.headers.get("X-Rescue-Token")
                 or (self.headers.get("Authorization", "").removeprefix("Bearer ").strip() or None)
                 or parse_qs(urlparse(self.path).query).get("token", [None])[0])
        return given is not None and secrets.compare_digest(given, tok)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode() or "{}")
        except Exception:
            return {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            return self._json(200, {"status": "ok", "service": "rescue-agent",
                                    "version": VERSION, "hostname": "ai-rescue",
                                    "time": datetime.now().isoformat()})
        if not self._authed():
            return self._json(401, {"error": "unauthorized",
                                    "hint": "send the boot token via X-Rescue-Token header, Authorization: Bearer, or ?token= ; the token is printed on the machine's console at boot"})
        if path == "/info":
            return self._json(200, sys_info())
        if path == "/diagnose":
            return self._diagnose(self._body())
        return self._json(404, {"error": "not found", "endpoints": ["/health", "/info", "/diagnose", "/exec"]})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/health":
            return self.do_GET()
        if not self._authed():
            return self._json(401, {"error": "unauthorized"})
        if path == "/diagnose":
            return self._diagnose(self._body())
        if path == "/exec":
            body = self._body()
            cmd = body.get("cmd", "")
            if not cmd:
                return self._json(400, {"error": "cmd is required"})
            timeout = min(int(body.get("timeout", 120)), 600)
            stdout, stderr, code = run(cmd, timeout=timeout)
            return self._json(200, {"cmd": cmd, "exitCode": code,
                                    "stdout": stdout[-65536:], "stderr": stderr[-16384:]})
        return self._json(404, {"error": "not found"})

    def _diagnose(self, body):
        cmd = "ai-debug diagnose"
        if body.get("llm"):
            cmd += " --llm"
        stdout, stderr, code = run(cmd, timeout=300)
        report = ""
        if os.path.exists("/tmp/ai-report.txt"):
            with open("/tmp/ai-report.txt") as f:
                report = f.read()
        return self._json(200, {"exitCode": code, "report": report or stdout,
                                "stderr_tail": stderr[-2000:],
                                "llm_used": bool(body.get("llm") and CONFIG.get("AI_API_KEY"))})

def main():
    global CONFIG
    CONFIG = load_config()
    get_token()
    print(f"[rescue-agent] listening on 0.0.0.0:{PORT} (token on console banner only)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
