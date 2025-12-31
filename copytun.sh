#!/usr/bin/env bash
# copyTun - WaterWall Half-Duplex Tunnel Manager (systemd + multi tunnel)
# UI: English (Assistant guidance: Persian)
#
# One-liner:
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ShidRayGit/Copytun/main/copytun.sh)"

set -euo pipefail

APP_NAME="copyTun"
VERSION="1.41"

# ---- layout ----
TUN_BASE="/opt/copytun"
WW_HOME="/opt/waterwall"
WW_BIN="${WW_HOME}/bin/WaterWall"
WW_LIBS="${WW_HOME}/libs"

SVC_TEMPLATE="/etc/systemd/system/copytun@.service"

# ---- WaterWall v1.41 URLs ----
URL_GCC_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64.zip"
URL_GCC_X64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64-old-cpu.zip"
URL_GCC_ARM64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64.zip"
URL_GCC_ARM64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64-old-cpu.zip"
URL_CLANG_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-x64.zip"
URL_CLANG_AVX512_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-avx512f-x64.zip"

# ---------------- helpers ----------------
log()  { printf '%s\n' "[*] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
die()  { printf '\n%s\n\n' "[ERROR] $*" >&2; exit 1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (use sudo)."; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

require_systemd() {
  have_cmd systemctl || die "systemctl not found. systemd is required."
  [[ -d /run/systemd/system ]] || die "systemd is not running on this host."
}

# robust I/O: always read from /dev/tty (fixes bash -c / wget -qO- stdin issues)
TTY="/dev/tty"
require_tty() {
  [[ -r "$TTY" ]] || die "No /dev/tty available. Use a real terminal (TTY)."
}

clean_choice() {
  # remove CR and whitespace
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | tr -d ' \t\n')"
  printf '%s' "$s"
}

pause() {
  require_tty
  read -r -p "Press Enter to continue... " _ < "$TTY" || true
}

safe_clear() {
  if [[ -t 1 ]] && have_cmd clear; then clear; fi
}

read_line() {
  # read a full line from TTY
  local prompt="$1" out
  require_tty
  printf '%s' "$prompt" > "$TTY"
  IFS= read -r out < "$TTY" || out=""
  printf '%s' "$out"
}

read_menu() {
  # read a menu choice line from TTY, cleaned
  local prompt="$1"
  local v
  v="$(read_line "$prompt")"
  v="$(clean_choice "$v")"
  printf '%s' "$v"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

prompt_port() {
  local label="$1" def="${2:-}"
  local v
  while true; do
    if [[ -n "$def" ]]; then
      v="$(read_line "${label} [${def}]: ")"
      v="${v:-$def}"
    else
      v="$(read_line "${label}: ")"
    fi
    v="$(clean_choice "$v")"
    if valid_port "$v"; then
      printf '%s' "$v"
      return 0
    fi
    warn "Invalid port. Use 1..65535"
  done
}

prompt_text() {
  local label="$1" def="${2:-}"
  local v
  if [[ -n "$def" ]]; then
    v="$(read_line "${label} [${def}]: ")"
    v="${v:-$def}"
  else
    v="$(read_line "${label}: ")"
  fi
  v="${v//$'\r'/}"
  printf '%s' "$v"
}

sanitize_name() {
  local n="$1"
  [[ -n "$n" ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  return 0
}

download_file() {
  local url="$1" out="$2"
  if have_cmd wget; then
    wget -qO "$out" "$url"
  elif have_cmd curl; then
    curl -fsSL "$url" -o "$out"
  else
    die "Neither wget nor curl is installed."
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

# ---------------- WaterWall install ----------------
pick_waterwall_url() {
  local arch
  arch="$(uname -m)"

  printf '\nSelect WaterWall binary (v%s):\n' "$VERSION"
  printf '%s\n' "---------------------------------"

  if [[ "$arch" == "x86_64" ]]; then
    printf '%s\n' "1) Auto (recommended: old-cpu)"
    printf '%s\n' "2) amd64 gcc x64"
    printf '%s\n' "3) amd64 gcc x64 old-cpu (fixes Illegal instruction)"
    printf '%s\n' "4) amd64 clang x64"
    printf '%s\n' "5) amd64 clang avx512 (very new CPUs only)"
    while true; do
      local c
      c="$(read_menu "Choice: ")"
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
      local c
      c="$(read_menu "Choice: ")"
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
  mkdir -p "${WW_HOME}/bin" "$WW_LIBS" "$TUN_BASE"
  [[ -x "$WW_BIN" ]] && return 0

  ensure_unzip

  local url tmpzip tmpdir
  url="$(pick_waterwall_url)"
  tmpzip="$(mktemp -t waterwall_XXXXXX.zip)"
  tmpdir="$(mktemp -d -t waterwall_ex_XXXXXX)"

  log "Downloading WaterWall..."
  download_file "$url" "$tmpzip"

  log "Extracting..."
  unzip -o "$tmpzip" -d "$tmpdir" >/dev/null

  local found
  found="$(find "$tmpdir" -maxdepth 3 -type f \( -name 'WaterWall' -o -name 'Waterwall' \) -print -quit || true)"
  [[ -n "$found" ]] || die "WaterWall binary not found inside the zip."

  cp -f "$found" "$WW_BIN"
  chmod +x "$WW_BIN"

  if [[ -d "$tmpdir/libs" ]]; then
    cp -rf "$tmpdir/libs/." "$WW_LIBS/" || true
  fi

  rm -f "$tmpzip"
  rm -rf "$tmpdir"

  log "Installed WaterWall: $WW_BIN"
}

# ---------------- systemd ----------------
ensure_service_template() {
  require_systemd
  [[ -f "$SVC_TEMPLATE" ]] && return 0

  log "Creating systemd service template: $SVC_TEMPLATE"
  cat > "$SVC_TEMPLATE" <<EOF
[Unit]
Description=copyTun WaterWall Tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TUN_BASE}/%i
ExecStart=${WW_BIN}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

svc_name() { printf 'copytun@%s.service' "$1"; }

svc_enable_start() {
  systemctl daemon-reload
  systemctl enable --now "$(svc_name "$1")" >/dev/null
}

svc_restart() { systemctl restart "$(svc_name "$1")"; }
svc_stop()    { systemctl stop "$(svc_name "$1")" || true; }

svc_status() {
  local s
  s="$(svc_name "$1")"
  systemctl --no-pager status "$s" || true
}

svc_journal() {
  local s
  s="$(svc_name "$1")"
  journalctl -u "$s" -n 120 --no-pager || true
}

# ---------------- tunnel files ----------------
tun_dir() { printf '%s/%s' "$TUN_BASE" "$1"; }
meta_file(){ printf '%s/meta.env' "$(tun_dir "$1")"; }

write_meta() {
  local name="$1"; shift
  local f; f="$(meta_file "$name")"
  {
    printf '%s\n' "# generated by copyTun"
    printf 'UPDATED_AT=%s\n' "$(date -Is)"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$f"
}

load_meta() {
  local name="$1"
  local f; f="$(meta_file "$name")"
  [[ -f "$f" ]] || return 1

  ROLE=""
  LOCAL_LISTEN_PORT=""
  TUNNEL_PORT=""
  FOREIGN_IP=""
  LISTEN_PORT=""
  TARGET_PORT=""
  TARGET_ADDR="127.0.0.1"

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

write_core_wrapper() {
  local name="$1" role_profile="$2" cfg_rel="$3"
  local dir; dir="$(tun_dir "$name")"
  cat > "${dir}/${name}.json" <<JSON
{
  "log": {
    "path": "logs/",
    "core":     { "loglevel": "INFO",  "file": "core.log",     "console": true },
    "network":  { "loglevel": "INFO",  "file": "network.log",  "console": true },
    "dns":      { "loglevel": "ERROR", "file": "dns.log",      "console": true },
    "internal": { "loglevel": "INFO",  "file": "internal.log", "console": true }
  },
  "misc": {
    "workers": 0,
    "mtu": 1500,
    "ram-profile": "${role_profile}",
    "libs-path": "libs/"
  },
  "configs": ["${cfg_rel}"]
}
JSON
  ln -sfn "${name}.json" "${dir}/core.json"
}

write_config_iran() {
  local name="$1" local_port="$2" foreign_ip="$3" tunnel_port="$4"
  local dir; dir="$(tun_dir "$name")"

  cat > "${dir}/configs/iran-halfduplex.json" <<JSON
{
  "name": "${name}_iran_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    {
      "name": "iran_in",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${local_port},
        "nodelay": true
      },
      "next": "hd_client"
    },
    {
      "name": "hd_client",
      "type": "HalfDuplexClient",
      "settings": {},
      "next": "to_foreign"
    },
    {
      "name": "to_foreign",
      "type": "TcpConnector",
      "settings": {
        "address": "${foreign_ip}",
        "port": ${tunnel_port},
        "nodelay": true
      }
    }
  ]
}
JSON

  write_core_wrapper "$name" "client" "configs/iran-halfduplex.json"
}

write_config_foreign() {
  local name="$1" listen_port="$2" target_port="$3" target_addr="${4:-127.0.0.1}"
  local dir; dir="$(tun_dir "$name")"

  cat > "${dir}/configs/foreign-halfduplex.json" <<JSON
{
  "name": "${name}_foreign_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    {
      "name": "foreign_in",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${listen_port},
        "nodelay": true
      },
      "next": "hd_server"
    },
    {
      "name": "hd_server",
      "type": "HalfDuplexServer",
      "settings": {},
      "next": "to_target"
    },
    {
      "name": "to_target",
      "type": "TcpConnector",
      "settings": {
        "address": "${target_addr}",
        "port": ${target_port},
        "nodelay": true
      }
    }
  ]
}
JSON

  write_core_wrapper "$name" "server" "configs/foreign-halfduplex.json"
}

# ---------------- UI flows ----------------
create_tunnel() {
  install_waterwall_if_needed
  ensure_service_template

  printf '\n%s\n' "Create tunnel"
  printf '%s\n' "--------------------------"

  local name
  while true; do
    name="$(prompt_text "Tunnel name (A-Z a-z 0-9 _ -)")"
    name="$(clean_choice "$name")"
    sanitize_name "$name" && break
    warn "Invalid name. Allowed: letters, digits, underscore, dash."
  done

  local dir; dir="$(tun_dir "$name")"
  [[ -e "$dir" ]] && die "Tunnel already exists: $name"

  mkdir -p "$dir/configs" "$dir/logs"
  ln -sfn "$WW_LIBS" "$dir/libs"

  printf '\n%s\n' "Where are you running this?"
  printf '%s\n' "1) Iran server (Client / HalfDuplexClient)"
  printf '%s\n' "2) Foreign server (Server / HalfDuplexServer)"

  local role
  role="$(read_menu "Choice (1/2): ")"

  if [[ "$role" == "1" ]]; then
    local local_port tunnel_port foreign_ip
    local_port="$(prompt_port "Local LISTEN port (user connects here)" "5055")"
    tunnel_port="$(prompt_port "Tunnel port (connect to foreign)" "449")"
    foreign_ip="$(prompt_text "Foreign server IP")"

    write_config_iran "$name" "$local_port" "$foreign_ip" "$tunnel_port"
    write_meta "$name" \
      "ROLE=iran" \
      "LOCAL_LISTEN_PORT=${local_port}" \
      "TUNNEL_PORT=${tunnel_port}" \
      "FOREIGN_IP=${foreign_ip}"

  elif [[ "$role" == "2" ]]; then
    local target_port listen_port
    target_port="$(prompt_port "Target service port on THIS server (e.g. Xray inbound)" "5055")"
    listen_port="$(prompt_port "Tunnel LISTEN port (Iran connects here)" "449")"

    write_config_foreign "$name" "$listen_port" "$target_port" "127.0.0.1"
    write_meta "$name" \
      "ROLE=foreign" \
      "LISTEN_PORT=${listen_port}" \
      "TARGET_PORT=${target_port}" \
      "TARGET_ADDR=127.0.0.1"
  else
    die "Invalid role."
  fi

  svc_enable_start "$name"
  log "Tunnel created and enabled: $name"
  printf '\n'
  svc_status "$name" || true
  pause
}

list_tunnels() {
  mkdir -p "$TUN_BASE"
  find "$TUN_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

print_tunnel_table() {
  local names
  mapfile -t names < <(list_tunnels)
  if [[ "${#names[@]}" -eq 0 ]]; then
    printf '%s\n' "No tunnels found."
    return 1
  fi

  printf '\n%s\n' "Tunnels:"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local i=1
  for n in "${names[@]}"; do
    local role="-" detail="-"
    if load_meta "$n"; then
      role="$ROLE"
      if [[ "$ROLE" == "iran" ]]; then
        detail="listen:${LOCAL_LISTEN_PORT} => ${FOREIGN_IP}:${TUNNEL_PORT}"
      elif [[ "$ROLE" == "foreign" ]]; then
        detail="listen:${LISTEN_PORT} => ${TARGET_ADDR}:${TARGET_PORT}"
      fi
    fi

    local svc="copytun@${n}.service"
    local st="inactive"
    systemctl is-active --quiet "$svc" && st="active" || true

    printf "%2d) %-20s  role=%-7s  status=%-8s  %s\n" "$i" "$n" "$role" "$st" "$detail"
    ((i++))
  done
  printf '%s\n' "--------------------------------------------------------------------------------"
  return 0
}

choose_log_file_menu() {
  local name="$1"
  local dir; dir="$(tun_dir "$name")"
  local logs_dir="${dir}/logs"

  [[ -d "$logs_dir" ]] || { warn "No logs directory."; return 1; }

  local files=()
  local f
  for f in core.log network.log dns.log internal.log; do
    [[ -f "${logs_dir}/${f}" ]] && files+=("$f")
  done

  if [[ "${#files[@]}" -eq 0 ]]; then
    warn "No log files found yet. (Try starting the service first.)"
    return 1
  fi

  printf '\n%s\n' "Log files:"
  local i=1
  for f in "${files[@]}"; do
    printf "%2d) %s\n" "$i" "$f"
    ((i++))
  done
  printf " 0) Back\n"

  local c
  c="$(read_menu "Select a file: ")"
  [[ "$c" == "0" || -z "$c" ]] && return 0
  [[ "$c" =~ ^[0-9]+$ ]] || { warn "Invalid number."; return 1; }

  local idx=$((c-1))
  (( idx >= 0 && idx < ${#files[@]} )) || { warn "Out of range."; return 1; }

  local chosen="${files[$idx]}"
  printf '\n%s\n' "1) tail -n 200"
  printf '%s\n' "2) tail -f (live)"
  printf '%s\n' "0) Back"
  local mode
  mode="$(read_menu "Choice: ")"

  case "$mode" in
    1)
      printf '\n---- %s ----\n' "${logs_dir}/${chosen}"
      tail -n 200 "${logs_dir}/${chosen}" || true
      ;;
    2)
      printf '\n---- live: %s (Ctrl+C to stop) ----\n' "${logs_dir}/${chosen}"
      tail -f "${logs_dir}/${chosen}" || true
      ;;
    0) return 0 ;;
    *) warn "Invalid choice." ;;
  esac
  return 0
}

edit_tunnel() {
  local name="$1"
  local dir; dir="$(tun_dir "$name")"
  load_meta "$name" || die "Missing meta.env for tunnel: $name"

  printf '\nEdit tunnel: %s (role=%s)\n' "$name" "$ROLE"
  printf '%s\n' "----------------------------------------"

  if [[ "$ROLE" == "iran" ]]; then
    local new_local new_tunnel new_ip
    new_local="$(prompt_port "Local LISTEN port" "$LOCAL_LISTEN_PORT")"
    new_tunnel="$(prompt_port "Tunnel port (connect to foreign)" "$TUNNEL_PORT")"
    new_ip="$(prompt_text "Foreign server IP" "$FOREIGN_IP")"

    write_config_iran "$name" "$new_local" "$new_ip" "$new_tunnel"
    write_meta "$name" \
      "ROLE=iran" \
      "LOCAL_LISTEN_PORT=${new_local}" \
      "TUNNEL_PORT=${new_tunnel}" \
      "FOREIGN_IP=${new_ip}"

  elif [[ "$ROLE" == "foreign" ]]; then
    local new_target new_listen
    new_target="$(prompt_port "Target service port" "$TARGET_PORT")"
    new_listen="$(prompt_port "Tunnel LISTEN port" "$LISTEN_PORT")"

    write_config_foreign "$name" "$new_listen" "$new_target" "127.0.0.1"
    write_meta "$name" \
      "ROLE=foreign" \
      "LISTEN_PORT=${new_listen}" \
      "TARGET_PORT=${new_target}" \
      "TARGET_ADDR=127.0.0.1"
  else
    die "Invalid ROLE in meta."
  fi

  svc_restart "$name"
  log "Updated and restarted: $name"
  pause
}

delete_tunnel() {
  local name="$1"
  local dir; dir="$(tun_dir "$name")"
  local confirm
  confirm="$(read_line "Type YES to delete '${name}': ")"
  confirm="$(clean_choice "$confirm")"
  [[ "$confirm" == "YES" ]] || { log "Cancelled."; pause; return 0; }

  systemctl disable --now "$(svc_name "$name")" >/dev/null 2>&1 || true
  rm -rf "$dir"
  log "Deleted tunnel: $name"
  pause
}

manage_tunnel_menu() {
  local name="$1"
  while true; do
    safe_clear
    printf 'Manage tunnel: %s\n' "$name"
    printf '%s\n' "------------------------------"
    printf '%s\n' "1) Start/Restart"
    printf '%s\n' "2) Stop"
    printf '%s\n' "3) Status (systemctl)"
    printf '%s\n' "4) Journal logs (journalctl)"
    printf '%s\n' "5) Log files (core/network/dns/internal)"
    printf '%s\n' "6) Edit settings"
    printf '%s\n' "7) Delete tunnel"
    printf '%s\n' "0) Back"

    local c
    c="$(read_menu "Choice: ")"
    case "$c" in
      1) svc_restart "$name"; log "Restarted."; pause ;;
      2) svc_stop "$name"; log "Stopped."; pause ;;
      3) svc_status "$name"; pause ;;
      4) svc_journal "$name"; pause ;;
      5) choose_log_file_menu "$name" || true; pause ;;
      6) edit_tunnel "$name" ;;
      7) delete_tunnel "$name"; return 0 ;;
      0) return 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

