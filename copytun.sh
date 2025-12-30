#!/usr/bin/env bash
# copyTun - WaterWall Half-Duplex Tunnel Manager
# Stable menu + input-safe + systemd
# Run:
#   sudo ./copytun.sh
# One-liner:
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ShidRayGit/Copytun/main/copytun.sh)"

set -euo pipefail

VERSION="1.41"

BASE_DIR="/opt/waterwall-tunnels"
WW_HOME="/opt/waterwall"
BIN_DIR="$WW_HOME/bin"
BIN_PATH="$BIN_DIR/WaterWall"
LIBS_DIR="$WW_HOME/libs"
SERVICE_TEMPLATE="/etc/systemd/system/waterwall@.service"

URL_GCC_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64.zip"
URL_GCC_X64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64-old-cpu.zip"
URL_GCC_ARM64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64.zip"
URL_GCC_ARM64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64-old-cpu.zip"

# ---------- helpers ----------
log()   { printf '%s\n' "[*] $*"; }
warn()  { printf '%s\n' "[!] $*" >&2; }
die()   { printf '\n%s\n\n' "[ERROR] $*" >&2; exit 1; }
pause() { read -r -p $'\nPress Enter to continue... ' _ || true; }

clean_input() {
  local s="$1"
  s="${s//$'\r'/}"
  s="${s//[[:space:]]/}"
  printf '%s' "$s"
}

need_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo)."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_systemd() {
  have_cmd systemctl || die "systemd is required."
}

download() {
  if have_cmd wget; then
    wget -qO "$2" "$1"
  else
    curl -fsSL "$1" -o "$2"
  fi
}

ensure_unzip() {
  have_cmd unzip && return
  apt update -y >/dev/null
  apt install -y unzip >/dev/null
}

pick_binary() {
  local arch
  arch="$(uname -m)"
  printf '%s\n' "Select WaterWall binary:"
  if [[ "$arch" == "x86_64" ]]; then
    printf '%s\n' "1) amd64 (old-cpu recommended)"
    printf '%s\n' "2) amd64"
    read -r -p "Choice: " c
    c="$(clean_input "$c")"
    [[ "$c" == "2" ]] && echo "$URL_GCC_X64" || echo "$URL_GCC_X64_OLD"
  else
    printf '%s\n' "1) arm64"
    printf '%s\n' "2) arm64 old-cpu"
    read -r -p "Choice: " c
    c="$(clean_input "$c")"
    [[ "$c" == "2" ]] && echo "$URL_GCC_ARM64_OLD" || echo "$URL_GCC_ARM64"
  fi
}

install_waterwall() {
  [[ -x "$BIN_PATH" ]] && return
  mkdir -p "$BIN_DIR" "$LIBS_DIR"
  ensure_unzip
  local url tmp
  url="$(pick_binary)"
  tmp="$(mktemp).zip"
  log "Downloading WaterWall..."
  download "$url" "$tmp"
  unzip -oq "$tmp" -d /tmp/waterwall
  cp /tmp/waterwall/WaterWall "$BIN_PATH"
  chmod +x "$BIN_PATH"
  rm -rf "$tmp" /tmp/waterwall
}

ensure_service() {
  [[ -f "$SERVICE_TEMPLATE" ]] && return
  cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=WaterWall Tunnel (%i)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR/%i
ExecStart=$BIN_PATH
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

create_tunnel() {
  read -r -p "Tunnel name: " NAME
  NAME="$(clean_input "$NAME")"
  [[ -z "$NAME" ]] && die "Empty name."
  local DIR="$BASE_DIR/$NAME"
  mkdir -p "$DIR/configs" "$DIR/logs"

  printf '%s\n' "1) Iran server"
  printf '%s\n' "2) Foreign server"
  read -r -p "Role: " ROLE
  ROLE="$(clean_input "$ROLE")"

  if [[ "$ROLE" == "1" ]]; then
    read -r -p "Local listen port: " LPORT
    read -r -p "Foreign IP: " FIP
    read -r -p "Tunnel port: " TPORT
    LPORT="$(clean_input "$LPORT")"
    FIP="$(clean_input "$FIP")"
    TPORT="$(clean_input "$TPORT")"

    cat > "$DIR/configs/iran.json" <<EOF
{
 "name":"iran",
 "nodes":[
  {"name":"in","type":"TcpListener","settings":{"address":"0.0.0.0","port":$LPORT},"next":"hd"},
  {"name":"hd","type":"HalfDuplexClient","next":"out"},
  {"name":"out","type":"TcpConnector","settings":{"address":"$FIP","port":$TPORT}}
 ]
}
EOF
    PROFILE="client"
    CFG="configs/iran.json"
  else
    read -r -p "Target service port: " TARGET
    read -r -p "Tunnel listen port: " LPORT
    TARGET="$(clean_input "$TARGET")"
    LPORT="$(clean_input "$LPORT")"

    cat > "$DIR/configs/foreign.json" <<EOF
{
 "name":"foreign",
 "nodes":[
  {"name":"in","type":"TcpListener","settings":{"address":"0.0.0.0","port":$LPORT},"next":"hd"},
  {"name":"hd","type":"HalfDuplexServer","next":"out"},
  {"name":"out","type":"TcpConnector","settings":{"address":"127.0.0.1","port":$TARGET}}
 ]
}
EOF
    PROFILE="server"
    CFG="configs/foreign.json"
  fi

  cat > "$DIR/$NAME.json" <<EOF
{
 "log":{"path":"logs/"},
 "misc":{"ram-profile":"$PROFILE","libs-path":"libs/"},
 "configs":["$CFG"]
}
EOF

  ln -sfn "$NAME.json" "$DIR/core.json"
  ln -sfn "$LIBS_DIR" "$DIR/libs"

  systemctl enable --now "waterwall@$NAME.service"
  log "Tunnel $NAME started."
  pause
}

main_menu() {
  need_root
  require_systemd
  install_waterwall
  ensure_service
  mkdir -p "$BASE_DIR"

  while true; do
    printf '\n%s\n' "============================================="
    printf ' copyTun - WaterWall Half-Duplex Manager v%s\n' "$VERSION"
    printf '%s\n' "============================================="
    printf '%s\n' "1) Create tunnel"
    printf '%s\n' "2) Exit"
    printf '%s\n' "---------------------------------------------"
    read -r -p "Choice: " c
    c="$(clean_input "$c")"
    case "$c" in
      1) create_tunnel ;;
      2) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main_menu