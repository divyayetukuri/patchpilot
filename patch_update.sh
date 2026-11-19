#!/usr/bin/env bash
# =============================================================================
# PatchPilot - patch_update.sh
# Automates package updates and security patches (apt & dnf compatible)
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/patchpilot"
REPORT_DIR="/var/lib/patchpilot/reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME=$(hostname -s)
LOG_FILE="${LOG_DIR}/patch_${HOSTNAME}_${TIMESTAMP}.log"
REPORT_FILE="${REPORT_DIR}/patch_report_${HOSTNAME}_${TIMESTAMP}.json"
REBOOT_FLAG="/var/run/patchpilot_reboot_required"
SECURITY_ONLY=false
DRY_RUN=false
AUTO_REBOOT=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()  { log "${GREEN}[INFO]${NC}  $*"; }
warn()  { log "${YELLOW}[WARN]${NC}  $*"; }
error() { log "${RED}[ERROR]${NC} $*"; }
title() { log "${CYAN}═══ $* ═══${NC}"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -s, --security-only   Apply security patches only
  -d, --dry-run         Simulate updates without applying
  -r, --auto-reboot     Reboot automatically if required
  -h, --help            Show this help

Examples:
  $(basename "$0") --security-only
  $(basename "$0") --dry-run
  $(basename "$0") --security-only --auto-reboot
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--security-only) SECURITY_ONLY=true ;;
    -d|--dry-run)       DRY_RUN=true ;;
    -r|--auto-reboot)   AUTO_REBOOT=true ;;
    -h|--help)          usage; exit 0 ;;
    *) error "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# ── Setup ─────────────────────────────────────────────────────────────────────
setup_dirs() {
  mkdir -p "$LOG_DIR" "$REPORT_DIR"
  chmod 750 "$LOG_DIR" "$REPORT_DIR"
}

detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
  elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
  elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
  else
    error "No supported package manager found (apt/dnf/yum)."
    exit 1
  fi
  info "Detected package manager: ${PKG_MGR}"
}

# ── APT functions ─────────────────────────────────────────────────────────────
apt_update_cache() {
  info "Refreshing APT cache..."
  apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
}

apt_list_upgradable() {
  if $SECURITY_ONLY; then
    apt-get --just-print upgrade 2>/dev/null \
      | grep -i "security" | awk '{print $2}' | sort -u
  else
    apt list --upgradable 2>/dev/null | grep -v "Listing" | awk -F'/' '{print $1}'
  fi
}

apt_apply_updates() {
  local flags="-y -q"
  if $DRY_RUN; then
    info "[DRY-RUN] Would run: apt-get upgrade ${flags}"
    apt-get --just-print upgrade 2>&1 | tee -a "$LOG_FILE"
    return
  fi
  if $SECURITY_ONLY; then
    info "Applying security patches only (unattended-upgrades)..."
    DEBIAN_FRONTEND=noninteractive unattended-upgrades -v 2>&1 | tee -a "$LOG_FILE"
  else
    info "Applying all upgrades..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade $flags 2>&1 | tee -a "$LOG_FILE"
    apt-get autoremove -y -q 2>&1 | tee -a "$LOG_FILE"
  fi
}

apt_check_reboot() {
  if [ -f /var/run/reboot-required ]; then
    warn "Reboot required! (kernel or critical library updated)"
    touch "$REBOOT_FLAG"
    if [ -f /var/run/reboot-required.pkgs ]; then
      warn "Packages requiring reboot:"
      cat /var/run/reboot-required.pkgs | tee -a "$LOG_FILE"
    fi
    return 0
  fi
  return 1
}

# ── DNF/YUM functions ─────────────────────────────────────────────────────────
dnf_update_cache() {
  info "Refreshing DNF metadata..."
  ${PKG_MGR} makecache -q 2>&1 | tee -a "$LOG_FILE"
}

dnf_list_upgradable() {
  if $SECURITY_ONLY; then
    ${PKG_MGR} updateinfo list security --available 2>/dev/null \
      | awk '{print $3}' | sort -u
  else
    ${PKG_MGR} list updates --quiet 2>/dev/null \
      | awk 'NR>1 {print $1}' | sort -u
  fi
}

dnf_apply_updates() {
  local flags="-y -q"
  if $DRY_RUN; then
    info "[DRY-RUN] Would run: ${PKG_MGR} upgrade ${flags}"
    ${PKG_MGR} upgrade --assumeno 2>&1 | tee -a "$LOG_FILE"
    return
  fi
  if $SECURITY_ONLY; then
    info "Applying security patches only..."
    ${PKG_MGR} update --security $flags 2>&1 | tee -a "$LOG_FILE"
  else
    info "Applying all updates..."
    ${PKG_MGR} upgrade $flags 2>&1 | tee -a "$LOG_FILE"
  fi
}

