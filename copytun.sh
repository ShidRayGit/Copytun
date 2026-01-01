#!/usr/bin/env bash
# copytun.sh - WaterWall Half-Duplex tunnel manager (menu-based)
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

# -----------------------------
# TTY-safe input (MANDATORY)
# -----------------------------
tty_read() {
  local __var="$1"
  local __prompt="${2:-}"
  [[ -n "$__prompt" ]] && printf -- "%s" "$__prompt" > /dev/tty
  local __val=""
  IFS= read -r __val < /dev/tty
  printf -v "$__var" "%s" "$__val"
}

tty_pause() {
  printf -- "Press Enter to continue..." > /dev/tty
  local _x
  IFS= read -r _x < /dev/tty
}

tty_clear() {
  if [[ -t 1 ]] && [[ -c /dev/tty ]]; then
    command -v clear >/dev/null 2>&1 && clear > /dev/tty 2>/dev/null || true
  fi
}

die() {
  printf -- "ERROR: %s\n" "${1:-Unknown error}" > /dev/tty
  exit 1
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (use sudo)."
  fi
}

# -----------------------------
# systemd template
# -----------------------------
ensure_systemd_template() {
  if [[ -f "${SYSTEMD_TEMPLATE}" ]]; then
    return 0
  fi

  cat > "${SYSTEMD_TEMPLATE}" <<'EOF'
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

  systemctl daemon-reload >/dev/null 2>&1 || true
}

svc_name() { printf -- "copytun@%s.service" "$1"; }

svc_enable_start() {
  local tn="$1"
  ensure_systemd_template
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$(svc_name "$tn")" >/dev/null 2>&1 || true
}

svc_restart() {
  local tn="$1"
  ensure_systemd_template
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "$(svc_name "$tn")" >/dev/null 2>&1 || true
}

svc_stop_disable() {
  local tn="$1"
  systemctl stop "$(svc_name "$tn")" >/dev/null 2>&1 || true
  systemctl disable "$(svc_name "$tn")" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

svc_is_active() { systemctl is-active --quiet "$(svc_name "$1")"; }

# -----------------------------
# WaterWall installer (v1.41) - robust zip binary detection
# -----------------------------
detect_arch() {
  local a
  a="$(uname -m 2>/dev/null || echo unknown)"
  case "$a" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unknown" ;;
  esac
}

ensure_deps() {
  local need=()
  command -v wget >/dev/null 2>&1 || need+=("wget")
  command -v unzip >/dev/null 2>&1 || need+=("unzip")
  [[ "${#need[@]}" -eq 0 ]] && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${need[@]}" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${need[@]}" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${need[@]}" >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${need[@]}" >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${need[@]}" >/dev/null 2>&1 || true
  fi
}

select_ww_asset() {
  local arch="$1"
  local choice=""
  tty_clear
  printf -- "WaterWall is not installed. Let's install %s.\n\n" "$WW_VER" > /dev/tty

  if [[ "$arch" == "x86_64" ]]; then
    printf -- "Select your Linux x86_64 build:\n" > /dev/tty
    printf -- "1) gcc x64\n" > /dev/tty
    printf -- "2) gcc x64 old-cpu (avoid Illegal instruction)\n" > /dev/tty
    printf -- "3) clang x64\n" > /dev/tty
    printf -- "4) clang avx512 (very new CPUs only)\n" > /dev/tty
    tty_read choice "Enter choice [1-4]: "
    case "$choice" in
      1) echo "Waterwall-linux-gcc-x64.zip" ;;
      2) echo "Waterwall-linux-gcc-x64-old-cpu.zip" ;;
      3) echo "Waterwall-linux-clang-x64.zip" ;;
      4) echo "Waterwall-linux-clang-avx512f-x64.zip" ;;
      *) die "Invalid choice." ;;
    esac
  elif [[ "$arch" == "arm64" ]]; then
    printf -- "Select your Linux arm64 build:\n" > /dev/tty
    printf -- "1) gcc arm64\n" > /dev/tty
    printf -- "2) gcc arm64 old-cpu\n" > /dev/tty
    tty_read choice "Enter choice [1-2]: "
    case "$choice" in
      1) echo "Waterwall-linux-gcc-arm64.zip" ;;
      2) echo "Waterwall-linux-gcc-arm64-old-cpu.zip" ;;
      *) die "Invalid choice." ;;
    esac
  else
    die "Unsupported architecture: $(uname -m)."
  fi
}

