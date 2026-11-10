#!/usr/bin/env python3
"""Final visual verification of Chinese rendering inside fbterm (v3).

Boots the v3 ISO as an ISO (its own bootloader, std VGA), waits for the
tty1 fbterm session, types `cat /run/rescue-banner.txt` and then
`ai-debug diagnose` into tty1 via monitor sendkey, and screendumps.
The PNGs must show real hanzi glyphs rendered by fbterm with the subset
font — as opposed to the fbcon diamond replacement glyphs seen when
fbterm is not running.
"""
import os, socket, subprocess, time, zlib, struct

ISO = os.environ.get("V3_ISO", "/data/home/dist-v3/AI-Rescue-PE.iso")
MON = "/tmp/qemu-fbverify-mon.sock"
OUTDIR = "/tmp/fbverify"
os.makedirs(OUTDIR, exist_ok=True)
try: os.unlink(MON)
except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-vga", "std", "-display", "none",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

def mon(cmd, wait=0.35):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MON)
    s.settimeout(10)
    try:
        s.recv(4096)
        s.sendall((cmd + "\n").encode())
        time.sleep(wait)
        s.recv(4096)
    except Exception:
        pass
    s.close()

KEYMAP = {"-": "minus", " ": "spc", "\n": "ret", "/": "slash", ".": "dot",
          "_": "shift-minus", "|": "shift-backslash"}
def type_cmd(text):
    for ch in text:
        key = KEYMAP.get(ch, ch)
        mon(f"sendkey {key}", wait=0.18)

def ppm_to_png(ppm_path, png_path):
    with open(ppm_path, "rb") as f:
        data = f.read()
    parts = []
    idx = 0
    while len(parts) < 4:
        while idx < len(data) and chr(data[idx]) in " \t\r\n":
            idx += 1
        if chr(data[idx]) == "#":
            while data[idx] != 10:
                idx += 1
            continue
        start = idx
        while idx < len(data) and chr(data[idx]) not in " \t\r\n":
            idx += 1
        parts.append(data[start:idx].decode())
    idx += 1
    w, h = int(parts[1]), int(parts[2])
    raw = data[idx:idx + w * h * 3]
    nz = sum(1 for b in raw if b != 0)
    def chunk(typ, payload):
        c = struct.pack(">I", len(payload)) + typ + payload
        c += struct.pack(">I", zlib.crc32(typ + payload) & 0xffffffff)
        return c
    scan = b""
    stride = w * 3
    for y in range(h):
        scan += b"\x00" + raw[y * stride:(y + 1) * stride]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(scan, 6))
    png += chunk(b"IEND", b"")
    with open(png_path, "wb") as f:
        f.write(png)
    return nz

def dump(tag):
    ppm = f"{OUTDIR}/{tag}.ppm"
    mon(f"screendump {ppm}", wait=2)
    if os.path.exists(ppm):
        nz = ppm_to_png(ppm, f"{OUTDIR}/{tag}.png")
        print(f"{tag}: nonzero_bytes={nz} -> {OUTDIR}/{tag}.png", flush=True)

print(f"booting {ISO}; waiting 330s for tty1 fbterm session ...", flush=True)
time.sleep(330)
type_cmd("cat /run/rescue-banner.txt\n")
time.sleep(8)
dump("banner-in-fbterm")
type_cmd("ai-debug diagnose\n")
time.sleep(60)
dump("diagnose-in-fbterm")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
print("QEMU-V3-FBTERM-VERIFY-DONE", flush=True)
