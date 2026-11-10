#!/usr/bin/env python3
"""Debug pass for the black VGA screen in the fbterm tests.

Boots the v3 64-bit live system by direct kernel boot with BOTH consoles
(console=tty0 for the VGA path under test, console=ttyS0 last so the boot
banner/token lands in the serial log), std VGA + monitor screendumps, and
SSH hostfwd. Once the token is known, SSH in and inspect the tty1/fbterm
state from inside: getty/fbterm processes, /dev/fb0, fonts, journal.
Nothing about the tty1 environment differs from the ISO boot path —
live-config autologin and the .profile fbterm hook key on tty1 itself.
"""
import os, re, socket, subprocess, time

LIVE = "/data/home/build/pe/iso/live"
ISO = "/data/home/dist-v3/AI-Rescue-PE.iso"
MON = "/tmp/qemu-vgadebug-mon.sock"
SERIAL_LOG = "/data/home/logs/qemu-v3-vgadebug-serial.log"
OUTDIR = "/tmp/vgadebug"
os.makedirs(OUTDIR, exist_ok=True)
for f in (MON, SERIAL_LOG):
    try: os.unlink(f)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2", "-cpu", "max",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=tty0 console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-vga", "std", "-display", "none",
    "-monitor", f"unix:{MON},server,nowait",
    "-netdev", "user,id=n0,hostfwd=tcp::18737-:8734,hostfwd=tcp::10025-:22",
    "-device", "e1000,netdev=n0",
    "-chardev", f"socket,path=/tmp/qemu-vgadebug.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
    "-serial", "chardev:ser0",
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

def dump(tag):
    ppm = f"{OUTDIR}/{tag}.ppm"
    mon(f"screendump {ppm}")
    time.sleep(2)
    if os.path.exists(ppm):
        with open(ppm, "rb") as f:
            data = f.read()
        # skip P6 header (3 lines-ish): count nonzero in last 1280*800*3 bytes
        raw = data[-1280 * 800 * 3:]
        nz = sum(1 for b in raw if b != 0)
        print(f"{tag}: nonzero_bytes={nz}", flush=True)
    else:
        print(f"{tag}: PPM missing", flush=True)

token = None
start = time.time()
while time.time() - start < 600:
    try:
        with open(SERIAL_LOG, errors="replace") as f:
            m = re.findall(r"RESCUE-TOKEN:\s*(\S+)", f.read())
            if m:
                token = m[-1]; break
    except FileNotFoundError:
        pass
    time.sleep(5)
print(f"token={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s", flush=True)

time.sleep(30)
dump("vga-after-token")
mon("sendkey ret")
time.sleep(5)
dump("vga-after-enter")

if token:
    remote = (
        "echo === who:; who; "
        "echo === processes:; ps -ef | grep -E 'fbterm|getty|login' | grep -v grep; "
        "echo === fb0:; ls -l /dev/fb0 2>&1; cat /sys/class/graphics/fb0/name 2>/dev/null; cat /sys/class/graphics/fb0/virtual_size 2>/dev/null; "
        "echo === fonts:; ls -la /usr/share/fonts/truetype/rescue/ 2>&1; which fbterm; "
        "echo === profile hook:; grep -n fbterm ~/.profile /etc/profile.d/*.sh 2>/dev/null | head; "
        "echo === tty1 journal:; sudo -n journalctl -b --no-pager 2>/dev/null | grep -iE 'fbterm|getty|tty1' | tail -15; "
        "echo === fbtermrc:; cat ~/.fbtermrc 2>/dev/null"
    )
    for _ in range(24):
        probe = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10025",
                                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                                "-o", "ConnectTimeout=10", "rescue@127.0.0.1", "true"],
                               capture_output=True, timeout=60)
        if probe.returncode == 0:
            break
        time.sleep(5)
    r = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10025",
                        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "ConnectTimeout=20", "rescue@127.0.0.1", remote],
                       capture_output=True, text=True, timeout=300)
    print(r.stdout, flush=True)
    print(r.stderr, flush=True)
    dump("vga-after-ssh-inspect")

qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
print("QEMU-V3-VGADEBUG-DONE", flush=True)
