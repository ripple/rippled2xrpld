#!/usr/bin/env bash
# =============================================================================
# migrate_to_xrpld.sh
# Migrates rippled → xrpld across Ubuntu/Debian, CentOS/RHEL, macOS, and
# Docker (docker run / docker-compose / Kubernetes).
#
# What this script does:
#   1.  Detects OS and package manager
#   2.  Detects if rippled is running inside Docker / docker-compose / k8s
#   3.  Detects how rippled was installed (RPM / Debian / binary)
#   4.  Finds the active config file (left IN PLACE — never moved)
#   5.  Detects the startup method (systemd / sysvinit / launchd / manual)
#   6.  Detects cron jobs, monitoring configs, logrotate, and scans /etc /usr /opt
#   7.  Stops and REMOVES the rippled service — config directory is untouched
#   8.  Installs the new xrpld package / updates Docker image
#   9.  Validates all filesystem paths declared in the config file
#   10. Updates cron jobs, monitoring configs, logrotate, and scanned files
#   11. Starts xrpld and verifies it is running
#   12. Prints a full change log of everything that was modified
#
# Usage:
#   sudo bash migrate_to_xrpld.sh [OPTIONS]
#
# Options:
#   --auto          Unattended mode: applies only the changes required for
#                   xrpld to run correctly (no interactive prompts).
#                   Optional/risky actions (directory rename, symlinks) are
#                   skipped.  Everything changed is printed at the end.
#
#   --yes           Fully non-interactive: accepts all prompts with their
#                   defaults (includes optional changes).
#
#   --config-dir    Override the config file search directory.
#   --scan-dir DIR  Add an extra directory to the filesystem rippled scan
#                   (repeatable).
#
# Exit codes:
#   0   Success
#   1   Unsupported environment / fatal error
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── CLI flags ─────────────────────────────────────────────────────────────────
NON_INTERACTIVE=false
AUTO_MODE=false           # --auto: required changes only, no prompts
OVERRIDE_CONFIG_DIR=""
declare -a EXTRA_SCAN_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)            AUTO_MODE=true; NON_INTERACTIVE=true ;;
    --yes)             NON_INTERACTIVE=true ;;
    --config-dir)      OVERRIDE_CONFIG_DIR="${2:-}"; shift ;;
    --config-dir=*)    OVERRIDE_CONFIG_DIR="${1#*=}" ;;
    --scan-dir)        EXTRA_SCAN_DIRS+=("${2:-}"); shift ;;
    --scan-dir=*)      EXTRA_SCAN_DIRS+=("${1#*=}") ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,2\}//' | head -40
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# ── Change log (populated throughout the script; printed at the end) ──────────
declare -a CHANGE_LOG=()

# record_change CATEGORY "description"
record_change() {
  local category="$1"; shift
  CHANGE_LOG+=("$(printf '  [%-18s] %s' "$category" "$*")")
}

# ── Decision helpers ──────────────────────────────────────────────────────────
# ask_yes_no "question" [default:yes|no]
#   In --yes mode  : return the default.
#   In --auto mode : NON_INTERACTIVE is also true, so same as --yes.
ask_yes_no() {
  local question="$1"
  local default="${2:-yes}"
  if $NON_INTERACTIVE; then
    [[ "$default" == "yes" ]] && return 0 || return 1
  fi
  local prompt
  [[ "$default" == "yes" ]] && prompt="[Y/n]" || prompt="[y/N]"
  read -r -p "$(echo -e "${YELLOW}?${RESET} ${question} ${prompt} ")" answer
  answer="${answer:-$default}"
  [[ "${answer,,}" =~ ^y ]]
}

# ask_optional "question" [default]
#   --auto mode : always returns NO (skips optional / risky actions).
#   --yes mode  : returns the default.
#   interactive : asks the user.
ask_optional() {
  local question="$1"
  local default="${2:-yes}"
  if $AUTO_MODE; then
    return 1   # skip optional steps in auto mode
  fi
  ask_yes_no "$question" "$default"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — OS detection
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting operating system"

OS_TYPE=""        # linux | macos
OS_DISTRO=""      # ubuntu | debian | centos | rhel | fedora | amzn | macos
OS_VERSION=""
PKG_MANAGER=""    # apt | yum | dnf | brew | none

detect_os() {
  local uname_out
  uname_out="$(uname -s)"

  case "$uname_out" in
    Linux)
      OS_TYPE="linux"
      if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_DISTRO="${ID,,}"
        OS_VERSION="${VERSION_ID:-unknown}"
      elif [[ -f /etc/centos-release ]]; then
        OS_DISTRO="centos"
      elif [[ -f /etc/redhat-release ]]; then
        OS_DISTRO="rhel"
      else
        die "Cannot determine Linux distribution."
      fi

      case "$OS_DISTRO" in
        ubuntu|debian|linuxmint|pop)
          PKG_MANAGER="apt" ;;
        centos|rhel|rocky|almalinux|ol)
          # prefer dnf if available
          command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum" ;;
        fedora)
          PKG_MANAGER="dnf" ;;
        amzn)
          PKG_MANAGER="yum" ;;
        *)
          warn "Unknown distro '${OS_DISTRO}'; will attempt generic detection."
          PKG_MANAGER="none" ;;
      esac
      ;;
    Darwin)
      OS_TYPE="macos"
      OS_DISTRO="macos"
      OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
      command -v brew &>/dev/null && PKG_MANAGER="brew" || PKG_MANAGER="none"
      ;;
    *)
      die "Unsupported OS: ${uname_out}. Use migrate_to_xrpld.ps1 for Windows."
      ;;
  esac

  info "OS       : ${OS_DISTRO} ${OS_VERSION} (${OS_TYPE})"
  info "Pkg mgr  : ${PKG_MANAGER}"
}

detect_os

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Detect Docker / docker-compose / Kubernetes
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting Docker / container runtime"

DOCKER_MODE=""           # docker | docker-compose | kubernetes | ""
DOCKER_CONTAINER_ID=""
DOCKER_CONTAINER_NAME=""
DOCKER_IMAGE=""          # e.g. xrpllabsofficial/xrpld:latest (old rippled image)
DOCKER_CONFIG_VOLUME=""  # host path bound to /etc/rippled inside container
DOCKER_COMPOSE_FILE=""   # path to docker-compose.yml
DOCKER_COMPOSE_SERVICE=""
KUBE_DEPLOYMENT=""
KUBE_NAMESPACE=""
KUBE_CONTAINER=""

# New xrpld image — update once Ripple publishes the official image
XRPLD_DOCKER_IMAGE="${XRPLD_DOCKER_IMAGE:-xrpllabsofficial/xrpld:latest}"

detect_docker() {
  # ── Kubernetes ────────────────────────────────────────────────────────────
  if command -v kubectl &>/dev/null; then
    # Look in all namespaces for pods running a rippled image
    local kubectl_out
    kubectl_out="$(kubectl get pods --all-namespaces \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\t"}{end}{"\n"}{end}' \
      2>/dev/null | grep -i 'rippled' | head -1 || true)"

    if [[ -n "$kubectl_out" ]]; then
      DOCKER_MODE="kubernetes"
      KUBE_NAMESPACE="$(echo "$kubectl_out" | cut -f1)"
      local pod_name
      pod_name="$(echo "$kubectl_out" | cut -f2)"
      DOCKER_IMAGE="$(echo "$kubectl_out" | cut -f3)"
      # Find the owning Deployment / StatefulSet
      KUBE_DEPLOYMENT="$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" \
        -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "$pod_name")"
      KUBE_CONTAINER="$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" \
        -o jsonpath='{.spec.containers[?(@.image=~".*rippled.*")].name}' 2>/dev/null || echo "rippled")"
      info "Kubernetes pod     : ${pod_name} (namespace: ${KUBE_NAMESPACE})"
      info "Deployment/owner   : ${KUBE_DEPLOYMENT}"
      info "Image              : ${DOCKER_IMAGE}"

      # Try to find the mounted config path on the host (best-effort via PVC or hostPath)
      local vol_mount
      vol_mount="$(kubectl get pod "$pod_name" -n "$KUBE_NAMESPACE" \
        -o jsonpath='{.spec.volumes[*].hostPath.path}' 2>/dev/null | tr ' ' '\n' \
        | grep -i 'rippled\|xrpld\|config' | head -1 || true)"
      [[ -n "$vol_mount" ]] && DOCKER_CONFIG_VOLUME="$vol_mount" && \
        info "Config hostPath    : ${DOCKER_CONFIG_VOLUME}"
      return
    fi
  fi

  # ── docker-compose ────────────────────────────────────────────────────────
  if command -v docker &>/dev/null 2>&1; then
    # Search for compose files in common locations
    local compose_candidates=(
      "docker-compose.yml"
      "docker-compose.yaml"
      "/opt/ripple/docker-compose.yml"
      "/opt/xrpld/docker-compose.yml"
      "${HOME}/docker-compose.yml"
    )
    for f in "${compose_candidates[@]}"; do
      if [[ -f "$f" ]] && grep -qi 'rippled' "$f" 2>/dev/null; then
        DOCKER_COMPOSE_FILE="$f"
        break
      fi
    done

    # Also try to find compose project from running container labels
    if [[ -z "$DOCKER_COMPOSE_FILE" ]]; then
      local compose_from_label
      compose_from_label="$(docker inspect \
        $(docker ps -q --filter "ancestor=*rippled*" 2>/dev/null || \
          docker ps -q 2>/dev/null) \
        --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
        2>/dev/null | grep -v '^$' | head -1 || true)"
      [[ -n "$compose_from_label" ]] && DOCKER_COMPOSE_FILE="$compose_from_label"
    fi

    if [[ -n "$DOCKER_COMPOSE_FILE" ]]; then
      DOCKER_MODE="docker-compose"
      # Extract service name that runs rippled
      DOCKER_COMPOSE_SERVICE="$(grep -B5 'rippled' "$DOCKER_COMPOSE_FILE" 2>/dev/null \
        | grep -E '^  [a-zA-Z]' | tail -1 | tr -d ' :' || echo "rippled")"
      DOCKER_IMAGE="$(grep -A20 "${DOCKER_COMPOSE_SERVICE}:" "$DOCKER_COMPOSE_FILE" \
        | grep 'image:' | head -1 | awk '{print $2}' || echo "")"
      info "docker-compose file: ${DOCKER_COMPOSE_FILE}"
      info "Service            : ${DOCKER_COMPOSE_SERVICE}"
      info "Image              : ${DOCKER_IMAGE}"

      # Find config volume mount
      DOCKER_CONFIG_VOLUME="$(grep -A30 "${DOCKER_COMPOSE_SERVICE}:" "$DOCKER_COMPOSE_FILE" \
        | grep -A10 'volumes:' | grep -E '.*:/etc/rippled' \
        | head -1 | sed 's|:.*||' | tr -d ' -' || true)"
      [[ -n "$DOCKER_CONFIG_VOLUME" ]] && \
        info "Config volume host : ${DOCKER_CONFIG_VOLUME}"
      return
    fi

    # ── Plain docker run ──────────────────────────────────────────────────────
    local running_container
    running_container="$(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' 2>/dev/null \
      | grep -i 'rippled' | head -1 || true)"

    if [[ -n "$running_container" ]]; then
      DOCKER_MODE="docker"
      DOCKER_CONTAINER_ID="$(echo "$running_container" | cut -f1)"
      DOCKER_IMAGE="$(echo "$running_container" | cut -f2)"
      DOCKER_CONTAINER_NAME="$(echo "$running_container" | cut -f3)"
      info "Docker container   : ${DOCKER_CONTAINER_NAME} (${DOCKER_CONTAINER_ID})"
      info "Image              : ${DOCKER_IMAGE}"

      # Extract config bind-mount
      DOCKER_CONFIG_VOLUME="$(docker inspect "${DOCKER_CONTAINER_ID}" \
        --format '{{range .Mounts}}{{if eq .Destination "/etc/rippled"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || true)"
      [[ -n "$DOCKER_CONFIG_VOLUME" ]] && \
        info "Config volume host : ${DOCKER_CONFIG_VOLUME}"
      return
    fi
  fi

  info "No Docker/container rippled deployment detected."
}

