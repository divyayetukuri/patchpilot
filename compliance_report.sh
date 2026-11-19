#!/usr/bin/env bash
# =============================================================================
# PatchPilot - compliance_report.sh
# Generates a detailed patch-compliance report (HTML + JSON)
# =============================================================================

set -euo pipefail

REPORT_DIR="/var/lib/patchpilot/reports"
LOG_DIR="/var/log/patchpilot"
HOSTNAME=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DATE_HUMAN=$(date +"%B %d, %Y %H:%M:%S %Z")
JSON_REPORT="${REPORT_DIR}/compliance_${HOSTNAME}_${TIMESTAMP}.json"
HTML_REPORT="${REPORT_DIR}/compliance_${HOSTNAME}_${TIMESTAMP}.html"
OUTPUT_FORMAT="${1:-both}"   # json | html | both

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()  { log "${GREEN}[INFO]${NC}  $*"; }
warn()  { log "${YELLOW}[WARN]${NC}  $*"; }

mkdir -p "$REPORT_DIR" "$LOG_DIR"

# ── Gather system facts ───────────────────────────────────────────────────────
OS_PRETTY=$(. /etc/os-release && echo "$PRETTY_NAME")
OS_ID=$(. /etc/os-release && echo "$ID")
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null || uptime)
LAST_BOOT=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "unknown")
CPU=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
TOTAL_MEM=$(free -h | awk '/Mem:/{print $2}')
DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
REBOOT_REQUIRED=false
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED=true

# ── Package stats ─────────────────────────────────────────────────────────────
get_pkg_stats_apt() {
  TOTAL_PKGS=$(dpkg -l 2>/dev/null | grep -c "^ii" || echo 0)
  UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "/" || echo 0)
  SECURITY_UPGRADES=$(apt-get --just-print upgrade 2>/dev/null \
    | grep -ci "security" || echo 0)
  # Last apt-get upgrade time
  LAST_UPGRADE=$(stat -c '%y' /var/lib/dpkg/info 2>/dev/null | cut -d. -f1 || echo "unknown")
  # Security advisories
  USN_COUNT=$([ -f /var/lib/update-notifier/package-data-downloads/Pockets ] \
    && cat /var/lib/update-notifier/package-data-downloads/Pockets | wc -l || echo "N/A")
}

get_pkg_stats_dnf() {
  TOTAL_PKGS=$(rpm -qa 2>/dev/null | wc -l || echo 0)
  UPGRADABLE=$(dnf list updates --quiet 2>/dev/null | awk 'NR>1' | wc -l || echo 0)
  SECURITY_UPGRADES=$(dnf updateinfo list security --available 2>/dev/null \
    | wc -l || echo 0)
  LAST_UPGRADE=$(dnf history list 2>/dev/null \
    | awk 'NR==2{print $3, $4}' || echo "unknown")
  USN_COUNT="N/A"
}

detect_and_collect() {
  if command -v apt-get &>/dev/null; then
    PKG_MGR="apt (Debian/Ubuntu)"
    get_pkg_stats_apt
  elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf (RHEL/Fedora)"
    get_pkg_stats_dnf
  elif command -v yum &>/dev/null; then
    PKG_MGR="yum (CentOS/RHEL)"
    PKG_MGR_CMD="yum"
    get_pkg_stats_dnf
  else
    PKG_MGR="unknown"; TOTAL_PKGS=0; UPGRADABLE=0
    SECURITY_UPGRADES=0; LAST_UPGRADE="unknown"; USN_COUNT="N/A"
  fi
}

# ── Compliance score ──────────────────────────────────────────────────────────
calc_compliance_score() {
  local score=100
  # Deduct points for pending updates
  [ "$UPGRADABLE" -gt 0 ]          && score=$((score - 20))
  [ "$SECURITY_UPGRADES" -gt 0 ]   && score=$((score - 30))
  $REBOOT_REQUIRED                  && score=$((score - 20))
  [ "$UPGRADABLE" -gt 50 ]          && score=$((score - 20))
  # Floor at 0
  [ $score -lt 0 ] && score=0
  COMPLIANCE_SCORE=$score
  if   [ $score -ge 90 ]; then COMPLIANCE_GRADE="A (Excellent)"
  elif [ $score -ge 75 ]; then COMPLIANCE_GRADE="B (Good)"
  elif [ $score -ge 60 ]; then COMPLIANCE_GRADE="C (Fair)"
  elif [ $score -ge 40 ]; then COMPLIANCE_GRADE="D (Poor)"
  else COMPLIANCE_GRADE="F (Critical)"
  fi
}

# ── Last 5 patch events from logs ─────────────────────────────────────────────
get_patch_history() {
  PATCH_HISTORY=()
  if [ -d "$LOG_DIR" ]; then
    while IFS= read -r f; do
      PATCH_HISTORY+=("$(basename "$f")")
    done < <(ls -t "${LOG_DIR}"/patch_*.log 2>/dev/null | head -5 || true)
  fi
}

