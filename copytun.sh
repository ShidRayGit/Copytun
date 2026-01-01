#!/usr/bin/env bash
# copytun.sh - WaterWall Half-Duplex tunnel manager
# Thanks to Rad Kesvat for the WaterWall project
# https://github.com/radkesvat/WaterWall
# https://radkesvat.github.io/WaterWall-Docs/docs/intro

set -Eeuo pipefail

WW_VER="v1.41"
WW_BASE="/opt/waterwall"
WW_BIN="${WW_BASE}/bin/WaterWall"
WW_LIBS="${WW_BASE}/libs"
CT_BASE="/opt/copytun"
SYSTEMD_TEMPLATE="/etc/systemd/system/copytun@.service"

# ================= TTY SAFE =================
tty_read() {
  local var="$1" prompt="${2:-}"
  [[ -n "$prompt" ]] && printf -- "%s" "$prompt" > /dev/tty
  IFS= read -r val < /dev/tty
  printf -v "$var" "%s" "$val"
}
pause(){ printf -- "Press Enter to continue..." > /dev/tty; read -r _ < /dev/tty; }
clear_tty(){ [[ -t 1 ]] && clear > /dev/tty 2>/dev/null || true; }
die(){ printf -- "ERROR: %s\n" "$1" > /dev/tty; exit 1; }
[[ $EUID -ne 0 ]] && die "Run as root"

# ================= systemd =================
ensure_systemd() {
  [[ -f $SYSTEMD_TEMPLATE ]] && return
  cat > "$SYSTEMD_TEMPLATE" <<'EOF'
[Unit]
Description=copytun WaterWall Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/copytun/%i
ExecStart=/opt/waterwall/bin/WaterWall
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
svc(){ echo "copytun@$1.service"; }

# ================= WaterWall install =================
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported arch" ;;
  esac
}

install_waterwall() {
  [[ -x "$WW_BIN" ]] && return
  mkdir -p "$WW_BASE/bin" "$WW_BASE/libs"

  local arch asset
  arch=$(detect_arch)

  clear_tty
  printf -- "Installing WaterWall %s\n\n" "$WW_VER" > /dev/tty

  if [[ $arch == x64 ]]; then
    printf -- "1) gcc x64\n2) gcc x64 old-cpu\n3) clang x64\n4) clang avx512\n" > /dev/tty
    tty_read c "Choice: "
    case $c in
      1) asset=Waterwall-linux-gcc-x64.zip ;;
      2) asset=Waterwall-linux-gcc-x64-old-cpu.zip ;;
      3) asset=Waterwall-linux-clang-x64.zip ;;
      4) asset=Waterwall-linux-clang-avx512f-x64.zip ;;
      *) die "Invalid choice" ;;
    esac
  else
    printf -- "1) gcc arm64\n2) gcc arm64 old-cpu\n" > /dev/tty
    tty_read c "Choice: "
    case $c in
      1) asset=Waterwall-linux-gcc-arm64.zip ;;
      2) asset=Waterwall-linux-gcc-arm64-old-cpu.zip ;;
      *) die "Invalid choice" ;;
    esac
  fi

  tmp=$(mktemp -d)
  wget -qO "$tmp/ww.zip" "https://github.com/radkesvat/WaterWall/releases/download/$WW_VER/$asset" || die "Download failed"
  unzip -q "$tmp/ww.zip" -d "$tmp/ww"

  bin=$(find "$tmp/ww" -type f ! -path '*/libs/*' -printf '%s %p\n' | sort -nr | awk 'NR==1{print $2}')
  [[ -n "$bin" ]] || die "Binary not found"

  install -m 755 "$bin" "$WW_BIN"
  libs=$(find "$tmp/ww" -type d -name libs | head -n1)
  [[ -n "$libs" ]] && cp -a "$libs/." "$WW_LIBS/"

  rm -rf "$tmp"
}

# ================= JSON =================
core_json() {
  cat > "$1/$2.json" <<EOF
{
  "log":{"path":"logs/","core":{"loglevel":"INFO","file":"core.log","console":false},
  "network":{"loglevel":"INFO","file":"network.log","console":false},
  "dns":{"loglevel":"INFO","file":"dns.log","console":false}},
  "misc":{"workers":0,"ram-profile":"server","libs-path":"${WW_LIBS}/"},
  "configs":["configs/$3"]
}
EOF
  ln -sf "$1/$2.json" "$1/core.json"
}

iran_json() {
cat > "$1/configs/iran-halfduplex.json" <<EOF
{
 "name":"$2-iran",
 "nodes":[
  {"name":"l","type":"TcpListener","settings":{"address":"0.0.0.0","port":$3},"next":"h"},
  {"name":"h","type":"HalfDuplexClient","settings":{},"next":"c"},
  {"name":"c","type":"TcpConnector","settings":{"address":"$4","port":$5}}
 ]
}
EOF
}

foreign_json() {
cat > "$1/configs/foreign-halfduplex.json" <<EOF
{
 "name":"$2-foreign",
 "nodes":[
  {"name":"l","type":"TcpListener","settings":{"address":"0.0.0.0","port":$3},"next":"h"},
  {"name":"h","type":"HalfDuplexServer","settings":{},"next":"c"},
  {"name":"c","type":"TcpConnector","settings":{"address":"127.0.0.1","port":$4}}
 ]
}
EOF
}

# ================= Create tunnel =================
create_tunnel() {
  install_waterwall
  ensure_systemd
  mkdir -p "$CT_BASE"

  clear_tty
  tty_read name "Tunnel name: "
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid name"

  dir="$CT_BASE/$name"
  mkdir -p "$dir/configs" "$dir/logs"

  printf -- "1) Iran (Client)\n2) Foreign (Server)\n" > /dev/tty
  tty_read r "Role: "

  if [[ $r == 1 ]]; then
    tty_read lp "Local port: "
    tty_read tp "Tunnel port: "
    tty_read ip "Foreign IP: "
    iran_json "$dir" "$name" "$lp" "$ip" "$tp"
    core_json "$dir" "$name" "iran-halfduplex.json"
    printf "ROLE=iran\nLP=%s\nTP=%s\nIP=%s\n" "$lp" "$tp" "$ip" > "$dir/meta.env"
  else
    tty_read tp "Tunnel port: "
    tty_read sp "Target service port: "
    foreign_json "$dir" "$name" "$tp" "$sp"
    core_json "$dir" "$name" "foreign-halfduplex.json"
    printf "ROLE=foreign\nTP=%s\nSP=%s\n" "$tp" "$sp" > "$dir/meta.env"
  fi

  systemctl enable --now "$(svc "$name")"
  pause
}

# ================= Menu =================
menu() {
  while true; do
    clear_tty
    printf -- "copytun - WaterWall Half-Duplex tunnel manager\n"
    printf -- "1) Create tunnel\n2) Exit\n"
    tty_read c "Choice: "
    case $c in
      1) create_tunnel ;;
      2) exit 0 ;;
    esac
  done
}

menu