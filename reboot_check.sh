#!/usr/bin/env bash
# =============================================================================
# PatchPilot - reboot_check.sh
# Checks if a reboot is required after patching and reports why
# =============================================================================

set -euo pipefail

LOG_DIR="/var/log/patchpilot"
REPORT_DIR="/var/lib/patchpilot/reports"
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/reboot_check_${HOSTNAME}_${TIMESTAMP}.log"
REPORT_FILE="${REPORT_DIR}/reboot_check_${HOSTNAME}_${TIMESTAMP}.json"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info() { log "${GREEN}[INFO]${NC}  $*"; }
warn() { log "${YELLOW}[WARN]${NC}  $*"; }
err()  { log "${RED}[ERROR]${NC} $*"; }

mkdir -p "$LOG_DIR" "$REPORT_DIR"

REBOOT_REQUIRED=false
REASONS=()
SERVICES_NEEDING_RESTART=()

# ── Method 1: APT reboot-required flag ───────────────────────────────────────
check_apt_reboot_flag() {
  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
    REASONS+=("APT flagged reboot-required")
    if [ -f /var/run/reboot-required.pkgs ]; then
      local pkgs; pkgs=$(cat /var/run/reboot-required.pkgs | tr '\n' ',' | sed 's/,$//')
      REASONS+=("Packages: ${pkgs}")
    fi
  fi
}

# ── Method 2: Kernel version mismatch ────────────────────────────────────────
check_kernel_mismatch() {
  local running_kernel installed_kernel
  running_kernel=$(uname -r)

  if command -v rpm &>/dev/null; then
    installed_kernel=$(rpm -q kernel --last 2>/dev/null | head -1 | awk '{print $1}' | sed 's/kernel-//')
  elif command -v dpkg &>/dev/null; then
    installed_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null \
      | awk '/^ii/{print $2}' | sed 's/linux-image-//' \
      | sort -V | tail -1)
  fi

  if [ -n "${installed_kernel:-}" ] && [ "$running_kernel" != "$installed_kernel" ]; then
    REBOOT_REQUIRED=true
    REASONS+=("Kernel mismatch: running=${running_kernel}, installed=${installed_kernel}")
  fi
}

# ── Method 3: needs-restarting (DNF/systemd) ─────────────────────────────────
check_needs_restarting() {
  if command -v needs-restarting &>/dev/null; then
    if ! needs-restarting -r &>/dev/null; then
      REBOOT_REQUIRED=true
      REASONS+=("needs-restarting reports reboot required")
    fi
    # Services needing restart
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && SERVICES_NEEDING_RESTART+=("$svc")
    done < <(needs-restarting -s 2>/dev/null | awk '{print $1}' || true)
  fi
}

# ── Method 4: /proc/sys/kernel/kexec_loaded ──────────────────────────────────
check_kexec() {
  if [ -f /proc/sys/kernel/kexec_loaded ] && \
     [ "$(cat /proc/sys/kernel/kexec_loaded)" = "1" ]; then
    REASONS+=("kexec kernel loaded")
  fi
}

# ── Method 5: Deleted library files in use ───────────────────────────────────
check_deleted_libs() {
  local deleted_count=0
  if command -v lsof &>/dev/null; then
    deleted_count=$(lsof +L1 2>/dev/null \
      | grep -cE '\.(so|so\.[0-9])' || true)
  elif [ -d /proc ]; then
    deleted_count=$(find /proc/*/fd -ls 2>/dev/null \
      | grep -c "(deleted)" || true)
  fi
  if [ "$deleted_count" -gt 0 ]; then
    REASONS+=("${deleted_count} deleted shared libraries still in use")
  fi
}

# ── Build JSON reasons array ──────────────────────────────────────────────────
json_array() {
  local items=("$@")
  printf '['
  for i in "${!items[@]}"; do
    printf '"%s"' "${items[$i]//\"/\\\"}"
    [[ $i -lt $(( ${#items[@]} - 1 )) ]] && printf ','
  done
  printf ']'
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  info "PatchPilot — Reboot Check on ${HOSTNAME}"

  check_apt_reboot_flag
  check_kernel_mismatch
  check_needs_restarting
  check_kexec
  check_deleted_libs

  local reasons_json; reasons_json=$(json_array "${REASONS[@]+"${REASONS[@]}"}")
  local svcs_json;    svcs_json=$(json_array "${SERVICES_NEEDING_RESTART[@]+"${SERVICES_NEEDING_RESTART[@]}"}")

  if $REBOOT_REQUIRED; then
    warn "⚠  REBOOT REQUIRED"
    for r in "${REASONS[@]+"${REASONS[@]}"}"; do warn "   • $r"; done
  else
    info "✓  No reboot required."
  fi

  if [ "${#SERVICES_NEEDING_RESTART[@]}" -gt 0 ]; then
    warn "Services that need restart (no reboot needed):"
    for svc in "${SERVICES_NEEDING_RESTART[@]}"; do warn "   • $svc"; done
  fi

  cat > "$REPORT_FILE" <<JSON
{
  "patchpilot_version": "1.0.0",
  "report_type": "reboot_check",
  "timestamp": "$(date +"%Y-%m-%dT%H:%M:%S%z")",
  "hostname": "${HOSTNAME}",
  "kernel_running": "$(uname -r)",
  "reboot_required": ${REBOOT_REQUIRED},
  "reasons": ${reasons_json},
  "services_needing_restart": ${svcs_json}
}
JSON

  info "Report saved: ${REPORT_FILE}"
  $REBOOT_REQUIRED && exit 1 || exit 0
}

main "$@"
