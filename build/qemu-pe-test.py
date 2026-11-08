#!/usr/bin/env python3
"""QEMU serial-console test for AI-Rescue-PE.iso
Boots the ISO's kernel/initrd directly (live-boot finds the squashfs on the
attached CD-ROM), with console=ttyS0, then logs in as rescue/rescue over the
serial socket and runs `ai-debug diagnose`. All serial output is captured.
Run on InstaBox main-1 (no KVM, TCG emulation).
"""
import socket, subprocess, sys, time, os, re

ISO = "/data/home/dist/AI-Rescue-PE.iso"
LIVE = "/data/home/build/pe/iso/live"
SOCK = "/tmp/qemu-pe-serial.sock"
LOG = "/data/home/logs/qemu-pe-serial.log"
TIMEOUT = int(os.environ.get("QEMU_TEST_TIMEOUT", "900"))

for f in (SOCK,):
    try: os.unlink(f)
    except FileNotFoundError: pass

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue-pe",
    "-display", "none",
    "-chardev", f"socket,path={SOCK},server=on,wait=off,id=ser0,logfile={LOG}",
    "-serial", "chardev:ser0",
    "-monitor", "none",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

time.sleep(3)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(SOCK)
s.settimeout(5)
buf = b""
def wait_for(pat, deadline):
    global buf
    while time.time() < deadline:
        if re.search(pat, buf):
            return True
        try:
            data = s.recv(65536)
            if data: buf += data
        except socket.timeout:
            pass
    return False

def send(line):
    s.sendall(line.encode() + b"\n")
    time.sleep(1)

start = time.time()
ok_login_prompt = wait_for(rb"login:", start + TIMEOUT)
print(f"login_prompt={ok_login_prompt} after {time.time()-start:.0f}s", flush=True)
if ok_login_prompt:
    send("rescue")
    ok_pw = wait_for(rb"[Pp]assword:", time.time() + 60)
    print(f"password_prompt={ok_pw}", flush=True)
    send("rescue")
    # shell prompt: rescue@ai-rescue-pe
    ok_shell = wait_for(rb"rescue@ai-rescue-pe", time.time() + 120)
    print(f"shell_prompt={ok_shell}", flush=True)
    if ok_shell:
        send("echo ===TEST-START===; whoami; uname -a")
        time.sleep(3)
        send("ai-debug diagnose > /tmp/out.txt 2>&1; echo DIAG-EXIT=$?; wc -l /tmp/out.txt; head -60 /tmp/out.txt")
        ok_diag = wait_for(rb"DIAG-EXIT=0", time.time() + 180)
        print(f"diagnose_ok={ok_diag}", flush=True)
        send("cat /tmp/ai-report.txt | head -30; echo ===TEST-END===")
        wait_for(rb"===TEST-END===", time.time() + 60)
        # collect remaining output
        try:
            while True:
                data = s.recv(65536)
                if not data: break
                buf += data
        except Exception:
            pass
with open("/data/home/logs/qemu-pe-console-capture.txt", "wb") as f:
    f.write(buf)
print(f"captured {len(buf)} bytes of console output", flush=True)
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
print("QEMU-PE-TEST-DONE", flush=True)