install_waterwall() {
  [[ -x "$WW_BIN" ]] && return 0

  ensure_deps

  local arch asset url tmpd
  arch="$(detect_arch)"
  asset="$(select_ww_asset "$arch")"
  url="https://github.com/radkesvat/WaterWall/releases/download/${WW_VER}/${asset}"

  tmpd="$(mktemp -d)"
  mkdir -p "${WW_BASE}/bin" "${WW_BASE}/libs"

  printf -- "\nDownloading: %s\n" "$url" > /dev/tty
  wget -qO "${tmpd}/ww.zip" "$url" || die "Failed to download WaterWall asset."
  unzip -q "${tmpd}/ww.zip" -d "${tmpd}/ww" || die "Failed to unzip WaterWall asset."

  # Robust binary discovery (zip layouts differ)
  local found_bin=""
  found_bin="$(find "${tmpd}/ww" -maxdepth 6 -type f \( -iname 'WaterWall' -o -iname 'waterwall' -o -iname 'waterwall*' \) 2>/dev/null | head -n 1 || true)"

  if [[ -z "$found_bin" ]]; then
    found_bin="$(
      find "${tmpd}/ww" -type f \
        ! -path '*/libs/*' \
        ! -name '*.so' ! -name '*.a' \
        ! -name '*.json' ! -name '*.txt' ! -name '*.md' \
        ! -name '*.yml' ! -name '*.yaml' \
        -printf '%s\t%p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR==1{print $2}'
    )"
  fi

  [[ -n "$found_bin" ]] || die "Could not locate WaterWall binary in the zip."

  install -m 0755 "$found_bin" "${WW_BIN}" || die "Failed to install WaterWall binary."
  chmod 0755 "${WW_BIN}" || true

  local found_libs=""
  found_libs="$(find "${tmpd}/ww" -maxdepth 6 -type d -name 'libs' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found_libs" ]]; then
    rm -rf "${WW_LIBS}" || true
    mkdir -p "${WW_LIBS}"
    cp -a "${found_libs}/." "${WW_LIBS}/"
  fi

  rm -rf "$tmpd" || true

  [[ -x "$WW_BIN" ]] || die "WaterWall installation failed."
  printf -- "WaterWall installed at: %s\n" "$WW_BIN" > /dev/tty
  tty_pause
}

# -----------------------------
# Validation helpers
# -----------------------------
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# -----------------------------
# JSON writers (PRETTY like your screenshots)
# - core.json ONLY (no <tunnel>.json)
# - libs-path = "libs/" and we symlink tunnel_dir/libs -> /opt/waterwall/libs
# - includes internal logs + mtu + ram-profile client/server
# -----------------------------
ensure_tunnel_layout() {
  local tdir="$1"
  mkdir -p "${tdir}/configs" "${tdir}/logs"
  : > "${tdir}/logs/core.log" || true
  : > "${tdir}/logs/network.log" || true
  : > "${tdir}/logs/dns.log" || true
  : > "${tdir}/logs/internal.log" || true

  # libs-path expects libs/ relative; make it exist
  ln -sfn "${WW_LIBS}" "${tdir}/libs"
}

write_core_json_pretty() {
  local tdir="$1"
  local ram_profile="$2"    # client | server
  local cfg_rel="$3"        # configs/iran-halfduplex.json

  cat > "${tdir}/core.json" <<EOF
{
  "log": {
    "path": "logs/",
    "core": {
      "loglevel": "INFO",
      "file": "core.log",
      "console": true
    },
    "network": {
      "loglevel": "INFO",
      "file": "network.log",
      "console": true
    },
    "dns": {
      "loglevel": "ERROR",
      "file": "dns.log",
      "console": true
    },
    "internal": {
      "loglevel": "INFO",
      "file": "internal.log",
      "console": true
    }
  },
  "misc": {
    "workers": 2,
    "mtu": 1480,
    "ram-profile": "${ram_profile}",
    "libs-path": "libs/"
  },
  "configs": ["${cfg_rel}"]
}
EOF
}

