#!/usr/bin/env bash
# Usage: 把 proxy-node 可执行文件和本脚本放同一目录，然后 sudo bash install.sh
# 支持 direct node_type=mx，也支持 node_type=v2node 且面板下发 protocol=mx

set -uo pipefail

##############################################################################
# 可改配置
##############################################################################
SERVICE_NAME="proxy-node"
BINARY="proxy-node"
INSTALL_DIR="/opt/proxy-node"
FREEBSD_RC_SCRIPT="/usr/local/etc/rc.d/${SERVICE_NAME}"
WARP_MENU_URL="${WARP_MENU_URL:-https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh}"
TCP_BRUTAL_REPO="${TCP_BRUTAL_REPO:-https://github.com/apernet/tcp-brutal.git}"
TCP_BRUTAL_SRC_DIR="${TCP_BRUTAL_SRC_DIR:-/usr/local/src/tcp-brutal}"
MUNDO_BRUTAL_REPO="${MUNDO_BRUTAL_REPO:-https://github.com/Mundo-Connect/Mundo-Brutal.git}"
MUNDO_BRUTAL_SRC_DIR="${MUNDO_BRUTAL_SRC_DIR:-/usr/local/src/mundo-brutal}"
BRUTAL_MBPS=0

##############################################################################
# 颜色输出
##############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

is_alpine() {
  [[ -f /etc/alpine-release ]]
}

is_freebsd() {
  [[ "$(uname -s)" == "FreeBSD" ]]
}

service_installed() {
  [[ -x "${BINARY_PATH}" ]] ||
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] ||
  [[ -f "/etc/init.d/${SERVICE_NAME}" ]] ||
  [[ -f "${FREEBSD_RC_SCRIPT}" ]] ||
  [[ -f "/etc/supervisor/conf.d/${SERVICE_NAME}.conf" ]] ||
  [[ -f "/etc/supervisord.d/${SERVICE_NAME}.conf" ]] ||
  [[ -f "${INSTALL_DIR}/watchdog.sh" ]]
}

service_running() {
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" onestatus &>/dev/null && return 0
  fi
  if command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
    systemctl is-active --quiet "${SERVICE_NAME}" && return 0
  fi
  if command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" status &>/dev/null && return 0
  fi
  if command -v supervisorctl &>/dev/null; then
    supervisorctl status "${SERVICE_NAME}" 2>/dev/null | grep -q RUNNING && return 0
  fi
  pgrep -f "${BINARY_PATH} -c ${CONFIG_FILE}" &>/dev/null
}

stop_service() {
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" stop &>/dev/null || true
  elif command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
    systemctl stop "${SERVICE_NAME}" &>/dev/null || true
  elif command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" stop &>/dev/null || true
  elif command -v supervisorctl &>/dev/null; then
    supervisorctl stop "${SERVICE_NAME}" &>/dev/null || true
  else
    pkill -f "${BINARY_PATH} -c ${CONFIG_FILE}" &>/dev/null || true
  fi
}

start_service() {
  if is_freebsd && [[ -x "${FREEBSD_RC_SCRIPT}" ]]; then
    service "${SERVICE_NAME}" start
  elif command -v systemctl &>/dev/null && systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
    systemctl start "${SERVICE_NAME}"
  elif command -v rc-service &>/dev/null && [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    rc-service "${SERVICE_NAME}" start
  elif command -v supervisorctl &>/dev/null; then
    supervisorctl start "${SERVICE_NAME}" || true
  elif [[ -x "${INSTALL_DIR}/watchdog.sh" ]]; then
    nohup "${INSTALL_DIR}/watchdog.sh" >/dev/null 2>&1 &
  fi
}

install_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Proxy Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  info "systemd 服务已安装（Restart=always，被 kill 也会自动拉起）"
  echo ""
  echo "  编辑配置: ${CONFIG_FILE}"
  echo "  补全配置: ${NODE_DEFAULTS_FILE}"
  echo "  启动:     systemctl start ${SERVICE_NAME}"
  echo "  日志:     journalctl -fu ${SERVICE_NAME}"
}