list_manage_flow() {
  ensure_service_template

  while true; do
    safe_clear
    if ! print_tunnel_table; then
      pause
      return 0
    fi

    local sel
    sel="$(read_menu "Select tunnel number (or 0 to back): ")"
    [[ -z "$sel" ]] && sel="0"
    [[ "$sel" =~ ^[0-9]+$ ]] || { warn "Enter a number."; pause; continue; }
    [[ "$sel" == "0" ]] && return 0

    local names
    mapfile -t names < <(list_tunnels)
    local idx=$((sel-1))
    (( idx >= 0 && idx < ${#names[@]} )) || { warn "Out of range."; pause; continue; }

    manage_tunnel_menu "${names[$idx]}"
  done
}

main_menu() {
  need_root
  require_systemd
  require_tty

  mkdir -p "$TUN_BASE" "$WW_HOME/bin" "$WW_LIBS"

  while true; do
    safe_clear
    printf '%s\n' "============================================="
    printf ' %s - WaterWall Half-Duplex Manager v%s\n' "$APP_NAME" "$VERSION"
    printf '%s\n' "============================================="
    printf '%s\n' "1) Create tunnel"
    printf '%s\n' "2) List / Manage tunnels"
    printf '%s\n' "3) Exit"
    printf '%s\n' "---------------------------------------------"

    local c
    c="$(read_menu "Choice: ")"
    case "$c" in
      1) create_tunnel ;;
      2) list_manage_flow ;;
      3) exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

main_menu