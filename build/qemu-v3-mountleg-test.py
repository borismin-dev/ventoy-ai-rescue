#!/usr/bin/env python3
"""Mount-leg verification for `ai-debug unlock` (v3).

The cryptsetup project's BitLocker test images decrypt correctly (proven:
OPEN-RC=0, blkid NTFS + UUID match) but their $MFTMirr is inconsistent, so
no Linux NTFS driver will mount them — they are decryption vectors, not
filesystem images. To verify unlock's post-decryption half (the part that
runs once /dev/mapper/bitlocker-<dev> exists with a consistent NTFS), this
test, in one guest session:
  1. really decrypts the xts-256 test volume with its recovery key
     (cryptsetup open -> /dev/mapper/realvol; blkid shows NTFS);
  2. creates /dev/mapper/bitlocker-sda as a dm-linear device over a PLAIN,
     consistent mkntfs NTFS image (/dev/sdb) — i.e. exactly the state a
     successfully decrypted volume presents to cmd_unlock;
  3. runs `ai-debug unlock /dev/sda`: it must skip cryptsetup (mapper
     exists), mount ntfs3 rw at /mnt/bitlocker-sda, and a write/read
     round-trip must succeed.
"""
import os, re, subprocess, time, configparser

ISO = "/data/home/dist-v3/AI-Rescue-PE.iso"
LIVE = "/data/home/build/pe/iso/live"
BITLK_IMG = "/tmp/bitlk/bitlk-images/bitlk-aes-xts-256.img"
# Fresh copy of the pristine NTFS image per run: a shared image gets its
# NTFS dirty flag set whenever a guest is hard-killed, after which ntfs3
# mounts read-only and ntfs-3g refuses outright — both look like product
# failures but are test-harness artifacts.
PLAIN_IMG = "/tmp/plain-ntfs-64.img"
subprocess.run(["cp", "/tmp/plain-ntfs-pristine.img", PLAIN_IMG], check=True)
CONF = "/tmp/bitlk/bitlk-images/images.conf"
SERIAL_LOG = "/data/home/logs/qemu-v3-mountleg-serial.log"
RESULT_LOG = "/data/home/logs/qemu-v3-mountleg-test.log"
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
    "qemu-system-x86_64", "-m", "2048", "-smp", "2",
    "-cdrom", ISO, "-boot", "order=d",
    "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
    "-append", "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue",
    "-drive", f"file={BITLK_IMG},format=raw,if=ide,index=0",
    "-drive", f"file={PLAIN_IMG},format=raw,if=ide,index=1",
    "-netdev", "user,id=n0,hostfwd=tcp::18734-:8734,hostfwd=tcp::10022-:22",
    "-device", "e1000,netdev=n0", "-display", "none",
    "-chardev", f"socket,path=/tmp/qemu-v3-mountleg.sock,server=on,wait=off,id=ser0,logfile={SERIAL_LOG}",
    "-serial", "chardev:ser0", "-monitor", "none",
], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)

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
note(f"token_from_serial_banner={'FOUND' if token else 'NOT-FOUND'} after {time.time()-start:.0f}s")

if token:
    for _ in range(36):
        probe = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10022",
                                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                                "-o", "ConnectTimeout=10", "rescue@127.0.0.1", "true"],
                               capture_output=True, timeout=60)
        if probe.returncode == 0:
            break
        time.sleep(5)
    # Device names are NOT assumed: sda/sdb enumeration between the two
    # otherwise identical "QEMU HARDDISK" devices has been observed to
    # flip between boots, so the guest picks the BitLocker device by
    # content (blkid TYPE) and derives the mapper/mount names from it.
    # Detection parses a blkid dump written to a file by a plain sudo
    # call: `sudo` inside $( ) intermittently fails sudo's ppid-based
    # timestamp check in this guest ("a password is required"), which
    # silently emptied every substitution-based variant tried.
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
        "echo MOUNTLEG-WRITE-TEST | sudo -n tee /mnt/bitlocker-$BASE/mountleg.txt >/dev/null && sudo -n cat /mnt/bitlocker-$BASE/mountleg.txt; "
        "sudo -n ai-debug diagnose 2>/dev/null | grep -A1 BitLocker | head -6"
    )
    r = subprocess.run(["sshpass", "-p", token, "ssh", "-p", "10022",
                        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "ConnectTimeout=20", "rescue@127.0.0.1", remote],
                       capture_output=True, text=True, timeout=600)
    out = r.stdout
    print(out, flush=True)
    note(f"real decrypt ok: {'REAL-OPEN-RC=0' in out and 'TYPE=\"ntfs\"' in out}")
    note(f"ai-debug unlock rc0: {'AI-UNLOCK-RC=0' in out}")
    note(f"unlock mounted ntfs3 rw: {'type ntfs3 (rw' in out}")
    note(f"write/read round-trip: {'MOUNTLEG-WRITE-TEST' in out}")
    note(f"diagnose shows unlocked: {'BitLocker 卷已解锁：' in out}")

with open(RESULT_LOG, "w") as f:
    f.write("\n".join(results) + "\n")
qemu.terminate()
try: qemu.wait(timeout=10)
except Exception: qemu.kill()
note("QEMU-V3-MOUNTLEG-TEST-DONE")
