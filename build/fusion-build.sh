#!/bin/bash
# Fusion build (runs on InstaBox main-1): SPLICE method, final recipe (v4.3).
#
# Why not a full ISO rebuild? Verified empirically on 2026-11-08:
#   - xorriso ISO9660/Joliet rebuilds fail at "CDBOOT: Couldn't find BOOTMGR"
#     (the original HotPE ISO is a UDF Bridge whose ISO9660 tree is only a
#     README.TXT stub; its boot chain reads BOOTMGR via UDF).
#   - A genisoimage -udf rebuild passes CDBOOT but bootmgr stalls/loops in
#     "Loading files..." (progress regresses, frames repeat on a ~1020 s
#     cycle; no /health within 1500 s), while the ORIGINAL ISO reaches the
#     Windows logo in ~300 s under the identical QEMU setup. Root cause:
#     cdrkit genisoimage's UDF extent allocation for large files is broken.
#   - A splice build with LZX chunk size 65536 got bootmgr to mount the WIM
#     and read the BCD, but winload.exe then failed with 0xc0000098:
#     bootmgr's built-in LZX decompressor only supports chunk <= 32768.
#
# Splice method: the pristine Boot.wim sits in ONE contiguous extent of the
# original ISO (offset 10600448, length 670543552; region sha256 == file
# sha256, verified). The fused WIM is recompressed (LZX:100, chunk 32768)
# to <= that length, zero-padded to exactly that length, and dd-written over
# the extent in a copy of the original ISO. Every other byte (UDF metadata,
# BCD, bootmgr, El Torito) stays bit-identical (head/tail hashes prove it).
# WIM tail padding is harmless: the format is header-offset driven.
#
# Fusion contents (all inside the WIM):
#   - ai-rescue.exe (stripped build, -ldflags '-s -w') -> /Windows/System32/
#   - agent autostart appended to HotPE's own /Windows/Pecmd.ini (last line,
#     runs after network init)
#   - WePE portable tools -> /ExtraTools/{Everything,Wimtool}
#     (WePE's portable Dism++ is NOT merged: HotPE already ships Dism++ as a
#     built-in module, duplicating it would waste the size budget)
# Size trims needed to fit the original extent (measured, see docs):
#   - stripped ai-rescue.exe (stored saving ~2.9 MB vs unstripped)
#   - HotPE random-wallpaper set (Windows\Web\Wallpaper\HotPE) removed except
#     one file; the Pecmd LOGO wallpaper (Windows\img0.jpg) is untouched.
set -x
W=${W:-/data/home/build/winpe}
SRCWIM=$W/hotpe/HotPE/Boot.wim
ORIGISO=$W/dl/HotPE-V2.8.251018.iso
WORK=${WORK_DIR:-$W/fusion-v4}
OUT_ISO=${OUT_ISO:-/data/home/dist/HotPE-Fusion-AIRescue.iso}
LIMIT=670543552
WIM_OFFSET_SEEK=2588   # 10600448 / 4096
mkdir -p $WORK/extras

cp $SRCWIM $WORK/BootF.wim || exit 2

# Pecmd.ini: extract pristine copy, append autostart line at the very end.
wimlib-imagex extract $SRCWIM 1 Windows/Pecmd.ini --dest-dir=$WORK || exit 2
printf '\r\n' >> $WORK/Pecmd.ini
printf '%s\r\n' 'EXEC !cmd /c start /min X:\Windows\System32\ai-rescue.exe agent' >> $WORK/Pecmd.ini

# Keep exactly one random wallpaper.
wimlib-imagex extract $SRCWIM 1 'Windows/Web/Wallpaper/HotPE/(1).jpg' --dest-dir=$WORK/keepwp || exit 2

# Stage the WePE portable tools at space-free paths for wimlib.
cp -r "$W/wepe/Program Files/Everything" $WORK/extras/Everything || exit 2
cp -r "$W/wepe/Program Files/Wimtool"    $WORK/extras/Wimtool    || exit 2

# v2 additions: ai-debug alias shim for the Windows PE + a desktop
# reopen entry (the agent lives in a console window; closing it stops
# the service, so the desktop gets a one-click way back). Injected into
# both Default and Public desktops - whichever the HotPE shell shows.
printf '@echo off\r\nstart ai-rescue.exe agent\r\n' > $WORK/extras/reopen-agent.cmd

# wimlib update: multiple commands go on standard input.
wimlib-imagex update $WORK/BootF.wim 1 <<EOF || exit 3
add $W/ai-rescue.exe /Windows/System32/ai-rescue.exe
add $W/ai-debug.cmd /Windows/System32/ai-debug.cmd
add $WORK/extras/reopen-agent.cmd /Users/Default/Desktop/AI维护-重开.cmd
add $WORK/extras/reopen-agent.cmd /Users/Public/Desktop/AI维护-重开.cmd
delete /Windows/Pecmd.ini
add $WORK/Pecmd.ini /Windows/Pecmd.ini
add $WORK/extras/Everything /ExtraTools/Everything
add $WORK/extras/Wimtool /ExtraTools/Wimtool
delete --recursive /Windows/Web/Wallpaper/HotPE
add $WORK/keepwp/(1).jpg /Windows/Web/Wallpaper/HotPE/(1).jpg
EOF

wimlib-imagex optimize $WORK/BootF.wim --recompress --compress=LZX:100 --chunk-size=32768 || exit 4
SZ=$(stat -c %s $WORK/BootF.wim)
echo "SIZE=$SZ LIMIT=$LIMIT"
[ "$SZ" -le "$LIMIT" ] || exit 5

# Pad to exactly the original WIM length and splice into a copy of the ISO.
truncate -s $LIMIT $WORK/BootF.wim || exit 6
cp $ORIGISO "$OUT_ISO" || exit 7
dd if=$WORK/BootF.wim of="$OUT_ISO" \
   bs=4096 seek=$WIM_OFFSET_SEEK conv=notrunc || exit 8
sha256sum "$OUT_ISO"
echo FUSION-DONE
