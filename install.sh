#!/usr/bin/env bash
# NextTrace Agent — 一键安装
# curl -fsSL https://raw.githubusercontent.com/reallinzc/nexttrace-web/main/install.sh | bash -s -- --host <id>
#
# Options:
#   --host <id>       Host ID (default: auto from hostname)
#   --label <name>    Display name (default: auto from ASN/hostname)
#   --region <region> Region (default: auto from IP geolocation)
#   --server <url>    WS server (default: wss://nexttrace.xunxian.cc/ws/agent)
#   --key <secret>    Agent key (default: none)
#   --uninstall       Remove agent
set -euo pipefail

# ── Parse args ──
HOST_ID=""
LABEL=""
REGION=""
SERVER="wss://nexttrace.xunxian.cc/ws/agent"
KEY=""
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)   HOST_ID="$2"; shift 2 ;;
    --label)  LABEL="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --server) SERVER="$2"; shift 2 ;;
    --key)    KEY="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Uninstall ──
if [ "$UNINSTALL" -eq 1 ]; then
  echo "Removing nt-agent..."
  systemctl stop nt-agent 2>/dev/null || true
  systemctl disable nt-agent 2>/dev/null || true
  rm -f /etc/systemd/system/nt-agent.service
  systemctl daemon-reload
  rm -rf /opt/nt-agent
  echo "✅ Removed"
  exit 0
fi

# ── Auto-detect via IP geolocation ──
echo "=== NextTrace Agent Install ==="
echo ""

GEO_JSON=""
detect_geo() {
  # Try multiple providers
  GEO_JSON=$(curl -fsSL --max-time 5 "https://ipinfo.io/json" 2>/dev/null || \
              curl -fsSL --max-time 5 "https://ip.sb/geoip" 2>/dev/null || \
              echo '{}')
}

if [ -z "$HOST_ID" ] || [ -z "$LABEL" ] || [ -z "$REGION" ]; then
  echo "[*] Auto-detecting location..."
  detect_geo
fi

# Host ID: fallback to sanitized hostname
if [ -z "$HOST_ID" ]; then
  HOST_ID=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | head -c 32)
  [ -z "$HOST_ID" ] && HOST_ID="node-$(date +%s | tail -c 6)"
fi

# Region: from geo
if [ -z "$REGION" ]; then
  CITY=$(echo "$GEO_JSON" | grep -o '"city"\s*:\s*"[^"]*"' | head -1 | cut -d'"' -f4)
  COUNTRY=$(echo "$GEO_JSON" | grep -o '"country"\s*:\s*"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$CITY" ]; then
    REGION="$CITY"
  elif [ -n "$COUNTRY" ]; then
    REGION="$COUNTRY"
  else
    REGION="Unknown"
  fi
fi

# Label: from ASN org or hostname
if [ -z "$LABEL" ]; then
  ORG=$(echo "$GEO_JSON" | grep -o '"org"\s*:\s*"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$ORG" ]; then
    # Extract short name: "AS12345 DMIT Inc" -> "DMIT"
    SHORT=$(echo "$ORG" | sed 's/^AS[0-9]* *//' | awk '{print $1}')
    LABEL="${SHORT:-$HOST_ID}"
  else
    LABEL="$HOST_ID"
  fi
fi

IP=$(echo "$GEO_JSON" | grep -o '"ip"\s*:\s*"[^"]*"' | head -1 | cut -d'"' -f4)

echo ""
echo "  Host ID : $HOST_ID"
echo "  Label   : $LABEL"
echo "  Region  : $REGION"
echo "  IP      : ${IP:-unknown}"
echo "  Server  : $SERVER"
echo ""

# ── Install nexttrace ──
echo "[1/3] nexttrace..."
if command -v nexttrace &>/dev/null; then
  echo "  ✅ $(nexttrace --version 2>&1 | head -1 | sed 's/\x1b\[[0-9;]*m//g')"
else
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) echo "  ❌ Unsupported arch: $ARCH"; exit 1 ;;
  esac
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  DL=$(curl -fsSL "https://api.github.com/repos/nxtrace/NTrace-core/releases/latest" \
    | grep -o "https://[^\"]*${OS}_${ARCH}[^\"]*" | grep -v sha256 | head -1)
  [ -z "$DL" ] && echo "  ❌ No download URL for ${OS}_${ARCH}" && exit 1
  curl -fsSL -o /tmp/nexttrace "$DL"
  chmod +x /tmp/nexttrace
  mv /tmp/nexttrace /usr/local/bin/nexttrace
  echo "  ✅ installed"
fi

# ── Install Node.js ──
echo "[2/3] Node.js..."
if command -v node &>/dev/null; then
  echo "  ✅ $(node --version)"
else
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    yum install -y nodejs >/dev/null 2>&1
  elif command -v apk &>/dev/null; then
    apk add --no-cache nodejs npm >/dev/null 2>&1
  else
    echo "  ❌ No supported package manager"; exit 1
  fi
  echo "  ✅ $(node --version)"
fi

# ── Deploy agent ──
echo "[3/3] Agent..."
mkdir -p /opt/nt-agent
cd /opt/nt-agent

# Install ws dependency
[ -d node_modules/ws ] || (npm init -y >/dev/null 2>&1 && npm install ws >/dev/null 2>&1)

# Download agent script
curl -fsSL -o /opt/nt-agent/nt-agent.js \
  "https://raw.githubusercontent.com/reallinzc/nexttrace-web/main/nt-agent.js"

# Systemd service
cat > /etc/systemd/system/nt-agent.service <<SVC
[Unit]
Description=NextTrace Agent (${HOST_ID})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/nt-agent
ExecStart=/usr/bin/node /opt/nt-agent/nt-agent.js --server ${SERVER} --id ${HOST_ID} --key ${KEY}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable nt-agent >/dev/null 2>&1
systemctl restart nt-agent
sleep 2

if systemctl is-active --quiet nt-agent; then
  echo "  ✅ agent running"
else
  echo "  ❌ agent failed to start"
  journalctl -u nt-agent --no-pager -n 5
  exit 1
fi

echo ""
echo "=== ✅ Done ==="
echo "  ${HOST_ID} → ${SERVER}"
echo ""
echo "  管理命令:"
echo "    状态: systemctl status nt-agent"
echo "    日志: journalctl -u nt-agent -f"
echo "    卸载: curl -fsSL https://raw.githubusercontent.com/reallinzc/nexttrace-web/main/install.sh | bash -s -- --uninstall"