install_openrc_service() {
  local run_dir="/run/${SERVICE_NAME}"
  mkdir -p "$run_dir"
  cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Proxy Node"
supervisor="supervise-daemon"
command="${BINARY_PATH}"
command_args="-c ${CONFIG_FILE}"
command_user="root:root"
directory="${INSTALL_DIR}"
pidfile="/run/${SERVICE_NAME}/${SERVICE_NAME}.pid"
respawn_delay=3
respawn_max=0
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -m 0755 -o root:root "${run_dir}"
}
EOF
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  rc-update add "${SERVICE_NAME}" default
  info "OpenRC 服务已安装（supervise-daemon respawn 无限重启）"
  if is_alpine; then
    info "已识别 Alpine Linux，服务已加入 default runlevel"
  fi
  echo ""
  echo "  编辑配置: ${CONFIG_FILE}"
  echo "  补全配置: ${NODE_DEFAULTS_FILE}"
  echo "  启动:     rc-service ${SERVICE_NAME} start"
  echo "  日志:     tail -f /var/log/${SERVICE_NAME}.log"
}

install_freebsd_service() {
  mkdir -p "$(dirname "${FREEBSD_RC_SCRIPT}")"
  cat > "${FREEBSD_RC_SCRIPT}" <<EOF
#!/bin/sh
# PROVIDE: proxy_node
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="proxy_node"
rcvar="proxy_node_enable"
load_rc_config "\$name"
: \${proxy_node_enable:="NO"}

pidfile="/var/run/${SERVICE_NAME}.pid"
command="/usr/sbin/daemon"
command_args="-f -P \${pidfile} -r -R 3 -o /var/log/${SERVICE_NAME}.log ${BINARY_PATH} -c ${CONFIG_FILE}"
required_files="${BINARY_PATH} ${CONFIG_FILE}"
start_precmd="proxy_node_prestart"

proxy_node_prestart() {
  ulimit -S -n "\$(ulimit -H -n)" 2>/dev/null || true
}

run_rc_command "\$1"
EOF
  chmod 555 "${FREEBSD_RC_SCRIPT}"
  sysrc proxy_node_enable=YES >/dev/null
  info "FreeBSD rc.d 服务已安装（daemon 自动重启）"
  echo ""
  echo "  编辑配置: ${CONFIG_FILE}"
  echo "  补全配置: ${NODE_DEFAULTS_FILE}"
  echo "  启动:     service ${SERVICE_NAME} start"
  echo "  停止:     service ${SERVICE_NAME} stop"
  echo "  日志:     tail -f /var/log/${SERVICE_NAME}.log"
}

