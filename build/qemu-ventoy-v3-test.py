#!/usr/bin/env python3
"""QEMU verification for the v3 Ventoy USB image (runs on InstaBox main-1).

SELECT_INDEX env: number of Down keypresses in the Ventoy menu before
Return (menu order is alphabetical; verify against ventoy-menu.png).
"""

Boots Ventoy-AI-Rescue-USB.img as an IDE hard disk (BIOS). Evidence:
  - screendump of the Ventoy menu once the screen settles
  - sendkey Return to boot the first entry (AI-Rescue-PE.iso, alphabetical)
  - the Linux PE's rescue-agent must then answer on host 18734 /health,
    which proves the whole chain: Ventoy MBR -> GRUB menu -> ISO -> live
    system -> agent. mDNS cannot be exercised over QEMU user networking.
"""
import hashlib, os, socket, subprocess, time, urllib.request

IMG = "/data/home/dist-v3/Ventoy-AI-Rescue-USB.img"
LOG = "/data/home/logs/qemu-ventoy-v3-test.log"
MON = "/tmp/qemu-ventoy-mon.sock"
SHOT_DIR = "/data/home/logs"
MENU_WAIT = 420      # TCG: allow up to 7 min to reach the menu
HEALTH_TIMEOUT = 900 # then up to 15 min for the PE + agent

lines = []
def note(msg):
    print(msg, flush=True)
    lines.append(msg)

def mon(cmd, wait=1.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(MON)
    s.recv(4096)
    s.sendall(cmd.encode() + b"\n")
    time.sleep(wait)
    try:
        s.recv(4096)
    except socket.timeout:
        pass
    s.close()

def screendump(name):
    path = f"{SHOT_DIR}/{name}"
    mon(f"screendump {path}")
    with open(path, "rb") as f:
        data = f.read()
    return hashlib.sha256(data).hexdigest()[:12], len(data), data[:4]

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2", "-cpu", "max",
    "-drive", f"file={IMG},format=raw,if=ide,index=0",
    "-boot", "order=c",
    "-netdev", "user,id=n0,hostfwd=tcp::18734-:8734,hostfwd=tcp::10022-:22",
    "-device", "e1000,netdev=n0",
    "-vga", "std", "-display", "none",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

start = time.time()
prev = None
stable = 0
menu_shot = None
while time.time() - start < MENU_WAIT:
    time.sleep(20)
    try:
        h, size, magic = screendump("ventoy-screen-poll.png")
    except Exception as e:
        note(f"screendump error: {e}")
        continue
    elapsed = int(time.time() - start)
    note(f"t={elapsed}s screen sha={h} bytes={size} magic={magic!r}")
    if h == prev:
        stable += 1
        if stable >= 2 and elapsed > 60:
            menu_shot = screendump("ventoy-menu.png")
            note(f"menu assumed reached (screen stable); saved ventoy-menu.png sha={menu_shot[0]}")
            break
    else:
        stable = 0
    prev = h
if not menu_shot:
    menu_shot = screendump("ventoy-menu.png")
    note(f"menu wait timed out; saved best-effort ventoy-menu.png sha={menu_shot[0]}")

SELECT_INDEX = int(os.environ.get("SELECT_INDEX", "0"))
note(f"sending {SELECT_INDEX} Down + Return to boot menu entry index {SELECT_INDEX}")
for _ in range(SELECT_INDEX):
    mon("sendkey down", wait=1)
mon("sendkey ret", wait=2)

# Ventoy then shows a boot-mode submenu (normal / grub2 / memdisk mode);
# it needs a second Return to accept "Boot in normal mode". Poll the screen
# until it changes to that submenu, then confirm. (Verified 2026-11-08:
# with only one Return the boot stalls at this submenu forever.)
for _ in range(12):
    time.sleep(10)
    try:
        h2, _, _ = screendump("ventoy-screen-poll.png")
    except Exception:
        continue
    if h2 != prev:
        break
note("sending second Return for 'Boot in normal mode'")
mon("sendkey ret", wait=2)

health = None
t0 = time.time()
while time.time() - t0 < HEALTH_TIMEOUT:
    try:
        with urllib.request.urlopen("http://127.0.0.1:18734/health", timeout=8) as r:
            health = (r.status, r.read().decode(errors="replace"))
        break
    except Exception:
        time.sleep(10)
if health:
    note(f"GET /health via Ventoy-booted PE -> {health[0]} {health[1][:240]}")
    h, size, magic = screendump("ventoy-pe-final.png")
    note(f"final screendump sha={h} bytes={size} magic={magic!r}")
else:
    note(f"GET /health FAILED within {HEALTH_TIMEOUT}s after menu Return")

with open(LOG, "w") as f:
    f.write("\n".join(lines) + "\n")
qemu.terminate()
try:
    qemu.wait(timeout=10)
except Exception:
    qemu.kill()
note("QEMU-VENTOY-TEST-DONE")