dnf_check_reboot() {
  if ${PKG_MGR} needs-restarting -r &>/dev/null; then
    return 1   # 0 = no reboot needed; non-zero = reboot needed (inverted)
  else
    warn "Reboot required! (kernel or critical service updated)"
    touch "$REBOOT_FLAG"
    return 0
  fi
}

# ── Collect system info ────────────────────────────────────────────────────────
collect_system_info() {
  KERNEL_BEFORE=$(uname -r)
  OS_PRETTY=$(. /etc/os-release && echo "$PRETTY_NAME")
  UPTIME=$(uptime -p 2>/dev/null || uptime)
  CPU_CORES=$(nproc)
  MEM_TOTAL=$(free -h | awk '/Mem:/{print $2}')
  DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
}

# ── Generate JSON report ──────────────────────────────────────────────────────
generate_report() {
  local pkg_count=$1 reboot_needed=$2
  local end_time; end_time=$(date +"%Y-%m-%dT%H:%M:%S%z")
  local kernel_after; kernel_after=$(uname -r)
  local status="success"
  $DRY_RUN && status="dry-run"

  cat > "$REPORT_FILE" <<JSON
{
  "patchpilot_version": "1.0.0",
  "report_type": "patch_update",
  "timestamp": "${end_time}",
  "hostname": "${HOSTNAME}",
  "os": "${OS_PRETTY}",
  "kernel_before": "${KERNEL_BEFORE}",
  "kernel_after": "${kernel_after}",
  "uptime": "${UPTIME}",
  "cpu_cores": ${CPU_CORES},
  "memory_total": "${MEM_TOTAL}",
  "disk_free_root": "${DISK_FREE}",
  "package_manager": "${PKG_MGR}",
  "security_only": ${SECURITY_ONLY},
  "dry_run": ${DRY_RUN},
  "packages_updated": ${pkg_count},
  "reboot_required": ${reboot_needed},
  "auto_reboot": ${AUTO_REBOOT},
  "log_file": "${LOG_FILE}",
  "status": "${status}"
}
JSON
  info "Report saved: ${REPORT_FILE}"
}

# ── Handle reboot ─────────────────────────────────────────────────────────────
handle_reboot() {
  if [ -f "$REBOOT_FLAG" ]; then
    if $AUTO_REBOOT && ! $DRY_RUN; then
      warn "Auto-rebooting in 60 seconds... (Ctrl+C to cancel)"
      shutdown -r +1 "PatchPilot: Scheduled reboot after patching"
    else
      warn "Manual reboot required. Run: sudo reboot"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  setup_dirs
  collect_system_info

  title "PatchPilot — Patch Update"
  info  "Host     : ${HOSTNAME}"
  info  "OS       : ${OS_PRETTY}"
  info  "Kernel   : ${KERNEL_BEFORE}"
  info  "Mode     : $(${SECURITY_ONLY} && echo 'Security Only' || echo 'Full Update')"
  $DRY_RUN && info "DRY-RUN mode enabled — no changes will be made."

  detect_package_manager

  title "Refreshing Package Metadata"
  case "$PKG_MGR" in
    apt) apt_update_cache ;;
    dnf|yum) dnf_update_cache ;;
  esac

  title "Listing Upgradable Packages"
  local pkg_list reboot_needed=false pkg_count=0
  case "$PKG_MGR" in
    apt) pkg_list=$(apt_list_upgradable) ;;
    dnf|yum) pkg_list=$(dnf_list_upgradable) ;;
  esac

  if [ -z "$pkg_list" ]; then
    info "System is up-to-date. No packages to update."
  else
    pkg_count=$(echo "$pkg_list" | wc -l)
    info "Packages to update (${pkg_count}):"
    echo "$pkg_list" | tee -a "$LOG_FILE"

    title "Applying Updates"
    case "$PKG_MGR" in
      apt) apt_apply_updates ;;
      dnf|yum) dnf_apply_updates ;;
    esac
    info "Update complete."
  fi

  title "Checking Reboot Status"
  case "$PKG_MGR" in
    apt) apt_check_reboot && reboot_needed=true || true ;;
    dnf|yum) dnf_check_reboot && reboot_needed=true || true ;;
  esac
  $reboot_needed || info "No reboot required."

  title "Generating Report"
  generate_report "$pkg_count" "$reboot_needed"
  handle_reboot

  title "PatchPilot — Done"
}

main "$@"
