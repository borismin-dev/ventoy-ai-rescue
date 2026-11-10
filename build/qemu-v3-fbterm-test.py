#!/usr/bin/env python3
"""QEMU VGA screendump test for v3 Chinese tty display (fbterm route).

Boots the v3 ISO *as an ISO* (isolinux/GRUB path, std VGA, no serial
console), waits, and takes monitor screendumps (PPM), converting the last
one to PNG for visual inspection: the tty1 autologin session should enter
fbterm and render the Chinese boot banner with the subset CJK font.
"""
import os, socket, subprocess, sys, time, zlib, struct

ISO = os.environ.get("V3_ISO", "/data/home/dist-v3/AI-Rescue-PE.iso")
MON = "/tmp/qemu-fbterm-mon.sock"
PPM = "/tmp/fbterm-final.ppm"
PNG = "/tmp/fbterm-final.png"
WAIT = int(os.environ.get("FBTERM_WAIT", "480"))

for f in (MON,):
    try: os.unlink(f)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-vga", "std", "-display", "none",
    "-monitor", f"unix:{MON},server,nowait",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

def mon(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MON)
    s.settimeout(10)
    s.recv(4096)
    s.sendall((cmd + "\n").encode())
    time.sleep(1)
    try:
        s.recv(4096)
    except Exception:
        pass
    s.close()

def ppm_to_png(ppm_path, png_path):
    with open(ppm_path, "rb") as f:
        data = f.read()
    # parse P6 header (whitespace separated, possible comment lines)
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
    assert parts[0] == "P6", parts
    w, h, maxv = int(parts[1]), int(parts[2]), int(parts[3])
    raw = data[idx:idx + w * h * 3]
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
    return w, h

print(f"booting {ISO}, waiting {WAIT}s ...", flush=True)
time.sleep(WAIT)
mon(f"screendump {PPM}")
time.sleep(2)
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
w, h = ppm_to_png(PPM, PNG)
print(f"screendump converted: {w}x{h} -> {PNG} ({os.path.getsize(PNG)} bytes)", flush=True)
print("QEMU-V3-FBTERM-TEST-DONE", flush=True)
