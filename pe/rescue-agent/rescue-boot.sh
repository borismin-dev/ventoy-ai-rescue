#!/bin/bash
# rescue-boot - runs once at boot (rescue-setup.service), after rescue-agent.
# 1. takes the boot token from /run/rescue-token and sets it as rescue's SSH password
# 2. waits for a DHCP address, then prints the connection banner (with QR code)
#    to the console, tty1 and ttyS0 so any human/agent nearby can connect
# 3. optionally establishes the outbound ssh -R reverse tunnel when the USB
#    rescue-config/agent.conf defines TUNNEL_HOST (user's own relay only)
# The token exists only in tmpfs (/run) and on the physical screen. It is
# never written to disk, never baked into the ISO, never uploaded anywhere.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TOKEN_FILE=/run/rescue-token
for i in $(seq 1 30); do [ -s "$TOKEN_FILE" ] && break; sleep 1; done
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null)
[ -n "$TOKEN" ] || { echo "[rescue-boot] no token file, aborting"; exit 1; }

# SSH password = boot token (previous fixed password is replaced every boot)
echo "rescue:${TOKEN}" | chpasswd
echo "root:${TOKEN}" | chpasswd

# wait for DHCP (systemd-networkd) up to ~40s
IPLIST=""
for i in $(seq 1 20); do
  IPLIST=$(ip -brief -4 a | grep -v '^lo' | awk '$2=="UP"{print $1": "$3}' | paste -sd'; ' -)
  [ -n "$IPLIST" ] && break
  sleep 2
done
[ -z "$IPLIST" ] && IPLIST="(no IPv4 yet - check cable / DHCP)"

# ---- optional outbound reverse tunnel (user's own relay from agent.conf) ----
TUNNEL_STATUS="off (LAN only - no TUNNEL_HOST in rescue-config/agent.conf)"
# shellcheck disable=SC1091
[ -f /run/rescue-config.env ] && . /run/rescue-config.env
if [ -n "${TUNNEL_HOST:-}" ]; then
  TUSER="${TUNNEL_USER:-root}"
  TPORT="${TUNNEL_PORT:-22}"
  RAPI="${TUNNEL_REMOTE_API_PORT:-18734}"
  RSSH="${TUNNEL_REMOTE_SSH_PORT:-10022}"
  KEYOPT=""
  if [ -n "${TUNNEL_KEY:-}" ] && [ -f "/run/agent.conf.dir/${TUNNEL_KEY}" ]; then
    KEYOPT="-i /run/agent.conf.dir/${TUNNEL_KEY}"
  elif [ -n "${TUNNEL_KEY:-}" ]; then
    # key may sit next to agent.conf on the USB; rescue-agent copied only the conf,
    # so also probe common mount points
    for d in /run/live/medium/rescue-config; do
      [ -f "$d/${TUNNEL_KEY}" ] && KEYOPT="-i $d/${TUNNEL_KEY}"
    done
  fi
  nohup ssh -N -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    -o ExitOnForwardFailure=yes $KEYOPT -p "$TPORT" \
    -R "${RAPI}:127.0.0.1:8734" -R "${RSSH}:127.0.0.1:22" \
    "${TUSER}@${TUNNEL_HOST}" > /run/tunnel.log 2>&1 &
  sleep 3
  if kill -0 $! 2>/dev/null; then
    TUNNEL_STATUS="on -> ${TUSER}@${TUNNEL_HOST}:${TPORT} (api :${RAPI}, ssh :${RSSH} on relay)"
  else
    TUNNEL_STATUS="FAILED to ${TUNNEL_HOST} - see /run/tunnel.log (LAN access still works)"
  fi
fi
echo "$TUNNEL_STATUS" > /run/tunnel.status

# The QR / connect URL must be openable from other LAN devices: prefer the
# wired interface's LAN IP, fall back to any IPv4, then to the mDNS name.
FIRST_IP="$(echo "$IPLIST" | tr ';' '\n' | grep -E '^[[:space:]]*e' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
[ -z "$FIRST_IP" ] && FIRST_IP="$(echo "$IPLIST" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
if [ -n "$FIRST_IP" ]; then
  CONNECT_URL="http://${FIRST_IP}:8734/?token=${TOKEN}"
else
  CONNECT_URL="http://ai-rescue.local:8734/?token=${TOKEN}"
fi
{
  echo ""
  echo "================================================================"
  echo "   AI-Rescue-PE  -  ready for maintenance agents"
  echo "================================================================"
  echo "  Host (mDNS) : ai-rescue.local        (hostname: ai-rescue)"
  echo "  Interfaces  : ${IPLIST}"
  echo "  Agent API   : http://ai-rescue.local:8734   (/health /info /diagnose /exec)"
  echo "  SSH         : ssh rescue@ai-rescue.local"
  echo "  TOKEN       : ${TOKEN}"
  echo "  SSH password: (the TOKEN above - changes every boot)"
  echo "  Tunnel      : ${TUNNEL_STATUS}"
  echo "  Offline diag: ai-debug diagnose"
  echo "----------------------------------------------------------------"
  echo "  Scan to connect:"
  qrencode -t ANSIUTF8 -s 1 "$CONNECT_URL" 2>/dev/null || echo "  $CONNECT_URL"
  echo "  $CONNECT_URL"
  echo "================================================================"
  # machine-parsable line (used by the QEMU verification harness)
  echo "RESCUE-TOKEN: ${TOKEN}"
} > /run/rescue-banner.txt 2>&1

# show banner on every available console
for tty in /dev/console /dev/tty1 /dev/ttyS0; do
  [ -w "$tty" ] && cat /run/rescue-banner.txt > "$tty" 2>/dev/null
done
cp /run/rescue-banner.txt /etc/issue 2>/dev/null || true
echo "[rescue-boot] banner printed; tunnel: ${TUNNEL_STATUS}"