write_iran_halfduplex_pretty() {
  local tdir="$1"
  local local_port="$2"
  local foreign_ip="$3"
  local tunnel_port="$4"

  cat > "${tdir}/configs/iran-halfduplex.json" <<EOF
{
  "name": "iran_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    {
      "name": "iranin",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${local_port},
        "nodelay": true
      },
      "next": "hdclient"
    },
    {
      "name": "hdclient",
      "type": "HalfDuplexClient",
      "settings": {},
      "next": "toforeign"
    },
    {
      "name": "toforeign",
      "type": "TcpConnector",
      "settings": {
        "address": "${foreign_ip}",
        "port": ${tunnel_port},
        "nodelay": true
      }
    }
  ]
}
EOF
}

write_foreign_halfduplex_pretty() {
  local tdir="$1"
  local tunnel_port="$2"
  local target_port="$3"

  cat > "${tdir}/configs/foreign-halfduplex.json" <<EOF
{
  "name": "foreign_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    {
      "name": "foreignin",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${tunnel_port},
        "nodelay": true
      },
      "next": "hdserver"
    },
    {
      "name": "hdserver",
      "type": "HalfDuplexServer",
      "settings": {},
      "next": "totarget"
    },
    {
      "name": "totarget",
      "type": "TcpConnector",
      "settings": {
        "address": "127.0.0.1",
        "port": ${target_port},
        "nodelay": true
      }
    }
  ]
}
EOF
}

write_meta_env() {
  local tdir="$1"; shift
  : > "${tdir}/meta.env"
  local kv
  for kv in "$@"; do
    printf -- "%s\n" "$kv" >> "${tdir}/meta.env"
  done
}

