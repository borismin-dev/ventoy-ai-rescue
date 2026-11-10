#!/usr/bin/env python3
"""Mount-leg verification for `ai-debug unlock` on the 32-bit ISO (v3).

Same situation as the 64-bit mount-leg test: cryptsetup's BitLocker test
images decrypt correctly but their NTFS is not mountable ($MFTMirr is
inconsistent), so unlock's post-decryption half is verified separately:
  1. really decrypt the xts-256 test volume (-> /dev/mapper/realvol,
     blkid shows NTFS);
  2. create /dev/mapper/bitlocker-sda as dm-linear over a PLAIN consistent
     mkntfs image — the exact state a decrypted volume presents;
  3. `ai-debug unlock /dev/sda` must skip cryptsetup, mount via ntfs-3g
     (the bookworm i386 kernel has no ntfs3) read-write at
     /mnt/bitlocker-sda, a write/read round-trip must succeed, and
     diagnose must report the volume as unlocked.
Runs on qemu-system-i386, pentium3, 768 MB, rtl8139.
"""
import os, re, subprocess, time, configparser

ISO = "/data/home/dist-v3/AI-Rescue-PE-32.iso"
LIVE = "/data/home/build/pe32/iso/live"
BITLK_IMG = "/tmp/bitlk/bitlk-images/bitlk-aes-xts-256.img"
# Fresh copy of the pristine NTFS image per run (see the 64-bit mount-leg
# test for why a shared, repeatedly hard-killed image is not reusable).
PLAIN_IMG = "/tmp/plain-ntfs-32.img"
subprocess.run(["cp", "/tmp/plain-ntfs-pristine.img", PLAIN_IMG], check=True)
CONF = "/tmp/bitlk/bitlk-images/images.conf"
SERIAL_LOG = "/data/home/logs/qemu-v3-32-mountleg-serial.log"
RESULT_LOG = "/data/home/logs/qemu-v3-32-mountleg-test.log"
try: os.unlink(SERIAL_LOG)
except FileNotFoundError: pass

cp = configparser.ConfigParser(interpolation=None)
cp.optionxform = str
cp.read(CONF)
RP = cp["bitlk-aes-xts-256"]["RP"].strip()

results = []
def note(m):
    print(m, flush=True)
    results.append(m)

qemu = subprocess.Popen([
    "qemu-system-i386", "-cpu", "pentium3", "-m", "768",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-drive", f"file={BITLK_IMG},format=raw,if=ide,index=0",
    "-drive", f"file={PLAIN_IMG},format=raw,if=ide,index=1",
    "-netdev", "user,id=n0,hostfwd=tcp::18736-:8734,hostfwd=tcp::10024-:22",
    "-device", "rtl8139,netdev=n0", "-display", "none",
    "-chardev", f"socket,path=/tmp/qemu-v3-32-mountleg.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
    "-serial", "chardev:ser0", "-monitor", "none",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

token = None
start = time.time()
while time.time() - start < 900:
    try:
        with open(SERIAL_LOG, errors="replace") as f:
            m = re.findall(r"RESCUE-TOKEN:\s*(\S+)", f.read())
            if m:
                token = m[-1]; break
    except FileNotFoundError:
        pass
    time.sleep(5)
note(f"token_from_serial_banner={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s")

if token:
    for _ in range(36):
        probe = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10024",
                                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                                "-o", "ConnectTimeout=10", "rescue@127.0.0.1", "true"],
                               capture_output=True, timeout=60)
        if probe.returncode == 0:
            break
        time.sleep(5)
    # Device names are NOT assumed (sda/sdb enumeration can flip between
    # boots); the guest picks the BitLocker device by blkid TYPE and
    # derives mapper/mount names from it. See the 64-bit mount-leg test.
    remote = (
        f"echo {token} | sudo -S -v 2>/dev/null; "
        "sleep 5; echo === device detection:; ls -l /dev/sd[a-z]; sudo -n /usr/sbin/blkid; "
        "sudo -n /usr/sbin/blkid > /tmp/blkid-list.txt; "
        "BITLK_DEV=$(grep 'TYPE=\"BitLocker\"' /tmp/blkid-list.txt | cut -d: -f1 | head -1); "
        "PLAIN_DEV=$(grep 'LABEL=\"PLAINTEST\"' /tmp/blkid-list.txt | cut -d: -f1 | head -1); "
        "BASE=$(basename $BITLK_DEV); echo bitlk-dev=$BITLK_DEV plain-dev=$PLAIN_DEV; "
        f"echo === real decrypt:; sudo -n bash -c \"printf '%s' '{RP}' | cryptsetup open --type bitlk $BITLK_DEV realvol\" 2>&1; echo REAL-OPEN-RC=$?; "
        "sudo -n /usr/sbin/blkid /dev/mapper/realvol; "
        "echo === dm-linear stand-in for decrypted device:; "
        "sudo -n blockdev --getsz $PLAIN_DEV > /tmp/plain-sectors.txt; SECT=$(cat /tmp/plain-sectors.txt); echo plain-sectors=$SECT; "
        "echo \"0 $SECT linear $PLAIN_DEV 0\" | sudo -n dmsetup create bitlocker-$BASE; ls -la /dev/mapper/; "
        "sudo -n /usr/sbin/blkid /dev/mapper/bitlocker-$BASE; "
        "echo === ai-debug unlock:; sudo -n ai-debug unlock $BITLK_DEV; echo AI-UNLOCK-RC=$?; "
        "mount | grep bitlocker; "
        "echo MOUNTLEG32-WRITE-TEST | sudo -n tee /mnt/bitlocker-$BASE/mountleg32.txt >/dev/null && sudo -n cat /mnt/bitlocker-$BASE/mountleg32.txt; "
        "sudo -n ai-debug diagnose 2>/dev/null | grep -A1 BitLocker | head -6"
    )
    r = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10024",
                        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "ConnectTimeout=20", "rescue@127.0.0.1", remote],
                       capture_output=True, text=True, timeout=600)
    out = r.stdout
    print(out, flush=True)
    note(f"real decrypt ok: {'REAL-OPEN-RC=0' in out and 'TYPE=\"ntfs\"' in out}")
    note(f"ai-debug unlock rc0: {'AI-UNLOCK-RC=0' in out}")
    note(f"unlock mounted ntfs-3g rw: {'type fuseblk (rw' in out}")
    note(f"write/read round-trip: {'MOUNTLEG32-WRITE-TEST' in out}")
    note(f"diagnose shows unlocked: {'BitLocker 卷已解锁：' in out}")

with open(RESULT_LOG, "w") as f:
    f.write("\n".join(results) + "\n")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
note("QEMU-V3-32-MOUNTLEG-TEST-DONE")
