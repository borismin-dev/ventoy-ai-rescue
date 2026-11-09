#!/bin/bash
# AI-Rescue-PE build script v2 — Linux Live rescue ISO (NOT Microsoft WinPE)
# Run as root (sudo bash build-pe.sh) on Debian 13 x86_64 (InstaBox main-1).
# NOTE: as a normal user mmdebstrap fails with "unable to pick chroot mode
# automatically" in this VM; running as root with --mode=root works (verified
# 2026-11-08). Set CLEAN=1 to rebuild the rootfs from scratch.
set -e
export PATH=$PATH:/usr/sbin:/sbin
WORK=${WORK:-/data/home/build/pe}
ROOTFS=$WORK/rootfs
ISO_DIR=$WORK/iso
OUT=${OUT:-/data/home/dist/AI-Rescue-PE.iso}
SRC=${SRC:-/data/home/build/files}   # ai-debug, rescue-agent.py, rescue-boot.sh, units live here
mkdir -p "$WORK" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

PACKAGES="live-boot,systemd-sysv,linux-image-amd64,firmware-linux-free,parted,gparted,testdisk,gddrescue,smartmontools,ntfs-3g,chntpw,memtester,rsync,curl,openssh-client,openssh-server,python3,util-linux,fdisk,iproute2,iputils-ping,net-tools,wget,less,vim-tiny,nano,file,usbutils,pciutils,hdparm,lvm2,mdadm,cryptsetup-bin,e2fsprogs,xfsprogs,btrfs-progs,dosfstools,exfatprogs,sshfs,ca-certificates,bash-completion,locales,console-setup,keyboard-configuration,sudo,psmisc,avahi-daemon,libnss-mdns,dbus,qrencode,jq,isc-dhcp-client"

if [ "${CLEAN:-0}" = "1" ]; then rm -rf "$ROOTFS"; fi
if [ ! -d "$ROOTFS/boot" ]; then
  echo "[pe] mmdebstrap rootfs -> $ROOTFS"
  mmdebstrap --mode=root --variant=minbase --include="$PACKAGES" trixie "$ROOTFS" http://deb.debian.org/debian
fi

echo "[pe] configure rootfs"
# hostname is FIXED to ai-rescue so mDNS publishes ai-rescue.local
echo "ai-rescue" > "$ROOTFS/etc/hostname"
# initial user rescue / password rescue — REPLACED at every boot by the random
# boot token (rescue-boot sets it via chpasswd). The fixed value only covers
# the first seconds of the first boot and local-console fallback.
chroot "$ROOTFS" bash -c 'id rescue 2>/dev/null || useradd -m -s /bin/bash rescue; echo "rescue:rescue" | chpasswd; usermod -aG sudo rescue' || true

# --- tools ---
[ -f "$SRC/ai-debug" ] && install -m 0755 "$SRC/ai-debug" "$ROOTFS/usr/local/bin/ai-debug"
# v2 command-name unification: `ai-rescue` works on the Linux PE too
# (the Windows PE gets an ai-debug.cmd shim next to ai-rescue.exe).
ln -sf ai-debug "$ROOTFS/usr/local/bin/ai-rescue"
[ -f "$SRC/rescue-agent.py" ] && install -m 0755 "$SRC/rescue-agent.py" "$ROOTFS/usr/local/bin/rescue-agent"
[ -f "$SRC/panel.html" ] && install -D -m 0644 "$SRC/panel.html" "$ROOTFS/usr/local/share/rescue-panel.html"
[ -f "$SRC/rescue-boot.sh" ] && install -m 0755 "$SRC/rescue-boot.sh" "$ROOTFS/usr/local/bin/rescue-boot"
install -m 0644 "$SRC/rescue-agent.service" "$ROOTFS/etc/systemd/system/rescue-agent.service"
install -m 0644 "$SRC/rescue-setup.service" "$ROOTFS/etc/systemd/system/rescue-setup.service"
install -m 0644 "$SRC/10-wired-dhcp.network" "$ROOTFS/etc/systemd/network/10-wired-dhcp.network"
mkdir -p "$ROOTFS/opt/rescue-config-example"
[ -f "$SRC/agent.conf.example" ] && install -m 0644 "$SRC/agent.conf.example" "$ROOTFS/opt/rescue-config-example/agent.conf.example"

# --- enable services (symlinks; systemctl enable also works in chroot) ---
W="$ROOTFS/etc/systemd/system/multi-user.target.wants"
mkdir -p "$W"
for s in rescue-agent rescue-setup; do
  ln -sf "/etc/systemd/system/$s.service" "$W/$s.service" || true
done
# NOTE: ln -sf succeeds even for a dangling target, so distro units must be
# linked to their real /lib path explicitly (an /etc-first attempt silently
# produced a dangling ssh.service symlink in the first v2 build - caught in
# pre-QEMU inspection 2026-11-08).
for s in ssh avahi-daemon systemd-networkd; do
  ln -sf "/lib/systemd/system/$s.service" "$W/$s.service" || true
