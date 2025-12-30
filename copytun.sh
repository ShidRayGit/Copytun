#!/usr/bin/env bash
# copyTun - WaterWall Half-Duplex Tunnel Manager (Menu + systemd)
# One-liner:
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ShidRayGit/Copytun/main/copytun.sh)"

set -euo pipefail

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
URL_CLANG_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-x64.zip"
URL_CLANG_AVX512_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-avx512f-x64.zip"

log()   { printf '%s\n' "[*] $*"; }
warn()  { printf '%s\n' "[!] $*" >&2; }
die()   { printf '\n%s\n\n' "[ERROR] $*" >&2; exit 1; }
pause() { read -r -p $'\nPress Enter to continue... ' _ || true; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_root(){ [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }
require_systemd(){ command -v systemctl >/dev/null 2>&1 || die "systemd is required."; }

safe_clear(){ [[ -t 1 ]] && command -v clear >/dev/null 2>&1 && clear || true; }

trim_choice() {
  # remove CR, spaces, tabs, newlines
  local s="${1:-}"
  s="${s//$'\r'/}"
  # remove all whitespace
  s="$(printf '%s' "$s" | tr -d ' \t\n')"
  printf '%s' "$s"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

prompt_port() {
  local msg="$1" def="${2:-}" p
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "${msg} [${def}]: " p
      p="${p:-$def}"
    else
      read -r -p "${msg}: " p
    fi
    p="$(trim_choice "$p")"
    if valid_port "$p"; then printf '%s' "$p"; return 0; fi
    warn "Invalid port. Use 1..65535"
  done
}

prompt_text() {
  local msg="$1" def="${2:-}" t
  if [[ -n "$def" ]]; then
    read -r -p "${msg} [${def}]: " t
    t="${t:-$def}"
  else
    read -r -p "${msg}: " t
  fi
  t="${t//$'\r'/}"
  printf '%s' "$t"
}

sanitize_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  return 0
}

download_file() {
  local url="$1" out="$2"
  if have_cmd wget; then wget -qO "$out" "$url"
  elif have_cmd curl; then curl -fsSL "$url" -o "$out"
  else die "Neither wget nor curl is installed."
  fi
}

ensure_unzip() {
  have_cmd unzip && return 0
  warn "unzip not found. Installing..."
  if have_cmd apt-get; then
    apt-get update -y >/dev/null
    apt-get install -y unzip >/dev/null
  elif have_cmd dnf; then
    dnf install -y unzip >/dev/null
  elif have_cmd yum; then
    yum install -y unzip >/dev/null
  else
    die "No supported package manager found. Install unzip manually."
  fi
}

pick_build_menu() {
  local arch c
  arch="$(uname -m)"

  printf '\nSelect WaterWall binary (v%s):\n' "$VERSION"
  printf '%s\n' "---------------------------------"

  if [[ "$arch" == "x86_64" ]]; then
    printf '%s\n' "1) Auto (recommended: old-cpu)"
    printf '%s\n' "2) amd64 gcc x64"
    printf '%s\n' "3) amd64 gcc x64 old-cpu"
    printf '%s\n' "4) amd64 clang x64"
    printf '%s\n' "5) amd64 clang avx512"
    while true; do
      read -r -p "Choice: " c
      c="$(trim_choice "$c")"
      case "${c:-1}" in
        1) printf '%s' "$URL_GCC_X64_OLD"; return 0 ;;
        2) printf '%s' "$URL_GCC_X64"; return 0 ;;
        3) printf '%s' "$URL_GCC_X64_OLD"; return 0 ;;
        4) printf '%s' "$URL_CLANG_X64"; return 0 ;;
        5) printf '%s' "$URL_CLANG_AVX512_X64"; return 0 ;;
        *) warn "Invalid choice." ;;
      esac
    done
  elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
    printf '%s\n' "1) Auto (recommended)"
    printf '%s\n' "2) arm64 gcc"
    printf '%s\n' "3) arm64 gcc old-cpu"
    while true; do
      read -r -p "Choice: " c
      c="$(trim_choice "$c")"
      case "${c:-1}" in
        1|2) printf '%s' "$URL_GCC_ARM64"; return 0 ;;
        3)   printf '%s' "$URL_GCC_ARM64_OLD"; return 0 ;;
        *) warn "Invalid choice." ;;
      esac
    done
  else
    die "Unsupported architecture: $arch"
  fi
}

