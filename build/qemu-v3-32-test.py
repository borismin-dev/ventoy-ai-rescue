#!/usr/bin/env python3
"""QEMU verification for AI-Rescue-PE-32.iso (v3 32-bit fallback).

qemu-system-i386, old-machine profile (default -cpu pentium3, 768 MB RAM),
kernel direct boot from the pe32 build tree. NIC selectable via NIC env
(rtl8139 first, then e1000). BitLocker test image attached as /dev/sda.
Checks: boot token banner, /health 200, no-token 401, diagnose exit 0 in
Chinese with the BitLocker locked line, DHCP address present, and (rtl8139
phase) the SSH end-to-end unlock with the public test recovery key.
"""
import json, os, re, subprocess, sys, time, urllib.request, urllib.error, configparser

ISO = "/data/home/dist-v3/AI-Rescue-PE-32.iso"
LIVE = "/data/home/build/pe32/iso/live"
BITLK_IMG = "/tmp/bitlk/bitlk-images/bitlk-aes-xts-256.img"
BITLK_CONF = "/tmp/bitlk/bitlk-images/images.conf"
NIC = os.environ.get("NIC", "rtl8139")
CPU = os.environ.get("QEMU32_CPU", "pentium3")
MEM = os.environ.get("QEMU32_MEM", "768")
TAG = f"32-{NIC}"
SERIAL_LOG = f"/data/home/logs/qemu-v3-{TAG}-serial.log"
RESULT_LOG = f"/data/home/logs/qemu-v3-{TAG}-test.log"
TIMEOUT = 1200

cp = configparser.ConfigParser(interpolation=None)
cp.optionxform = str
cp.read(BITLK_CONF)
RP = cp["bitlk-aes-xts-256"]["RP"].strip()

try: os.unlink(SERIAL_LOG)
except FileNotFoundError: pass

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

def ssh(token, remote_cmd, timeout=300):
    return subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10023",
                           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                           "-o", "ConnectTimeout=20", "rescue@127.0.0.1", remote_cmd],
                          capture_output=True, text=True, timeout=timeout)

qemu = subprocess.Popen([
    "qemu-system-i386", "-cpu", CPU, "-m", MEM,
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-drive", f"file={BITLK_IMG},format=raw,if=ide,index=1",
    "-netdev", "user,id=n0,hostfwd=tcp::18735-:8734,hostfwd=tcp::10023-:22",
    "-device", f"{NIC},netdev=n0",
    "-display", "none",
    "-chardev", f"socket,path=/tmp/qemu-v3-{TAG}-serial.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
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
                token = m[-1]; break
    except FileNotFoundError:
        pass
    time.sleep(5)
note(f"[{TAG}] cpu={CPU} mem={MEM} token_from_serial_banner={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s")

if token:
    health = None
    t0 = time.time()
    while time.time() - t0 < 300:
        try:
            health = curl("http://127.0.0.1:18735/health", timeout=10); break
        except Exception:
            time.sleep(5)
    note(f"[{TAG}] GET /health -> {health[0] if health else 'FAILED'} (DHCP+agent up)")
    try:
        curl("http://127.0.0.1:18735/diagnose", timeout=15)
        note(f"[{TAG}] AUTH-CHECK FAILED: /diagnose without token succeeded")
    except urllib.error.HTTPError as e:
        note(f"[{TAG}] auth check: /diagnose without token -> HTTP {e.code} (expected 401)")
    except Exception as e:
        note(f"[{TAG}] auth check inconclusive: {e}")
    try:
        code, body = curl("http://127.0.0.1:18735/info", token=token, timeout=30)
        info = json.loads(body)
        note(f"[{TAG}] GET /info -> {code} ipv4={info.get('ipv4')}")
    except Exception as e:
        note(f"[{TAG}] GET /info FAILED: {e}")
    try:
        code, body = curl("http://127.0.0.1:18735/diagnose", token=token, timeout=600)
        diag = json.loads(body)
        rep = diag.get("report", "")
        note(f"[{TAG}] GET /diagnose -> exitCode={diag.get('exitCode')} report_chars={len(rep)}")
        note(f"[{TAG}] diagnose Chinese header: {'诊断报告' in rep}")
        note(f"[{TAG}] diagnose BitLocker locked line: {'BitLocker 加密，未解锁：/dev/sda' in rep}")
    except Exception as e:
        note(f"[{TAG}] GET /diagnose FAILED: {e}")
    if NIC == "rtl8139":
        try:
            r = ssh(token,
                f"echo {token} | sudo -S -v 2>/dev/null; "
                f"printf '%s' '{RP}' | sudo ai-debug unlock /dev/sda; echo UNLOCK-RC=$?; "
                "ls /mnt/bitlocker-sda | head -3; mount | grep bitlocker", timeout=300)
            out = r.stdout
            note(f"[{TAG}] unlock end-to-end rc0: {'UNLOCK-RC=0' in out}")
            note(f"[{TAG}] unlock tail: {out.strip()[-300:]!r}")
        except Exception as e:
            note(f"[{TAG}] unlock FAILED: {e}")

with open(RESULT_LOG, "w") as f:
    f.write("\n".join(results) + "\n")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
note(f"QEMU-V3-{TAG}-TEST-DONE")