# ── JSON output ───────────────────────────────────────────────────────────────
generate_json() {
  local history_json="["
  for i in "${!PATCH_HISTORY[@]}"; do
    history_json+="\"${PATCH_HISTORY[$i]}\""
    [[ $i -lt $(( ${#PATCH_HISTORY[@]} - 1 )) ]] && history_json+=","
  done
  history_json+="]"

  cat > "$JSON_REPORT" <<JSON
{
  "patchpilot_version": "1.0.0",
  "report_type": "compliance",
  "generated_at": "$(date +"%Y-%m-%dT%H:%M:%S%z")",
  "hostname": "${HOSTNAME}",
  "system": {
    "os": "${OS_PRETTY}",
    "os_id": "${OS_ID}",
    "kernel": "${KERNEL}",
    "architecture": "${ARCH}",
    "cpu": "${CPU}",
    "memory_total": "${TOTAL_MEM}",
    "disk_free_root": "${DISK_FREE}",
    "uptime": "${UPTIME}",
    "last_boot": "${LAST_BOOT}"
  },
  "patching": {
    "package_manager": "${PKG_MGR}",
    "total_installed_packages": ${TOTAL_PKGS},
    "pending_updates": ${UPGRADABLE},
    "pending_security_updates": ${SECURITY_UPGRADES},
    "last_patch_run": "${LAST_UPGRADE}",
    "reboot_required": ${REBOOT_REQUIRED}
  },
  "compliance": {
    "score": ${COMPLIANCE_SCORE},
    "grade": "${COMPLIANCE_GRADE}",
    "fully_patched": $([ "$UPGRADABLE" -eq 0 ] && echo true || echo false),
    "security_compliant": $([ "$SECURITY_UPGRADES" -eq 0 ] && echo true || echo false),
    "reboot_pending": ${REBOOT_REQUIRED}
  },
  "patch_history_logs": ${history_json}
}
JSON
  info "JSON report: ${JSON_REPORT}"
}

# ── HTML output ───────────────────────────────────────────────────────────────
generate_html() {
  local score_color
  if   [ "$COMPLIANCE_SCORE" -ge 90 ]; then score_color="#27ae60"
  elif [ "$COMPLIANCE_SCORE" -ge 75 ]; then score_color="#2980b9"
  elif [ "$COMPLIANCE_SCORE" -ge 60 ]; then score_color="#f39c12"
  elif [ "$COMPLIANCE_SCORE" -ge 40 ]; then score_color="#e67e22"
  else score_color="#e74c3c"
  fi

  cat > "$HTML_REPORT" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>PatchPilot Compliance Report — ${HOSTNAME}</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',sans-serif;background:#0f1117;color:#e0e0e0;padding:2rem}
  .container{max-width:900px;margin:auto}
  h1{color:#00d4ff;font-size:2rem;margin-bottom:.25rem}
  .subtitle{color:#888;margin-bottom:2rem;font-size:.9rem}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;margin-bottom:2rem}
  .card{background:#1a1d2e;border-radius:12px;padding:1.5rem;border-left:4px solid #00d4ff}
  .card.warn{border-color:#f39c12}
  .card.danger{border-color:#e74c3c}
  .card.ok{border-color:#27ae60}
  .card-title{font-size:.75rem;text-transform:uppercase;letter-spacing:.1em;color:#888;margin-bottom:.5rem}
  .card-value{font-size:2rem;font-weight:700;color:#fff}
  .card-sub{font-size:.8rem;color:#aaa;margin-top:.25rem}
  .score-circle{display:flex;align-items:center;justify-content:center;width:120px;height:120px;
    border-radius:50%;border:8px solid ${score_color};margin:1rem auto;
    font-size:2.5rem;font-weight:900;color:${score_color}}
  .section{background:#1a1d2e;border-radius:12px;padding:1.5rem;margin-bottom:1.5rem}
  .section h2{color:#00d4ff;font-size:1.1rem;margin-bottom:1rem;border-bottom:1px solid #2a2d3e;padding-bottom:.5rem}
  table{width:100%;border-collapse:collapse}
  td,th{padding:.6rem 1rem;text-align:left;border-bottom:1px solid #2a2d3e;font-size:.9rem}
  th{color:#888;font-weight:600;text-transform:uppercase;font-size:.75rem}
  .badge{display:inline-block;padding:.2rem .6rem;border-radius:4px;font-size:.75rem;font-weight:600}
  .badge-ok{background:#1a3a2a;color:#27ae60}
  .badge-warn{background:#3a2a1a;color:#f39c12}
  .badge-danger{background:#3a1a1a;color:#e74c3c}
  footer{text-align:center;color:#444;font-size:.8rem;margin-top:2rem}
</style>
</head>
<body>
<div class="container">
  <h1>🛡️ PatchPilot Compliance Report</h1>
  <div class="subtitle">Generated: ${DATE_HUMAN} &nbsp;|&nbsp; Host: <strong>${HOSTNAME}</strong></div>

  <div class="cards">
    <div class="card $([ "$UPGRADABLE" -eq 0 ] && echo ok || echo danger)">
      <div class="card-title">Pending Updates</div>
      <div class="card-value">${UPGRADABLE}</div>
      <div class="card-sub">packages upgradable</div>
    </div>
    <div class="card $([ "$SECURITY_UPGRADES" -eq 0 ] && echo ok || echo danger)">
      <div class="card-title">Security Patches</div>
      <div class="card-value">${SECURITY_UPGRADES}</div>
      <div class="card-sub">pending security fixes</div>
    </div>
    <div class="card $($REBOOT_REQUIRED && echo warn || echo ok)">
      <div class="card-title">Reboot Required</div>
      <div class="card-value">$($REBOOT_REQUIRED && echo "YES" || echo "NO")</div>
      <div class="card-sub">kernel/lib updates</div>
    </div>
    <div class="card">
      <div class="card-title">Total Packages</div>
      <div class="card-value">${TOTAL_PKGS}</div>
      <div class="card-sub">installed</div>
    </div>
  </div>

  <div class="section" style="text-align:center">
    <h2>Compliance Score</h2>
    <div class="score-circle">${COMPLIANCE_SCORE}</div>
    <p style="font-size:1.2rem;margin-top:.5rem;color:${score_color}">${COMPLIANCE_GRADE}</p>
  </div>

  <div class="section">
    <h2>System Information</h2>
    <table>
      <tr><th>Property</th><th>Value</th></tr>
      <tr><td>Operating System</td><td>${OS_PRETTY}</td></tr>
      <tr><td>Kernel</td><td>${KERNEL}</td></tr>
      <tr><td>Architecture</td><td>${ARCH}</td></tr>
      <tr><td>CPU</td><td>${CPU}</td></tr>
      <tr><td>Memory</td><td>${TOTAL_MEM}</td></tr>
      <tr><td>Disk Free (/)</td><td>${DISK_FREE}</td></tr>
      <tr><td>Uptime</td><td>${UPTIME}</td></tr>
      <tr><td>Last Boot</td><td>${LAST_BOOT}</td></tr>
      <tr><td>Package Manager</td><td>${PKG_MGR}</td></tr>
      <tr><td>Last Patch Run</td><td>${LAST_UPGRADE}</td></tr>
    </table>
  </div>

  <div class="section">
    <h2>Compliance Checklist</h2>
    <table>
      <tr><th>Check</th><th>Status</th></tr>
      <tr><td>All packages up-to-date</td>
          <td><span class="badge $([ "$UPGRADABLE" -eq 0 ] && echo badge-ok || echo badge-danger)">
            $([ "$UPGRADABLE" -eq 0 ] && echo "✓ PASS" || echo "✗ FAIL (${UPGRADABLE} pending)")</span></td></tr>
      <tr><td>No pending security patches</td>
          <td><span class="badge $([ "$SECURITY_UPGRADES" -eq 0 ] && echo badge-ok || echo badge-danger)">
            $([ "$SECURITY_UPGRADES" -eq 0 ] && echo "✓ PASS" || echo "✗ FAIL (${SECURITY_UPGRADES} pending)")</span></td></tr>
      <tr><td>Reboot not pending</td>
          <td><span class="badge $($REBOOT_REQUIRED && echo badge-warn || echo badge-ok)">
            $($REBOOT_REQUIRED && echo "⚠ REBOOT NEEDED" || echo "✓ PASS")</span></td></tr>
      <tr><td>Patch history exists</td>
          <td><span class="badge $([ "${#PATCH_HISTORY[@]}" -gt 0 ] && echo badge-ok || echo badge-warn)">
            $([ "${#PATCH_HISTORY[@]}" -gt 0 ] && echo "✓ ${#PATCH_HISTORY[@]} log(s) found" || echo "⚠ No logs found")</span></td></tr>
    </table>
  </div>

  <footer>PatchPilot v1.0.0 &nbsp;|&nbsp; Linux Administration Project</footer>
</div>
</body>
</html>
HTML
  info "HTML report: ${HTML_REPORT}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  info "PatchPilot — Compliance Report for ${HOSTNAME}"
  detect_and_collect
  calc_compliance_score
  get_patch_history

  info "Compliance Score : ${COMPLIANCE_SCORE}/100 — ${COMPLIANCE_GRADE}"
  info "Pending Updates  : ${UPGRADABLE}"
  info "Security Patches : ${SECURITY_UPGRADES}"
  info "Reboot Required  : ${REBOOT_REQUIRED}"

  case "$OUTPUT_FORMAT" in
    json) generate_json ;;
    html) generate_html ;;
    *)    generate_json; generate_html ;;
  esac
}

main "$@"
