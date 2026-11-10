#!/bin/bash
# Assemble a Ventoy USB disk image from the OFFICIAL Ventoy 1.1.18 release
# payload (no source build involved). Layout matches Ventoy2Disk output:
#   sector 0      : boot.img boot code (partition table written by parted)
#   sectors 1..   : core.img (GRUB2 i386-pc core image from the release)
#   partition 1   : FAT32 data partition (a filesystem Ventoy supports);
#                   ISOs + ventoy/ventoy.json + rescue-config/ live here.
#                   Written with mtools - no kernel FAT driver needed.
#   partition 2   : VTOYEFI, byte copy of ventoy/ventoy.disk.img (32 MiB)
# Usage:
#   VENTOY_DIR=<extracted ventoy-1.1.18> make-ventoy-usb-img.sh \
#       <AI-Rescue-PE.iso> <HotPE-Fusion-AIRescue.iso> <output.img> [sizeMiB]
#   v3: set PE32_ISO=<AI-Rescue-PE-32.iso> to also copy the 32-bit fallback
#   ISO into the data partition as /AI-Rescue-PE-32.iso.
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin

VENTOY_DIR=${VENTOY_DIR:?set VENTOY_DIR to the extracted ventoy-1.1.18 directory}
PE_ISO=${1:?}
FUSION_ISO=${2:?}
OUT=${3:?}
IMG_MB=${4:-2048}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

P2_MB=32
P1_START_MB=1
P1_END_MB=$((IMG_MB - P2_MB))
P1_MB=$((P1_END_MB - P1_START_MB))

echo "[ventoy-img] image=${OUT} size=${IMG_MB}MiB part1=${P1_MB}MiB part2=${P2_MB}MiB"
rm -f "$OUT"
truncate -s "${IMG_MB}M" "$OUT"
parted -s "$OUT" mklabel msdos
parted -s "$OUT" mkpart primary fat32 "${P1_START_MB}MiB" "${P1_END_MB}MiB"
parted -s "$OUT" mkpart primary fat16 "${P1_END_MB}MiB" 100%
# BIOS: many legacy BIOSes require an active partition; UEFI: partition 2
# must carry the ESP type (0xEF on MBR) to be detected as the system partition.
parted -s "$OUT" set 1 boot on
parted -s "$OUT" set 2 esp on

# partition 2: prebuilt VTOYEFI image from the official release, byte copy
xz -dc "$VENTOY_DIR/ventoy/ventoy.disk.img.xz" | dd of="$OUT" bs=1M seek="$P1_END_MB" conv=notrunc status=none

# MBR boot code (first 446 bytes only - keep the partition table) + GRUB core
dd if="$VENTOY_DIR/boot/boot.img" of="$OUT" bs=446 count=1 conv=notrunc status=none
xz -dc "$VENTOY_DIR/boot/core.img.xz" | dd of="$OUT" bs=512 seek=1 conv=notrunc status=none

# partition 1: build a FAT32 filesystem image and populate it with mtools
P1IMG=$(mktemp /tmp/ventoy-part1.XXXXXX.img)
truncate -s "${P1_MB}M" "$P1IMG"
mformat -i "$P1IMG" -F -T $((P1_MB * 2048)) -h 255 -s 63 ::
mmd -i "$P1IMG" ::/ventoy ::/rescue-config
mcopy -i "$P1IMG" "$SCRIPT_DIR/ventoy.json" ::/ventoy/ventoy.json
mcopy -i "$P1IMG" "$PE_ISO" ::/AI-Rescue-PE.iso
mcopy -i "$P1IMG" "$FUSION_ISO" ::/HotPE-Fusion-AIRescue.iso
if [ -n "${PE32_ISO:-}" ]; then
  mcopy -i "$P1IMG" "$PE32_ISO" ::/AI-Rescue-PE-32.iso
fi
if [ -f "$SCRIPT_DIR/../pe/rescue-agent/agent.conf.example" ]; then
  mcopy -i "$P1IMG" "$SCRIPT_DIR/../pe/rescue-agent/agent.conf.example" ::/rescue-config/agent.conf.example
fi
mdir -i "$P1IMG" ::/ ::/ventoy ::/rescue-config
dd if="$P1IMG" of="$OUT" bs=1M seek="$P1_START_MB" conv=notrunc status=none
rm -f "$P1IMG"

ls -la "$OUT"
sha256sum "$OUT"
echo "[ventoy-img] DONE"