install_waterwall_if_needed() {
  mkdir -p "$BIN_DIR" "$LIBS_DIR" "$BASE_DIR"
  [[ -x "$BIN_PATH" ]] && return 0

  ensure_unzip

  local url tmpzip tmpdir
  url="$(pick_build_menu)"
  tmpzip="$(mktemp -t waterwall_XXXXXX.zip)"
  tmpdir="$(mktemp -d -t waterwall_ex_XXXXXX)"

  log "Downloading WaterWall..."
  download_file "$url" "$tmpzip"

  log "Extracting..."
  unzip -o "$tmpzip" -d "$tmpdir" >/dev/null

  local found
  found="$(find "$tmpdir" -maxdepth 3 -type f \( -name 'WaterWall' -o -name 'Waterwall' \) -print -quit || true)"
  [[ -n "$found" ]] || die "WaterWall binary not found in zip."

  cp -f "$found" "$BIN_PATH"
  chmod +x "$BIN_PATH"

  [[ -d "$tmpdir/libs" ]] && cp -rf "$tmpdir/libs/." "$LIBS_DIR/" || true

  rm -f "$tmpzip"
  rm -rf "$tmpdir"
  log "Installed: $BIN_PATH"
}

ensure_service_template() {
  require_systemd
  [[ -f "$SERVICE_TEMPLATE" ]] && return 0

  log "Creating systemd template: $SERVICE_TEMPLATE"
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

service_name_for(){ printf 'waterwall@%s.service' "$1"; }

start_enable_tunnel() {
  systemctl daemon-reload
  systemctl enable --now "$(service_name_for "$1")" >/dev/null
}

restart_tunnel(){ systemctl restart "$(service_name_for "$1")"; }
stop_tunnel(){ systemctl stop "$(service_name_for "$1")" || true; }

status_tunnel() {
  local svc
  svc="$(service_name_for "$1")"
  systemctl --no-pager status "$svc" || true
  printf '%s\n' "---- last logs ----"
  journalctl -u "$svc" -n 80 --no-pager || true
}

write_meta() {
  local dir="$1"; shift
  {
    printf '%s\n' "# generated by copyTun"
    printf 'UPDATED_AT=%s\n' "$(date -Is)"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "${dir}/tunnel.meta"
}

load_meta() {
  local dir="$1" f="${dir}/tunnel.meta"
  [[ -f "$f" ]] || return 1
  ROLE=""; LOCAL_LISTEN_PORT=""; TUNNEL_PORT=""; FOREIGN_IP=""
  LISTEN_PORT=""; TARGET_PORT=""; TARGET_ADDR="127.0.0.1"

  while IFS='=' read -r k v; do
    [[ -z "${k:-}" ]] && continue
    [[ "$k" =~ ^# ]] && continue
    v="${v%$'\r'}"
    case "$k" in
      ROLE) ROLE="$v" ;;
      LOCAL_LISTEN_PORT) LOCAL_LISTEN_PORT="$v" ;;
      TUNNEL_PORT) TUNNEL_PORT="$v" ;;
      FOREIGN_IP) FOREIGN_IP="$v" ;;
      LISTEN_PORT) LISTEN_PORT="$v" ;;
      TARGET_PORT) TARGET_PORT="$v" ;;
      TARGET_ADDR) TARGET_ADDR="$v" ;;
    esac
  done < "$f"
  return 0
}

write_config_iran() {
  local tname="$1" dir="$2" local_port="$3" foreign_ip="$4" tunnel_port="$5"
  mkdir -p "${dir}/configs" "${dir}/logs"
  [[ -d "$LIBS_DIR" ]] && ln -sfn "$LIBS_DIR" "${dir}/libs" || mkdir -p "${dir}/libs"

  cat > "${dir}/configs/iran-halfduplex.json" <<JSON
{
  "name": "${tname}_iran_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    { "name": "iranin", "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": ${local_port}, "nodelay": true },
      "next": "hdclient" },
    { "name": "hdclient", "type": "HalfDuplexClient", "settings": {}, "next": "toforeign" },
    { "name": "toforeign", "type": "TcpConnector",
      "settings": { "address": "${foreign_ip}", "port": ${tunnel_port}, "nodelay": true } }
  ]
}
JSON

  cat > "${dir}/${tname}.json" <<JSON
{
  "log": { "path": "logs/" },
  "misc": { "ram-profile": "client", "libs-path": "libs/" },
  "configs": ["configs/iran-halfduplex.json"]
}
JSON

  ln -sfn "${tname}.json" "${dir}/core.json"
}

