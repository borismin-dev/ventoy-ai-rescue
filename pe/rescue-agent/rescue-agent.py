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
  POST /action          token - one-click maintenance actions (v2): {"action": "cleanup",
                        "dry_run": bool} works on mounted Windows volumes; fixboot
                        answers {"error": "not supported on linux-pe"}

Auth: a one-time token is generated at every boot (secrets.token_urlsafe),
stored ONLY in tmpfs at /run/rescue-token, shown ONLY on the local console
banner (with a QR code). The same token is set as the `rescue` user's SSH
password by rescue-boot. It is never baked into the ISO, never written to
persistent storage, never sent anywhere by this program.
Exception (v2): if rescue-config/agent.conf sets RESCUE_TOKEN (>= 8 chars),
that fixed token is used instead of the random per-boot one, so other
agents can be configured once. It then lives on the user's own USB stick
(their choice), still only copied to tmpfs at runtime.
Token transport: header `X-Rescue-Token: <token>`, or
`Authorization: Bearer <token>`, or `?token=<token>` query parameter.

Config: at startup the agent looks for rescue-config/agent.conf on the boot
USB (scan of removable partitions + the live medium). Recognised keys:
  AI_API_BASE, AI_API_KEY, AI_MODEL   - forwarded to ai-debug's LLM mode
  TUNNEL_HOST/USER/PORT/...           - used by rescue-boot for the ssh -R tunnel
  RESCUE_TOKEN                        - optional fixed agent token (>= 8 chars)
The config file itself lives on the user's own USB stick; nothing in the ISO
contains any server, account, or key.
"""
import json, os, secrets, shutil, subprocess, sys, time
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
            print(f"[rescue-agent] 已从 {path} 加载配置：keys={sorted(env.keys())}", flush=True)
        except Exception as e:
            print(f"[rescue-agent] 配置加载失败：{e}", flush=True)
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
    # Fixed token from rescue-config/agent.conf (RESCUE_TOKEN, >= 8 chars)
    # when configured: stable across reboots/agent restarts. Written to
    # TOKEN_PATH so rescue-boot (banner + SSH password) uses the same one.
    fixed = (CONFIG.get("RESCUE_TOKEN") or "").strip()
    if len(fixed) >= 8:
        TOKEN = fixed
        try:
            with open(TOKEN_PATH, "w") as f:
                f.write(TOKEN + "\n")
            os.chmod(TOKEN_PATH, 0o600)
        except Exception:
            pass
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

def _panel_extras():
    """Read-only extras for the status panel (v2 item 9): memory, mounted
    filesystem volumes, and per-disk SMART verdicts."""
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem["total"] = int(line.split()[1]) * 1024
                elif line.startswith("MemAvailable:"):
                    mem["avail"] = int(line.split()[1]) * 1024
    except Exception:
        pass
    vols = []
    out, _, _ = run("df -B1 -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null", timeout=10)
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        try:
            total = int(parts[1]); free = int(parts[3])
        except Exception:
            continue
        vols.append({"mount": " ".join(parts[5:]), "total": total, "free": free})
    smart = []
    exe = shutil.which("smartctl") or ("/usr/sbin/smartctl" if os.path.exists("/usr/sbin/smartctl") else None)
    if exe:
        names, _, _ = run("lsblk -dn -o NAME,TYPE | awk '$2==\"disk\"{print $1}'", timeout=10)
        for name in names.split()[:6]:
            o, _, _ = run(f"{exe} -H /dev/{name} 2>/dev/null | grep -iE 'overall-health|SMART.*(PASSED|FAILED)' | head -1", timeout=12)
            smart.append({"device": f"/dev/{name}", "verdict": o.strip() or "unknown"})
    return mem, vols, smart

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
    mem, vols, smart = _panel_extras()
    return {
        "hostname": "ai-rescue",
        "mdns": "ai-rescue.local",
        "agent_version": VERSION,
        "time": datetime.now().isoformat(),
        "system": out.strip().splitlines(),
        "ipv4": [l.strip() for l in ips.splitlines() if l.strip()],
        "disks": disks,
        "memory": mem,
        "volumes": vols,
        "smart": smart,
        "llm_configured": bool(CONFIG.get("AI_API_KEY")),
        "llm_model": CONFIG.get("AI_MODEL") if CONFIG.get("AI_API_KEY") else None,
        "tunnel": tunnel,
        "api_port": PORT,
        "ssh": "ssh rescue@ai-rescue.local（密码 = 本机控制台横幅上的开机令牌）",
    }

# ---------- v2 item 9: read-only status panel ----------
# The same single panel.html the Windows agent embeds. Its JS only calls
# GET /info and GET /diagnose; there is no way to operate anything from it.
_PANEL_CANDIDATES = [
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "panel.html"),
    "/usr/local/share/rescue-panel.html",
    "/usr/local/bin/panel.html",
]

def _load_panel():
    for p in _PANEL_CANDIDATES:
        try:
            with open(p, "rb") as f:
                return f.read()
        except Exception:
            pass
    return None

PANEL_HTML = _load_panel()

PANEL_401 = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI-Rescue 维护面板</title></head>
<body style="font-family:sans-serif;background:#f4f6f8;color:#1c2733;padding:24px">
<h2>令牌缺失或无效（401）</h2>
<p>这个只读面板需要令牌才能打开。请扫描 PE 屏幕上的二维码，或使用控制台横幅里带
?token= 的完整地址访问。</p>
</body></html>""".encode()

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

    def _html(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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
        if path in ("/", "/index.html"):
            # read-only panel (item 9): same auth as the API; a missing or
            # wrong token gets the 401 hint page, never the panel itself
            if not self._authed():
                return self._html(401, PANEL_401)
            if PANEL_HTML is None:
                return self._json(404, {"error": "panel.html not installed"})
            return self._html(200, PANEL_HTML)
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
        if path == "/action":
            body = self._body()
            act = body.get("action", "")
            if act == "cleanup":
                return self._json(200, action_cleanup(bool(body.get("dry_run"))))
            if act == "fixboot":
                return self._json(200, {"action": act, "error": "not supported on linux-pe"})
            return self._json(400, {"error": f"unknown action: {act} (supported: cleanup; fixboot is Windows-PE only)"})
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

# ---------- v2 item 8: /action cleanup (Linux PE) ----------
# Fixed whitelist, same paths as the Windows build. Only volumes that are
# already mounted read-write and carry a Windows installation are touched;
# pagefile.sys / hiberfil.sys / Prefetch are never in the whitelist.

def _rw_windows_mounts():
    mounts = []
    try:
        with open("/proc/mounts") as f:
            lines = f.read().splitlines()
    except Exception:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        mnt = parts[1].replace("\\040", " ")
        if "ro" in parts[3].split(","):
            continue
        if mnt == "/" or mnt.startswith(("/proc", "/sys", "/dev", "/run", "/lib/live", "/tmp", "/var")):
            continue
        if os.path.isdir(os.path.join(mnt, "Windows")):
            mounts.append(mnt)
    return mounts

def _dir_stats(root):
    size = 0
    files = 0
    for dp, _dn, fn in os.walk(root):
        for name in fn:
            try:
                size += os.path.getsize(os.path.join(dp, name))
                files += 1
            except OSError:
                pass
    return size, files

def _clear_contents(path, dry_run, only_exts=None):
    t = {"path": path, "dry_run": dry_run, "size_before": 0, "size_after": 0, "files_removed": 0}
    if not os.path.isdir(path):
        t["note"] = "not present"
        return t
    before, _ = _dir_stats(path)
    t["size_before"] = before
    removed = 0
    if dry_run:
        t["size_after"] = before
        t["note"] = "dry-run: nothing deleted"
        return t
    if only_exts:
        for dp, _dn, fn in os.walk(path):
            for name in fn:
                if os.path.splitext(name)[1].lower() in only_exts:
                    try:
                        os.remove(os.path.join(dp, name))
                        removed += 1
                    except OSError:
                        pass
    else:
        for name in os.listdir(path):
            p = os.path.join(path, name)
            try:
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p)
                else:
                    os.remove(p)
                removed += 1
            except OSError:
                pass
    after, _ = _dir_stats(path)
    t["size_after"] = after
    t["files_removed"] = removed
    return t

