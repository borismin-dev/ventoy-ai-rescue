#!/bin/bash
# AI-Rescue-PE-32 build script (v3) — 32-bit i686 fallback Live rescue ISO.
# Slim sibling of build-pe.sh for old 32-bit machines (Pentium 4 / early Core
# era, 512 MB-1 GB RAM): Legacy BIOS first, diagnose/cleanup/panel/unlock,
# no fixboot deep repair, no gparted. Run as root on Debian 13 (InstaBox main-1).
# The i386 binaries run natively on the x86_64 kernel, so chroot steps work.
# BASE SUITE = bookworm (Debian 12), not trixie: Debian 13 removed the i386
# kernel entirely (trixie i386 is multiarch-only, for running 32-bit binaries
# on amd64 hosts). Bookworm is the last release with i386 kernels (686 /
# 686-pae) and has LTS support until 2028-06-30.
set -e
export PATH=$PATH:/usr/sbin:/sbin
WORK=${WORK:-/data/home/build/pe32}
ROOTFS=$WORK/rootfs
ISO_DIR=$WORK/iso
OUT=${OUT:-/data/home/dist-v3/AI-Rescue-PE-32.iso}
SRC=${SRC:-/data/home/build/files}   # ai-debug, rescue-agent.py, rescue-boot.sh, units live here
mkdir -p "$WORK" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

# Trimmed vs the amd64 build: no gparted (GUI), no vim-tiny/net-tools/sshfs/
# bash-completion/memtester. Old-NIC support is in-kernel (8139too, e1000,
# via-rhine, sis900 are modules in linux-image-686-pae; firmware-linux-free
# covers the few chips that need blobs).
PACKAGES="live-boot,systemd-sysv,linux-image-686-pae,firmware-linux-free,parted,testdisk,gddrescue,smartmontools,ntfs-3g,chntpw,rsync,curl,openssh-client,openssh-server,python3,util-linux,fdisk,iproute2,iputils-ping,wget,less,nano,file,usbutils,pciutils,hdparm,lvm2,mdadm,cryptsetup-bin,dislocker,e2fsprogs,xfsprogs,btrfs-progs,dosfstools,exfatprogs,ca-certificates,locales,console-setup,keyboard-configuration,sudo,psmisc,avahi-daemon,libnss-mdns,dbus,qrencode,jq,isc-dhcp-client,fbterm,fontconfig"

if [ "${CLEAN:-0}" = "1" ]; then rm -rf "$ROOTFS"; fi
if [ ! -d "$ROOTFS/boot" ]; then
  echo "[pe32] mmdebstrap i386 rootfs -> $ROOTFS"
  mmdebstrap --mode=root --arch=i386 --variant=minbase --include="$PACKAGES" bookworm "$ROOTFS" http://deb.debian.org/debian
fi

echo "[pe32] configure rootfs"
if [ -d "$ROOTFS/boot" ]; then
  chroot "$ROOTFS" bash -c 'export DEBIAN_FRONTEND=noninteractive; dpkg -s dislocker fbterm fontconfig >/dev/null 2>&1 || { apt-get update && apt-get install -y dislocker fbterm fontconfig; }' || echo "[pe32] WARN: v3 package ensure failed (continuing)"
fi
echo "ai-rescue" > "$ROOTFS/etc/hostname"
chroot "$ROOTFS" bash -c 'id rescue 2>/dev/null || useradd -m -s /bin/bash rescue; echo "rescue:rescue" | chpasswd; usermod -aG sudo rescue' || true

# --- tools (same sources as the 64-bit PE) ---
[ -f "$SRC/ai-debug" ] && install -m 0755 "$SRC/ai-debug" "$ROOTFS/usr/local/bin/ai-debug"
ln -sf ai-debug "$ROOTFS/usr/local/bin/ai-rescue"
[ -f "$SRC/rescue-agent.py" ] && install -m 0755 "$SRC/rescue-agent.py" "$ROOTFS/usr/local/bin/rescue-agent"
[ -f "$SRC/panel.html" ] && install -D -m 0644 "$SRC/panel.html" "$ROOTFS/usr/local/share/rescue-panel.html"
[ -f "$SRC/rescue-boot.sh" ] && install -m 0755 "$SRC/rescue-boot.sh" "$ROOTFS/usr/local/bin/rescue-boot"
install -m 0644 "$SRC/rescue-agent.service" "$ROOTFS/etc/systemd/system/rescue-agent.service"
install -m 0644 "$SRC/rescue-setup.service" "$ROOTFS/etc/systemd/system/rescue-setup.service"
install -m 0644 "$SRC/10-wired-dhcp.network" "$ROOTFS/etc/systemd/network/10-wired-dhcp.network"
mkdir -p "$ROOTFS/opt/rescue-config-example"
[ -f "$SRC/agent.conf.example" ] && install -m 0644 "$SRC/agent.conf.example" "$ROOTFS/opt/rescue-config-example/agent.conf.example"

# NOTE: the getty@tty1 autologin drop-in is written ONCE, further below
# ("console autologin on tty1" section) — do not add a second writer
# here; see build-pe.sh for why.

# --- enable services ---
W="$ROOTFS/etc/systemd/system/multi-user.target.wants"
mkdir -p "$W"
for s in rescue-agent rescue-setup; do
  ln -sf "/etc/systemd/system/$s.service" "$W/$s.service" || true
done
for s in ssh avahi-daemon systemd-networkd; do
  ln -sf "/lib/systemd/system/$s.service" "$W/$s.service" || true
