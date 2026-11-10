#!/usr/bin/env python3
"""QEMU verification for AI-Rescue-PE v3 (amd64): agent chain + Chinese
diagnose + BitLocker end-to-end unlock with the cryptsetup project's public
test image (tests/bitlk-images, key read at runtime from its images.conf —
a published test vector, not a user secret).

Boots the v3 ISO (kernel direct), attaches bitlk-aes-xts-256.img as a raw
IDE disk (/dev/sda), user-net host forwards 18734->8734, 10022->22.
Checks: /health 200, no-token 401, diagnose (Chinese) flags the volume as
「BitLocker 加密，未解锁」, then via SSH (boot token): non-root unlock is
refused, unknown device is refused, and a real unlock with the recovery
key DECRYPTS the volume (cryptsetup open succeeds inside ai-debug).
Note: the published test images' NTFS is internally inconsistent
($MFTMirr), so no Linux driver can mount them; unlock is expected to
report the decryption success and then fail the mount gracefully with
chkdsk guidance. The mount half of unlock is verified separately by
qemu-v3-mountleg-test.py against a consistent NTFS.
"""
import json, os, re, subprocess, sys, time, urllib.request, urllib.error, configparser

ISO = "/data/home/dist-v3/AI-Rescue-PE.iso"
LIVE = "/data/home/build/pe/iso/live"
BITLK_IMG = "/tmp/bitlk/bitlk-images/bitlk-aes-xts-256.img"
BITLK_CONF = "/tmp/bitlk/bitlk-images/images.conf"
SERIAL_LOG = "/data/home/logs/qemu-v3-serial.log"
RESULT_LOG = "/data/home/logs/qemu-v3-test.log"
REPORT_TXT = "/data/home/logs/qemu-v3-report.txt"
TIMEOUT = 900

cp = configparser.ConfigParser(interpolation=None)
cp.optionxform = str
cp.read(BITLK_CONF)
RP = cp["bitlk-aes-xts-256"]["RP"].strip()

for _f in (SERIAL_LOG,):
    try: os.unlink(_f)
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
    r = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10022",
                        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "ConnectTimeout=20", "rescue@127.0.0.1", remote_cmd],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-drive", f"file={BITLK_IMG},format=raw,if=ide,index=1",
    "-netdev", "user,id=n0,hostfwd=tcp::18734-:8734,hostfwd=tcp::10022-:22",
    "-device", "e1000,netdev=n0",
    "-display", "none",
    "-chardev", f"socket,path=/tmp/qemu-v3-serial.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
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
note(f"token_from_serial_banner={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s")

def get_diagnose(tok, timeout=600):
    code, body = curl("http://127.0.0.1:18734/diagnose", token=tok, timeout=timeout)
    return json.loads(body)

if token:
    health = None
    t0 = time.time()
    while time.time() - t0 < 300:
        try:
            health = curl("http://127.0.0.1:18734/health", timeout=10); break
        except Exception:
            time.sleep(5)
    note(f"GET /health -> {health[0] if health else 'FAILED'}")
    try:
        curl("http://127.0.0.1:18734/diagnose", timeout=15)
        note("AUTH-CHECK FAILED: /diagnose without token succeeded")
    except urllib.error.HTTPError as e:
        note(f"auth check: /diagnose without token -> HTTP {e.code} (expected 401)")
    except Exception as e:
        note(f"auth check inconclusive: {e}")
    try:
        diag = get_diagnose(token)
        rep = diag.get("report", "")
        with open(REPORT_TXT, "w") as f:
            f.write(rep)
        note(f"GET /diagnose -> exitCode={diag.get('exitCode')} report_chars={len(rep)}")
        note(f"diagnose Chinese header: {'诊断报告' in rep}")
        note(f"diagnose BitLocker locked line: {'BitLocker 加密，未解锁：/dev/sda' in rep}")
    except Exception as e:
        note(f"GET /diagnose FAILED: {e}")
    # non-root unlock must be refused
    try:
        rc, out, err = ssh(token, "ai-debug unlock /dev/sda; echo RC=$?", timeout=120)
        note(f"unlock as non-root refused: {'需要 root' in out} rc-line={'RC=1' in out}")
    except Exception as e:
        note(f"non-root unlock check FAILED: {e}")
    # root unlock with a bogus target must fail gracefully
    try:
        rc, out, err = ssh(token, f"echo {token} | sudo -S ai-debug unlock /dev/sdz 2>/dev/null; echo RC=$?", timeout=120)
        note(f"unlock bogus device graceful: {'不在 BitLocker 卷列表中' in out} {'RC=1' in out}")
    except Exception as e:
        note(f"bogus unlock check FAILED: {e}")
    # real unlock with the recovery key: decryption must succeed inside
    # ai-debug; the mount then fails gracefully on this synthetic image
    # (inconsistent $MFTMirr — see docstring) with chkdsk guidance, and
    # the decrypted mapper device must be left in place.
    try:
        rc, out, err = ssh(token,
            f"echo {token} | sudo -S -v 2>/dev/null; "
            f"printf '%s' '{RP}' | sudo ai-debug unlock /dev/sda; echo UNLOCK-RC=$?; "
            "ls -la /dev/mapper/ | grep bitlocker; sudo cryptsetup status bitlocker-sda | head -4",
            timeout=300)
        note(f"unlock decrypted the volume: {'解密成功' in out}")
        note(f"unlock mount failed gracefully with guidance: {'挂载失败' in out and 'chkdsk' in out}")
        note(f"decrypted mapper kept: {'bitlocker-sda' in out and 'is active' in out}")
        note(f"unlock output tail: {out.strip()[-400:]!r}")
    except Exception as e:
        note(f"end-to-end unlock FAILED: {e}")

with open(RESULT_LOG, "w") as f:
    f.write("\n".join(results) + "\n")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
note("QEMU-V3-TEST-DONE")