load_meta_env() {
  local tdir="$1"
  [[ -f "${tdir}/meta.env" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  source "${tdir}/meta.env"
  set +a
}

regenerate_from_meta() {
  local tn="$1"
  local tdir="${CT_BASE}/${tn}"
  [[ -d "$tdir" ]] || die "Tunnel dir not found."
  load_meta_env "$tdir" || die "meta.env missing."

  ensure_tunnel_layout "$tdir"

  if [[ "${ROLE:-}" == "iran" ]]; then
    valid_port "${IRAN_LOCAL_PORT:-}" || die "Invalid meta: IRAN_LOCAL_PORT"
    valid_port "${IRAN_TUNNEL_PORT:-}" || die "Invalid meta: IRAN_TUNNEL_PORT"
    [[ -n "${IRAN_FOREIGN_IP:-}" ]] || die "Invalid meta: IRAN_FOREIGN_IP"
    write_iran_halfduplex_pretty "$tdir" "$IRAN_LOCAL_PORT" "$IRAN_FOREIGN_IP" "$IRAN_TUNNEL_PORT"
    write_core_json_pretty "$tdir" "client" "configs/iran-halfduplex.json"
  elif [[ "${ROLE:-}" == "foreign" ]]; then
    valid_port "${FOREIGN_TARGET_PORT:-}" || die "Invalid meta: FOREIGN_TARGET_PORT"
    valid_port "${FOREIGN_TUNNEL_PORT:-}" || die "Invalid meta: FOREIGN_TUNNEL_PORT"
    write_foreign_halfduplex_pretty "$tdir" "$FOREIGN_TUNNEL_PORT" "$FOREIGN_TARGET_PORT"
    write_core_json_pretty "$tdir" "server" "configs/foreign-halfduplex.json"
  else
    die "Unknown ROLE in meta.env (expected iran or foreign)."
  fi

  # Ensure no stray <tunnel>.json exists (user requirement)
  rm -f "${tdir}/${tn}.json" 2>/dev/null || true
}

# -----------------------------
# Create tunnel
# -----------------------------
create_tunnel() {
  install_waterwall
  ensure_systemd_template
  mkdir -p "${CT_BASE}"

  tty_clear
  local tn
  tty_read tn "Enter tunnel name (A-Z a-z 0-9 _ -): "
  valid_name "$tn" || die "Invalid tunnel name."
  local tdir="${CT_BASE}/${tn}"
  [[ -d "$tdir" ]] && die "Tunnel already exists: ${tn}"

  mkdir -p "$tdir/configs" "$tdir/logs"
  ensure_tunnel_layout "$tdir"

  local role_choice
  printf -- "\nSelect role:\n" > /dev/tty
  printf -- "1) Iran server (Client / HalfDuplexClient)\n" > /dev/tty
  printf -- "2) Foreign server (Server / HalfDuplexServer)\n" > /dev/tty
  tty_read role_choice "Enter choice [1-2]: "

  if [[ "$role_choice" == "1" ]]; then
    local local_port tunnel_port foreign_ip
    tty_read local_port "Local listen port (users connect here, e.g. 5055): "
    valid_port "$local_port" || die "Invalid port."
    tty_read tunnel_port "Tunnel port (connects to foreign server, e.g. 449): "
    valid_port "$tunnel_port" || die "Invalid port."
    tty_read foreign_ip "Foreign server IP (or hostname): "
    [[ -n "$foreign_ip" ]] || die "Foreign IP/host cannot be empty."

    write_meta_env "$tdir" \
      "TUNNEL_NAME=${tn}" \
      "ROLE=iran" \
      "IRAN_LOCAL_PORT=${local_port}" \
      "IRAN_TUNNEL_PORT=${tunnel_port}" \
      "IRAN_FOREIGN_IP=${foreign_ip}"

    regenerate_from_meta "$tn"

  elif [[ "$role_choice" == "2" ]]; then
    local target_port tunnel_port
    tty_read target_port "Target service port (e.g. Xray inbound, e.g. 5055): "
    valid_port "$target_port" || die "Invalid port."
    tty_read tunnel_port "Tunnel listen port (e.g. 449): "
    valid_port "$tunnel_port" || die "Invalid port."

    write_meta_env "$tdir" \
      "TUNNEL_NAME=${tn}" \
      "ROLE=foreign" \
      "FOREIGN_TARGET_PORT=${target_port}" \
      "FOREIGN_TUNNEL_PORT=${tunnel_port}"

    regenerate_from_meta "$tn"
  else
    rm -rf "$tdir" || true
    die "Invalid choice."
  fi

  svc_enable_start "$tn"

  printf -- "\nTunnel created: %s\n" "$tn" > /dev/tty
  printf -- "Service: %s\n" "$(svc_name "$tn")" > /dev/tty
  tty_pause
}

# -----------------------------
# Edit / Delete
# -----------------------------
edit_tunnel() {
  local tn="$1"
  local tdir="${CT_BASE}/${tn}"
  load_meta_env "$tdir" || die "meta.env missing."

  tty_clear
  printf -- "Editing tunnel: %s\nRole: %s\n\n" "$tn" "$ROLE" > /dev/tty

  if [[ "$ROLE" == "iran" ]]; then
    printf -- "1) Edit Foreign IP (current: %s)\n" "${IRAN_FOREIGN_IP:-}" > /dev/tty
    printf -- "2) Edit Local listen port (current: %s)\n" "${IRAN_LOCAL_PORT:-}" > /dev/tty
    printf -- "3) Edit Tunnel port (current: %s)\n" "${IRAN_TUNNEL_PORT:-}" > /dev/tty
    printf -- "0) Back\n" > /dev/tty
    local c v
    tty_read c "Choose: "
    case "$c" in
      1) tty_read v "New Foreign IP/host: "; [[ -n "$v" ]] || die "Empty."; IRAN_FOREIGN_IP="$v" ;;
      2) tty_read v "New Local listen port: "; valid_port "$v" || die "Invalid port."; IRAN_LOCAL_PORT="$v" ;;
      3) tty_read v "New Tunnel port: "; valid_port "$v" || die "Invalid port."; IRAN_TUNNEL_PORT="$v" ;;
      0) return 0 ;;
      *) die "Invalid choice." ;;
    esac
    write_meta_env "$tdir" \
      "TUNNEL_NAME=${tn}" \
      "ROLE=iran" \
      "IRAN_LOCAL_PORT=${IRAN_LOCAL_PORT}" \
      "IRAN_TUNNEL_PORT=${IRAN_TUNNEL_PORT}" \
      "IRAN_FOREIGN_IP=${IRAN_FOREIGN_IP}"

  elif [[ "$ROLE" == "foreign" ]]; then
    printf -- "1) Edit Target service port (current: %s)\n" "${FOREIGN_TARGET_PORT:-}" > /dev/tty
    printf -- "2) Edit Tunnel listen port (current: %s)\n" "${FOREIGN_TUNNEL_PORT:-}" > /dev/tty
    printf -- "0) Back\n" > /dev/tty
    local c v
    tty_read c "Choose: "
    case "$c" in
      1) tty_read v "New Target service port: "; valid_port "$v" || die "Invalid port."; FOREIGN_TARGET_PORT="$v" ;;
      2) tty_read v "New Tunnel listen port: "; valid_port "$v" || die "Invalid port."; FOREIGN_TUNNEL_PORT="$v" ;;
      0) return 0 ;;
      *) die "Invalid choice." ;;
    esac
    write_meta_env "$tdir" \
      "TUNNEL_NAME=${tn}" \
      "ROLE=foreign" \
      "FOREIGN_TARGET_PORT=${FOREIGN_TARGET_PORT}" \
      "FOREIGN_TUNNEL_PORT=${FOREIGN_TUNNEL_PORT}"
  else
    die "Unknown ROLE in meta.env."
  fi

  regenerate_from_meta "$tn"
  svc_restart "$tn"
  printf -- "\nUpdated and restarted: %s\n" "$(svc_name "$tn")" > /dev/tty
  tty_pause
}