def action_cleanup(dry_run):
    vols = _rw_windows_mounts()
    out = {"action": "cleanup", "dry_run": dry_run, "volumes": []}
    total_freed = 0
    for mnt in vols:
        targets = [
            _clear_contents(os.path.join(mnt, "Windows", "Temp"), dry_run),
            _clear_contents(os.path.join(mnt, "Windows", "SoftwareDistribution", "Download"), dry_run),
            _clear_contents(os.path.join(mnt, "Windows", "Logs", "CBS"), dry_run, only_exts={".log", ".cab"}),
            _clear_contents(os.path.join(mnt, "$Recycle.Bin"), dry_run),
        ]
        users = os.path.join(mnt, "Users")
        if os.path.isdir(users):
            for name in sorted(os.listdir(users)):
                targets.append(_clear_contents(
                    os.path.join(users, name, "AppData", "Local", "Temp"), dry_run))
        freed = sum(t["size_before"] - t["size_after"] for t in targets)
        total_freed += freed
        out["volumes"].append({"volume": mnt, "targets": targets, "freed_bytes": freed})
    if not vols:
        out["note"] = "no read-write mounted volume with a Windows installation found (mount one rw first)"
    out["total_freed_bytes"] = total_freed
    out["summary"] = f"cleanup dry_run={dry_run} on {len(vols)} volume(s), freed {total_freed} bytes"
    return out

def main():
    global CONFIG
    CONFIG = load_config()
    get_token()
    src = "固定（agent.conf）" if len((CONFIG.get("RESCUE_TOKEN") or "").strip()) >= 8 else "随机（每次开机生成）"
    print(f"[rescue-agent] 令牌来源：{src}", flush=True)
    print(f"[rescue-agent] 正在监听 0.0.0.0:{PORT}（令牌仅显示在本机控制台横幅上）", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

if __name__ == "__main__":
    main()