write_config_foreign() {
  local tname="$1" dir="$2" listen_port="$3" target_port="$4" target_addr="${5:-127.0.0.1}"
  mkdir -p "${dir}/configs" "${dir}/logs"
  [[ -d "$LIBS_DIR" ]] && ln -sfn "$LIBS_DIR" "${dir}/libs" || mkdir -p "${dir}/libs"

  cat > "${dir}/configs/foreign-halfduplex.json" <<JSON
{
  "name": "${tname}_foreign_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    { "name": "foreignin", "type": "TcpListener",
      "settings": { "address": "0.0.0.0", "port": ${listen_port}, "nodelay": true },
      "next": "hdserver" },
    { "name": "hdserver", "type": "HalfDuplexServer", "settings": {}, "next": "totarget" },
    { "name": "totarget", "type": "TcpConnector",
      "settings": { "address": "${target_addr}", "port": ${target_port}, "nodelay": true } }
  ]
}
JSON

  cat > "${dir}/${tname}.json" <<JSON
{
  "log": { "path": "logs/" },
  "misc": { "ram-profile": "server", "libs-path": "libs/" },
  "configs": ["configs/foreign-halfduplex.json"]
}
JSON

  ln -sfn "${tname}.json" "${dir}/core.json"
}

create_tunnel() {
  install_waterwall_if_needed
  ensure_service_template

  printf '%s\n' ""
  printf '%s\n' "Create new tunnel"
  printf '%s\n' "-----------------"

  local tname
  while true; do
    tname="$(prompt_text "Tunnel name (A-Z a-z 0-9 _ -)")"
    tname="$(trim_choice "$tname")"
    sanitize_name "$tname" && break
    warn "Invalid name. Allowed: letters, digits, underscore, dash."
  done

  local dir="${BASE_DIR}/${tname}"
  [[ -e "$dir" ]] && die "Tunnel already exists: $tname"
  mkdir -p "$dir"

  printf '%s\n' ""
  printf '%s\n' "Where are you running this?"
  printf '%s\n' "1) Iran server (Client / HalfDuplexClient)"
  printf '%s\n' "2) Foreign server (Server / HalfDuplexServer)"

  local role_choice
  read -r -p "Choice (1/2): " role_choice
  role_choice="$(trim_choice "$role_choice")"

  if [[ "$role_choice" == 1* ]]; then
    local local_port tunnel_port foreign_ip
    local_port="$(prompt_port "Local LISTEN port (user connects here) e.g. 5055" "5055")"
    tunnel_port="$(prompt_port "Tunnel port (connect to foreign) e.g. 449" "449")"
    foreign_ip="$(prompt_text "Foreign server IP")"
    write_config_iran "$tname" "$dir" "$local_port" "$foreign_ip" "$tunnel_port"
    write_meta "$dir" "ROLE=iran" "LOCAL_LISTEN_PORT=$local_port" "TUNNEL_PORT=$tunnel_port" "FOREIGN_IP=$foreign_ip"
  elif [[ "$role_choice" == 2* ]]; then
    local target_port listen_port
    target_port="$(prompt_port "Target service port on THIS server (e.g. Xray inbound)" "5055")"
    listen_port="$(prompt_port "Tunnel LISTEN port (Iran connects here)" "449")"
    write_config_foreign "$tname" "$dir" "$listen_port" "$target_port" "127.0.0.1"
    write_meta "$dir" "ROLE=foreign" "LISTEN_PORT=$listen_port" "TARGET_PORT=$target_port" "TARGET_ADDR=127.0.0.1"
  else
    die "Invalid role choice."
  fi

  start_enable_tunnel "$tname"
  log "Tunnel created and enabled: $tname"
  status_tunnel "$tname"
  pause
}

