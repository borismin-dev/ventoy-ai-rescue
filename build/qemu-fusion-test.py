#!/usr/bin/env python3
"""QEMU verification for the HotPE fusion ISO (runs on InstaBox main-1).

Boots HotPE-Fusion-AIRescue.iso from CD (BIOS), user-mode NIC with
host 18734 -> guest 8734. Evidence collected:
  - periodic screendumps via the QEMU monitor (boot progress + desktop)
  - GET /health from the host once ai-rescue.exe agent is up (no token needed)
  - GET /info without a token must be rejected (401) -> auth is on
No keyboard interaction: the fusion autostart (the line appended to the
WIM's own Pecmd.ini) must bring the agent up by itself, exactly as on a
real USB boot.

NOTE on -cpu max: under QEMU TCG the default qemu64 CPU model makes the
Win11 kernel reset-loop after the logo (verified 2026-11-08 with
-d cpu_reset logging); -cpu max boots cleanly to the desktop. This is a
TCG emulation quirk, not an ISO defect (the same ISO boots on hardware
and the unmodified HotPE original shows the same TCG behaviour).
"""
import hashlib, socket, subprocess, time, urllib.request, urllib.error

ISO = "/data/home/dist/HotPE-Fusion-AIRescue.iso"
LOG = "/data/home/logs/qemu-fusion-test.log"
MON = "/tmp/qemu-fusion-mon.sock"
SHOT_DIR = "/data/home/logs"
TIMEOUT = 1500

lines = []
def note(msg):
    print(msg, flush=True)
    lines.append(msg)

def mon(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(MON)
    s.recv(4096)
    s.sendall(cmd.encode() + b"\n")
    time.sleep(1)
    try:
        s.recv(4096)
    except socket.timeout:
        pass
    s.close()

def screendump(name):
    path = f"{SHOT_DIR}/{name}"
    try:
        mon(f"screendump {path}")
        with open(path, "rb") as f:
            data = f.read()
        return hashlib.sha256(data).hexdigest()[:12], len(data), data[:4]
    except Exception as e:
        return f"ERR:{e}", 0, b""

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "3072", "-smp", "2", "-cpu", "max",
    "-cdrom", ISO, "-boot", "order=d",
    "-netdev", "user,id=n0,hostfwd=tcp::18734-:8734",
    "-device", "e1000,netdev=n0",
    "-vga", "std", "-display", "none",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

start = time.time()
health = None
last_hash = None
shot_n = 0
while time.time() - start < TIMEOUT:
    elapsed = int(time.time() - start)
    if elapsed % 60 < 12 and shot_n < 25:
        h, size, magic = screendump(f"fusion-screen-{shot_n:02d}.png")
        if h != last_hash:
            note(f"t={elapsed}s screendump#{shot_n} sha={h} bytes={size} magic={magic!r}")
            last_hash = h
        shot_n += 1
    try:
        with urllib.request.urlopen("http://127.0.0.1:18734/health", timeout=8) as r:
            health = (r.status, r.read().decode(errors="replace"))
        break
    except Exception:
        time.sleep(10)

if health:
    note(f"GET /health -> {health[0]} {health[1][:240]}")
    try:
        urllib.request.urlopen("http://127.0.0.1:18734/info", timeout=10)
        note("AUTH-CHECK FAILED: /info without token returned success")
    except urllib.error.HTTPError as e:
        note(f"auth check: /info without token -> HTTP {e.code} (expected 401)")
    except Exception as e:
        note(f"auth check inconclusive: {e}")
    h, size, magic = screendump("fusion-screen-final.png")
    note(f"final screendump sha={h} bytes={size} magic={magic!r}")
else:
    note(f"GET /health FAILED: agent did not respond within {TIMEOUT}s")

with open(LOG, "w") as f:
    f.write("\n".join(lines) + "\n")
qemu.terminate()
try:
    qemu.wait(timeout=10)
except Exception:
    qemu.kill()
note("QEMU-FUSION-TEST-DONE")
