#!/usr/bin/env bash
# WaterWall Half-Duplex Tunnel Manager (v1.41)
# - Multi-tunnel
# - systemd persistent service
# - auto/manual binary selection (amd64/arm64 + old-cpu)
set -u

VERSION="1.41"

# Base paths (you can change if you want)
BASE_DIR="/opt/waterwall-tunnels"
WW_HOME="/opt/waterwall"
BIN_DIR="${WW_HOME}/bin"
BIN_PATH="${BIN_DIR}/WaterWall"
LIBS_DIR="${WW_HOME}/libs"
BUILD_INFO="${WW_HOME}/BUILD_INFO.txt"

SERVICE_TEMPLATE="/etc/systemd/system/waterwall@.service"

# Download URLs (as provided by you)
URL_GCC_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64.zip"
URL_GCC_X64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-x64-old-cpu.zip"
URL_GCC_ARM64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64.zip"
URL_GCC_ARM64_OLD="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-gcc-arm64-old-cpu.zip"
URL_CLANG_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-x64.zip"
URL_CLANG_AVX512_X64="https://github.com/radkesvat/WaterWall/releases/download/v1.41/Waterwall-linux-clang-avx512f-x64.zip"

# ---------- helpers ----------
die() { echo -e "\n[!] $*\n" >&2; exit 1; }
info() { echo -e "[*] $*"; }
warn() { echo -e "[!] $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "این اسکریپت باید با root اجرا بشه. (sudo bash $0)"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() {
  read -r -p $'\nEnter بزن برای ادامه... ' _
}

is_systemd_ok() {
  have_cmd systemctl && [[ -d /run/systemd/system ]]
}

sanitize_name() {
  # allow: a-zA-Z0-9 _ -
  local n="$1"
  if [[ -z "$n" ]]; then return 1; fi
  if [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 0
  fi
  return 1
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

prompt_port() {
  local prompt="$1"
  local default="${2:-}"
  local p
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "${prompt} [${default}]: " p
      [[ -z "$p" ]] && p="$default"
    else
      read -r -p "${prompt}: " p
    fi
    if valid_port "$p"; then
      echo "$p"
      return 0
    fi
    warn "پورت نامعتبره. عدد بین 1 تا 65535."
  done
}

prompt_text() {
  local prompt="$1"
  local default="${2:-}"
  local t
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " t
    [[ -z "$t" ]] && t="$default"
  else
    read -r -p "${prompt}: " t
  fi
  echo "$t"
}

download_file() {
  local url="$1"
  local out="$2"
  if have_cmd curl; then
    curl -L --fail -o "$out" "$url" || return 1
  elif have_cmd wget; then
    wget -O "$out" "$url" || return 1
  else
    return 2
  fi
}

extract_zip() {
  local zip="$1"
  local dest="$2"
  mkdir -p "$dest"

  if have_cmd unzip; then
    unzip -o "$zip" -d "$dest" >/dev/null
    return 0
  fi

  # fallback: python3 zipfile
  if have_cmd python3; then
    python3 - <<PY
import zipfile, sys, os
zip_path = sys.argv[1]
dest = sys.argv[2]
with zipfile.ZipFile(zip_path, 'r') as z:
    z.extractall(dest)
print("ok")
PY "$zip" "$dest" >/dev/null || return 1
    return 0
  fi

  return 1
}

cpu_flags_line() {
  # Works on most Linux
  if have_cmd lscpu; then
    lscpu | awk -F: '/Flags/ {print $2}' | head -n1
  else
    cat /proc/cpuinfo 2>/dev/null | awk -F: '/flags/ {print $2; exit}'
  fi
}

auto_pick_build_x64() {
  # If no AVX flag => pick old-cpu (more compatible)
  local flags
  flags="$(cpu_flags_line | tr 'A-Z' 'a-z')"
  if echo "$flags" | grep -qw avx; then
    echo "gcc-x64"
  else
    echo "gcc-x64-old"
  fi
}

auto_pick_build_arm64() {
  # default to gcc-arm64 (you can override)
  echo "gcc-arm64"
}

pick_build_menu() {
  local arch="$1"

  echo
  echo "انتخاب باینری WaterWall v${VERSION}:"
  echo "------------------------------------"

  if [[ "$arch" == "x86_64" ]]; then
    local auto
    auto="$(auto_pick_build_x64)"
    echo "1) Auto (پیشنهادی)  => ${auto}"
    echo "2) amd64 gcc x64"
    echo "3) amd64 gcc x64 old-cpu (برای CPU قدیمی / Illegal instruction)"
    echo "4) amd64 clang x64"
    echo "5) amd64 clang avx512 (فقط CPU خیلی جدید)"
    echo
    local c
    while true; do
      read -r -p "گزینه: " c
      case "$c" in
        1|"") echo "$auto"; return 0 ;;
        2) echo "gcc-x64"; return 0 ;;
        3) echo "gcc-x64-old"; return 0 ;;
        4) echo "clang-x64"; return 0 ;;
        5) echo "clang-avx512-x64"; return 0 ;;
        *) warn "گزینه نامعتبر." ;;
      esac
    done
  elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
    local auto
    auto="$(auto_pick_build_arm64)"
    echo "1) Auto (پیشنهادی)  => ${auto}"
    echo "2) arm64 gcc"
    echo "3) arm64 gcc old-cpu"
    echo
    local c
    while true; do
      read -r -p "گزینه: " c
      case "$c" in
        1|"") echo "$auto"; return 0 ;;
        2) echo "gcc-arm64"; return 0 ;;
        3) echo "gcc-arm64-old"; return 0 ;;
        *) warn "گزینه نامعتبر." ;;
      esac
    done
  else
    die "معماری پشتیبانی نمی‌شود: $arch"
  fi
}