done
mkdir -p "$ROOTFS/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.socket "$ROOTFS/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" || true
# dbus is required by avahi
ln -sf /lib/systemd/system/dbus.service "$W/dbus.service" || true
ln -sf /lib/systemd/system/avahi-daemon.service "$W/avahi-daemon.service" || true
mkdir -p "$ROOTFS/etc/systemd/system/dbus-org.freedesktop.Avahi.service.d" || true

# --- console autologin on tty1 (user is physically present at the machine) ---
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin rescue --noclear %I $TERM
EOF

# --- sshd: password auth on (password = per-boot token), no root login ---
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/10-rescue.conf" <<'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
EOF
# host keys are generated on first boot by ssh.service (Debian does this via
# sshd-keygen / ssh-keygen -A in the unit's ExecStartPre on most builds);
# make sure of it:
cat > "$ROOTFS/etc/systemd/system/ssh.service.d-rescue.conf" <<'EOF'
EOF
mkdir -p "$ROOTFS/etc/systemd/system/ssh.service.d"
cat > "$ROOTFS/etc/systemd/system/ssh.service.d/rescue-keys.conf" <<'EOF'
[Service]
ExecStartPre=-/usr/bin/ssh-keygen -A
EOF
rm -f "$ROOTFS/etc/systemd/system/ssh.service.d-rescue.conf"

# --- mDNS name resolution from inside the PE too ---
if grep -q '^hosts:' "$ROOTFS/etc/nsswitch.conf" 2>/dev/null && ! grep -q mdns "$ROOTFS/etc/nsswitch.conf"; then
  sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' "$ROOTFS/etc/nsswitch.conf"
fi

# --- motd ---
cat > "$ROOTFS/etc/motd" <<'EOF'
================================================================
 AI-Rescue-PE  (Linux Live rescue environment, not Microsoft WinPE)
 Hostname: ai-rescue  (mDNS: ai-rescue.local) - auto DHCP, auto login
 A maintenance agent API starts automatically on port 8734.
 The per-boot TOKEN on the boot banner is the API token AND the
 SSH password for user "rescue" (sudo password = same token).

 Agent API (from another agent on the LAN):
   curl http://ai-rescue.local:8734/health
   curl -H "X-Rescue-Token: <TOKEN>" http://ai-rescue.local:8734/diagnose
   ssh rescue@ai-rescue.local
 Local AI debugging:
   ai-debug diagnose            offline diagnosis -> /tmp/ai-report.txt
   ai-debug diagnose --llm      + LLM (needs AI_API_KEY via rescue-config)
   ai-debug ask "question"      ask the LLM (OpenAI-compatible API)
   ai-debug setup-local-model   optional local llama.cpp + small GGUF
 Plug-and-play config: put rescue-config/agent.conf in the root of
 the Ventoy USB data partition (LLM settings, reverse-tunnel relay).
================================================================
EOF

KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | head -1)
echo "[pe] kernel=$KERNEL initrd=$INITRD"
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd.img"

echo "[pe] mksquashfs"
# CRITICAL: delete any previous squashfs first. mksquashfs appends to an
# existing destination by default, and even with -noappend the v2 builds on
# 2026-11-08 produced an archive containing THREE stacked root filesystems
# (the live system then booted the oldest copy). Verified via unsquashfs -l.
rm -f "$ISO_DIR/live/filesystem.squashfs"
mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -comp xz -e boot -noappend

cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=10
insmod all_video
menuentry "AI-Rescue-PE (Linux Live Rescue + ai-debug + rescue-agent)" {
  linux /live/vmlinuz boot=live components quiet username=rescue hostname=ai-rescue
  initrd /live/initrd.img
}
menuentry "AI-Rescue-PE (safe graphics / nomodeset)" {
  linux /live/vmlinuz boot=live components nomodeset username=rescue hostname=ai-rescue
  initrd /live/initrd.img
}
EOF
mkdir -p "$ISO_DIR/EFI/BOOT"
grub-mkstandalone -O x86_64-efi -o "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" || true
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/" || true
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/" || true
cat > "$ISO_DIR/isolinux.cfg" <<'EOF'
DEFAULT live
TIMEOUT 100
LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet username=rescue hostname=ai-rescue
EOF

echo "[pe] xorriso -> $OUT"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "AI_RESCUE_PE" \
  -eltorito-boot isolinux.bin -eltorito-catalog boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot -e EFI/BOOT/BOOTX64.EFI -no-emul-boot -isohybrid-gpt-basdat \
  -output "$OUT" "$ISO_DIR" || \
xorriso -as mkisofs -iso-level 3 -volid "AI_RESCUE_PE" \
  -eltorito-boot isolinux.bin -eltorito-catalog boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
  -output "$OUT" "$ISO_DIR"
ls -lh "$OUT"; sha256sum "$OUT"
echo "[pe] DONE"