done
mkdir -p "$ROOTFS/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.socket "$ROOTFS/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" || true
ln -sf /lib/systemd/system/dbus.service "$W/dbus.service" || true
ln -sf /lib/systemd/system/avahi-daemon.service "$W/avahi-daemon.service" || true
mkdir -p "$ROOTFS/etc/systemd/system/dbus-org.freedesktop.Avahi.service.d" || true

# --- console autologin on tty1 ---
# v3: ExecStartPre adds rescue to the video group first (fbterm needs
# /dev/fb0, root:video 0660; live-config does not put rescue in video).
# See build-pe.sh for the full note.
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStartPre=-/usr/sbin/usermod -aG video rescue
ExecStart=
ExecStart=-/sbin/agetty --autologin rescue --noclear %I $TERM
EOF

# --- sshd ---
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/10-rescue.conf" <<'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
EOF
mkdir -p "$ROOTFS/etc/systemd/system/ssh.service.d"
cat > "$ROOTFS/etc/systemd/system/ssh.service.d/rescue-keys.conf" <<'EOF'
[Service]
ExecStartPre=-/usr/bin/ssh-keygen -A
EOF

# --- mDNS name resolution from inside the PE too ---
if grep -q '^hosts:' "$ROOTFS/etc/nsswitch.conf" 2>/dev/null && ! grep -q mdns "$ROOTFS/etc/nsswitch.conf"; then
  sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' "$ROOTFS/etc/nsswitch.conf"
fi

# --- 中文语言环境 + 子集字体 + fbterm（与 64 位版一致） ---
chroot "$ROOTFS" bash -c 'sed -i "s/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen 2>/dev/null; locale-gen zh_CN.UTF-8 >/dev/null 2>&1' || true
printf 'LANG=zh_CN.UTF-8\n' > "$ROOTFS/etc/default/locale"
if [ -f "$SRC/fonts/NotoSansSC-Subset.ttf" ]; then
  install -D -m 0644 "$SRC/fonts/NotoSansSC-Subset.ttf" "$ROOTFS/usr/share/fonts/truetype/rescue/NotoSansSC-Subset.ttf"
  chroot "$ROOTFS" fc-cache -f >/dev/null 2>&1 || true
fi
mkdir -p "$ROOTFS/home/rescue"
cat > "$ROOTFS/home/rescue/.profile" <<'EOF'
# AI-Rescue-PE 登录钩子（构建时写入）
if [ "$TERM" = "fbterm" ] && [ -z "$RESCUE_BANNER_SHOWN" ]; then
  export RESCUE_BANNER_SHOWN=1
  for i in $(seq 1 30); do [ -s /run/rescue-banner.txt ] && break; sleep 1; done
  [ -s /run/rescue-banner.txt ] && cat /run/rescue-banner.txt
fi
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -e /dev/fb0 ] && [ "$TERM" != "fbterm" ] && command -v fbterm >/dev/null 2>&1; then
  exec fbterm -- bash -l
fi
EOF
cat > "$ROOTFS/home/rescue/.fbtermrc" <<'EOF'
font-size=16
EOF
chroot "$ROOTFS" chown -R rescue:rescue /home/rescue || true

# --- motd ---
cat > "$ROOTFS/etc/motd" <<'EOF'
================================================================
 AI-Rescue-PE-32（Linux Live 救援环境 32 位精简版，不是微软 WinPE）
 主机名：ai-rescue（mDNS：ai-rescue.local）- 自动 DHCP、自动登录
 维护智能体 API 开机自动在 8734 端口启动。
 开机横幅上的令牌（TOKEN）就是 API 令牌，也是 rescue 用户的
 SSH 密码（sudo 密码相同）。
 本机调试：
   ai-debug diagnose            离线诊断 -> /tmp/ai-report.txt
   ai-debug unlock              解锁 BitLocker 加密卷（交互输入恢复密钥）
================================================================
EOF

KERNEL=$(ls "$ROOTFS"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | head -1)
echo "[pe32] kernel=$KERNEL initrd=$INITRD"
cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd.img"

echo "[pe32] mksquashfs"
rm -f "$ISO_DIR/live/filesystem.squashfs"
nice -n 10 ionice -c3 mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -comp xz -e boot -noappend

cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=10
insmod all_video
menuentry "AI-Rescue-PE-32（32 位救援系统 + ai-debug + rescue-agent）" {
  linux /live/vmlinuz boot=live components quiet username=rescue hostname=ai-rescue
  initrd /live/initrd.img
}
menuentry "AI-Rescue-PE-32（安全图形模式 / nomodeset）" {
  linux /live/vmlinuz boot=live components nomodeset username=rescue hostname=ai-rescue
  initrd /live/initrd.img
}
EOF
mkdir -p "$ISO_DIR/EFI/BOOT"
grub-mkstandalone -O i386-efi -o "$ISO_DIR/EFI/BOOT/BOOTIA32.EFI" "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" || true
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/" || true
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/" || true
cat > "$ISO_DIR/isolinux.cfg" <<'EOF'
DEFAULT live
TIMEOUT 100
LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet username=rescue hostname=ai-rescue
EOF

echo "[pe32] xorriso -> $OUT"
mkdir -p "$(dirname "$OUT")"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "AI_RESCUE_P32" \
  -eltorito-boot isolinux.bin -eltorito-catalog boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot -e EFI/BOOT/BOOTIA32.EFI -no-emul-boot -isohybrid-gpt-basdat \
  -output "$OUT" "$ISO_DIR" || \
xorriso -as mkisofs -iso-level 3 -volid "AI_RESCUE_P32" \
  -eltorito-boot isolinux.bin -eltorito-catalog boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
  -output "$OUT" "$ISO_DIR"
ls -lh "$OUT"; sha256sum "$OUT"
echo "[pe32] DONE"