build_to_url() {
  local build="$1"
  case "$build" in
    gcc-x64) echo "$URL_GCC_X64" ;;
    gcc-x64-old) echo "$URL_GCC_X64_OLD" ;;
    gcc-arm64) echo "$URL_GCC_ARM64" ;;
    gcc-arm64-old) echo "$URL_GCC_ARM64_OLD" ;;
    clang-x64) echo "$URL_CLANG_X64" ;;
    clang-avx512-x64) echo "$URL_CLANG_AVX512_X64" ;;
    *) return 1 ;;
  esac
}

install_waterwall_if_needed() {
  mkdir -p "$BIN_DIR" "$BASE_DIR" "$WW_HOME"

  if [[ -x "$BIN_PATH" ]]; then
    return 0
  fi

  info "WaterWall پیدا نشد. نصب می‌کنم..."

  local arch
  arch="$(uname -m)"
  local build
  build="$(pick_build_menu "$arch")"

  local url
  url="$(build_to_url "$build")" || die "Build نامعتبر: $build"

  info "دانلود: $url"
  local tmpzip tmpdir
  tmpzip="$(mktemp -t waterwall_zip_XXXXXX.zip)"
  tmpdir="$(mktemp -d -t waterwall_extract_XXXXXX)"

  if ! download_file "$url" "$tmpzip"; then
    rm -f "$tmpzip"; rm -rf "$tmpdir"
    die "دانلود ناموفق بود. (curl/wget و اینترنت رو چک کن)"
  fi

  info "Extract..."
  if ! extract_zip "$tmpzip" "$tmpdir"; then
    rm -f "$tmpzip"; rm -rf "$tmpdir"
    die "Extract ناموفق بود. (unzip یا python3 لازم است)"
  fi

  # Find binary (WaterWall / Waterwall)
  local found
  found="$(find "$tmpdir" -maxdepth 3 -type f \( -name 'WaterWall' -o -name 'Waterwall' \) -print -quit)"
  if [[ -z "$found" ]]; then
    rm -f "$tmpzip"; rm -rf "$tmpdir"
    die "باینری WaterWall داخل zip پیدا نشد."
  fi

  # Install binary
  cp -f "$found" "$BIN_PATH"
  chmod +x "$BIN_PATH"

  # If package contains libs folder, install it (optional)
  if [[ -d "$tmpdir/libs" ]]; then
    mkdir -p "$LIBS_DIR"
    cp -rf "$tmpdir/libs/." "$LIBS_DIR/" || true
  fi

  # Save build info
  cat > "$BUILD_INFO" <<EOF
version=${VERSION}
build=${build}
url=${url}
installed_at=$(date -Is)
arch=${arch}
EOF

  rm -f "$tmpzip"
  rm -rf "$tmpdir"

  info "نصب شد: $BIN_PATH"
}