detect_docker

# If we found a docker deployment, set INSTALL_METHOD early so the rest of
# the script knows to follow the container migration path.
if [[ -n "$DOCKER_MODE" ]]; then
  INSTALL_METHOD="$DOCKER_MODE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Detect rippled installation (non-Docker)
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting rippled installation"

INSTALL_METHOD=""   # rpm | deb | binary | homebrew | not_found
RIPPLED_BIN=""
RIPPLED_PKG_NAME="rippled"

detect_installation() {
  # ── RPM-based systems (CentOS, RHEL, Rocky, AlmaLinux, Fedora, Amazon Linux)
  # We use three escalating strategies so we catch the package regardless of
  # what exact name it was registered under.
  if command -v rpm &>/dev/null; then

    # Strategy 1: exact package name 'rippled'
    if rpm -q rippled &>/dev/null 2>&1; then
      INSTALL_METHOD="rpm"
      RIPPLED_PKG_NAME="rippled"
      RIPPLED_BIN="$(rpm -ql rippled 2>/dev/null | grep -E '/bin/rippled$' | head -1 || true)"
      info "Found rippled via RPM package (name: rippled)"

    # Strategy 2: broad search across all installed RPMs — catches 'ripple-rippled',
    # 'rippled-stable', etc.
    else
      local rpm_pkg_name
      rpm_pkg_name="$(rpm -qa 2>/dev/null | grep -i 'rippled' | head -1 || true)"
      if [[ -n "$rpm_pkg_name" ]]; then
        INSTALL_METHOD="rpm"
        RIPPLED_PKG_NAME="$rpm_pkg_name"
        RIPPLED_BIN="$(rpm -ql "$rpm_pkg_name" 2>/dev/null | grep -E '/bin/rippled$' | head -1 || true)"
        info "Found rippled via RPM package (name: ${rpm_pkg_name})"
      fi
    fi

    # Strategy 3: if we're on an RPM distro and the binary exists but the
    # package scan missed it, ask rpm which package owns the binary.
    if [[ -z "$INSTALL_METHOD" ]]; then
      local bin_path
      bin_path="$(command -v rippled 2>/dev/null || true)"
      # Also check common non-PATH locations
      for candidate in /usr/bin/rippled /usr/local/bin/rippled \
                       /opt/ripple/bin/rippled; do
        [[ -x "$candidate" ]] && { bin_path="$candidate"; break; }
      done

      if [[ -n "$bin_path" ]]; then
        local owner_pkg
        owner_pkg="$(rpm -qf "$bin_path" 2>/dev/null | grep -v 'not owned' | head -1 || true)"
        if [[ -n "$owner_pkg" ]]; then
          INSTALL_METHOD="rpm"
          RIPPLED_PKG_NAME="$owner_pkg"
          RIPPLED_BIN="$bin_path"
          info "Found rippled binary owned by RPM package: ${owner_pkg}"
        fi
      fi
    fi
  fi

  # ── Debian / Ubuntu (only reached if RPM check above found nothing)
  if [[ -z "$INSTALL_METHOD" ]] && command -v dpkg &>/dev/null; then
    if dpkg -s rippled &>/dev/null 2>&1; then
      INSTALL_METHOD="deb"
      RIPPLED_PKG_NAME="rippled"
      RIPPLED_BIN="$(dpkg -L rippled 2>/dev/null | grep -E '/bin/rippled$' | head -1 || true)"
      info "Found rippled via Debian package (name: rippled)"
    else
      # Try broader dpkg search in case package has a different name
      local deb_pkg_name
      deb_pkg_name="$(dpkg -l 2>/dev/null | grep -i 'rippled' | awk '{print $2}' | head -1 || true)"
      if [[ -n "$deb_pkg_name" ]]; then
        INSTALL_METHOD="deb"
        RIPPLED_PKG_NAME="$deb_pkg_name"
        RIPPLED_BIN="$(dpkg -L "$deb_pkg_name" 2>/dev/null | grep -E '/bin/rippled$' | head -1 || true)"
        info "Found rippled via Debian package (name: ${deb_pkg_name})"
      fi
    fi
  fi

  # ── Homebrew (macOS)
  if [[ -z "$INSTALL_METHOD" ]] && \
     [[ "$PKG_MANAGER" == "brew" ]] && \
     brew list --formula 2>/dev/null | grep -q '^rippled$'; then
    INSTALL_METHOD="homebrew"
    RIPPLED_PKG_NAME="rippled"
    RIPPLED_BIN="$(brew --prefix rippled 2>/dev/null)/bin/rippled"
    info "Found rippled via Homebrew"
  fi

  # ── Plain binary (last resort — no package manager owns it)
  if [[ -z "$INSTALL_METHOD" ]]; then
    local bin_candidate
    bin_candidate="$(command -v rippled 2>/dev/null || true)"
    if [[ -z "$bin_candidate" ]]; then
      for p in /usr/local/bin/rippled /opt/ripple/bin/rippled \
                /usr/bin/rippled /opt/local/bin/rippled; do
        [[ -x "$p" ]] && { bin_candidate="$p"; break; }
      done
    fi
    if [[ -n "$bin_candidate" ]]; then
      INSTALL_METHOD="binary"
      RIPPLED_BIN="$bin_candidate"
      info "Found rippled as standalone binary: ${RIPPLED_BIN}"
    fi
  fi

  if [[ -z "$INSTALL_METHOD" ]]; then
    die "rippled not found on this system. Nothing to migrate."
  fi

  # Sanity-check: if pkg reported a path that isn't executable, fall back to PATH
  if [[ -n "$RIPPLED_BIN" && ! -x "$RIPPLED_BIN" ]]; then
    warn "Package-reported path '${RIPPLED_BIN}' not executable; falling back to PATH."
    RIPPLED_BIN="$(command -v rippled 2>/dev/null || true)"
  fi
  [[ -z "$RIPPLED_BIN" ]] && RIPPLED_BIN="(not resolved)"

  # Cross-check: on RPM-based distros, warn if INSTALL_METHOD ended up as
  # 'binary' — they almost certainly installed it via yum/dnf and the package
  # name is just non-standard. Manual confirmation is safest.
  if [[ "$INSTALL_METHOD" == "binary" && \
        "$PKG_MANAGER" =~ ^(yum|dnf)$ ]]; then
    warn "On an RPM-based distro but rippled was not found in the RPM database."
    warn "If it was installed via yum/dnf under a non-standard package name, run:"
    warn "  rpm -qa | grep -i rippled"
    warn "and re-run this script with  RIPPLED_PKG_NAME=<name>"
  fi

  info "Install  : ${INSTALL_METHOD}  (pkg: ${RIPPLED_PKG_NAME})"
  info "Binary   : ${RIPPLED_BIN}"

  if [[ -x "$RIPPLED_BIN" ]]; then
    local ver
    ver="$("$RIPPLED_BIN" --version 2>/dev/null | head -1 || echo 'unknown')"
    info "Version  : ${ver}"
  fi
}

detect_installation

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Detect config file
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting config file"

CONFIG_FILE=""
CONFIG_DIR=""

detect_config() {
  local candidates=()

  if [[ -n "$OVERRIDE_CONFIG_DIR" ]]; then
    candidates=("${OVERRIDE_CONFIG_DIR}/rippled.cfg" "${OVERRIDE_CONFIG_DIR}/xrpld.cfg")
  else
    candidates=(
      "/etc/rippled/rippled.cfg"
      "/etc/rippled.cfg"
      "/opt/ripple/etc/rippled.cfg"
      "/usr/local/etc/rippled/rippled.cfg"
      "/usr/local/etc/rippled.cfg"
      # Homebrew (Apple Silicon)
      "/opt/homebrew/etc/rippled.cfg"
      # User home
      "${HOME}/.config/ripple/rippled.cfg"
      "${HOME}/rippled.cfg"
    )
  fi

  # Primary: check well-known paths
  for cfg in "${candidates[@]}"; do
    if [[ -f "$cfg" ]]; then
      CONFIG_FILE="$cfg"
      break
    fi
  done

  # Secondary: read --conf from the live process command line
  if [[ -z "$CONFIG_FILE" && "$OS_TYPE" == "linux" ]]; then
    local pid
    pid="$(pgrep -x rippled 2>/dev/null | head -1 || true)"
    if [[ -n "$pid" && -f "/proc/${pid}/cmdline" ]]; then
      local cmdline
      cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
      if [[ "$cmdline" =~ --conf[[:space:]]+([^[:space:]]+) ]]; then
        local proc_cfg="${BASH_REMATCH[1]}"
        [[ -f "$proc_cfg" ]] && CONFIG_FILE="$proc_cfg"
      fi
    fi
  fi

  if [[ -z "$CONFIG_FILE" ]]; then
    warn "No rippled.cfg found. You may need to set --config-dir."
    warn "Continuing — the config step will be skipped."
  else
    CONFIG_DIR="$(dirname "$CONFIG_FILE")"
    info "Config   : ${CONFIG_FILE}"
  fi
}

detect_config

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — Detect startup method
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting startup method"

START_METHOD=""     # systemd | sysvinit | launchd | manual
SERVICE_NAME="rippled"
LAUNCHD_PLIST=""
LAUNCHD_PLIST_PATH=""