list_tunnel_names() {
  mkdir -p "$BASE_DIR"
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

print_tunnels_table() {
  local names
  mapfile -t names < <(list_tunnel_names)
  [[ "${#names[@]}" -eq 0 ]] && { printf '%s\n' "No tunnels found."; return 1; }

  printf '%s\n' ""
  printf '%s\n' "Tunnels:"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local i=1
  for n in "${names[@]}"; do
    local dir="${BASE_DIR}/${n}" role="-" detail="-"
    if load_meta "$dir"; then
      role="$ROLE"
      [[ "$ROLE" == "iran" ]] && detail="listen:${LOCAL_LISTEN_PORT} => ${FOREIGN_IP}:${TUNNEL_PORT}"
      [[ "$ROLE" == "foreign" ]] && detail="listen:${LISTEN_PORT} => ${TARGET_ADDR}:${TARGET_PORT}"
    fi
    local svc="waterwall@${n}.service" st="inactive"
    systemctl is-active --quiet "$svc" && st="active" || true
    printf "%2d) %-20s  role=%-7s  status=%-8s  %s\n" "$i" "$n" "$role" "$st" "$detail"
    ((i++))
  done
  printf '%s\n' "--------------------------------------------------------------------------------"
  return 0
}

edit_tunnel() {
  local tname="$1" dir="${BASE_DIR}/${tname}"
  load_meta "$dir" || die "Missing meta: ${dir}/tunnel.meta"

  printf '%s\n' ""
  printf 'Edit tunnel: %s (role=%s)\n' "$tname" "$ROLE"
  printf '%s\n' "----------------------------------------"

  if [[ "$ROLE" == "iran" ]]; then
    local new_local new_tunnel new_ip
    new_local="$(prompt_port "Local LISTEN port" "$LOCAL_LISTEN_PORT")"
    new_tunnel="$(prompt_port "Tunnel port (to foreign)" "$TUNNEL_PORT")"
    new_ip="$(prompt_text "Foreign server IP" "$FOREIGN_IP")"
    write_config_iran "$tname" "$dir" "$new_local" "$new_ip" "$new_tunnel"
    write_meta "$dir" "ROLE=iran" "LOCAL_LISTEN_PORT=$new_local" "TUNNEL_PORT=$new_tunnel" "FOREIGN_IP=$new_ip"
  else
    local new_listen new_target
    new_target="$(prompt_port "Target service port" "$TARGET_PORT")"
    new_listen="$(prompt_port "Tunnel LISTEN port" "$LISTEN_PORT")"
    write_config_foreign "$tname" "$dir" "$new_listen" "$new_target" "127.0.0.1"
    write_meta "$dir" "ROLE=foreign" "LISTEN_PORT=$new_listen" "TARGET_PORT=$new_target" "TARGET_ADDR=127.0.0.1"
  fi

  restart_tunnel "$tname"
  log "Updated and restarted."
  pause
}

delete_tunnel() {
  local tname="$1" dir="${BASE_DIR}/${tname}" svc
  svc="$(service_name_for "$tname")"
  read -r -p "Type YES to delete tunnel '${tname}': " confirm
  confirm="$(trim_choice "$confirm")"
  [[ "$confirm" == "YES" ]] || { log "Cancelled."; pause; return 0; }
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
  rm -rf "$dir"
  log "Deleted: $tname"
  pause
}

manage_one_tunnel() {
  local tname="$1" dir="${BASE_DIR}/${tname}"
  while true; do
    safe_clear
    printf 'Manage tunnel: %s\n' "$tname"
    printf '%s\n' "--------------------------"
    printf '%s\n' "1) Start/Restart"
    printf '%s\n' "2) Stop"
    printf '%s\n' "3) Status + Logs"
    printf '%s\n' "4) Edit settings"
    printf '%s\n' "5) Delete tunnel"
    printf '%s\n' "0) Back"
    local c
    read -r -p "Choice: " c
    c="$(trim_choice "$c")"
    case "$c" in
      1|1*) restart_tunnel "$tname"; log "Restarted."; pause ;;
      2|2*) stop_tunnel "$tname"; log "Stopped."; pause ;;
      3|3*) status_tunnel "$tname"; pause ;;
      4|4*) edit_tunnel "$tname" ;;
      5|5*) delete_tunnel "$tname"; return 0 ;;
      0|0*) return 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

list_and_manage() {
  ensure_service_template
  while true; do
    safe_clear
    if ! print_tunnels_table; then pause; return 0; fi
    read -r -p "Select tunnel number (or 0 to back): " sel
    sel="$(trim_choice "$sel")"
    [[ -z "$sel" ]] && sel="0"
    [[ "$sel" =~ ^[0-9]+$ ]] || { warn "Enter a number."; pause; continue; }
    [[ "$sel" == "0" ]] && return 0
    local names
    mapfile -t names < <(list_tunnel_names)
    local idx=$((sel-1))
    (( idx >= 0 && idx < ${#names[@]} )) || { warn "Out of range."; pause; continue; }
    manage_one_tunnel "${names[$idx]}"
  done
}

main_menu() {
  need_root
  require_systemd
  mkdir -p "$BASE_DIR" "$WW_HOME" "$BIN_DIR" "$LIBS_DIR"

  while true; do
    safe_clear
    printf '%s\n' "============================================="
    printf ' copyTun - WaterWall Half-Duplex Manager v%s\n' "$VERSION"
    printf '%s\n' "============================================="
    printf '%s\n' "1) Create tunnel"
    printf '%s\n' "2) List / Manage tunnels"
    printf '%s\n' "3) Exit"
    printf '%s\n' "---------------------------------------------"

    local c
    read -r -p "Choice: " c
    c="$(trim_choice "$c")"

    case "$c" in
      1|1*) create_tunnel ;;
      2|2*) list_and_manage ;;
      3|3*) exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

main_menu