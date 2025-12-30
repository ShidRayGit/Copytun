#!/usr/bin/env bash
# Copytun - WaterWall Half-Duplex Tunnel Manager
# Author: ShidRayGit
# Requires: bash, systemd, wget/curl, unzip
set -u

VERSION="1.41"

BASE_DIR="/opt/waterwall-tunnels"
WW_HOME="/opt/waterwall"
BIN_DIR="${WW_HOME}/bin"
BIN_PATH="${BIN_DIR}/WaterWall"
LIBS_DIR="${WW_HOME}/libs"
SERVICE_TEMPLATE="/etc/systemd/system/waterwall@.service"

URL_GCC_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64.zip"
URL_GCC_X64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64-old-cpu.zip"
URL_GCC_ARM64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64.zip"
URL_GCC_ARM64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64-old-cpu.zip"

die() { echo -e "\n[!] $*\n" >&2; exit 1; }
info() { echo -e "[*] $*"; }
pause() { read -r -p $'\nEnter بزن برای ادامه...' _; }

need_root() {
  [[ $EUID -eq 0 ]] || die "اسکریپت باید با root اجرا شود (sudo)."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  have_cmd unzip && return
  info "نصب unzip ..."
  apt update && apt install -y unzip || die "نصب unzip ناموفق بود."
}

download() {
  local url="$1" out="$2"
  if have_cmd wget; then
    wget -qO "$out" "$url"
  elif have_cmd curl; then
    curl -fsSL "$url" -o "$out"
  else
    die "wget یا curl موجود نیست."
  fi
}

pick_binary() {
  local arch
  arch="$(uname -m)"

  echo
  echo "انتخاب باینری WaterWall:"
  echo "1) Auto (پیشنهادی)"
  echo "2) amd64"
  echo "3) amd64 old-cpu"
  echo "4) arm64"
  echo "5) arm64 old-cpu"
  read -r -p "گزینه: " c

  case "$arch:$c" in
    x86_64:3) echo "$URL_GCC_X64_OLD" ;;
    x86_64:2) echo "$URL_GCC_X64" ;;
    x86_64:*|*:1) echo "$URL_GCC_X64_OLD" ;;
    aarch64:5) echo "$URL_GCC_ARM64_OLD" ;;
    aarch64:4) echo "$URL_GCC_ARM64" ;;
    aarch64:*|*:1) echo "$URL_GCC_ARM64" ;;
    *) die "معماری پشتیبانی نمی‌شود: $arch" ;;
  esac
}

install_waterwall() {
  [[ -x "$BIN_PATH" ]] && return
  mkdir -p "$BIN_DIR" "$LIBS_DIR"

  install_deps
  local url tmpzip tmpdir
  url="$(pick_binary)"
  tmpzip="$(mktemp).zip"
  tmpdir="$(mktemp -d)"

  info "دانلود WaterWall..."
  download "$url" "$tmpzip"

  unzip -o "$tmpzip" -d "$tmpdir" >/dev/null
  local bin
  bin="$(find "$tmpdir" -type f -name 'WaterWall' -o -name 'Waterwall' | head -n1)"
  [[ -n "$bin" ]] || die "باینری WaterWall پیدا نشد."

  cp "$bin" "$BIN_PATH"
  chmod +x "$BIN_PATH"

  rm -rf "$tmpzip" "$tmpdir"
  info "WaterWall نصب شد."
}

ensure_service() {
  [[ -f "$SERVICE_TEMPLATE" ]] && return
  cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=WaterWall Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}/%i
ExecStart=${BIN_PATH}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

create_tunnel() {
  read -r -p "اسم تانل: " NAME
  [[ -z "$NAME" ]] && die "اسم خالی است."

  local DIR="${BASE_DIR}/${NAME}"
  [[ -e "$DIR" ]] && die "تانل وجود دارد."
  mkdir -p "$DIR/configs" "$DIR/logs"

  echo "1) سرور ایران"
  echo "2) سرور خارج"
  read -r -p "نقش: " ROLE

  if [[ "$ROLE" == "1" ]]; then
    read -r -p "پورت Listen لوکال (مثلاً 5055): " LPORT
    read -r -p "IP سرور خارج: " FIP
    read -r -p "پورت تانل (مثلاً 449): " TPORT

    cat > "$DIR/configs/iran.json" <<EOF
{
  "name": "${NAME}_iran",
  "nodes": [
    {
      "name": "in",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $LPORT },
      "next": "hdc"
    },
    { "name": "hdc", "type": "HalfDuplexClient", "next": "out" },
    {
      "name": "out",
      "type": "TcpConnector",
      "settings": { "address": "$FIP", "port": $TPORT }
    }
  ]
}
EOF

    CFG="configs/iran.json"
    PROFILE="client"
  else
    read -r -p "پورت سرویس مقصد (مثلاً xray): " TARGET
    read -r -p "پورت Listen تانل: " LPORT

    cat > "$DIR/configs/foreign.json" <<EOF
{
  "name": "${NAME}_foreign",
  "nodes": [
    {
      "name": "in",
      "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": $LPORT },
      "next": "hds"
    },
    { "name": "hds", "type": "HalfDuplexServer", "next": "out" },
    {
      "name": "out",
      "type": "TcpConnector",
      "settings": { "address": "127.0.0.1", "port": $TARGET }
    }
  ]
}
EOF

    CFG="configs/foreign.json"
    PROFILE="server"
  fi

  cat > "$DIR/${NAME}.json" <<EOF
{
  "log": { "path": "logs/" },
  "misc": { "ram-profile": "$PROFILE", "libs-path": "libs/" },
  "configs": ["$CFG"]
}
EOF

  ln -sfn "${NAME}.json" "$DIR/core.json"
  ln -sfn "$LIBS_DIR" "$DIR/libs"

  systemctl enable --now "waterwall@${NAME}.service"
  info "تانل ${NAME} فعال شد."
}

main_menu() {
  need_root
  install_waterwall
  ensure_service
  mkdir -p "$BASE_DIR"

  while true; do
    clear
    echo "==== Copytun ===="
    echo "1) ایجاد تانل"
    echo "2) لیست سرویس‌ها"
    echo "3) خروج"
    read -r -p "گزینه: " c
    case "$c" in
      1) create_tunnel; pause ;;
      2) systemctl list-units 'waterwall@*'; pause ;;
      3) exit 0 ;;
    esac
  done
}

main_menu