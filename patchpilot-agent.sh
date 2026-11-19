#!/usr/bin/env bash
# ==============================================================================
# PatchPilot Core Agent (Bash)
# Automates package auditing, security patching, reboot checks, and metrics.
# Supports: APT (Debian/Ubuntu) and DNF/YUM (RHEL/Rocky/AlmaLinux/Fedora)
# ==============================================================================

set -euo pipefail

VERSION="1.0.0"
CONFIG_FILE="/etc/patchpilot/patchpilot.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBOOT_CHECK_BIN="${SCRIPT_DIR}/patchpilot-reboot-check.sh"

# Default fallback values
DEFAULT_LOG_DIR="/var/log/patchpilot"
MIN_FREE_DISK_MB=1024
MODE="audit"
SCOPE="security"
OUTPUT_JSON=false
DRY_RUN=false

# Source config if available
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
elif [ -f "${SCRIPT_DIR}/../config/patchpilot.conf" ]; then
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/../config/patchpilot.conf"
fi

LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    local message="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$OUTPUT_JSON" = false ]; then
        echo "[${ts}] [${level}] ${message}"
    fi
    if [ -w "$LOG_DIR" ] || [ "$(id -u)" -eq 0 ]; then
        echo "[${ts}] [${level}] ${message}" >> "${LOG_DIR}/agent.log" 2>/dev/null || true
    fi
}

usage() {
    cat <<EOF
PatchPilot Agent v${VERSION}
Usage: $(basename "$0") [OPTIONS]

Options:
  -a, --audit            Perform read-only patch audit and package assessment (default)
  -s, --apply-security   Install pending security patches
  -u, --apply-all        Install all pending package updates
  -r, --check-reboot     Check if system reboot is currently required
  -j, --json             Output audit results as valid JSON
  -d, --dry-run          Simulate patch operations without changing system state
  -c, --config <file>    Specify custom configuration file path
  -h, --help             Display this help message and exit

Examples:
  $(basename "$0") --audit --json
  sudo $(basename "$0") --apply-security
  $(basename "$0") --check-reboot
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# CLI Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--audit)
            MODE="audit"
            shift
            ;;
        -s|--apply-security)
            MODE="apply"
            SCOPE="security"
            shift
            ;;
        -u|--apply-all)
            MODE="apply"
            SCOPE="all"
            shift
            ;;
        -r|--check-reboot)
            MODE="reboot-only"
            shift
            ;;
        -j|--json)
            OUTPUT_JSON=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            if [ -f "$CONFIG_FILE" ]; then
                # shellcheck disable=SC1090
                source "$CONFIG_FILE"
            fi
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# ------------------------------------------------------------------------------
# System & Package Manager Detection
# ------------------------------------------------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_NAME="Linux"
        OS_VERSION="unknown"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        PKG_MGR="unsupported"
    fi
}

detect_os

