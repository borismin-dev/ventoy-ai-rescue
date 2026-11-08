#!/bin/bash
# CI smoke test for AI-Rescue-PE.iso (TCG emulation, no KVM on the runner).
# Kernel-direct boot with a serial console; PASS if the live system prints
# the rescue-agent RESCUE-TOKEN banner or reaches a login prompt in time.
# Usage: qemu-smoke-ci.sh <iso> <serial-log> [timeout-seconds]
set -u
ISO=${1:?usage: qemu-smoke-ci.sh ISO LOG [TIMEOUT]}
LOG=${2:?usage: qemu-smoke-ci.sh ISO LOG [TIMEOUT]}
TIMEOUT=${3:-600}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/iso"
xorriso -osirrox on -indev "$ISO" -extract /live "$WORK/iso/live" >/dev/null 2>&1
if [ ! -f "$WORK/iso/live/vmlinuz" ] || [ ! -f "$WORK/iso/live/initrd.img" ]; then
  echo "SMOKE-FAIL: /live/vmlinuz or /live/initrd.img not found in ISO"
  exit 1
fi

qemu-system-x86_64 -m 2048 -smp 2 \
  -cdrom "$ISO" -boot order=d \
  -kernel "$WORK/iso/live/vmlinuz" -initrd "$WORK/iso/live/initrd.img" \
  -append "boot=live components console=ttyS0,115200 username=rescue hostname=ai-rescue" \
  -netdev user,id=n0 -device e1000,netdev=n0 \
  -display none -serial "file:$LOG" -monitor none &
QPID=$!

deadline=$(( $(date +%s) + TIMEOUT ))
ok=1
while [ "$(date +%s)" -lt "$deadline" ]; do
  if grep -aqE 'RESCUE-TOKEN:|ai-rescue login:' "$LOG" 2>/dev/null; then
    ok=0
    break
  fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 10
done
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null

if [ "$ok" -eq 0 ]; then
  echo "SMOKE-PASS: boot banner found within ${TIMEOUT}s (serial log: $LOG)"
else
  echo "SMOKE-FAIL: no login/token banner within ${TIMEOUT}s (serial log: $LOG)"
fi
exit "$ok"