ensure_service_template() {
  is_systemd_ok || die "systemd/systemctl در این سیستم فعال نیست. برای دائمی بودن تونل، systemd لازم است."

  mkdir -p "$(dirname "$SERVICE_TEMPLATE")"

  if [[ -f "$SERVICE_TEMPLATE" ]]; then
    return 0
  fi

  info "ساخت سرویس template: $SERVICE_TEMPLATE"
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

write_meta() {
  local dir="$1"
  shift
  # remaining args are KEY=VAL
  {
    echo "# generated by ww-halfduplex-manager"
    echo "UPDATED_AT=$(date -Is)"
    for kv in "$@"; do
      echo "$kv"
    done
  } > "${dir}/tunnel.meta"
}

load_meta() {
  local dir="$1"
  local f="${dir}/tunnel.meta"
  [[ -f "$f" ]] || return 1

  # defaults
  ROLE=""
  LOCAL_LISTEN_PORT=""
  TUNNEL_PORT=""
  FOREIGN_IP=""
  LISTEN_PORT=""
  TARGET_PORT=""
  TARGET_ADDR="127.0.0.1"

  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
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
      *) : ;;
    esac
  done < "$f"

  return 0
}

write_config_iran() {
  local tname="$1"
  local dir="$2"
  local local_port="$3"
  local foreign_ip="$4"
  local tunnel_port="$5"

  mkdir -p "${dir}/configs" "${dir}/logs"
  # symlink libs to global libs if exists, else make local empty dir
  if [[ -d "$LIBS_DIR" ]]; then
    ln -sfn "$LIBS_DIR" "${dir}/libs"
  else
    mkdir -p "${dir}/libs"
  fi

  cat > "${dir}/configs/iran-halfduplex.json" <<JSON
{
  "name": "${tname}_iran_halfduplex",
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
JSON

  # core file named by tunnel, and core.json -> that file
  cat > "${dir}/${tname}.json" <<JSON
{
  "log": {
    "path": "logs/",
    "core":    { "loglevel": "INFO", "file": "core.log",    "console": true },
    "network": { "loglevel": "INFO", "file": "network.log", "console": true },
    "dns":     { "loglevel": "ERROR","file": "dns.log",     "console": true },
    "internal":{ "loglevel": "INFO", "file": "internal.log","console": true }
  },
  "misc": {
    "workers": 0,
    "mtu": 1500,
    "ram-profile": "client",
    "libs-path": "libs/"
  },
  "configs": ["configs/iran-halfduplex.json"]
}
JSON

  ln -sfn "${tname}.json" "${dir}/core.json"
}

write_config_foreign() {
  local tname="$1"
  local dir="$2"
  local listen_port="$3"
  local target_port="$4"
  local target_addr="${5:-127.0.0.1}"

  mkdir -p "${dir}/configs" "${dir}/logs"
  if [[ -d "$LIBS_DIR" ]]; then
    ln -sfn "$LIBS_DIR" "${dir}/libs"
  else
    mkdir -p "${dir}/libs"
  fi

  cat > "${dir}/configs/foreign-halfduplex.json" <<JSON
{
  "name": "${tname}_foreign_halfduplex",
  "config-version": 1,
  "core-minimum-version": 1,
  "nodes": [
    {
      "name": "foreignin",
      "type": "TcpListener",
      "settings": {
        "address": "0.0.0.0",
        "port": ${listen_port},
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
        "address": "${target_addr}",
        "port": ${target_port},
        "nodelay": true
      }
    }
  ]
}
JSON

  cat > "${dir}/${tname}.json" <<JSON
{
  "log": {
    "path": "logs/",
    "core":    { "loglevel": "INFO", "file": "core.log",    "console": true },
    "network": { "loglevel": "INFO", "file": "network.log", "console": true },
    "dns":     { "loglevel": "ERROR","file": "dns.log",     "console": true },
    "internal":{ "loglevel": "INFO", "file": "internal.log","console": true }
  },
  "misc": {
    "workers": 0,
    "mtu": 1500,
    "ram-profile": "server",
    "libs-path": "libs/"
  },
  "configs": ["configs/foreign-halfduplex.json"]
}
JSON

  ln -sfn "${tname}.json" "${dir}/core.json"
}

service_name_for() {
  local tname="$1"
  echo "waterwall@${tname}.service"
}

start_enable_tunnel() {
  local tname="$1"
  local svc
  svc="$(service_name_for "$tname")"
  systemctl daemon-reload
  systemctl enable --now "$svc"
}

restart_tunnel() {
  local tname="$1"
  local svc
  svc="$(service_name_for "$tname")"
  systemctl restart "$svc"
}

stop_tunnel() {
  local tname="$1"
  local svc
  svc="$(service_name_for "$tname")"
  systemctl stop "$svc" || true
}

status_tunnel() {
  local tname="$1"
  local svc
  svc="$(service_name_for "$tname")"
  systemctl --no-pager status "$svc" || true
  echo
  echo "---- last logs ----"
  journalctl -u "$svc" -n 50 --no-pager || true
}

delete_tunnel() {
  local tname="$1"
  local dir="${BASE_DIR}/${tname}"
  local svc
  svc="$(service_name_for "$tname")"

  read -r -p "برای حذف کامل تونل '${tname}' تایپ کن YES: " confirm
  [[ "$confirm" == "YES" ]] || { info "لغو شد."; return 0; }

  systemctl disable --now "$svc" >/dev/null 2>&1 || true
  rm -rf "$dir"
  info "حذف شد: $tname"
}

list_tunnel_names() {
  mkdir -p "$BASE_DIR"
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

print_tunnels_table() {
  local names
  mapfile -t names < <(list_tunnel_names)
  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "هیچ تونلی ساخته نشده."
    return 1
  fi

  echo
  echo "لیست تونل‌ها:"
  echo "---------------------------------------------"
  local i=1
  for n in "${names[@]}"; do
    local dir="${BASE_DIR}/${n}"
    local role="-"
    local detail="-"
    if load_meta "$dir"; then
      role="$ROLE"
      if [[ "$ROLE" == "iran" ]]; then
        detail="listen:${LOCAL_LISTEN_PORT}  =>  ${FOREIGN_IP}:${TUNNEL_PORT}"
      elif [[ "$ROLE" == "foreign" ]]; then
        detail="listen:${LISTEN_PORT}  =>  ${TARGET_ADDR}:${TARGET_PORT}"
      fi
    fi

    local svc="waterwall@${n}.service"
    local st="unknown"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      st="active"
    else
      st="inactive"
    fi

    printf "%2d) %-20s  role=%-7s  status=%-8s  %s\n" "$i" "$n" "$role" "$st" "$detail"
    ((i++))
  done
  echo "---------------------------------------------"
  return 0
}

create_tunnel() {
  install_waterwall_if_needed
  ensure_service_template

  echo
  echo "ایجاد تونل جدید"
  echo "---------------"

  local tname
  while true; do
    tname="$(prompt_text "اسم تانل (فقط حروف/عدد/-/_ )")"
    if sanitize_name "$tname"; then
      break
    fi
    warn "اسم نامعتبره. فقط A-Z a-z 0-9 و - و _ مجاز است."
  done

  local dir="${BASE_DIR}/${tname}"
  if [[ -e "$dir" ]]; then
    die "تونل با این اسم وجود دارد: $tname"
  fi
  mkdir -p "$dir"

  echo
  echo "این سرور کدام است؟"
  echo "1) سرور ایران (Client / HalfDuplexClient)"
  echo "2) سرور خارج (Server / HalfDuplexServer)"
  local role_choice
  while true; do
    read -r -p "گزینه (1/2): " role_choice
    case "$role_choice" in
      1|2) break ;;
      *) warn "گزینه نامعتبر." ;;
    esac
  done

  if [[ "$role_choice" == "1" ]]; then
    # Iran
    local local_port tunnel_port foreign_ip
    local_port="$(prompt_port "پورت لوکال برای Listen (مثلاً 5055 که کاربر وصل میشه)" "5055")"
    tunnel_port="$(prompt_port "پورت تانل (پورتی که به سرور خارج وصل میشی، مثلاً 449)" "449")"
    foreign_ip="$(prompt_text "IP سرور خارج")"

    write_config_iran "$tname" "$dir" "$local_port" "$foreign_ip" "$tunnel_port"
    write_meta "$dir" \
      "ROLE=iran" \
      "LOCAL_LISTEN_PORT=${local_port}" \
      "TUNNEL_PORT=${tunnel_port}" \
      "FOREIGN_IP=${foreign_ip}" \
      "TARGET_ADDR=127.0.0.1"

  else
    # Foreign
    local target_port listen_port
    target_port="$(prompt_port "پورت سرویس مقصد روی همین سرور (مثلاً inbound xray)" "5055")"
    listen_port="$(prompt_port "پورت Listen برای دریافت تانل از ایران (پورت تانل)" "449")"

    write_config_foreign "$tname" "$dir" "$listen_port" "$target_port" "127.0.0.1"
    write_meta "$dir" \
      "ROLE=foreign" \
      "LISTEN_PORT=${listen_port}" \
      "TARGET_PORT=${target_port}" \
      "TARGET_ADDR=127.0.0.1"
  fi

  start_enable_tunnel "$tname"

  echo
  info "تونل ساخته شد و فعال شد: $tname"
  echo "Service: waterwall@${tname}.service"
  echo
  status_tunnel "$tname"
  pause
}