delete_tunnel() {
  local tn="$1"
  local tdir="${CT_BASE}/${tn}"
  [[ -d "$tdir" ]] || die "Tunnel not found."

  tty_clear
  printf -- "Delete tunnel '%s'?\nType YES to confirm: " "$tn" > /dev/tty
  local ans
  IFS= read -r ans < /dev/tty
  if [[ "$ans" != "YES" ]]; then
    printf -- "Cancelled.\n" > /dev/tty
    tty_pause
    return 0
  fi

  svc_stop_disable "$tn"
  rm -rf "$tdir" || true

  printf -- "Deleted tunnel: %s\n" "$tn" > /dev/tty
  tty_pause
}

# -----------------------------
# Log file viewer (MANDATORY)
# -----------------------------
view_log_files() {
  local tn="$1"
  local tdir="${CT_BASE}/${tn}"
  local ldir="${tdir}/logs"
  [[ -d "$ldir" ]] || die "Logs directory not found."

  local files=()
  local f
  for f in core.log network.log dns.log internal.log; do
    [[ -f "${ldir}/${f}" ]] && files+=("${f}")
  done

  tty_clear
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf -- "No log files found in %s\n" "$ldir" > /dev/tty
    tty_pause
    return 0
  fi

  printf -- "Log files for %s:\n" "$tn" > /dev/tty
  local i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    printf -- "%d) %s\n" "$i" "$f" > /dev/tty
  done
  printf -- "0) Back\n" > /dev/tty

  local c
  tty_read c "Choose file: "
  [[ "$c" == "0" ]] && return 0
  [[ "$c" =~ ^[0-9]+$ ]] || die "Invalid selection."
  (( c >= 1 && c <= ${#files[@]} )) || die "Out of range."
  local selected="${files[$((c-1))]}"

  tty_clear
  printf -- "1) tail -n 200\n" > /dev/tty
  printf -- "2) tail -f (live)\n" > /dev/tty
  printf -- "0) Back\n" > /dev/tty
  local mode
  tty_read mode "Choose: "
  case "$mode" in
    1) tail -n 200 "${ldir}/${selected}" > /dev/tty; printf -- "\n" > /dev/tty; tty_pause ;;
    2) printf -- "Live mode. Press Ctrl+C to stop.\n\n" > /dev/tty; tail -f "${ldir}/${selected}" > /dev/tty ;;
    0) return 0 ;;
    *) die "Invalid choice." ;;
  esac
}