detect_startup() {
  # systemd
  if command -v systemctl &>/dev/null 2>&1; then
    if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null 2>&1 \
       && systemctl list-unit-files "${SERVICE_NAME}.service" | grep -q rippled; then
      START_METHOD="systemd"
      info "Startup  : systemd (unit: ${SERVICE_NAME}.service)"
      local state
      state="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo inactive)"
      info "State    : ${state}"
      return
    fi
  fi

  # SysV init
  if [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
    START_METHOD="sysvinit"
    info "Startup  : SysV init (/etc/init.d/${SERVICE_NAME})"
    return
  fi

  # launchd (macOS)
  if [[ "$OS_TYPE" == "macos" ]]; then
    # Search both system and user domains
    for plist_dir in /Library/LaunchDaemons /Library/LaunchAgents \
                     "${HOME}/Library/LaunchAgents"; do
      local found
      found="$(find "$plist_dir" -name "*rippled*" 2>/dev/null | head -1 || true)"
      if [[ -n "$found" ]]; then
        START_METHOD="launchd"
        LAUNCHD_PLIST_PATH="$found"
        LAUNCHD_PLIST="$(basename "$found" .plist)"
        info "Startup  : launchd (${LAUNCHD_PLIST_PATH})"
        return
      fi
    done
  fi

  # Fallback: process is running but no service manager detected
  if pgrep -x rippled &>/dev/null 2>&1; then
    START_METHOD="manual"
    warn "Startup  : manual (rippled is running but no service manager found)"
  else
    START_METHOD="none"
    info "Startup  : not currently managed / not running"
  fi
}

detect_startup

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Detect cron jobs referencing rippled
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting cron jobs"

CRON_FILES_WITH_RIPPLED=()   # files that contain 'rippled' references

detect_cron_jobs() {
  local cron_dirs=(
    "/etc/cron.d"
    "/etc/cron.daily"
    "/etc/cron.hourly"
    "/etc/cron.weekly"
    "/etc/cron.monthly"
  )
  local cron_files=(
    "/etc/crontab"
    "/var/spool/cron/crontabs/root"
    "/var/spool/cron/root"
  )

  # Per-user crontabs
  while IFS= read -r line; do
    local uname_field
    uname_field="$(echo "$line" | cut -d: -f1)"
    cron_files+=("/var/spool/cron/crontabs/${uname_field}")
    cron_files+=("/var/spool/cron/${uname_field}")
  done < /etc/passwd

  # Collect from files
  for f in "${cron_files[@]}"; do
    if [[ -f "$f" ]] && grep -qE '\brippled\b' "$f" 2>/dev/null; then
      CRON_FILES_WITH_RIPPLED+=("$f")
      info "Cron job referencing rippled found: ${f}"
    fi
  done

  # Collect from directories
  for d in "${cron_dirs[@]}"; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        CRON_FILES_WITH_RIPPLED+=("$f")
        info "Cron file referencing rippled found: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # macOS: launchd-based periodic jobs
  if [[ "$OS_TYPE" == "macos" ]]; then
    for plist_dir in /Library/LaunchDaemons /Library/LaunchAgents \
                     "${HOME}/Library/LaunchAgents"; do
      if [[ -d "$plist_dir" ]]; then
        while IFS= read -r f; do
          CRON_FILES_WITH_RIPPLED+=("$f")
          info "LaunchD plist referencing rippled found: ${f}"
        done < <(grep -rlE '\brippled\b' "$plist_dir" 2>/dev/null || true)
      fi
    done
  fi

  if [[ ${#CRON_FILES_WITH_RIPPLED[@]} -eq 0 ]]; then
    info "No cron jobs referencing rippled found."
  fi
}

detect_cron_jobs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — Detect monitoring tools referencing rippled
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting monitoring tools"

MONITORING_FILES_WITH_RIPPLED=()   # config files that reference rippled
MONITORING_TOOLS_FOUND=()

detect_monitoring() {
  # ── monit ───────────────────────────────────────────────────────────────────
  local monit_dirs=("/etc/monit" "/etc/monit.d" "/etc/monit/conf.d"
                    "/usr/local/etc/monit" "/opt/monit/etc")
  for d in "${monit_dirs[@]}"; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("monit")
        info "monit config referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # ── supervisor ──────────────────────────────────────────────────────────────
  local supervisor_dirs=("/etc/supervisor" "/etc/supervisor/conf.d"
                          "/etc/supervisord.d" "/usr/local/etc/supervisor.d")
  for d in "${supervisor_dirs[@]}"; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("supervisor")
        info "supervisor config referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # ── nagios / icinga ─────────────────────────────────────────────────────────
  for d in /etc/nagios /etc/nagios3 /etc/icinga /etc/icinga2; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("nagios/icinga")
        info "nagios/icinga config referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # ── Prometheus / node_exporter / custom exporters ───────────────────────────
  for d in /etc/prometheus /etc/prometheus/conf.d /usr/local/etc/prometheus; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("prometheus")
        info "Prometheus config referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # ── Datadog ─────────────────────────────────────────────────────────────────
  for d in /etc/datadog-agent/conf.d /etc/dd-agent/conf.d; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("datadog")
        info "Datadog config referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  # ── systemd-watchdog / custom watchdog scripts ───────────────────────────────
  # Scan common script directories
  for d in /usr/local/bin /usr/local/sbin /opt/scripts /opt/ripple/scripts; do
    if [[ -d "$d" ]]; then
      while IFS= read -r f; do
        MONITORING_FILES_WITH_RIPPLED+=("$f")
        MONITORING_TOOLS_FOUND+=("script")
        info "Script referencing rippled: ${f}"
      done < <(grep -rlE '\brippled\b' "$d" 2>/dev/null || true)
    fi
  done

  if [[ ${#MONITORING_FILES_WITH_RIPPLED[@]} -eq 0 ]]; then
    info "No monitoring configs referencing rippled found."
  fi
}

detect_monitoring

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6b — Detect logrotate config for rippled
# ─────────────────────────────────────────────────────────────────────────────
header "Detecting logrotate config"

LOGROTATE_FILE=""           # e.g. /etc/logrotate.d/rippled
LOGROTATE_LOG_PATHS=()      # log file paths declared in the logrotate stanza

detect_logrotate() {
  # Primary: package-installed drop-in (most common)
  local candidates=(
    "/etc/logrotate.d/rippled"
    "/etc/logrotate.d/xrpld"
  )

  # Secondary: scan the entire logrotate.d directory for any file that
  # mentions rippled (catches custom names like /etc/logrotate.d/ripple)
  if [[ -d /etc/logrotate.d ]]; then
    while IFS= read -r f; do
      [[ " ${candidates[*]} " == *" $f "* ]] || candidates+=("$f")
    done < <(grep -rlE '\brippled\b' /etc/logrotate.d/ 2>/dev/null || true)
  fi

  # Also check the main logrotate.conf in case rippled was inlined there
  if grep -qE '\brippled\b' /etc/logrotate.conf 2>/dev/null; then
    candidates+=("/etc/logrotate.conf")
    warn "rippled log rotation is inlined in /etc/logrotate.conf — manual review recommended."
  fi

  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    LOGROTATE_FILE="$f"
    info "logrotate config   : ${LOGROTATE_FILE}"

    # Extract the log file paths listed at the top of the stanza (lines before
    # the opening '{' that look like absolute paths ending in .log or *)
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*/[^{] ]] && \
        LOGROTATE_LOG_PATHS+=("$(echo "$line" | tr -d ' \t')")
    done < <(sed '/^{/,$d' "$f" 2>/dev/null || true)

    for lp in "${LOGROTATE_LOG_PATHS[@]}"; do
      info "  Log path in stanza : ${lp}"
    done
    break   # only process the first match; additional files go via monitoring
  done

  if [[ -z "$LOGROTATE_FILE" ]]; then
    info "No logrotate config referencing rippled found."
  fi
}

detect_logrotate

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6c — Broad filesystem scan  (/etc, /usr, /opt and subdirectories)
#
# Scans text files in three directory groups for the string "rippled" and
# classifies every hit into one of five buckets:
#
#   NAME      — process/service/daemon name reference
#               e.g.  name: rippled   comm: rippled   ExecStart=… rippled
#               → auto-fix: rippled → xrpld  (negative lookbehind for '/')
#
#   SCRIPT_CALL — a shell/Python/Ruby script explicitly invoking rippled as a
#               command (bare word or via a variable), e.g.:
#                 rippled server_info
#                 $(rippled …)
#                 DAEMON=rippled
#                 exec rippled --conf …
#               → auto-fix: command name rippled → xrpld
#                           binary path /…/rippled → /…/xrpld
#
#   LOG_PATH  — /var/log/rippled/… in any context
#               → auto-fix: path updated to /var/log/xrpld/
#
#   CONFIG_PATH — /etc/rippled/… or /opt/ripple/etc/… (config stays in place)
#               → report only; these are intentional references to the config
#                 dir we deliberately leave untouched
#
#   UNKNOWN   — none of the above patterns matched confidently
#               → printed to console; operator decides
#
# Files already handled by earlier sections (logrotate, cron, monitoring) are
# skipped to avoid double-reporting.
#
# Scan directories:
#   /etc                    — daemon configs, service files, monitoring tools
#   /usr/local/{bin,sbin,lib,share,etc}  — custom scripts & wrappers
#   /opt                    — third-party / in-house installs
#   Extra dirs from --scan-dir flag (repeatable)
# ─────────────────────────────────────────────────────────────────────────────
header "Scanning filesystem for rippled references"

# Accumulated results (shared across all scanned dirs):
declare -A SCAN_NAME_REFS=()        # file → matched lines
declare -A SCAN_SCRIPT_REFS=()      # file → matched lines  (auto-fix bin path too)
declare -A SCAN_LOG_PATH_REFS=()    # file → matched lines
declare -A SCAN_CFG_PATH_REFS=()    # file → matched lines  (keep in place)
declare -A SCAN_UNKNOWN_REFS=()     # file → matched lines  (manual review)

# Extra directories the operator can add via --scan-dir (populated by CLI parsing)
EXTRA_SCAN_DIRS=()

# ── Shared classification function ───────────────────────────────────────────
# classify_line <filepath> <is_script:true|false> <lineno> <content>
classify_line() {
  local filepath="$1" is_script="$2" lineno="$3" content="$4"

  # ── CONFIG PATH — /etc/rippled or /opt/ripple/etc ─────────────────────────
  if echo "$content" | grep -qE '/etc/rippled|/opt/ripple/etc'; then
    SCAN_CFG_PATH_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
    return
  fi

  # ── LOG PATH — /var/log/rippled ───────────────────────────────────────────
  # If this reference is inside the rippled config file itself, leave it alone
  # (the config stays in place and the log directory is the operator's concern).
  # Only auto-fix log paths found in external files (monitoring, scripts, etc.).
  if echo "$content" | grep -qE '/var/log/rippled|/var/log/ripple/'; then
    if [[ -n "${CONFIG_FILE:-}" && "$filepath" == "$CONFIG_FILE" ]]; then
      SCAN_CFG_PATH_REFS["$filepath"]+="${lineno}: ${content} [log path in config — kept as-is]"$'\n'
    else
      SCAN_LOG_PATH_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
    fi
    return
  fi

  # ── SCRIPT CALL — invocation patterns in executable scripts ───────────────
  # Catches:
  #   rippled <args>           bare command call
  #   $(rippled …)             command substitution
  #   `rippled …`              backtick substitution
  #   exec rippled             exec call
  #   /path/to/rippled         hard-coded binary path (any location)
  #   VARNAME=…rippled         variable assignment pointing at binary
  #   VARNAME="rippled"        variable holding daemon name
  if $is_script; then
    if echo "$content" | grep -qE \
      '(^\s*(exec\s+|command\s+)?\brippled\b|\$\(.*\brippled\b|\`.*\brippled\b|[A-Z_]+=.*\brippled\b|/[a-zA-Z0-9._/-]*/rippled\b)'; then
      SCAN_SCRIPT_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
      return
    fi
  fi

  # ── NAME — monitoring/init config keyword patterns ────────────────────────
  if echo "$content" | grep -qE \
    '(^\s*(name|comm|exe|cmdline|cmdname|process|service|match|pattern|program|tag|command|pid_file|pidfile)\s*[=:]\s*["\x27]?rippled["\x27]?'\
'|ExecStart\s*=.*\brippled\b|^\s*(User|Group|RuntimeDirectory|WorkingDirectory)\s*=\s*rippled)'; then
    SCAN_NAME_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
    return
  fi

  # ── Any remaining binary path (non-script context) ───────────────────────
  if echo "$content" | grep -qE '(^|[[:space:]="\x27:])/[a-zA-Z0-9._/-]*rippled[a-zA-Z0-9._/-]*'; then
    # In a non-script file a hard-coded binary path can't auto-fix safely
    SCAN_UNKNOWN_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
    return
  fi

  # ── UNKNOWN ───────────────────────────────────────────────────────────────
  SCAN_UNKNOWN_REFS["$filepath"]+="${lineno}: ${content}"$'\n'
}

# ── is_script_file <path> → true if file looks like a shell/Python/Ruby/Perl script
is_script_file() {
  local fp="$1"
  # Executable bit is a strong hint
  [[ -x "$fp" ]] && return 0
  # Check shebang line
  local shebang
  shebang="$(head -1 "$fp" 2>/dev/null || true)"
  echo "$shebang" | grep -qE '^#!(.*/(ba)?sh|.*/(z|k|da)?sh|.*/env\s+(ba)?sh|.*/python|.*/ruby|.*/perl|.*/node)' \
    && return 0
  # Check file extension
  [[ "$fp" =~ \.(sh|bash|zsh|ksh|py|rb|pl|php|lua|tcl)$ ]] && return 0
  return 1
}

# ── Per-directory scanner ─────────────────────────────────────────────────────
# scan_directory <dir> <label> <find_args…>
scan_directory() {
  local scan_dir="$1" label="$2"; shift 2
  local find_extra_args=("$@")

  [[ -d "$scan_dir" ]] || { info "  Skipping ${label} — directory not found."; return; }

  info "Scanning ${label} (${scan_dir})..."

  # Build skip-list
  local -a already_handled=()
  [[ -n "$LOGROTATE_FILE" ]] && already_handled+=("$LOGROTATE_FILE")
  already_handled+=("${CRON_FILES_WITH_RIPPLED[@]}")
  already_handled+=("${MONITORING_FILES_WITH_RIPPLED[@]}")

  local skip_ext_re='(\.pyc|\.pyo|\.so(\.[0-9]+)*|\.a|\.o|\.rpm|\.deb|\.png|\.jpg|\.gif|\.svg|\.gz|\.bz2|\.xz|\.zip|\.tar|\.jar|\.war|\.class|\.mo|\.pot)$'

  while IFS= read -r filepath; do
    # Already handled?
    local skip=false
    for ah in "${already_handled[@]}"; do
      [[ "$filepath" == "$ah" ]] && { skip=true; break; }
    done
    $skip && continue

    # Binary extension?
    [[ "$filepath" =~ $skip_ext_re ]] && continue

    # Non-text file? (use file(1) — faster than reading content)
    file "$filepath" 2>/dev/null | grep -qiE 'text|ASCII|UTF|script|shell|python|ruby|perl' \
      || continue

    # Does it mention rippled at all?
    local matches
    matches="$(grep -nE '\brippled\b' "$filepath" 2>/dev/null || true)"
    [[ -z "$matches" ]] && continue

    local is_script=false
    is_script_file "$filepath" && is_script=true

    local has_name=false has_script=false has_log=false has_cfg=false has_unk=false

    while IFS= read -r match_line; do
      [[ -z "$match_line" ]] && continue
      local lineno="${match_line%%:*}"
      local content="${match_line#*:}"

      # Record which buckets this file lands in (for the summary tag line)
      local before_name=${#SCAN_NAME_REFS[@]}
      local before_script=${#SCAN_SCRIPT_REFS[@]}
      local before_log=${#SCAN_LOG_PATH_REFS[@]}
      local before_cfg=${#SCAN_CFG_PATH_REFS[@]}
      local before_unk=${#SCAN_UNKNOWN_REFS[@]}

      classify_line "$filepath" "$is_script" "$lineno" "$content"

      [[ ${#SCAN_NAME_REFS[@]}     -gt $before_name   ]] && has_name=true
      [[ ${#SCAN_SCRIPT_REFS[@]}   -gt $before_script ]] && has_script=true
      [[ ${#SCAN_LOG_PATH_REFS[@]} -gt $before_log    ]] && has_log=true
      [[ ${#SCAN_CFG_PATH_REFS[@]} -gt $before_cfg    ]] && has_cfg=true
      [[ ${#SCAN_UNKNOWN_REFS[@]}  -gt $before_unk    ]] && has_unk=true

    done <<< "$matches"

    # Summarise per file
    local tags=""
    $has_name   && tags+=" [NAME→fix]"
    $has_script && tags+=" [SCRIPT-CALL→fix]"
    $has_log    && tags+=" [LOG-PATH→fix]"
    $has_cfg    && tags+=" [CONFIG-PATH→keep]"
    $has_unk    && tags+=" [UNKNOWN→review]"
    info "    ${filepath}${tags}"

  done < <(find "$scan_dir" "${find_extra_args[@]}" -type f 2>/dev/null | sort)
}

# ── Run the scans ─────────────────────────────────────────────────────────────

# /etc — all files
scan_directory /etc "/etc"

# /usr — limit to subtrees that realistically contain custom scripts;
# skip /usr/share/doc, /usr/share/locale, /usr/lib/debug, and /usr/lib/X11
# to avoid noise from package documentation and compiled libraries.
scan_directory /usr "/usr (scripts & configs)" \
  \( \
    -path '/usr/local/bin'   -o \
    -path '/usr/local/sbin'  -o \
    -path '/usr/local/lib'   -o \
    -path '/usr/local/etc'   -o \
    -path '/usr/local/share' \
  \) -prune -false -o \
  \( \
    -not -path '/usr/share/doc/*' \
    -not -path '/usr/share/locale/*' \
    -not -path '/usr/share/man/*' \
    -not -path '/usr/lib/debug/*' \
    -not -path '/usr/lib/jvm/*' \
  \)

# Also scan /usr/local explicitly (separate pass for clarity)
scan_directory /usr/local "/usr/local"

# /opt — full tree (custom installs live here)
scan_directory /opt "/opt"

# Any extra dirs the operator passed via --scan-dir
for extra_dir in "${EXTRA_SCAN_DIRS[@]}"; do
  scan_directory "$extra_dir" "extra:${extra_dir}"
done

# ── Print totals ──────────────────────────────────────────────────────────────
echo ""
info "Scan complete across /etc, /usr, /opt:"
info "  Process/service name refs  : ${#SCAN_NAME_REFS[@]} file(s)  [auto-fix]"
info "  Script invocation refs     : ${#SCAN_SCRIPT_REFS[@]} file(s)  [auto-fix]"
info "  Log-path refs              : ${#SCAN_LOG_PATH_REFS[@]} file(s)  [auto-fix]"
info "  Config-path refs           : ${#SCAN_CFG_PATH_REFS[@]} file(s)  [keep in place]"
info "  Unknown refs               : ${#SCAN_UNKNOWN_REFS[@]} file(s)  [manual review]"

if [[ ${#SCAN_UNKNOWN_REFS[@]} -gt 0 ]]; then
  echo ""
  warn "The following lines need manual review (could not be auto-classified):"
  for f in "${!SCAN_UNKNOWN_REFS[@]}"; do
    warn "  File: ${f}"
    while IFS= read -r ln; do
      [[ -n "$ln" ]] && warn "    ${ln}"
    done <<< "${SCAN_UNKNOWN_REFS[$f]}"
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — Summary & confirmation
# ─────────────────────────────────────────────────────────────────────────────
header "Migration summary"

echo ""
echo -e "  ${BOLD}OS              :${RESET} ${OS_DISTRO} ${OS_VERSION}"
echo -e "  ${BOLD}Install method  :${RESET} ${INSTALL_METHOD}"
echo -e "  ${BOLD}Binary          :${RESET} ${RIPPLED_BIN}"
echo -e "  ${BOLD}Config file     :${RESET} ${CONFIG_FILE:-not found}"
echo -e "  ${BOLD}Startup method  :${RESET} ${START_METHOD}"
if [[ ${#CRON_FILES_WITH_RIPPLED[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Cron jobs       :${RESET} ${#CRON_FILES_WITH_RIPPLED[@]} file(s) to update"
fi
if [[ ${#MONITORING_FILES_WITH_RIPPLED[@]} -gt 0 ]]; then
  echo -e "  ${BOLD}Monitor configs :${RESET} ${#MONITORING_FILES_WITH_RIPPLED[@]} file(s) to update"
fi
if [[ -n "$LOGROTATE_FILE" ]]; then
  echo -e "  ${BOLD}logrotate       :${RESET} ${LOGROTATE_FILE}"
fi
local scan_auto=$(( ${#SCAN_NAME_REFS[@]} + ${#SCAN_SCRIPT_REFS[@]} + ${#SCAN_LOG_PATH_REFS[@]} ))
local scan_review=${#SCAN_UNKNOWN_REFS[@]}
echo -e "  ${BOLD}Filesystem scan  :${RESET} ${scan_auto} file(s) auto-fixable, ${scan_review} need manual review"
echo ""
echo -e "  ${BOLD}Plan:${RESET}"
echo -e "    1.  Stop rippled (${START_METHOD})"
echo -e "    2.  Uninstall old ${INSTALL_METHOD} package"
echo -e "    3.  Add xrpld repo and install xrpld"
echo -e "    4.  Keep config in place: ${CONFIG_FILE:-none found}"
echo -e "    5.  Update cron jobs  (${#CRON_FILES_WITH_RIPPLED[@]} file(s))"
echo -e "    6.  Update monitoring configs  (${#MONITORING_FILES_WITH_RIPPLED[@]} file(s))"
echo -e "    7.  Update logrotate config  (${LOGROTATE_FILE:-none})"
echo -e "    8.  Patch xrpld systemd unit with correct config path"
echo -e "    9.  Enable and start xrpld (${START_METHOD})"
echo -e "    10. Verify xrpld is running"
echo ""

ask_yes_no "Proceed with migration?" || { info "Aborted by user."; exit 0; }

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — Stop rippled
# ─────────────────────────────────────────────────────────────────────────────
header "Stopping rippled"

stop_rippled() {
  case "$START_METHOD" in
    systemd)
      info "Running: systemctl stop ${SERVICE_NAME}"
      systemctl stop "${SERVICE_NAME}" || warn "systemctl stop failed (may already be stopped)"
      systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
      record_change "SERVICE STOP" "systemctl stop + disable ${SERVICE_NAME}"
      ;;
    sysvinit)
      info "Running: service ${SERVICE_NAME} stop"
      service "${SERVICE_NAME}" stop || warn "init stop failed"
      record_change "SERVICE STOP" "service ${SERVICE_NAME} stop"
      ;;
    launchd)
      info "Running: launchctl unload ${LAUNCHD_PLIST_PATH}"
      launchctl unload "${LAUNCHD_PLIST_PATH}" 2>/dev/null || warn "launchctl unload failed"
      record_change "SERVICE STOP" "launchctl unload ${LAUNCHD_PLIST_PATH}"
      ;;
    manual|none)
      if pgrep -x rippled &>/dev/null; then
        warn "No service manager detected. Sending SIGTERM to rippled process(es)..."
        pkill -SIGTERM -x rippled || true
        local waited=0
        while pgrep -x rippled &>/dev/null && [[ $waited -lt 15 ]]; do
          sleep 1; ((waited++))
        done
        pgrep -x rippled &>/dev/null && \
          die "rippled is still running after 15 s. Stop it manually and re-run."
        record_change "SERVICE STOP" "SIGTERM sent to rippled process"
      else
        info "rippled is not running. Proceeding."
      fi
      ;;
  esac
  success "rippled stopped."
}

stop_rippled

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — Uninstall old package / binary
# ─────────────────────────────────────────────────────────────────────────────
header "Uninstalling rippled"

uninstall_rippled() {
  case "$INSTALL_METHOD" in
    rpm)
      info "Removing RPM package: ${RIPPLED_PKG_NAME}"
      # --nodeps avoids pulling down dependent packages; RPM does NOT remove
      # config files marked %config(noreplace) — they stay on disk as-is.
      rpm -e --nodeps "${RIPPLED_PKG_NAME}" || die "rpm -e failed"
      find "$(dirname "${CONFIG_FILE:-/etc/rippled/rippled.cfg}")" \
        -name '*.rpmsave' -delete 2>/dev/null || true
      record_change "UNINSTALL" "rpm -e ${RIPPLED_PKG_NAME}"
      ;;
    deb)
      info "Removing Debian package (keeping config files): ${RIPPLED_PKG_NAME}"
      DEBIAN_FRONTEND=noninteractive apt-get remove -y "${RIPPLED_PKG_NAME}" \
        || die "apt-get remove failed"
      rm -f /lib/systemd/system/rippled.service \
            /usr/lib/systemd/system/rippled.service \
            /etc/systemd/system/rippled.service 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || true
      record_change "UNINSTALL" "apt-get remove ${RIPPLED_PKG_NAME} + unit file removed"
      ;;
    homebrew)
      info "Uninstalling Homebrew formula (keeping config): ${RIPPLED_PKG_NAME}"
      brew uninstall rippled || die "brew uninstall failed"
      record_change "UNINSTALL" "brew uninstall rippled"
      ;;
    binary)
      if [[ -x "$RIPPLED_BIN" ]]; then
        info "Removing binary: ${RIPPLED_BIN}"
        rm -f "${RIPPLED_BIN}" || die "Cannot remove binary ${RIPPLED_BIN}"
        record_change "UNINSTALL" "binary removed: ${RIPPLED_BIN}"
      fi
      rm -f /etc/systemd/system/rippled.service \
            /lib/systemd/system/rippled.service 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || true
      ;;
    docker|docker-compose|kubernetes)
      info "Docker/k8s removal handled in the Docker migration section."
      ;;
  esac
  success "rippled package/binary removed. Config files untouched."
}

uninstall_rippled

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8a — Docker / container migration (runs instead of sections 8-12
#              when a container deployment was detected)
# ─────────────────────────────────────────────────────────────────────────────

migrate_docker() {
  [[ -z "$DOCKER_MODE" ]] && return   # skip if not a container deployment

  header "Docker migration (${DOCKER_MODE})"

  # Resolve config path: prefer the bind-mounted host path we found; fall back
  # to the system-level rippled.cfg if it exists.
  local cfg_host_path="${DOCKER_CONFIG_VOLUME:-${CONFIG_FILE}}"
  [[ -n "$cfg_host_path" ]] && \
    info "Config host path   : ${cfg_host_path} (left untouched)"

  case "$DOCKER_MODE" in

    # ── docker-compose ───────────────────────────────────────────────────────
    docker-compose)
      info "Stopping compose service: ${DOCKER_COMPOSE_SERVICE}"
      docker compose -f "${DOCKER_COMPOSE_FILE}" stop "${DOCKER_COMPOSE_SERVICE}" \
        2>/dev/null || \
        docker-compose -f "${DOCKER_COMPOSE_FILE}" stop "${DOCKER_COMPOSE_SERVICE}" \
        || warn "Could not stop compose service gracefully."

      # Backup the compose file
      cp -p "${DOCKER_COMPOSE_FILE}" "${DOCKER_COMPOSE_FILE}.bak-rippled"
      info "Backed up compose file to ${DOCKER_COMPOSE_FILE}.bak-rippled"

      # Replace the image reference rippled → xrpld
      sed -i "s|image:.*rippled.*|image: ${XRPLD_DOCKER_IMAGE}|g" \
        "${DOCKER_COMPOSE_FILE}"

      # Also update any container_name or service labels
      sed -i 's|\brippled\b|xrpld|g' "${DOCKER_COMPOSE_FILE}"

      # Update config volume destination path if it was /etc/rippled
      # xrpld may read from /etc/xrpld — keep the host-side path unchanged,
      # only update the container-side mount target.
      sed -i 's|:/etc/rippled|:/etc/xrpld|g' "${DOCKER_COMPOSE_FILE}"

      if command -v diff &>/dev/null; then
        diff "${DOCKER_COMPOSE_FILE}.bak-rippled" "${DOCKER_COMPOSE_FILE}" || true
      fi
      success "docker-compose.yml updated."

      # Pull new image
      info "Pulling new image: ${XRPLD_DOCKER_IMAGE}"
      docker pull "${XRPLD_DOCKER_IMAGE}" || die "docker pull failed"

      # Start new service
      info "Starting xrpld via docker-compose..."
      docker compose -f "${DOCKER_COMPOSE_FILE}" up -d "${DOCKER_COMPOSE_SERVICE}" \
        2>/dev/null || \
        docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d "${DOCKER_COMPOSE_SERVICE}" \
        || die "docker-compose up failed"

      success "xrpld container started via docker-compose."
      ;;

    # ── plain docker run ──────────────────────────────────────────────────────
    docker)
      info "Stopping container: ${DOCKER_CONTAINER_NAME}"
      docker stop "${DOCKER_CONTAINER_ID}" 2>/dev/null || true
      docker rm   "${DOCKER_CONTAINER_ID}" 2>/dev/null || true

      # Pull new image
      info "Pulling new image: ${XRPLD_DOCKER_IMAGE}"
      docker pull "${XRPLD_DOCKER_IMAGE}" || die "docker pull failed"

      # Reconstruct docker run args from the old container's inspect output
      local old_inspect
      old_inspect="$(docker inspect "${DOCKER_CONTAINER_ID}" 2>/dev/null || echo "{}")"

      # Ports
      local port_args=""
      while IFS= read -r mapping; do
        [[ -n "$mapping" ]] && port_args="$port_args -p $mapping"
      done < <(echo "$old_inspect" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)[0]
for port, binds in (data.get('NetworkSettings',{}).get('Ports',{}) or {}).items():
  if binds:
    for b in binds:
      print(f'{b.get(\"HostPort\",\"\")}:{port.split(\"/\")[0]}')
" 2>/dev/null || true)

      # Volumes — rewrite /etc/rippled → /etc/xrpld in container side
      local vol_args=""
      while IFS= read -r vol; do
        [[ -n "$vol" ]] && vol_args="$vol_args -v $vol"
      done < <(echo "$old_inspect" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)[0]
for m in data.get('Mounts',[]):
  src=m.get('Source',''); dst=m.get('Destination','')
  dst=dst.replace('/etc/rippled','/etc/xrpld')
  if src and dst: print(f'{src}:{dst}')
" 2>/dev/null || true)

      # Network
      local net_args=""
      local net_name
      net_name="$(echo "$old_inspect" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)[0]
nets=list(data.get('NetworkSettings',{}).get('Networks',{}).keys())
print(nets[0] if nets else '')
" 2>/dev/null || true)"
      [[ -n "$net_name" && "$net_name" != "bridge" ]] && \
        net_args="--network ${net_name}"

      # Env vars
      local env_args=""
      while IFS= read -r ev; do
        [[ -n "$ev" ]] && env_args="$env_args -e $ev"
      done < <(echo "$old_inspect" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)[0]
for e in (data.get('Config',{}).get('Env') or []):
  print(e)
" 2>/dev/null || true)

      local restart_policy
      restart_policy="$(echo "$old_inspect" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)[0]
p=data.get('HostConfig',{}).get('RestartPolicy',{})
name=p.get('Name','no')
mc=p.get('MaximumRetryCount',0)
print(name if name!='on-failure' else f'on-failure:{mc}')
" 2>/dev/null || echo "unless-stopped")"

      info "Launching new xrpld container..."
      # shellcheck disable=SC2086
      docker run -d \
        --name xrpld \
        --restart "${restart_policy}" \
        ${port_args} \
        ${vol_args} \
        ${net_args} \
        ${env_args} \
        "${XRPLD_DOCKER_IMAGE}" \
        || die "docker run xrpld failed"

      success "xrpld container started (name: xrpld)."
      ;;

    # ── Kubernetes ───────────────────────────────────────────────────────────
    kubernetes)
      info "Patching Kubernetes deployment: ${KUBE_DEPLOYMENT} (ns: ${KUBE_NAMESPACE})"

      # Try Deployment first, then StatefulSet
      for kind in deployment statefulset; do
        if kubectl get "${kind}" "${KUBE_DEPLOYMENT}" \
             -n "${KUBE_NAMESPACE}" &>/dev/null 2>&1; then
          info "Updating ${kind}/${KUBE_DEPLOYMENT} image → ${XRPLD_DOCKER_IMAGE}"
          kubectl set image "${kind}/${KUBE_DEPLOYMENT}" \
            "${KUBE_CONTAINER}=${XRPLD_DOCKER_IMAGE}" \
            -n "${KUBE_NAMESPACE}" \
            || die "kubectl set image failed"

          # Also patch the container name label if it says 'rippled'
          kubectl patch "${kind}" "${KUBE_DEPLOYMENT}" \
            -n "${KUBE_NAMESPACE}" \
            --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/name\",\"value\":\"xrpld\"}]" \
            2>/dev/null || true

          info "Waiting for rollout..."
          kubectl rollout status "${kind}/${KUBE_DEPLOYMENT}" \
            -n "${KUBE_NAMESPACE}" --timeout=120s \
            || warn "Rollout did not complete within 120 s — check manually."

          success "Kubernetes ${kind}/${KUBE_DEPLOYMENT} updated to xrpld."
          break
        fi
      done

      info ""
      info "Note: The config ConfigMap / PVC / hostPath was left untouched."
      info "If your config is in a ConfigMap named 'rippled-config', consider"
      info "renaming it: kubectl get cm rippled-config -n ${KUBE_NAMESPACE} -o yaml"
      info "            | sed 's/rippled-config/xrpld-config/g' | kubectl apply -f -"
      ;;
  esac

  # Verify container is running
  header "Verifying xrpld container"
  local waited=0
  while [[ $waited -lt 30 ]]; do
    local running=""
    case "$DOCKER_MODE" in
      docker|docker-compose)
        running="$(docker ps --filter 'name=xrpld' --format '{{.Names}}' 2>/dev/null || true)"
        ;;
      kubernetes)
        running="$(kubectl get pods -n "${KUBE_NAMESPACE}" \
          -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' \
          2>/dev/null | tr ' ' '\n' | grep xrpld | head -1 || true)"
        ;;
    esac
    if [[ -n "$running" ]]; then
      success "xrpld container/pod is running: ${running}"
      break
    fi
    sleep 3; ((waited+=3))
  done
  [[ $waited -ge 30 ]] && warn "xrpld container not detected after 30 s — check logs manually."

  header "Docker migration complete"
  echo ""
  echo -e "  ${GREEN}${BOLD}rippled → xrpld container migration successful!${RESET}"
  echo ""
  case "$DOCKER_MODE" in
    docker)
      echo -e "    docker logs -f xrpld"
      echo -e "    docker exec -it xrpld xrpld server_info"
      ;;
    docker-compose)
      echo -e "    docker compose -f ${DOCKER_COMPOSE_FILE} logs -f xrpld"
      ;;
    kubernetes)
      local xrpld_pod
      xrpld_pod="$(kubectl get pods -n "${KUBE_NAMESPACE}" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
        | grep xrpld | head -1 || echo '<xrpld-pod>')"
      echo -e "    kubectl logs -f ${xrpld_pod} -n ${KUBE_NAMESPACE}"
      echo -e "    kubectl exec -it ${xrpld_pod} -n ${KUBE_NAMESPACE} -- xrpld server_info"
      ;;
  esac
  echo ""
  exit 0   # Docker path is complete; skip the rest of the script
}

migrate_docker

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8b — Install xrpld (non-Docker path)
# ─────────────────────────────────────────────────────────────────────────────
header "Installing xrpld"

# ── Repo configuration ────────────────────────────────────────────────────────
# Adjust these URLs when Ripple publishes the official xrpld repository.
XRPLD_RPM_REPO_URL="${XRPLD_RPM_REPO_URL:-https://repos.ripple.com/repos/xrpld-rpm/stable/}"
XRPLD_DEB_REPO_URL="${XRPLD_DEB_REPO_URL:-https://repos.ripple.com/repos/xrpld-deb}"
XRPLD_DEB_REPO_KEY="${XRPLD_DEB_REPO_KEY:-https://repos.ripple.com/repos/xrpld-deb/ripple-release.gpg}"
XRPLD_BREW_TAP="${XRPLD_BREW_TAP:-ripple/tap}"

install_xrpld() {
  case "$PKG_MANAGER" in

    # ── APT (Ubuntu / Debian) ─────────────────────────────────────────────────
    apt)
      info "Configuring Ripple APT repository for xrpld..."
      apt-get install -y curl gnupg2 lsb-release ca-certificates \
        || die "Failed to install prerequisites"

      local codename
      codename="$(lsb_release -sc 2>/dev/null || echo 'focal')"

      # Import signing key
      curl -fsSL "${XRPLD_DEB_REPO_KEY}" \
        | gpg --dearmor -o /usr/share/keyrings/xrpld-archive-keyring.gpg \
        || die "Failed to import xrpld GPG key"

      # Add repo
      echo "deb [signed-by=/usr/share/keyrings/xrpld-archive-keyring.gpg] \
${XRPLD_DEB_REPO_URL} ${codename} stable" \
        > /etc/apt/sources.list.d/xrpld.list

      apt-get update -qq || die "apt-get update failed"
      DEBIAN_FRONTEND=noninteractive apt-get install -y xrpld \
        || die "apt-get install xrpld failed"
      ;;

    # ── YUM (CentOS / RHEL / Amazon Linux) ───────────────────────────────────
    yum)
      info "Configuring Ripple YUM repository for xrpld..."
      cat > /etc/yum.repos.d/xrpld.repo <<EOF
[xrpld-stable]
name=xrpld Stable
baseurl=${XRPLD_RPM_REPO_URL}
enabled=1
gpgcheck=1
gpgkey=${XRPLD_RPM_REPO_URL}/repodata/repomd.xml.key
EOF
      yum install -y xrpld || die "yum install xrpld failed"
      ;;

    # ── DNF (Fedora / CentOS 8+ / RHEL 8+) ───────────────────────────────────
    dnf)
      info "Configuring Ripple DNF repository for xrpld..."
      cat > /etc/yum.repos.d/xrpld.repo <<EOF
[xrpld-stable]
name=xrpld Stable
baseurl=${XRPLD_RPM_REPO_URL}
enabled=1
gpgcheck=1
gpgkey=${XRPLD_RPM_REPO_URL}/repodata/repomd.xml.key
EOF
      dnf install -y xrpld || die "dnf install xrpld failed"
      ;;

    # ── Homebrew (macOS) ──────────────────────────────────────────────────────
    brew)
      info "Tapping ${XRPLD_BREW_TAP} and installing xrpld..."
      brew tap "${XRPLD_BREW_TAP}" || warn "brew tap may already exist"
      brew install xrpld || die "brew install xrpld failed"
      ;;

    # ── No package manager: attempt binary download ───────────────────────────
    none)
      warn "No supported package manager detected."
      echo ""
      echo -e "  ${YELLOW}Manual installation required:${RESET}"
      echo -e "  Download the xrpld binary for your platform from:"
      echo -e "  ${CYAN}https://github.com/XRPLF/rippled/releases${RESET}"
      echo -e "  and place it at the same path as the old binary."
      echo ""
      ask_yes_no "Have you placed the xrpld binary in PATH already?" no \
        || die "xrpld binary not available. Aborting."
      ;;
  esac

  # Verify
  local xrpld_bin
  xrpld_bin="$(command -v xrpld 2>/dev/null || true)"
  [[ -z "$xrpld_bin" ]] && die "xrpld binary not found in PATH after install."
  local xver
  xver="$("$xrpld_bin" --version 2>/dev/null | head -1 || echo 'unknown')"
  success "xrpld installed: ${xrpld_bin}  (${xver})"
  record_change "INSTALL" "xrpld installed via ${PKG_MANAGER}: ${xrpld_bin} ${xver}"
}

install_xrpld

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Config file handling
#
# The config file stays exactly where it is. We do NOT move, copy, or rename
# it. The xrpld systemd unit (and any other startup method) will be patched
# in the next section to point at its current path.
# ─────────────────────────────────────────────────────────────────────────────
header "Config file — keeping in place"

XRPLD_CONFIG_FILE=""

handle_config() {
  if [[ -z "$CONFIG_FILE" ]]; then
    warn "No rippled config file was found."
    warn "xrpld will start with compiled defaults — create a config manually if needed."
    return
  fi

  XRPLD_CONFIG_FILE="$CONFIG_FILE"
  success "Config stays at existing path: ${XRPLD_CONFIG_FILE}"
  info "(No files will be moved or renamed.)"
}

handle_config

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9b — Validate and sync config paths ↔ filesystem
#
# rippled.cfg declares filesystem paths in several forms:
#
#   [database_path]           ← bare path as section body
#   /var/lib/rippled/db
#
#   [debug_logfile]           ← bare path as section body
#   /var/log/rippled/debug.log
#
#   [node_db]                 ← path= key inside a sub-section
#   type=NuDB
#   path=/var/lib/rippled/db/nudb
#
#   [shard_db]
#   path=/var/lib/rippled/shards
#
# For every path found this section:
#   1. Checks the path exists on disk.
#   2. If missing: warns and offers to create the directory.
#   3. If the path contains "rippled" in a directory component and we are
#      migrating to xrpld naming:
#        a. Asks the operator if they want to rename the directory.
#        b. If yes: mv old → new on disk, then update the config file to
#           match — both changes happen together or not at all.
#        c. Optionally creates a compatibility symlink old → new so nothing
#           else breaks while other references are cleaned up.
# ─────────────────────────────────────────────────────────────────────────────
header "Validating config paths against filesystem"

# Populated by parse_config_paths:
declare -A CFG_PATH_ENTRIES=()   # key (section:field) → absolute path value

# ── Parse rippled.cfg for all absolute path values ────────────────────────────
parse_config_paths() {
  [[ -z "${XRPLD_CONFIG_FILE:-}" ]] && {
    warn "No config file found — skipping path validation."
    return
  }

  local current_section=""
  local section_lines=()    # accumulate non-key lines inside a section

  # Counter used to make unique keys when the same section appears more than
  # once (e.g. multiple [node_db] blocks for NuDB + RocksDB).
  local -A section_count=()

  flush_section_body() {
    # After we've collected all lines in a section, check if the body is a
    # bare absolute path (e.g. [database_path] whose only content is a path).
    local idx="${section_count[$current_section]:-0}"
    for ln in "${section_lines[@]}"; do
      ln="$(echo "$ln" | sed 's/^[[:space:]]*//')"
      if [[ "$ln" == /* ]]; then
        # Append an index so duplicate sections don't overwrite each other
        CFG_PATH_ENTRIES["${current_section}:body:${idx}"]="$ln"
        (( idx++ )) || true
      fi
    done
    section_count[$current_section]=$idx
    section_lines=()
  }

  while IFS= read -r raw_line; do
    # Strip inline comments and trailing whitespace
    local line
    line="$(echo "$raw_line" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    # Section header
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      flush_section_body
      current_section="${BASH_REMATCH[1],,}"   # lower-case
      continue
    fi

    # key = value  (look for any key whose value looks like an absolute path)
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(/.+) ]]; then
      local key="${BASH_REMATCH[1],,}"
      local val="${BASH_REMATCH[2]}"
      # Keys that carry paths:
      case "$key" in
        path|db_path|database_path|log_file|logfile|debug_logfile|\
        validators_file|validator_key_file|peer_private_key_file)
          # Use a counter suffix so duplicate sections (e.g. multiple [node_db])
          # don't silently overwrite each other.
          local kidx="${section_count[${current_section}:${key}]:-0}"
          CFG_PATH_ENTRIES["${current_section}:${key}:${kidx}"]="$val"
          section_count["${current_section}:${key}"]=$(( kidx + 1 ))
          ;;
      esac
      continue
    fi

    # Collect bare lines for flush_section_body
    section_lines+=("$line")

  done < "$XRPLD_CONFIG_FILE"

  flush_section_body
}

# ── Validate + sync ───────────────────────────────────────────────────────────
validate_config_paths() {
  parse_config_paths

  if [[ ${#CFG_PATH_ENTRIES[@]} -eq 0 ]]; then
    info "No filesystem paths found in config — nothing to validate."
    return
  fi

  info "Paths declared in ${XRPLD_CONFIG_FILE}:"
  echo ""

  # Track config file changes so we do one sed pass at the end
  local -a old_paths=()
  local -a new_paths=()

  for entry_key in $(echo "${!CFG_PATH_ENTRIES[@]}" | tr ' ' '\n' | sort); do
    local cfg_path="${CFG_PATH_ENTRIES[$entry_key]}"
    # Strip glob/wildcard suffixes for existence check (e.g. /path/*.log)
    local check_path="${cfg_path%%\**}"
    check_path="${check_path%/}"
    local parent_dir
    parent_dir="$(dirname "$check_path")"

    printf "  %-45s " "${entry_key} = ${cfg_path}"

    # ── Does the path exist? ──────────────────────────────────────────────────
    if [[ -e "$check_path" ]]; then
      echo -e "${GREEN}EXISTS${RESET}"

    elif [[ -e "${check_path%.*}" ]]; then
      # File path where extension was stripped — close enough
      echo -e "${GREEN}EXISTS (parent ok)${RESET}"

    else
      echo -e "${RED}MISSING${RESET}"
      warn "  Path does not exist: ${cfg_path}"

      # Whether the parent exists or not, we use mkdir -p to create the full
      # path tree. This is a required action in all modes — xrpld will not
      # start without the paths its config declares.
      if [[ ! -d "$parent_dir" ]]; then
        warn "  Parent directory also missing: ${parent_dir}"
        warn "  Will attempt to create full path tree with mkdir -p."
      fi

      if ask_yes_no "  Create missing directory (full path): ${check_path}?" yes; then
        mkdir -p "$check_path" \
          && { success "  Created: ${check_path}"
               record_change "DIR CREATED" "${check_path} (required by config)"; } \
          || { warn "  Could not create ${check_path}"
               warn "  xrpld may fail to start — ensure this path exists before proceeding."; }
      fi
    fi

    # ── Does the path contain 'rippled' in a directory component? ─────────────
    # Only flag directory components, not just the final filename.
    local dir_part
    dir_part="$(dirname "$cfg_path")"
    if echo "$dir_part" | grep -qE '(^|/)rippled(/|$)'; then
      local new_cfg_path
      new_cfg_path="$(echo "$cfg_path" | sed 's|/rippled/|/xrpld/|g; s|/rippled$|/xrpld|g')"
      echo ""
      warn "  Config path uses 'rippled' directory: ${cfg_path}"
      warn "  Suggested xrpld path               : ${new_cfg_path}"
      echo ""

      # Directory rename is optional/risky — skip in --auto mode
      if ask_optional "  Rename directory and update config to use '${new_cfg_path}'?" no; then
        local old_dir new_dir
        old_dir="$(echo "$dir_part" | sed 's|/rippled\(/\|$\)|/rippled|')"
        new_dir="$(echo "$dir_part" | sed 's|/rippled\(/\|$\)|/xrpld|g')"

        # Resolve to the top-most rippled→xrpld directory to rename
        # (avoids renaming nested subdirs one by one)
        local rename_from rename_to
        rename_from="$(echo "$cfg_path" | grep -oE '^(/[^/]+)*/rippled' | head -1)"
        rename_to="${rename_from%rippled}xrpld"

        if [[ -z "$rename_from" ]]; then
          warn "  Could not determine source directory — skipping rename."
        elif [[ -e "$rename_to" ]]; then
          warn "  Target already exists: ${rename_to}"
          warn "  Updating config to point there without renaming."
          old_paths+=("$cfg_path")
          new_paths+=("$new_cfg_path")
        else
          info "  Renaming: ${rename_from} → ${rename_to}"
          mv "$rename_from" "$rename_to" \
            && { success "  Directory renamed."
                 record_change "DIR RENAMED" "${rename_from} → ${rename_to}"; } \
            || { warn "  mv failed — config will NOT be updated."; continue; }

          old_paths+=("$cfg_path")
          new_paths+=("$new_cfg_path")

          # Symlink is optional — skip in --auto mode
          if ask_optional "  Create symlink ${rename_from} → ${rename_to} for compatibility?" yes; then
            ln -s "$rename_to" "$rename_from" \
              && { success "  Symlink created: ${rename_from} → ${rename_to}"
                   record_change "SYMLINK" "${rename_from} → ${rename_to}"; } \
              || warn    "  Could not create symlink."
          fi
        fi
      fi
    fi

  done

  # ── Apply all config file path rewrites in a single pass ──────────────────
  if [[ ${#old_paths[@]} -gt 0 ]]; then
    echo ""
    info "Updating config file with renamed paths..."
    cp -p "$XRPLD_CONFIG_FILE" "${XRPLD_CONFIG_FILE}.bak-paths" \
      && info "Config backed up as ${XRPLD_CONFIG_FILE}.bak-paths"

    local perl_script=""
    for i in "${!old_paths[@]}"; do
      local op="${old_paths[$i]}"
      local np="${new_paths[$i]}"
      # Escape special regex chars in the path
      local op_esc
      op_esc="$(printf '%s' "$op" | sed 's|[/.]|\\&|g')"
      perl_script+="s{\Q${op}\E}{${np}}g; "
    done

    perl -i -pe "$perl_script" "$XRPLD_CONFIG_FILE" \
      && { success "Config updated with new paths."
           for i in "${!old_paths[@]}"; do
             record_change "CONFIG PATH" "${old_paths[$i]} → ${new_paths[$i]}"
           done; } \
      || warn    "perl -i failed — edit ${XRPLD_CONFIG_FILE} manually."

    if command -v diff &>/dev/null; then
      diff "${XRPLD_CONFIG_FILE}.bak-paths" "$XRPLD_CONFIG_FILE" || true
    fi
  fi

  echo ""
  success "Config path validation complete."
}

validate_config_paths

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 — Update cron jobs
# ─────────────────────────────────────────────────────────────────────────────
header "Updating cron jobs"

migrate_cron_jobs() {
  if [[ ${#CRON_FILES_WITH_RIPPLED[@]} -eq 0 ]]; then
    info "No cron jobs to update."
    return
  fi

  for f in "${CRON_FILES_WITH_RIPPLED[@]}"; do
    [[ -f "$f" ]] || continue

    info "Updating: ${f}"
    # Back up first
    cp -p "$f" "${f}.bak-rippled" \
      && info "  Backed up as ${f}.bak-rippled"

    # Replace 'rippled' with 'xrpld' – avoid replacing inside URLs or unrelated words
    # Using word-boundary aware sed substitution
    sed -i.tmp \
      -e 's|\brippled\b|xrpld|g' \
      -e 's|rippled\.cfg|xrpld.cfg|g' \
      "$f" && rm -f "${f}.tmp"

    if command -v diff &>/dev/null; then
      diff "${f}.bak-rippled" "$f" || true
    fi

    success "  ${f} updated."
    record_change "CRON" "rippled → xrpld in ${f}"
  done
}

migrate_cron_jobs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 — Update monitoring tool configs
# ─────────────────────────────────────────────────────────────────────────────
header "Updating monitoring configs"

migrate_monitoring_configs() {
  if [[ ${#MONITORING_FILES_WITH_RIPPLED[@]} -eq 0 ]]; then
    info "No monitoring configs to update."
    return
  fi

  for f in "${MONITORING_FILES_WITH_RIPPLED[@]}"; do
    [[ -f "$f" ]] || continue

    info "Updating: ${f}"
    cp -p "$f" "${f}.bak-rippled" \
      && info "  Backed up as ${f}.bak-rippled"

    sed -i.tmp \
      -e 's|\brippled\b|xrpld|g' \
      -e 's|rippled\.cfg|xrpld.cfg|g' \
      "$f" && rm -f "${f}.tmp"

    if command -v diff &>/dev/null; then
      diff "${f}.bak-rippled" "$f" || true
    fi

    success "  ${f} updated."
    record_change "MONITORING" "rippled → xrpld in ${f}"
  done

  # Reload monitoring daemons that are active
  if printf '%s\n' "${MONITORING_TOOLS_FOUND[@]}" | grep -q 'monit'; then
    if command -v monit &>/dev/null && monit status &>/dev/null 2>&1; then
      info "Reloading monit..."
      monit reload 2>/dev/null || warn "monit reload failed — restart it manually."
    fi
  fi

  if printf '%s\n' "${MONITORING_TOOLS_FOUND[@]}" | grep -q 'supervisor'; then
    if command -v supervisorctl &>/dev/null; then
      info "Reloading supervisor..."
      supervisorctl reread 2>/dev/null || true
      supervisorctl update 2>/dev/null || warn "supervisorctl update failed — check manually."
    fi
  fi

  if printf '%s\n' "${MONITORING_TOOLS_FOUND[@]}" | grep -q 'prometheus'; then
    warn "Prometheus configs updated. Reload Prometheus to apply:"
    warn "  kill -HUP \$(pgrep prometheus)"
    warn "  or: systemctl reload prometheus"
  fi

  if printf '%s\n' "${MONITORING_TOOLS_FOUND[@]}" | grep -q 'datadog'; then
    warn "Datadog configs updated. Restart the Datadog agent to apply:"
    warn "  systemctl restart datadog-agent"
  fi
}

migrate_monitoring_configs

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11b — Update logrotate config
# ─────────────────────────────────────────────────────────────────────────────
header "Updating logrotate config"

migrate_logrotate() {
  if [[ -z "$LOGROTATE_FILE" ]]; then
    info "No logrotate config to update."
    return
  fi

  info "Updating: ${LOGROTATE_FILE}"
  cp -p "${LOGROTATE_FILE}" "${LOGROTATE_FILE}.bak-rippled" \
    && info "Backed up as ${LOGROTATE_FILE}.bak-rippled"

  # What we rewrite:
  #   1. The drop-in filename itself (handled by the rename below)
  #   2. Any reference to the 'rippled' process name in postrotate signals
  #      e.g.  kill -HUP $(cat /var/run/rippled/rippled.pid)
  #            systemctl reload rippled
  #   3. Log file paths if they contain 'rippled' in the directory name
  #      e.g.  /var/log/rippled/*.log  →  /var/log/xrpld/*.log
  #      NOTE: we do NOT rename the actual log directory — that is the
  #      operator's call. We update the pattern so xrpld's new log location
  #      is watched, and print a note about the old directory.

  sed -i \
    -e 's|/var/log/rippled|/var/log/xrpld|g' \
    -e 's|\brippled\.pid\b|xrpld.pid|g' \
    -e 's|systemctl reload rippled|systemctl reload xrpld|g' \
    -e 's|systemctl kill rippled|systemctl kill xrpld|g' \
    -e 's|kill.*rippled|kill -USR1 $(pgrep xrpld)|g' \
    -e 's|\brippled\b|xrpld|g' \
    "${LOGROTATE_FILE}"

  if command -v diff &>/dev/null; then
    diff "${LOGROTATE_FILE}.bak-rippled" "${LOGROTATE_FILE}" || true
  fi

  # If the file is named after the old service (e.g. /etc/logrotate.d/rippled),
  # rename it so logrotate picks it up under the new name.
  local dir base new_path
  dir="$(dirname "${LOGROTATE_FILE}")"
  base="$(basename "${LOGROTATE_FILE}")"
  if [[ "$base" == "rippled" || "$base" == *"rippled"* ]]; then
    new_path="${dir}/$(echo "$base" | sed 's/rippled/xrpld/g')"
    mv "${LOGROTATE_FILE}" "${new_path}" \
      && { success "Renamed: ${LOGROTATE_FILE} → ${new_path}"
           record_change "LOGROTATE" "renamed ${LOGROTATE_FILE} → ${new_path}"; } \
      || warn "Could not rename logrotate file — update it manually."
    LOGROTATE_FILE="$new_path"
  else
    success "logrotate config updated: ${LOGROTATE_FILE}"
    record_change "LOGROTATE" "updated ${LOGROTATE_FILE}"
  fi

  # Warn if the old log directory still exists — xrpld will write to the new
  # path once it starts, but the operator may want to archive the old logs.
  if [[ -d /var/log/rippled ]]; then
    warn "/var/log/rippled still exists."
    warn "xrpld will log to /var/log/xrpld (or its configured [log] path)."
    warn "Archive or remove old logs manually when ready:"
    warn "  mv /var/log/rippled /var/log/rippled.old"
  fi

  # Force logrotate to re-read its configs (no rotation, just validation)
  if command -v logrotate &>/dev/null; then
    logrotate --debug /etc/logrotate.conf &>/dev/null \
      && info "logrotate config validated (--debug pass)." \
      || warn "logrotate --debug reported issues — review ${LOGROTATE_FILE}"
  fi
}

migrate_logrotate

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11c — Apply /etc scan fixes
# ─────────────────────────────────────────────────────────────────────────────
header "Applying scan fixes"

# ── Shared helper: backup + apply + diff ─────────────────────────────────────
apply_fix() {
  local filepath="$1"; shift   # remaining args are sed/perl expressions
  [[ -f "$filepath" ]] || return
  [[ -f "${filepath}.bak-rippled" ]] || \
    cp -p "$filepath" "${filepath}.bak-rippled" 2>/dev/null || true
  "$@" && true   # caller passes the actual command
  if command -v diff &>/dev/null; then
    diff "${filepath}.bak-rippled" "$filepath" 2>/dev/null || true
  fi
}

migrate_scan_results() {
  local total_name=${#SCAN_NAME_REFS[@]}
  local total_script=${#SCAN_SCRIPT_REFS[@]}
  local total_log=${#SCAN_LOG_PATH_REFS[@]}
  local total_cfg=${#SCAN_CFG_PATH_REFS[@]}
  local total_unk=${#SCAN_UNKNOWN_REFS[@]}

  # ── NAME refs — monitoring/init configs: rename the daemon name ───────────
  if [[ $total_name -gt 0 ]]; then
    info "Fixing process/service name refs in ${total_name} file(s)..."
    for filepath in "${!SCAN_NAME_REFS[@]}"; do
      # Negative lookbehind for '/' so we never touch path components
      apply_fix "$filepath" \
        perl -i -pe 's{(?<!/)\brippled\b}{xrpld}g' "$filepath" \
        && { success "  Fixed: ${filepath}"
             record_change "NAME REF" "rippled → xrpld in ${filepath}"; } \
        || warn    "  Could not fix: ${filepath} — edit manually"
    done
  else
    info "No process/service name references to fix."
  fi

  # ── SCRIPT CALL refs — scripts invoking rippled: rename command + path ─────
  if [[ $total_script -gt 0 ]]; then
    info "Fixing script invocation refs in ${total_script} file(s)..."
    for filepath in "${!SCAN_SCRIPT_REFS[@]}"; do
      apply_fix "$filepath" \
        perl -i -pe '
          s{(/[a-zA-Z0-9._/-]*/)(rippled)\b}{$1xrpld}g;
          s{(?<!/)\brippled\b}{xrpld}g;
        ' "$filepath" \
        && { success "  Fixed: ${filepath}"
             record_change "SCRIPT" "rippled → xrpld in ${filepath}"; } \
        || warn    "  Could not fix: ${filepath} — edit manually"
    done
  else
    info "No script invocation references to fix."
  fi

  # ── LOG PATH refs — /var/log/rippled → /var/log/xrpld ─────────────────────
  if [[ $total_log -gt 0 ]]; then
    info "Fixing log-path refs in ${total_log} file(s)..."
    for filepath in "${!SCAN_LOG_PATH_REFS[@]}"; do
      apply_fix "$filepath" \
        sed -i \
          -e 's|/var/log/rippled|/var/log/xrpld|g' \
          -e 's|/var/log/ripple/|/var/log/xrpld/|g' \
          "$filepath" \
        && { success "  Fixed: ${filepath}"
             record_change "LOG PATH" "/var/log/rippled → /var/log/xrpld in ${filepath}"; } \
        || warn    "  Could not fix: ${filepath}"
    done
  else
    info "No log-path references to fix."
  fi

  # ── CONFIG PATH refs — kept in place, report only ─────────────────────────
  if [[ $total_cfg -gt 0 ]]; then
    info "Config-path references in ${total_cfg} file(s) — left untouched:"
    for filepath in "${!SCAN_CFG_PATH_REFS[@]}"; do
      info "  ${filepath}"
      while IFS= read -r ln; do
        [[ -n "$ln" ]] && info "    ${ln}"
      done <<< "${SCAN_CFG_PATH_REFS[$filepath]}"
    done
  fi

  # ── UNKNOWN refs — pause and ask operator ─────────────────────────────────
  if [[ $total_unk -gt 0 ]]; then
    echo ""
    warn "═══ MANUAL REVIEW REQUIRED ══════════════════════════════════════════"
    warn "${total_unk} file(s) have references that could not be auto-classified."
    warn "Each line is shown below. Decide if 'rippled' should become 'xrpld'."
    echo ""
    for filepath in "${!SCAN_UNKNOWN_REFS[@]}"; do
      warn "  File: ${filepath}"
      while IFS= read -r ln; do
        [[ -n "$ln" ]] && warn "    ${ln}"
      done <<< "${SCAN_UNKNOWN_REFS[$filepath]}"
    done
    warn "═════════════════════════════════════════════════════════════════════"
    echo ""
    if $AUTO_MODE; then
      warn "AUTO MODE: continuing past unknown refs — review the files above after migration."
    elif ! ask_yes_no "Continue migration (fix the above files later)?" yes; then
      info "Aborted. Fix the files above and re-run."
      exit 0
    fi
  fi
}

migrate_scan_results

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 — Update and start xrpld service
# ─────────────────────────────────────────────────────────────────────────────
header "Starting xrpld"

start_xrpld() {
  case "$START_METHOD" in

    systemd)
      # The new xrpld package drops a unit file but with no config path set.
      # We must patch ExecStart so it points to the migrated config file.
      local unit_file=""
      unit_file="$(find /lib/systemd /usr/lib/systemd /etc/systemd \
        -name 'xrpld.service' 2>/dev/null | head -1 || true)"
      # Also check systemctl cat output for the canonical unit path
      if [[ -z "$unit_file" ]] && command -v systemctl &>/dev/null; then
        local cat_out
        cat_out="$(systemctl cat xrpld.service 2>/dev/null | head -3 || true)"
        if [[ "$cat_out" =~ ^#[[:space:]]+(/.+\.service) ]]; then
          unit_file="${BASH_REMATCH[1]}"
        fi
      fi

      # Fix 4 (B2): warn early if config path is unknown — xrpld would start with defaults
      if [[ -z "$XRPLD_CONFIG_FILE" ]]; then
        warn "XRPLD_CONFIG_FILE is not set — xrpld will start with its compiled-in default config."
        warn "Verify the correct config path and either re-run this script or create a drop-in:"
        warn "  mkdir -p /etc/systemd/system/xrpld.service.d"
        warn "  printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/xrpld --conf /etc/xrpld/xrpld.cfg\\n' \\"
        warn "    > /etc/systemd/system/xrpld.service.d/config.conf"
      fi

      if [[ -n "$XRPLD_CONFIG_FILE" && -n "$unit_file" && -f "$unit_file" ]]; then
        info "Patching unit file: ${unit_file}"
        cp -p "$unit_file" "${unit_file}.bak" 2>/dev/null || true
        if grep -q '\-\-conf' "$unit_file"; then
          # Replace existing --conf argument
          sed -i "s|--conf [^ ]*|--conf ${XRPLD_CONFIG_FILE}|g" "$unit_file"
        else
          # Fix 3 (B1): append --conf to ExecStart, then verify the sed actually matched
          sed -i "s|\(ExecStart=.*xrpld\)|\1 --conf ${XRPLD_CONFIG_FILE}|g" "$unit_file"
          if ! grep -q '\-\-conf' "$unit_file"; then
            warn "Could not inject '--conf' into ExecStart in ${unit_file}."
            warn "ExecStart may reference a wrapper script rather than 'xrpld' directly."
            warn "Manually add '--conf ${XRPLD_CONFIG_FILE}' to ExecStart, or create a drop-in:"
            warn "  mkdir -p /etc/systemd/system/xrpld.service.d"
            warn "  printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/xrpld --conf ${XRPLD_CONFIG_FILE}\\n' \\"
            warn "    > /etc/systemd/system/xrpld.service.d/config.conf"
          fi
        fi
        # Confirm final ExecStart state (only print success when --conf is actually present)
        if grep -q '\-\-conf' "$unit_file"; then
          info "Unit ExecStart now uses config: ${XRPLD_CONFIG_FILE}"
          record_change "UNIT PATCH" "Injected --conf ${XRPLD_CONFIG_FILE} into ${unit_file}"
        fi
      elif [[ -z "$unit_file" ]]; then
        warn "Could not locate xrpld.service unit file to patch."
        warn "If xrpld fails to start, create a drop-in:"
        warn "  mkdir -p /etc/systemd/system/xrpld.service.d"
        warn "  printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/xrpld --conf ${XRPLD_CONFIG_FILE:-/etc/xrpld/xrpld.cfg}\\n' \\"
        warn "    > /etc/systemd/system/xrpld.service.d/config.conf"
      fi

      systemctl daemon-reload
      systemctl enable xrpld   || warn "systemctl enable xrpld failed"
      systemctl start xrpld    || die  "systemctl start xrpld failed"
      success "xrpld started via systemd."
      record_change "SERVICE START" "systemctl enable + start xrpld"
      ;;

    sysvinit)
      # If an init script for xrpld was installed, use it; otherwise warn.
      if [[ -f /etc/init.d/xrpld ]]; then
        service xrpld start || die "service xrpld start failed"
        success "xrpld started via SysV init."
      else
        warn "No /etc/init.d/xrpld script found."
        warn "Start xrpld manually: xrpld --conf ${XRPLD_CONFIG_FILE:-/etc/xrpld/xrpld.cfg} --silent &"
      fi
      ;;

    launchd)
      # Look for the new plist installed by the xrpld package
      local new_plist
      new_plist="$(find /Library/LaunchDaemons -name '*xrpld*' 2>/dev/null | head -1 || true)"
      if [[ -n "$new_plist" ]]; then
        # Patch config path if needed
        if [[ -n "$XRPLD_CONFIG_FILE" ]]; then
          sed -i '' "s|rippled\.cfg|$(basename "${XRPLD_CONFIG_FILE}")|g" "$new_plist" 2>/dev/null || true
        fi
        launchctl load -w "$new_plist" || die "launchctl load failed"
        success "xrpld started via launchd (${new_plist})."
      else
        warn "No launchd plist for xrpld found."
        warn "Start xrpld manually or create a plist."
      fi
      ;;

    manual|none)
      warn "No service manager in use. Starting xrpld manually..."
      local cfg_arg=""
      [[ -n "$XRPLD_CONFIG_FILE" ]] && cfg_arg="--conf ${XRPLD_CONFIG_FILE}"
      # shellcheck disable=SC2086
      xrpld $cfg_arg --silent &
      disown
      info "xrpld launched in background (PID $!)."
      ;;
  esac
}

start_xrpld

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 — Verification
# ─────────────────────────────────────────────────────────────────────────────
header "Verifying xrpld"

verify_xrpld() {
  local max_wait=60    # increased: systemd may need a moment to transition active
  local waited=0
  local process_up=false
  info "Waiting up to ${max_wait}s for xrpld to come up..."

  # ── Fix 5 (D2): for systemd, loop on is-active; treat 'failed' as immediate fatal ──
  if [[ "$START_METHOD" == "systemd" ]]; then
    while [[ $waited -lt $max_wait ]]; do
      local active
      active="$(systemctl is-active xrpld 2>/dev/null || echo unknown)"
      case "$active" in
        active)
          success "xrpld systemd unit is active."
          process_up=true
          break
          ;;
        failed)
          error "xrpld systemd unit entered 'failed' state."
          error "Check: journalctl -u xrpld -n 50 --no-pager"
          exit 1
          ;;
        activating|deactivating|unknown)
          info "  systemd status: ${active} (${waited}s elapsed, retrying...)"
          sleep 2
          ((waited+=2))
          ;;
        *)
          # inactive or anything else — keep waiting briefly
          sleep 2
          ((waited+=2))
          ;;
      esac
    done

    if ! $process_up; then
      local final_state
      final_state="$(systemctl is-active xrpld 2>/dev/null || echo unknown)"
      error "xrpld unit did not reach 'active' state after ${max_wait}s (current: ${final_state})."
      error "Check: journalctl -u xrpld -n 50 --no-pager"
      exit 1
    fi

  else
    # Non-systemd: wait for the process to appear in the process table
    while [[ $waited -lt $max_wait ]]; do
      if pgrep -x xrpld &>/dev/null; then
        success "xrpld process is running (pid: $(pgrep -x xrpld | head -1))."
        process_up=true
        break
      fi
      sleep 2
      ((waited+=2))
    done

    if ! $process_up; then
      error "xrpld process not detected after ${max_wait}s."
      error "Check logs:"
      if [[ "$OS_TYPE" == "macos" ]]; then
        error "  log show --predicate 'process == \"xrpld\"' --last 5m"
      else
        error "  ${XRPLD_CONFIG_FILE:+Check log path in ${XRPLD_CONFIG_FILE}; also try }/var/log/xrpld/xrpld.log"
      fi
      exit 1
    fi
  fi

  # ── Fix 6 (D3): RPC check — distinguish refused vs syncing ──────────────────
  # Give the server a brief moment to open its RPC port before probing
  sleep 3

  # Derive RPC port from config (default 5005)
  local rpc_port=5005
  if [[ -n "$XRPLD_CONFIG_FILE" && -f "$XRPLD_CONFIG_FILE" ]]; then
    local cfg_port
    cfg_port="$(grep -i '^\s*port\s*=' "$XRPLD_CONFIG_FILE" 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')"
    [[ "$cfg_port" =~ ^[0-9]+$ ]] && rpc_port="$cfg_port"
  fi

  local rpc_ok=false
  local rpc_output=""
  if command -v curl &>/dev/null; then
    # Use curl with a short timeout; capture both stdout and exit code
    rpc_output="$(curl -sf --max-time 5 \
      -H 'Content-Type: application/json' \
      -d '{"method":"server_info","params":[{}]}' \
      "http://127.0.0.1:${rpc_port}" 2>/dev/null || true)"
  elif command -v xrpld &>/dev/null; then
    # Fall back to the xrpld CLI client if available
    rpc_output="$(xrpld server_info 2>/dev/null || true)"
  fi

  if [[ -z "$rpc_output" ]]; then
    # No response at all — likely connection refused (port not open yet or wrong port)
    warn "RPC probe on port ${rpc_port} got no response (connection refused or wrong port)."
    warn "xrpld process is up but the RPC port may not be open yet."
    warn "Verify manually: curl -s http://127.0.0.1:${rpc_port} -d '{\"method\":\"server_info\",\"params\":[{}]}'"
  else
    # We got a response — extract server_state
    local server_state
    server_state="$(echo "$rpc_output" | grep -o '"server_state"\s*:\s*"[^"]*"' | head -1 || true)"
    if [[ -n "$server_state" ]]; then
      info "RPC check OK — ${server_state}"
      rpc_ok=true
      # States that mean xrpld is healthy (syncing/tracking/proposing/full are all fine)
      if echo "$server_state" | grep -qiE 'disconnected|offline'; then
        warn "server_state indicates xrpld is not connected to the network."
        warn "Check network connectivity and peer configuration."
      fi
    else
      # Got a response but no server_state — JSON parse issue or error envelope
      warn "RPC responded but server_state could not be parsed."
      warn "Raw response excerpt: ${rpc_output:0:200}"
    fi
  fi

  return 0
}

verify_xrpld

# ─────────────────────────────────────────────────────────────────────────────
# Done — print change log
# ─────────────────────────────────────────────────────────────────────────────
header "Migration complete"
echo ""
echo -e "  ${GREEN}${BOLD}rippled → xrpld migration successful!${RESET}"
echo ""

# ── Change log ────────────────────────────────────────────────────────────────
if [[ ${#CHANGE_LOG[@]} -gt 0 ]]; then
  echo -e "${BOLD}${CYAN}Changes made during this migration:${RESET}"
  echo -e "${CYAN}────────────────────────────────────────────────────────────────${RESET}"
  for entry in "${CHANGE_LOG[@]}"; do
    echo -e "  ${entry}"
  done
  echo -e "${CYAN}────────────────────────────────────────────────────────────────${RESET}"
  echo ""
else
  info "No changes were recorded (dry-run or already migrated)."
fi

# ── Items that still need manual attention ─────────────────────────────────────
if [[ ${#SCAN_UNKNOWN_REFS[@]} -gt 0 ]]; then
  echo -e "${BOLD}${YELLOW}Items still requiring manual review:${RESET}"
  for f in "${!SCAN_UNKNOWN_REFS[@]}"; do
    echo -e "  ${YELLOW}${f}${RESET}"
    while IFS= read -r ln; do
      [[ -n "$ln" ]] && echo -e "    ${ln}"
    done <<< "${SCAN_UNKNOWN_REFS[$f]}"
  done
  echo ""
fi
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"

if [[ "$START_METHOD" == "systemd" ]]; then
  echo -e "    systemctl status xrpld"
  echo -e "    journalctl -u xrpld -f"
elif [[ "$START_METHOD" == "launchd" ]]; then
  echo -e "    launchctl list | grep xrpld"
fi

echo -e "    xrpld server_info"
[[ -n "$XRPLD_CONFIG_FILE" ]] && echo -e "    Config: ${XRPLD_CONFIG_FILE}"
echo ""
