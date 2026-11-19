#!/usr/bin/env bash
# ==============================================================================
# PatchPilot Reboot Check Utility
# Purpose: Detect if a system reboot is required due to kernel or core library updates
# Supports: Debian, Ubuntu, RHEL, CentOS, Rocky Linux, AlmaLinux, Fedora
# Exit Codes:
#   0 = No reboot required
#   1 = Reboot is required
#   2 = Error / Unsupported package manager
# ==============================================================================

set -euo pipefail

FORMAT="${1:-text}" # 'text' or 'json'

reboot_required=false
reasons=()

# ------------------------------------------------------------------------------
# 1. Debian / Ubuntu Detection (/var/run/reboot-required)
# ------------------------------------------------------------------------------
if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
    reboot_required=true
    if [ -f /var/run/reboot-required.pkgs ]; then
        pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
        reasons+=("Debian reboot flag set by packages: ${pkgs}")
    else
        reasons+=("Debian reboot flag /run/reboot-required exists")
    fi
fi

# ------------------------------------------------------------------------------
# 2. RHEL / Rocky / Fedora Detection (needs-restarting)
# ------------------------------------------------------------------------------
if command -v needs-restarting >/dev/null 2>&1; then
    # -r flag: check if reboot is required (kernel or core system libraries)
    if ! needs-restarting -r >/dev/null 2>&1; then
        reboot_required=true
        reasons+=("needs-restarting -r reported reboot required (core libraries/kernel updated)")
    fi
fi

# ------------------------------------------------------------------------------
# 3. Kernel Version Comparison (Secondary check for all Linux distros)
# ------------------------------------------------------------------------------
running_kernel=$(uname -r)
latest_installed_kernel=""

if command -v rpm >/dev/null 2>&1; then
    latest_installed_kernel=$(rpm -q --last kernel 2>/dev/null | head -n1 | awk '{print $1}' | sed 's/^kernel-//' || true)
elif command -v dpkg-query >/dev/null 2>&1; then
    latest_installed_kernel=$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V | tail -n1 | sed 's/^linux-image-//' || true)
fi

if [ -n "$latest_installed_kernel" ] && [ "$latest_installed_kernel" != "$running_kernel" ]; then
    reboot_required=true
    reasons+=("Running kernel (${running_kernel}) differs from latest installed (${latest_installed_kernel})")
fi

# ------------------------------------------------------------------------------
# Output Results
# ------------------------------------------------------------------------------
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ "$FORMAT" = "json" ]; then
    reason_json=$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    if [ "$reason_json" = "[]" ] && [ ${#reasons[@]} -gt 0 ]; then
        # Fallback if jq is not installed
        reason_json="[\"$(IFS=,; echo "${reasons[*]}")\"]"
    fi
    cat <<EOF
{
  "timestamp": "${timestamp}",
  "reboot_required": ${reboot_required},
  "running_kernel": "${running_kernel}",
  "latest_installed_kernel": "${latest_installed_kernel:-unknown}",
  "reasons": ${reason_json}
}
EOF
else
    if [ "$reboot_required" = true ]; then
        echo "[WARNING] System reboot IS REQUIRED on $(hostname)"
        echo "Running Kernel: ${running_kernel}"
        echo "Latest Installed Kernel: ${latest_installed_kernel:-unknown}"
        echo "Reasons:"
        for reason in "${reasons[@]}"; do
            echo "  - ${reason}"
        done
        exit 1
    else
        echo "[OK] No reboot required on $(hostname). Running kernel: ${running_kernel}"
        exit 0
    fi
fi

if [ "$reboot_required" = true ]; then
    exit 1
else
    exit 0
fi
