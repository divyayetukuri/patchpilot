#!/usr/bin/env bash
# =============================================================================
# PatchPilot - install.sh
# Installs PatchPilot scripts and systemd units on a Linux server
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[PatchPilot]${NC} $*"; }
title() { echo -e "\n${CYAN}═══ $* ═══${NC}"; }

INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
SYSTEMD_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd"

# Root check
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

title "Installing PatchPilot Scripts"
install -m 755 "${SCRIPT_DIR}/patch_update.sh"      "${INSTALL_DIR}/patch_update.sh"
install -m 755 "${SCRIPT_DIR}/reboot_check.sh"      "${INSTALL_DIR}/reboot_check.sh"
install -m 755 "${SCRIPT_DIR}/compliance_report.sh" "${INSTALL_DIR}/compliance_report.sh"
info "Scripts installed to ${INSTALL_DIR}"

title "Installing systemd Units"
install -m 644 "${SYSTEMD_SRC}/patchpilot.service"        "${SYSTEMD_DIR}/"
install -m 644 "${SYSTEMD_SRC}/patchpilot.timer"          "${SYSTEMD_DIR}/"
install -m 644 "${SYSTEMD_SRC}/patchpilot-report.service" "${SYSTEMD_DIR}/"
install -m 644 "${SYSTEMD_SRC}/patchpilot-report.timer"   "${SYSTEMD_DIR}/"

title "Enabling and Starting Timers"
systemctl daemon-reload
systemctl enable --now patchpilot.timer
systemctl enable --now patchpilot-report.timer

title "Creating Directories"
mkdir -p /var/log/patchpilot /var/lib/patchpilot/reports
chmod 750 /var/log/patchpilot /var/lib/patchpilot/reports

title "Installation Complete"
info "Timers active:"
systemctl list-timers patchpilot* --no-pager
info ""
info "Run manually: sudo patch_update.sh --security-only"
info "View logs   : journalctl -u patchpilot -f"
info "Reports     : /var/lib/patchpilot/reports/"