edit_tunnel() {
  local tname="$1"
  local dir="${BASE_DIR}/${tname}"

  load_meta "$dir" || die "meta پیدا نشد: ${dir}/tunnel.meta"

  echo
  echo "ویرایش تونل: $tname (role=$ROLE)"
  echo "--------------------------------"

  if [[ "$ROLE" == "iran" ]]; then
    local new_local new_tunnel new_ip
    new_local="$(prompt_port "پورت Listen لوکال (کاربر بهش وصل میشه)" "$LOCAL_LISTEN_PORT")"
    new_tunnel="$(prompt_port "پورت تانل (اتصال به خارج)" "$TUNNEL_PORT")"
    new_ip="$(prompt_text "IP سرور خارج" "$FOREIGN_IP")"

    write_config_iran "$tname" "$dir" "$new_local" "$new_ip" "$new_tunnel"
    write_meta "$dir" \
      "ROLE=iran" \
      "LOCAL_LISTEN_PORT=${new_local}" \
      "TUNNEL_PORT=${new_tunnel}" \
      "FOREIGN_IP=${new_ip}" \
      "TARGET_ADDR=127.0.0.1"

  elif [[ "$ROLE" == "foreign" ]]; then
    local new_listen new_target
    new_target="$(prompt_port "پورت مقصد (مثلاً xray)" "$TARGET_PORT")"
    new_listen="$(prompt_port "پورت Listen تانل" "$LISTEN_PORT")"

    write_config_foreign "$tname" "$dir" "$new_listen" "$new_target" "127.0.0.1"
    write_meta "$dir" \
      "ROLE=foreign" \
      "LISTEN_PORT=${new_listen}" \
      "TARGET_PORT=${new_target}" \
      "TARGET_ADDR=127.0.0.1"
  else
    die "ROLE نامعتبر در meta: $ROLE"
  fi

  restart_tunnel "$tname"
  info "ویرایش انجام شد و سرویس ریستارت شد."
  pause
}

