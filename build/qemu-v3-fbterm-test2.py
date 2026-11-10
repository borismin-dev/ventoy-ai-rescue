#!/usr/bin/env python3
"""Second-pass VGA test for v3 Chinese tty display (fbterm route).

The first-pass test took a single screendump after 540 s and got a fully
black frame — inconclusive (boot menu timing, console blanking, or a real
fbterm failure all look the same). This pass boots the ISO the same way
(std VGA, ISO's own bootloader) but dumps at several points and sends an
Enter keypress before the later dumps to defeat console blanking:
  dump1 @ ~90 s   (boot menu / early kernel)
  dump2 @ ~300 s  (system should be up, tty1 autologin + fbterm)
  sendkey ret
  dump3 @ ~420 s  (post-keypress state)
PPMs are converted to PNGs next to the PPMs for visual inspection.
"""
import os, socket, subprocess, time, zlib, struct

ISO = os.environ.get("V3_ISO", "/data/home/dist-v3/AI-Rescue-PE.iso")
MON = "/tmp/qemu-fbterm2-mon.sock"
OUTDIR = "/tmp/fbterm2"
os.makedirs(OUTDIR, exist_ok=True)
try: os.unlink(MON)
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
    try:
        s.recv(4096)
        s.sendall((cmd + "\n").encode())
        time.sleep(1)
        s.recv(4096)
    except Exception:
        pass
    s.close()

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
    assert parts[0] == "P6", parts
    w, h, maxv = int(parts[1]), int(parts[2]), int(parts[3])
    raw = data[idx:idx + w * h * 3]
    nonzero = sum(1 for b in raw if b != 0)
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
    return w, h, nonzero

def dump(tag):
    ppm = f"{OUTDIR}/{tag}.ppm"
    mon(f"screendump {ppm}")
    time.sleep(2)
    if os.path.exists(ppm):
        w, h, nz = ppm_to_png(ppm, f"{OUTDIR}/{tag}.png")
        print(f"{tag}: {w}x{h} nonzero_bytes={nz} -> {OUTDIR}/{tag}.png", flush=True)
    else:
        print(f"{tag}: PPM missing", flush=True)

print(f"booting {ISO} (multi-dump pass)", flush=True)
time.sleep(90)
dump("dump1-90s")
time.sleep(210)
dump("dump2-300s")
mon("sendkey ret")
time.sleep(5)
dump("dump3-after-enter")
time.sleep(115)
mon("sendkey ret")
time.sleep(5)
dump("dump4-420s")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
print("QEMU-V3-FBTERM2-TEST-DONE", flush=True)