# ------------------------------------------------------------------------------
# Pre-Flight Safety Checks
# ------------------------------------------------------------------------------
check_preflight() {
    # 1. Root check if in apply mode
    if [ "$MODE" = "apply" ] && [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
        log_msg "ERROR" "Patch execution requires root privileges. Please re-run with sudo."
        exit 1
    fi

    # 2. Disk space check (/var partition or root partition)
    local free_mb
    free_mb=$(df -m /var 2>/dev/null | tail -1 | awk '{print $4}' || df -m / | tail -1 | awk '{print $4}')
    if [ "$free_mb" -lt "$MIN_FREE_DISK_MB" ]; then
        log_msg "ERROR" "Insufficient disk space! Free: ${free_mb}MB, Required: ${MIN_FREE_DISK_MB}MB."
        exit 1
    fi

    # 3. Lock check (prevent collisions with background package manager)
    if [ "$PKG_MGR" = "apt" ]; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            log_msg "ERROR" "APT package manager lock detected. Another process is managing packages."
            exit 1
        fi
    elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
        if [ -f /var/run/dnf.pid ] || [ -f /var/run/yum.pid ]; then
            log_msg "ERROR" "DNF/YUM lock file found. Another package transaction is in progress."
            exit 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# Audit Logic (APT & DNF)
# ------------------------------------------------------------------------------
audit_packages() {
    TOTAL_PENDING=0
    SECURITY_PENDING=0
    PENDING_PKGS_LIST=()
    SECURITY_PKGS_LIST=()

    if [ "$PKG_MGR" = "apt" ]; then
        # Refresh cache quietly if permitted, ignore errors if non-root
        apt-get update -qq -o Acquire::Languages=none >/dev/null 2>&1 || true

        # Query upgradable packages simulating dist-upgrade
        local apt_sim
        apt_sim=$(apt-get -s dist-upgrade 2>/dev/null || true)

        # Parse packages marked Inst
        while read -r line; do
            if [[ "$line" =~ ^Inst[[:space:]]+([^[:space:]]+)[[:space:]]+\[([^]]+)\][[:space:]]+\(([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
                pkg_name="${BASH_REMATCH[1]}"
                cur_ver="${BASH_REMATCH[2]}"
                new_ver="${BASH_REMATCH[3]}"
                origin="${BASH_REMATCH[4]}"
                TOTAL_PENDING=$((TOTAL_PENDING + 1))
                PENDING_PKGS_LIST+=("${pkg_name}|${cur_ver}|${new_ver}")

                # Security package check based on repository archive/origin
                if [[ "$origin" =~ security|-security|Debian-Security ]]; then
                    SECURITY_PENDING=$((SECURITY_PENDING + 1))
                    SECURITY_PKGS_LIST+=("${pkg_name}|${cur_ver}|${new_ver}")
                fi
            fi
        done <<< "$apt_sim"

    elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
        # Check all available updates
        local all_updates
        all_updates=$($PKG_MGR check-update -q 2>/dev/null || true)
        while read -r line; do
            if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
                pkg_name="${BASH_REMATCH[1]}"
                new_ver="${BASH_REMATCH[2]}"
                repo="${BASH_REMATCH[3]}"
                if [[ "$pkg_name" != "Last" && "$pkg_name" != "Obsoleting" ]]; then
                    TOTAL_PENDING=$((TOTAL_PENDING + 1))
                    PENDING_PKGS_LIST+=("${pkg_name}|unknown|${new_ver}")
                fi
            fi
        done <<< "$all_updates"

        # Check security updates only
        local sec_updates
        sec_updates=$($PKG_MGR check-update --security -q 2>/dev/null || true)
        while read -r line; do
            if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
                pkg_name="${BASH_REMATCH[1]}"
                new_ver="${BASH_REMATCH[2]}"
                repo="${BASH_REMATCH[3]}"
                if [[ "$pkg_name" != "Last" && "$pkg_name" != "Obsoleting" ]]; then
                    SECURITY_PENDING=$((SECURITY_PENDING + 1))
                    SECURITY_PKGS_LIST+=("${pkg_name}|unknown|${new_ver}")
                fi
            fi
        done <<< "$sec_updates"
    else
        log_msg "ERROR" "Unsupported package manager: ${PKG_MGR}"
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# Reboot Status Check
# ------------------------------------------------------------------------------
check_reboot() {
    REBOOT_REQUIRED=false
    REBOOT_REASON="None"

    if [ -f "$REBOOT_CHECK_BIN" ]; then
        if ! bash "$REBOOT_CHECK_BIN" text >/dev/null 2>&1; then
            REBOOT_REQUIRED=true
            REBOOT_REASON="Pending kernel or core libraries update"
        fi
    else
        # Direct fallback check
        if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
            REBOOT_REQUIRED=true
            REBOOT_REASON="Flag file /run/reboot-required exists"
        elif command -v needs-restarting >/dev/null 2>&1; then
            if ! needs-restarting -r >/dev/null 2>&1; then
                REBOOT_REQUIRED=true
                REBOOT_REASON="needs-restarting -r reported reboot required"
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# Apply Patches Logic
# ------------------------------------------------------------------------------
apply_patches() {
    log_msg "INFO" "Starting patch execution. Scope: ${SCOPE}, Dry-Run: ${DRY_RUN}"

    if [ "$PKG_MGR" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        if [ "$DRY_RUN" = true ]; then
            log_msg "INFO" "[DRY-RUN] Simulating apt-get dist-upgrade..."
            apt-get -s dist-upgrade
        else
            log_msg "INFO" "Executing apt-get update..."
            apt-get update -y
            if [ "$SCOPE" = "security" ]; then
                log_msg "INFO" "Applying Debian/Ubuntu security updates..."
                # Use unattended-upgrade if installed or filter dist-upgrade
                if command -v unattended-upgrade >/dev/null 2>&1; then
                    unattended-upgrade -d
                else
                    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
                fi
            else
                log_msg "INFO" "Applying all system package upgrades..."
                apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
            fi
            apt-get autoremove -y || true
        fi
    elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
        if [ "$DRY_RUN" = true ]; then
            log_msg "INFO" "[DRY-RUN] Simulating ${PKG_MGR} upgrade..."
            "$PKG_MGR" check-update || true
        else
            if [ "$SCOPE" = "security" ]; then
                log_msg "INFO" "Applying security advisories using ${PKG_MGR} update --security..."
                "$PKG_MGR" update --security -y
            else
                log_msg "INFO" "Applying full system update using ${PKG_MGR} update..."
                "$PKG_MGR" update -y
            fi
        fi
    fi

    log_msg "INFO" "Patch execution finished successfully."
}

# ------------------------------------------------------------------------------
# JSON Output Generator
# ------------------------------------------------------------------------------
output_json_report() {
    local compliance="COMPLIANT"
    if [ "$SECURITY_PENDING" -gt 0 ]; then
        compliance="NON_COMPLIANT_SECURITY"
    elif [ "$REBOOT_REQUIRED" = true ]; then
        compliance="REBOOT_PENDING"
    fi

    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local uptime_sec
    uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"

    cat <<EOF
{
  "patchpilot_version": "${VERSION}",
  "timestamp": "${ts}",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "ip_address": "$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")",
  "os": {
    "name": "${OS_NAME}",
    "id": "${OS_ID}",
    "version": "${OS_VERSION}",
    "kernel": "$(uname -r)",
    "package_manager": "${PKG_MGR}",
    "uptime_seconds": ${uptime_sec}
  },
  "compliance_status": "${compliance}",
  "summary": {
    "total_pending_updates": ${TOTAL_PENDING},
    "security_pending_updates": ${SECURITY_PENDING},
    "reboot_required": ${REBOOT_REQUIRED},
    "reboot_reason": "${REBOOT_REASON}"
  }
}
EOF
}

# ------------------------------------------------------------------------------
# Main Execution Entry
# ------------------------------------------------------------------------------
check_preflight

if [ "$MODE" = "reboot-only" ]; then
    if [ "$OUTPUT_JSON" = true ]; then
        bash "$REBOOT_CHECK_BIN" json
    else
        bash "$REBOOT_CHECK_BIN" text
    fi
    exit $?
fi

audit_packages
check_reboot

if [ "$MODE" = "audit" ]; then
    if [ "$OUTPUT_JSON" = true ]; then
        output_json_report
    else
        echo "=================================================="
        echo " PatchPilot Node Audit: $(hostname)"
        echo " OS: ${OS_NAME} (${PKG_MGR}) | Kernel: $(uname -r)"
        echo "--------------------------------------------------"
        echo " Total Pending Updates:    ${TOTAL_PENDING}"
        echo " Security Pending Updates: ${SECURITY_PENDING}"
        echo " Reboot Required:          ${REBOOT_REQUIRED} (${REBOOT_REASON})"
        if [ "$SECURITY_PENDING" -gt 0 ]; then
            echo " Status:                   [NON-COMPLIANT] Pending security patches!"
        elif [ "$REBOOT_REQUIRED" = true ]; then
            echo " Status:                   [ACTION REQUIRED] Pending reboot"
        else
            echo " Status:                   [COMPLIANT] System up to date"
        fi
        echo "=================================================="
    fi
elif [ "$MODE" = "apply" ]; then
    apply_patches
    # Re-run reboot check post-patch
    check_reboot
    log_msg "INFO" "Post-patch reboot required: ${REBOOT_REQUIRED}"
fi