manage_one_tunnel() {
  local tname="$1"
  local dir="${BASE_DIR}/${tname}"

  while true; do
    echo
    echo "مدیریت تونل: $tname"
    echo "-------------------------"
    echo "1) Start/Restart"
    echo "2) Stop"
    echo "3) Status + Logs"
    echo "4) نمایش فایل‌ها (core/config/meta)"
    echo "5) Edit تنظیمات"
    echo "6) حذف تونل"
    echo "0) برگشت"
    local c
    read -r -p "گزینه: " c
    case "$c" in
      1) restart_tunnel "$tname"; info "restart شد."; pause ;;
      2) stop_tunnel "$tname"; info "stop شد."; pause ;;
      3) status_tunnel "$tname"; pause ;;
      4)
        echo
        echo "---- ${dir}/tunnel.meta ----"
        cat "${dir}/tunnel.meta" 2>/dev/null || true
        echo
        echo "---- ${dir}/core.json ----"
        cat "${dir}/core.json" 2>/dev/null || true
        echo
        if [[ -f "${dir}/configs/iran-halfduplex.json" ]]; then
          echo "---- ${dir}/configs/iran-halfduplex.json ----"
          cat "${dir}/configs/iran-halfduplex.json"
        fi
        if [[ -f "${dir}/configs/foreign-halfduplex.json" ]]; then
          echo "---- ${dir}/configs/foreign-halfduplex.json ----"
          cat "${dir}/configs/foreign-halfduplex.json"
        fi
        pause
        ;;
      5) edit_tunnel "$tname" ;;
      6) delete_tunnel "$tname"; pause; return 0 ;;
      0) return 0 ;;
      *) warn "گزینه نامعتبر." ;;
    esac
  done
}