public_ipv6_status() {
  local output line addr
  if command -v ip &>/dev/null; then
    output="$(ip -o -6 addr show scope global 2>/dev/null || true)"
  elif command -v ifconfig &>/dev/null; then
    output="$(ifconfig 2>/dev/null | awk '/inet6 / {print}' || true)"
  else
    return 2
  fi

  while IFS= read -r line; do
    addr=""
    for word in $line; do
      case "$word" in
        */*) addr="${word%%/*}" ;;
        [0-9a-fA-F]*:*) addr="$word" ;;
      esac
      [[ -n "$addr" ]] || continue
      addr="${addr#addr:}"
      addr="${addr%%%*}"
      case "$addr" in
        ""|::1|fe80:*|FE80:*|fc*|FC*|fd*|FD*) ;;
        2*|3*) return 0 ;;
      esac
    done
  done <<< "$output"

  return 1
}

want_warp_setup() {
  local answer="${PROXY_NODE_WARP:-}"
  if [[ -z "$answer" && -t 0 ]]; then
    echo ""
    warn "首次安装检测到尚未存在 ${CONFIG_FILE}"
    warn "当前网卡未检测到公网 IPv6，IPv6 目标可能无法从节点侧拨通。"
    read -r -p "是否现在一键运行 WARP 添加 IPv6? [y/N]: " answer
  fi

  case "$answer" in
    y|Y|yes|YES|Yes|1|true|TRUE|True|on|ON|On)
      return 0
      ;;
  esac
  return 1
}

run_warp_setup_if_requested() {
  if is_freebsd; then
    return 0
  fi
  public_ipv6_status
  case "$?" in
    0)
      info "检测到公网 IPv6，跳过 WARP 提示"
      return 0
      ;;
    2)
      warn "未检测到 ip/ifconfig，跳过公网 IPv6 检测和 WARP 提示"
      return 0
      ;;
  esac

  if ! want_warp_setup; then
    if [[ "${PROXY_NODE_WARP:-}" == "" && ! -t 0 ]]; then
      info "非交互安装未启用 WARP；如需启用可设置 PROXY_NODE_WARP=1"
    fi
    return 0
  fi

  if ! command -v wget &>/dev/null; then
    warn "未检测到 wget，跳过 WARP 一键脚本"
    warn "可手动执行: wget -N ${WARP_MENU_URL} && bash menu.sh [option] [license/url/token]"
    return 0
  fi

  local option="${PROXY_NODE_WARP_OPTION:-6}"
  local argument="${PROXY_NODE_WARP_ARGUMENT:-${PROXY_NODE_WARP_TOKEN:-${PROXY_NODE_WARP_LICENSE:-${PROXY_NODE_WARP_URL:-}}}}"
  if [[ -z "${PROXY_NODE_WARP_OPTION:-}" && -t 0 ]]; then
    local input_option=""
    read -r -p "WARP menu option [6=IPv6, d=双栈，默认 6]: " input_option
    if [[ -n "$input_option" ]]; then
      option="$input_option"
    fi
  fi
  if [[ -z "$argument" && -t 0 ]]; then
    read -r -p "license/url/token（可选，留空跳过）: " argument
  fi

  info "下载 WARP 一键脚本: ${WARP_MENU_URL}"
  if ! wget -N "${WARP_MENU_URL}"; then
    warn "WARP 脚本下载失败，跳过（不影响 proxy-node 安装）"
    return 0
  fi

  info "运行 WARP 一键脚本"
  if [[ -n "$option" && -n "$argument" ]]; then
    bash menu.sh "$option" "$argument" || warn "WARP 脚本执行失败，请根据上方输出手动处理"
  elif [[ -n "$option" ]]; then
    bash menu.sh "$option" || warn "WARP 脚本执行失败，请根据上方输出手动处理"
  else
    bash menu.sh || warn "WARP 脚本执行失败，请根据上方输出手动处理"
  fi
}


prompt_brutal_mbps() {
  local mbps="${PROXY_NODE_BRUTAL_MBPS:-}"
  if [[ -z "$mbps" && -t 0 ]]; then
    read -r -p "请输入 Brutal 速率 Mbps [1000]: " mbps
  fi
  [[ "$mbps" =~ ^[0-9]+$ && "$mbps" -gt 0 ]] || mbps=1000
  echo "$mbps"
}


set_config_brutal_mbps() {
  BRUTAL_MBPS="$(prompt_brutal_mbps)"
  sed -i -E "s/\"brutalMbps\"[[:space:]]*:[[:space:]]*-?[0-9]+/\"brutalMbps\": ${BRUTAL_MBPS}/" "$CONFIG_FILE" || true
  info "Brutal 速率已写入配置: ${BRUTAL_MBPS} Mbps"
}

set_config_brutal_disabled() {
  sed -i -E "s/\"brutalMbps\"[[:space:]]*:[[:space:]]*-?[0-9]+/\"brutalMbps\": -1/" "$CONFIG_FILE" || true
  warn "Brutal 模块未成功加载，保持禁用: brutalMbps=-1"
}

choose_brutal_setup() {
  local answer="${PROXY_NODE_BRUTAL:-}"
  if [[ -z "$answer" && -n "${PROXY_NODE_TCP_BRUTAL:-}" ]]; then
    case "$PROXY_NODE_TCP_BRUTAL" in
      ""|0|n|N|no|NO|No|false|FALSE|False|off|OFF|Off) answer=0 ;;
      *) answer=tcp ;;
    esac
  fi
  if [[ -z "$answer" && -t 0 ]]; then
    echo "" >&2
    warn "Brutal 可选安装，默认不安装。安装成功后才会询问速率。" >&2
    echo "  0) 不安装 Brutal（默认）" >&2
    echo "  1) 安装 Mundo X Brutal（推荐）" >&2
    echo "  2) 安装 TCP Brutal" >&2
    read -r -p "请选择 Brutal 安装类型 [0/1/2，默认 0]: " answer
  fi

  case "$answer" in
    ""|0|n|N|no|NO|No|false|FALSE|False|off|OFF|Off)
      echo ""
      ;;
    y|Y|yes|YES|Yes|mundo|MUNDO|Mundo|m|M|1|true|TRUE|True|on|ON|On)
      echo "mundo"
      ;;
    tcp|TCP|Tcp|2)
      echo "tcp"
      ;;
    *)
      warn "未识别 Brutal 安装选项: ${answer}，默认不安装" >&2
      echo ""
      ;;
  esac
}

brutal_module_loaded() {
  local name
  if [[ -r /proc/modules ]]; then
    while read -r name _; do
      case "$name" in
        brutal|tcp_brutal|mundo|mundo_brutal|*brutal*) return 0 ;;
      esac
    done < /proc/modules
  elif command -v lsmod &>/dev/null; then
    while read -r name _; do
      case "$name" in
        Module) ;;
        brutal|tcp_brutal|mundo|mundo_brutal|*brutal*) return 0 ;;
      esac
    done < <(lsmod 2>/dev/null || true)
  fi
  return 1
}

kernel_build_dir() {
  local rel dir
  rel="$(uname -r)"
  for dir in "/lib/modules/${rel}/build" "/usr/src/kernels/${rel}" "/usr/src/linux-headers-${rel}"; do
    [[ -e "${dir}/Makefile" ]] && { printf '%s\n' "$dir"; return 0; }
  done
  return 1
}

kernel_headers_ready() {
  kernel_build_dir >/dev/null
}

apt_install_one_of() {
  local pkg
  for pkg in "$@"; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
      return 0
    fi
  done
  return 1
}

alpine_kernel_dev_package() {
  local rel flavor
  rel="$(uname -r)"
  flavor="${rel##*-}"
  if [[ -z "$flavor" || "$flavor" == "$rel" ]]; then
    flavor="lts"
  fi
  printf 'linux-%s-dev' "$flavor"
}

install_brutal_build_deps() {
  local clang_major=""
  clang_major="$(kernel_clang_major)"
  if command -v apk &>/dev/null; then
    local kernel_dev
    kernel_dev="$(alpine_kernel_dev_package)"
    info "安装 Alpine Brutal 构建依赖: ${kernel_dev}"
    apk add --no-cache bash ca-certificates curl git make gcc clang llvm lld kmod binutils linux-headers musl-dev elfutils-dev "$kernel_dev" ||
      apk add --no-cache bash ca-certificates curl git make gcc clang llvm lld kmod binutils linux-headers musl-dev
  elif command -v apt-get &>/dev/null; then
    apt-get update || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git make kmod binutils build-essential libelf-dev pkg-config || return 1
    if [[ -n "$clang_major" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y "clang-${clang_major}" "llvm-${clang_major}" "lld-${clang_major}" || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y clang llvm lld || true
  elif command -v dnf &>/dev/null; then
    dnf install -y ca-certificates curl git make kmod binutils gcc elfutils-libelf-devel || return 1
    dnf install -y clang llvm lld || true
  elif command -v yum &>/dev/null; then
    yum install -y ca-certificates curl git make kmod binutils gcc elfutils-libelf-devel || return 1
    yum install -y clang llvm lld || true
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm ca-certificates curl git make kmod binutils gcc clang llvm lld libelf || return 1
  elif command -v zypper &>/dev/null; then
    zypper --non-interactive install ca-certificates curl git make kmod binutils gcc clang llvm lld libelf-devel || return 1
  else
    warn "未识别包管理器，无法自动安装 Brutal 构建依赖"
  fi

  command -v git &>/dev/null || { warn "未检测到 git"; return 1; }
  command -v make &>/dev/null || { warn "未检测到 make"; return 1; }
}

ensure_brutal_kernel_headers() {
  if kernel_headers_ready; then
    info "已检测到当前内核 headers/build 目录: $(kernel_build_dir)"
    return 0
  fi

  local rel
  rel="$(uname -r)"
  warn "未检测到当前内核 headers/build 目录，尝试安装: ${rel}"

  if command -v apk &>/dev/null; then
    apk add --no-cache linux-headers "$(alpine_kernel_dev_package)" || apk add --no-cache linux-headers || true
  elif command -v apt-get &>/dev/null; then
    apt-get update || true
    apt_install_one_of "linux-headers-${rel}" linux-headers-amd64 linux-headers-generic || true
  elif command -v dnf &>/dev/null; then
    dnf install -y "kernel-devel-${rel}" kernel-headers || dnf install -y kernel-devel kernel-headers || true
  elif command -v yum &>/dev/null; then
    yum install -y "kernel-devel-${rel}" kernel-headers || yum install -y kernel-devel kernel-headers || true
  elif command -v pacman &>/dev/null; then
    local pkg="linux-headers"
    case "$rel" in
      *-lts*) pkg="linux-lts-headers" ;;
      *-zen*) pkg="linux-zen-headers" ;;
      *-hardened*) pkg="linux-hardened-headers" ;;
    esac
    pacman -Sy --noconfirm "$pkg" || true
  elif command -v zypper &>/dev/null; then
    zypper --non-interactive install kernel-default-devel kernel-devel || true
  else
    warn "未识别包管理器，无法自动安装 kernel headers"
  fi

  if kernel_headers_ready; then
    info "kernel headers 已就绪: $(kernel_build_dir)"
    return 0
  fi

  warn "kernel headers 仍不可用，跳过 Brutal 安装"
  warn "请先安装与当前内核匹配的 headers/devel 包: ${rel}"
  return 1
}

kernel_compiler_text() {
  local build_dir
  build_dir="$(kernel_build_dir 2>/dev/null || true)"
  if [[ -n "$build_dir" && -r "${build_dir}/include/generated/compile.h" ]]; then
    sed -n 's/^#define LINUX_COMPILER "\(.*\)"/\1/p' "${build_dir}/include/generated/compile.h"
  fi
  [[ -r /proc/version ]] && cat /proc/version
}

kernel_uses_clang() {
  kernel_compiler_text | grep -qi 'clang'
}

kernel_clang_major() {
  kernel_compiler_text | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p' | head -n 1
}

llvm_tools_ready() {
  local suffix="${1:-}" tool
  for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf; do
    command -v "${tool}${suffix}" &>/dev/null || return 1
  done
}

select_brutal_make_args() {
  local clang_major
  BRUTAL_MAKE_ARGS=()
  if kernel_uses_clang; then
    clang_major="$(kernel_clang_major)"
    if [[ -n "$clang_major" ]] && command -v "clang-${clang_major}" &>/dev/null; then
      if llvm_tools_ready "-${clang_major}"; then
        BRUTAL_MAKE_ARGS=(LLVM="-${clang_major}" LLVM_IAS=1)
        info "当前内核由 clang ${clang_major} 构建，Brutal 模块使用 LLVM=-${clang_major} 编译"
      elif llvm_tools_ready ""; then
        BRUTAL_MAKE_ARGS=(LLVM=1 LLVM_IAS=1)
        info "当前内核由 clang ${clang_major} 构建，Brutal 模块使用默认 LLVM 工具链编译"
      else
        warn "当前内核由 clang ${clang_major} 构建，但 LLVM ${clang_major} 工具链不完整"
        return 1
      fi
    elif llvm_tools_ready ""; then
      BRUTAL_MAKE_ARGS=(LLVM=1 LLVM_IAS=1)
      info "当前内核由 clang/LLVM 构建，Brutal 模块使用 LLVM=1 编译"
    else
      warn "当前内核由 clang 构建，但 LLVM 工具链不完整"
      return 1
    fi
    return 0
  fi

  if command -v gcc &>/dev/null; then
    BRUTAL_MAKE_ARGS=(CC=gcc)
    info "Brutal 模块使用 gcc 编译"
    return 0
  fi
  if command -v clang &>/dev/null; then
    BRUTAL_MAKE_ARGS=(CC=clang)
    info "未检测到 gcc，Brutal 模块使用 clang 编译"
    return 0
  fi

  warn "未检测到可用 C 编译器"
  return 1
}

update_brutal_source() {
  local repo="${1:-$TCP_BRUTAL_REPO}"
  local src_dir="${2:-$TCP_BRUTAL_SRC_DIR}"
  if [[ -d "${src_dir}/.git" ]]; then
    info "更新 Brutal 源码: ${src_dir}"
    git -C "${src_dir}" pull --ff-only
    return $?
  fi

  info "拉取 Brutal 源码: ${repo}"
  mkdir -p "$(dirname "${src_dir}")"
  git clone --depth 1 "${repo}" "${src_dir}"
}

find_brutal_module() {
  local src_dir="${1:-}"
  local module
  if [[ -n "$src_dir" ]]; then
    module="$(find "$src_dir" -type f \( -name '*brutal*.ko*' -o -name 'mundo*.ko*' -o -name '*.ko' \) 2>/dev/null | head -n 1)"
    [[ -n "$module" ]] && { printf '%s\n' "$module"; return 0; }
  fi
  find "/lib/modules/$(uname -r)" -type f \( -name '*brutal*.ko*' -o -name 'mundo*.ko*' \) 2>/dev/null | head -n 1
}

install_brutal_module_from_source() {
  local src_dir="${1:-$TCP_BRUTAL_SRC_DIR}"
  local label="${2:-Brutal}"
  local module module_name target_dir

  select_brutal_make_args || return 1
  make -C "${src_dir}" clean >/dev/null 2>&1 || true
  make -C "${src_dir}" "${BRUTAL_MAKE_ARGS[@]}" || return 1

  chmod +x "${src_dir}/install.sh" "${src_dir}"/*.sh 2>/dev/null || true
  make -C "${src_dir}" "${BRUTAL_MAKE_ARGS[@]}" install || {
    module="$(find "${src_dir}" -type f -name '*.ko' 2>/dev/null | head -n 1)"
    [[ -n "$module" ]] || return 1
    target_dir="/lib/modules/$(uname -r)/extra"
    mkdir -p "$target_dir"
    install -m644 "$module" "$target_dir/$(basename "$module")"
  }

  depmod -a 2>/dev/null || true
  module="$(find_brutal_module "$src_dir")"
  if [[ -z "$module" ]]; then
    warn "未找到已安装的 ${label} kernel module"
    return 1
  fi
  module_name="$(basename "$module")"
  module_name="${module_name%%.ko*}"

  mkdir -p /etc/modules-load.d
  echo "$module_name" > "/etc/modules-load.d/${module_name}.conf"
  touch /etc/modules
  grep -qxF "$module_name" /etc/modules || echo "$module_name" >> /etc/modules
  if command -v rc-update &>/dev/null && [[ -x /etc/init.d/modules ]]; then
    rc-update add modules boot >/dev/null 2>&1 || true
  fi

  if command -v modprobe &>/dev/null && modprobe "$module_name" 2>/dev/null && brutal_module_loaded; then
    info "${label} kernel module 已加载: ${module_name}"
    return 0
  fi
  if command -v insmod &>/dev/null && insmod "$module" 2>/dev/null && brutal_module_loaded; then
    info "${label} kernel module 已加载: ${module}"
    return 0
  fi
  if brutal_module_loaded; then
    info "${label} kernel module 已加载"
    return 0
  fi

  warn "${label} kernel module 已安装但未能立即加载"
  return 1
}

run_brutal_source_setup() {
  local repo="${1:-$TCP_BRUTAL_REPO}"
  local src_dir="${2:-$TCP_BRUTAL_SRC_DIR}"
  local label="${3:-Brutal}"

  install_brutal_build_deps || {
    warn "${label} 构建依赖安装失败，跳过"
    return 1
  }
  ensure_brutal_kernel_headers || return 1
  update_brutal_source "$repo" "$src_dir" || {
    warn "${label} 源码拉取/更新失败，跳过"
    return 1
  }
  install_brutal_module_from_source "$src_dir" "$label"
}

run_tcp_brutal_setup_if_requested() {
  if is_freebsd; then
    info "FreeBSD 不使用 Linux Brutal 内核模块"
    return 0
  fi
  local kind
  kind="$(choose_brutal_setup)"
  if [[ -z "$kind" ]]; then
    if [[ "${PROXY_NODE_BRUTAL:-${PROXY_NODE_TCP_BRUTAL:-}}" == "" && ! -t 0 ]]; then
      info "非交互安装未启用 Brutal；如需启用可设置 PROXY_NODE_BRUTAL=1(Mundo X) 或 2(TCP)"
    fi
    return 0
  fi

  if [[ "$kind" == "mundo" ]]; then
    run_brutal_source_setup "$MUNDO_BRUTAL_REPO" "$MUNDO_BRUTAL_SRC_DIR" "Mundo X Brutal" || {
      warn "Mundo X Brutal 源码构建/加载失败"
      set_config_brutal_disabled
      return 0
    }
    set_config_brutal_mbps
    return 0
  fi

  run_brutal_source_setup "$TCP_BRUTAL_REPO" "$TCP_BRUTAL_SRC_DIR" "TCP Brutal" || {
    warn "TCP Brutal 源码构建/加载失败"
    set_config_brutal_disabled
    return 0
  }
  set_config_brutal_mbps
}

##############################################################################
# 检查
##############################################################################
[[ $EUID -eq 0 ]] || error "请用 root 运行: sudo bash $0"

# 脚本所在目录（即 binary 所在目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_BINARY="${SCRIPT_DIR}/${BINARY}"

[[ -f "$SRC_BINARY" ]] || error "找不到可执行文件: ${SRC_BINARY}\n请把 ${BINARY} 和本脚本放在同一目录"

BINARY_PATH="${INSTALL_DIR}/${BINARY}"
CONFIG_FILE="${INSTALL_DIR}/config.json"
NODE_DEFAULTS_FILE="${INSTALL_DIR}/node_config.defaults.json"
UPDATE_MODE=0
WAS_RUNNING=0
CONFIG_WAS_MISSING=0

if [[ ! -f "$CONFIG_FILE" ]]; then
  CONFIG_WAS_MISSING=1
fi

if service_installed; then
  UPDATE_MODE=1
  if service_running; then
    WAS_RUNNING=1
  fi
  info "检测到已安装，执行更新（保留现有配置）"
  stop_service
fi

##############################################################################
# 1. 安装目录 & binary
##############################################################################
mkdir -p "$INSTALL_DIR"
install -m755 "$SRC_BINARY" "${INSTALL_DIR}/${BINARY}"
info "安装 binary → ${INSTALL_DIR}/${BINARY}"

##############################################################################
# 2. GeoIP MMDB（可选）
##############################################################################
info "GeoIP 国家库已切换为 MMDB Country 格式，不再自动下载 geoip.dat/geosite.dat。"
info "如需使用 GeoLite2-Country:cn 这类路由规则，请从 MaxMind 免费下载 GeoLite2-Country.mmdb。"
info "下载后可放到 ${INSTALL_DIR}/GeoLite2-Country.mmdb；旧 geoip:cn 规则会读取 ${INSTALL_DIR}/geoip.mmdb。"

##############################################################################
# 3. Reality 本地补全 JSON（仅保留必须且面板不会下发的字段）
##############################################################################
if [[ ! -f "$NODE_DEFAULTS_FILE" ]]; then
  if [[ -f "${SCRIPT_DIR}/node_config.defaults.json.example" ]]; then
    cp "${SCRIPT_DIR}/node_config.defaults.json.example" "$NODE_DEFAULTS_FILE"
    info "复制节点默认补全配置 → ${NODE_DEFAULTS_FILE}"
  else
    cat > "$NODE_DEFAULTS_FILE" <<'EOF'
{
  "tls_settings": {
    "short_id": "",
    "private_key": ""
  }
}
EOF
    info "生成节点默认补全配置 → ${NODE_DEFAULTS_FILE}"
  fi
else
  info "节点默认补全配置已存在，跳过"
fi

##############################################################################
# 4. 默认配置（已存在则跳过）
##############################################################################
if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<EOF
{
  "log_level": "info",
  "panel": {
    "api_host": "https://YOUR_PANEL",
    "api_key": "YOUR_TOKEN",
    "node_id": 1,
    "node_type": "mx",
    "pull_interval": 60,
    "push_interval": 120,
    "node_config_defaults_path": "${INSTALL_DIR}/node_config.defaults.json"
  },
  "panels": [],
  "mundoproxy": {
    "asset_path": "${INSTALL_DIR}",
    "log_level": "warning",
    "listen_ip": "0.0.0.0",
    "brutalMbps": 0,
    "report_min_traffic_kb": 10
  },
  "cert": {
    "mode": "self",
    "cert_file": "${INSTALL_DIR}/cert.pem",
    "key_file": "${INSTALL_DIR}/key.pem",
    "domain": "example.com"
  }
}
EOF
  warn "已生成默认配置 ${CONFIG_FILE}，请编辑后再启动"
  info "提示: panel.node_type 支持 mx；若使用 v2node，也支持面板下发 protocol=mx"
else
  info "配置文件已存在，跳过"
fi

if [[ "$CONFIG_WAS_MISSING" -eq 1 ]]; then
  run_tcp_brutal_setup_if_requested
  run_warp_setup_if_requested
fi

##############################################################################
# 5. 保活（FreeBSD rc.d → systemd → OpenRC → supervisord → watchdog）
##############################################################################
if is_freebsd; then
  install_freebsd_service

elif ! is_alpine && command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
  # ── systemd ─────────────────────────────────────────────────────────────
  install_systemd_service

elif command -v rc-update &>/dev/null && [[ -x /sbin/openrc-run || -x /usr/bin/openrc-run ]]; then
  # ── OpenRC / Alpine ──────────────────────────────────────────────────────
  install_openrc_service

elif command -v supervisorctl &>/dev/null; then
  # ── supervisord ──────────────────────────────────────────────────────────
  CONF_DIR="/etc/supervisor/conf.d"
  [[ -d "$CONF_DIR" ]] || CONF_DIR="/etc/supervisord.d"
  mkdir -p "$CONF_DIR"
  cat > "${CONF_DIR}/${SERVICE_NAME}.conf" <<EOF
[program:${SERVICE_NAME}]
command=${BINARY_PATH} -c ${CONFIG_FILE}
directory=${INSTALL_DIR}
autostart=true
autorestart=true
startsecs=3
startretries=999
redirect_stderr=true
stdout_logfile=/var/log/${SERVICE_NAME}.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
EOF
  supervisorctl reread && supervisorctl update || true
  info "supervisord 配置已安装"

else
  # ── 兜底：watchdog 死循环 + crontab @reboot ──────────────────────────────
  WATCHDOG="${INSTALL_DIR}/watchdog.sh"
  cat > "$WATCHDOG" <<'WDEOF'
#!/usr/bin/env bash
LOG="/var/log/proxy-node.log"
BINARY_PATH_PLACEHOLDER
CONFIG_FILE_PLACEHOLDER
while true; do
  echo "$(date '+%F %T') [watchdog] 启动" >> "$LOG"
  "$BINARY_PATH_PLACEHOLDER_VAL" -c "$CONFIG_FILE_PLACEHOLDER_VAL" >> "$LOG" 2>&1
  echo "$(date '+%F %T') [watchdog] 退出(code=$?)，3秒后重启" >> "$LOG"
  sleep 3
done
WDEOF
  # 替换占位符
  sed -i "s|BINARY_PATH_PLACEHOLDER_VAL|${BINARY_PATH}|g; s|CONFIG_FILE_PLACEHOLDER_VAL|${CONFIG_FILE}|g" "$WATCHDOG"
  sed -i '/^BINARY_PATH_PLACEHOLDER$/d; /^CONFIG_FILE_PLACEHOLDER$/d' "$WATCHDOG"
  chmod +x "$WATCHDOG"
  ( crontab -l 2>/dev/null | grep -v "$WATCHDOG"; echo "@reboot $WATCHDOG &" ) | crontab -
  warn "未检测到 init 系统，已通过 crontab @reboot 安装 watchdog"
  warn "立即启动: nohup ${WATCHDOG} &"
fi

if [[ "$UPDATE_MODE" -eq 1 ]]; then
  if [[ "$WAS_RUNNING" -eq 1 ]]; then
    start_service
    info "更新前服务正在运行，已重新启动"
  else
    stop_service
    info "更新前服务未运行，保持停止状态"
  fi
fi

echo ""
if [[ "$UPDATE_MODE" -eq 1 ]]; then
  info "更新完成！目录: ${INSTALL_DIR}"
else
  info "安装完成！目录: ${INSTALL_DIR}"
fi
info "节点默认补全配置: ${NODE_DEFAULTS_FILE}"