# -----------------------------
# List / manage tunnels
# -----------------------------
manage_tunnel() {
  local tn="$1"
  local sname
  sname="$(svc_name "$tn")"

  while true; do
    tty_clear
    local st="inactive"
    svc_is_active "$tn" && st="active"
    printf -- "Manage tunnel: %s  [%s]\n" "$tn" "$st" > /dev/tty
    printf -- "--------------------------------\n" > /dev/tty
    printf -- "1) Start / Restart\n" > /dev/tty
    printf -- "2) Stop\n" > /dev/tty
    printf -- "3) Service status (systemctl status)\n" > /dev/tty
    printf -- "4) Service logs (journalctl -u)\n" > /dev/tty
    printf -- "5) View log files\n" > /dev/tty
    printf -- "6) Edit tunnel\n" > /dev/tty
    printf -- "7) Delete tunnel\n" > /dev/tty
    printf -- "0) Back\n" > /dev/tty

    local c
    tty_read c "Choose: "
    case "$c" in
      1) svc_enable_start "$tn"; svc_restart "$tn"; printf -- "Restarted.\n" > /dev/tty; tty_pause ;;
      2) systemctl stop "$sname" >/dev/null 2>&1 || true; printf -- "Stopped.\n" > /dev/tty; tty_pause ;;
      3) systemctl status "$sname" --no-pager > /dev/tty 2>&1 || true; tty_pause ;;
      4) journalctl -u "$sname" --no-pager -n 200 > /dev/tty 2>&1 || true; tty_pause ;;
      5) view_log_files "$tn" ;;
      6) edit_tunnel "$tn" ;;
      7) delete_tunnel "$tn"; return 0 ;;
      0) return 0 ;;
      *) printf -- "Invalid choice.\n" > /dev/tty; tty_pause ;;
    esac
  done
}

list_tunnels() {
  mkdir -p "${CT_BASE}"
  local dirs=()
  local d
  while IFS= read -r -d '' d; do
    dirs+=("$d")
  done < <(find "${CT_BASE}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  if [[ "${#dirs[@]}" -eq 0 ]]; then
    tty_clear
    printf -- "No tunnels found.\n" > /dev/tty
    tty_pause
    return 0
  fi

  tty_clear
  printf -- "Tunnels:\n" > /dev/tty
  printf -- "---------------------------------------------\n" > /dev/tty

  local i=0
  local names=()
  for d in "${dirs[@]}"; do
    i=$((i+1))
    local tn role summary st
    tn="$(basename "$d")"
    names+=("$tn")

    role="unknown"; summary="(no meta.env)"
    if load_meta_env "$d" 2>/dev/null; then
      role="${ROLE:-unknown}"
      if [[ "$role" == "iran" ]]; then
        summary="local:${IRAN_LOCAL_PORT:-?} -> ${IRAN_FOREIGN_IP:-?}:${IRAN_TUNNEL_PORT:-?}"
      elif [[ "$role" == "foreign" ]]; then
        summary="0.0.0.0:${FOREIGN_TUNNEL_PORT:-?} -> 127.0.0.1:${FOREIGN_TARGET_PORT:-?}"
      fi
    fi

    st="inactive"
    svc_is_active "$tn" && st="active"

    printf -- "%2d) %-20s role:%-7s  %-35s  [%s]\n" "$i" "$tn" "$role" "$summary" "$st" > /dev/tty
  done

  printf -- "---------------------------------------------\n" > /dev/tty
  printf -- "Select a tunnel by number (or 0 to back)\n" > /dev/tty
  local choice
  tty_read choice "Enter: "
  [[ "$choice" == "0" ]] && return 0
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid selection."
  (( choice >= 1 && choice <= ${#names[@]} )) || die "Out of range."
  manage_tunnel "${names[$((choice-1))]}"
}

# -----------------------------
# Main menu
# -----------------------------
main_menu() {
  need_root
  mkdir -p "${CT_BASE}"
  ensure_systemd_template

  while true; do
    tty_clear
    printf -- "copytun - WaterWall Half-Duplex tunnel manager\n" > /dev/tty
    printf -- "---------------------------------------------\n" > /dev/tty
    printf -- "1) Create tunnel\n" > /dev/tty
    printf -- "2) List / Manage tunnels\n" > /dev/tty
    printf -- "3) Exit\n" > /dev/tty
    local c
    tty_read c "Choose: "
    case "$c" in
      1) create_tunnel ;;
      2) list_tunnels ;;
      3) tty_clear; exit 0 ;;
      *) printf -- "Invalid choice.\n" > /dev/tty; tty_pause ;;
    esac
  done
}

main_menu
```0