list_and_manage() {
  ensure_service_template

  while true; do
    if ! print_tunnels_table; then
      pause
      return 0
    fi

    echo
    read -r -p "شماره تونل برای مدیریت (یا 0 برای برگشت): " sel
    [[ -z "$sel" ]] && sel="0"
    if [[ "$sel" == "0" ]]; then
      return 0
    fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
      warn "عدد وارد کن."
      continue
    fi

    local names
    mapfile -t names < <(list_tunnel_names)
    local idx=$((sel-1))
    if (( idx < 0 || idx >= ${#names[@]} )); then
      warn "شماره خارج از محدوده."
      continue
    fi

    manage_one_tunnel "${names[$idx]}"
  done
}

main_menu() {
  need_root
  is_systemd_ok || die "systemd فعال نیست. این اسکریپت برای پایداری تونل به systemd نیاز دارد."

  mkdir -p "$BASE_DIR" "$WW_HOME" "$BIN_DIR"

  while true; do
    clear || true
    echo "==============================================="
    echo " WaterWall Half-Duplex Tunnel Manager (v${VERSION})"
    echo "==============================================="
    echo "1) ایجاد تونل جدید"
    echo "2) لیست/مدیریت تونل‌ها"
    echo "3) خروج"
    echo "-----------------------------------------------"
    local c
    read -r -p "گزینه: " c
    case "$c" in
      1) create_tunnel ;;
      2) list_and_manage ;;
      3) exit 0 ;;
      *) warn "گزینه نامعتبر."; pause ;;
    esac
  done
}

main_menu