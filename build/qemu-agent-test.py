#!/usr/bin/env python3
"""QEMU verification for AI-Rescue-PE v2 agent chain (runs on InstaBox host).

Boots AI-Rescue-PE.iso (kernel direct; live squashfs from the CD-ROM) with a
user-mode NIC and host forwards:
  host 18734 -> guest 8734 (rescue-agent API)
  host 10022 -> guest 22   (OpenSSH)
The serial console is logged to a file; the per-boot TOKEN is parsed from the
banner line `RESCUE-TOKEN: ...` in that log (exactly what a human would read
off the screen). Then, from the host, like any external agent would:
  curl /health, /info, /diagnose, /exec   and   ssh rescue@... with the token.
mDNS (ai-rescue.local) cannot be exercised over QEMU user networking and is
reported as unverified in this environment.
"""
import json, re, subprocess, sys, time, urllib.request

ISO = "/data/home/dist/AI-Rescue-PE.iso"
LIVE = "/data/home/build/pe/iso/live"
SERIAL_LOG = "/data/home/logs/qemu-agent-serial.log"
RESULT_LOG = "/data/home/logs/qemu-agent-test.log"
REPORT_TXT = "/data/home/logs/qemu-pe-report.txt"
TIMEOUT = 900

results = []
def note(msg):
    print(msg, flush=True)
    results.append(msg)

def curl(url, token=None, timeout=30, data=None):
    req = urllib.request.Request(url, data=data)
    if token:
        req.add_header("X-Rescue-Token", token)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode(errors="replace")

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-netdev", "user,id=n0,hostfwd=tcp::18734-:8734,hostfwd=tcp::10022-:22",
    "-device", "e1000,netdev=n0",
    "-display", "none",
    "-chardev", f"socket,path=/tmp/qemu-agent-serial.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
    "-serial", "chardev:ser0",
    "-monitor", "none",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

token = None
start = time.time()
while time.time() - start < TIMEOUT:
    try:
        with open(SERIAL_LOG, errors="replace") as f:
            m = re.findall(r"RESCUE-TOKEN:\s*(\S+)", f.read())
            if m:
                token = m[-1]
                break
    except FileNotFoundError:
        pass
    time.sleep(5)
note(f"token_from_serial_banner={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s")
if token:
    note(f"token_length={len(token)} (value not written to the result log)")

if token:
    # wait for API
    health = None
    t0 = time.time()
    while time.time() - t0 < 300:
        try:
            code, body = curl("http://127.0.0.1:18734/health", timeout=10)
            health = (code, body); break
        except Exception:
            time.sleep(5)
    note(f"GET /health -> {health[0] if health else 'FAILED'} {health[1][:200] if health else ''}")
    try:
        code, body = curl("http://127.0.0.1:18734/info", token=token, timeout=30)
        info = json.loads(body)
        note(f"GET /info -> {code} hostname={info.get('hostname')} mdns={info.get('mdns')} ipv4={info.get('ipv4')} llm_configured={info.get('llm_configured')} tunnel={info.get('tunnel')}")
    except Exception as e:
        note(f"GET /info FAILED: {e}")
    try:
        code, body = curl("http://127.0.0.1:18734/diagnose", token=token, timeout=600)
        diag = json.loads(body)
        note(f"GET /diagnose -> {code} exitCode={diag.get('exitCode')} report_chars={len(diag.get('report',''))}")
        with open(REPORT_TXT, "w") as f:
            f.write(diag.get("report", ""))
    except Exception as e:
        note(f"GET /diagnose FAILED: {e}")
    try:
        payload = json.dumps({"cmd": "echo AGENT-EXEC-OK; whoami; hostname"}).encode()
        req = urllib.request.Request("http://127.0.0.1:18734/exec", data=payload)
        req.add_header("X-Rescue-Token", token)
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=120) as r:
            ex = json.loads(r.read().decode())
        note(f"POST /exec -> exitCode={ex.get('exitCode')} stdout={ex.get('stdout','').strip()[:200]!r}")
    except Exception as e:
        note(f"POST /exec FAILED: {e}")
    # unauthenticated /diagnose must be rejected
    try:
        curl("http://127.0.0.1:18734/diagnose", timeout=15)
        note("AUTH-CHECK FAILED: /diagnose without token returned success")
    except urllib.error.HTTPError as e:
        note(f"auth check: /diagnose without token -> HTTP {e.code} (expected 401)")
    except Exception as e:
        note(f"auth check inconclusive: {e}")
    # SSH with the token as password (sshpass on the host)
    try:
        r = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10022",
                            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                            "-o", "ConnectTimeout=20", "rescue@127.0.0.1",
                            "echo SSH-AGENT-OK; whoami; hostname; ai-debug diagnose | head -5"],
                           capture_output=True, text=True, timeout=300)
        ok = "SSH-AGENT-OK" in r.stdout
        note(f"SSH login with boot token -> {'OK' if ok else 'FAILED'} rc={r.returncode} out={r.stdout.strip()[:300]!r} err={r.stderr.strip()[:200]!r}")
    except Exception as e:
        note(f"SSH test FAILED: {e}")

with open(RESULT_LOG, "w") as f:
    f.write("\n".join(results) + "\n")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
note("QEMU-AGENT-TEST-DONE")
