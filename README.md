# PatchPilot 🛡️

> **Automate package updates, security patches, reboot checks, and patch-compliance reporting across Linux servers.**

[![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black)](https://kernel.org)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ansible](https://img.shields.io/badge/Ansible-EE0000?style=flat&logo=ansible&logoColor=white)](https://www.ansible.com)
[![systemd](https://img.shields.io/badge/systemd-000000?style=flat&logo=systemd&logoColor=white)](https://systemd.io)

---

## 📋 Project Overview

**PatchPilot** is a Linux administration project that automates the full patch management lifecycle across heterogeneous Linux servers (Debian/Ubuntu via `apt`, RHEL/CentOS/Fedora via `dnf`). It uses Bash scripting for local execution, Ansible for fleet-wide orchestration, and systemd for scheduling — producing actionable compliance reports in JSON and HTML.

---

## 🏗️ Project Structure

```
patchpilot/
├── scripts/
│   ├── patch_update.sh        # Core patching script (apt + dnf)
│   ├── reboot_check.sh        # Multi-method reboot detection
│   └── compliance_report.sh   # JSON + HTML compliance reports
├── ansible/
│   ├── ansible.cfg            # Ansible configuration
│   ├── patch_servers.yml      # Main playbook
│   ├── inventory/
│   │   └── hosts.ini          # Host groups & variables
│   └── roles/
│       └── patchpilot/
│           ├── tasks/main.yml      # Patching tasks (apt + dnf)
│           ├── handlers/main.yml   # Service restart handlers
│           ├── defaults/main.yml   # Default variables
│           └── templates/
│               └── compliance_report.json.j2
├── systemd/
│   ├── patchpilot.service          # Patch service unit
│   ├── patchpilot.timer            # Weekly Sunday 02:00 timer
│   ├── patchpilot-report.service   # Report service unit
│   └── patchpilot-report.timer     # Daily 06:00 report timer
├── reports/                        # Generated reports land here
├── install.sh                      # One-shot installer
└── README.md
```

---

## ⚙️ Technologies Used

| Technology | Purpose |
|---|---|
| **Bash** | Core patch automation scripts |
| **apt / apt-get** | Debian/Ubuntu package management |
| **unattended-upgrades** | Debian security-only patching |
| **dnf / yum** | RHEL/CentOS/Fedora package management |
| **Ansible** | Fleet-wide orchestration & rolling updates |
| **systemd** | Scheduling via `.service` + `.timer` units |
| **JSON / HTML** | Structured compliance reporting |

---

## 🚀 Quick Start

### 1. Local Single-Server Install
```bash
# Clone / copy project
git clone https://github.com/yourorg/patchpilot.git
cd patchpilot

# Install (requires root)
sudo bash install.sh
```

### 2. Run Patches Manually
```bash
# Full update
sudo patch_update.sh

# Security patches only
sudo patch_update.sh --security-only

# Dry-run (no changes made)
sudo patch_update.sh --dry-run

# Security + auto-reboot if needed
sudo patch_update.sh --security-only --auto-reboot
```

### 3. Check Reboot Status
```bash
sudo reboot_check.sh
echo $?   # 0 = no reboot needed, 1 = reboot required
```

### 4. Generate Compliance Report
```bash
sudo compliance_report.sh           # JSON + HTML
sudo compliance_report.sh json      # JSON only
sudo compliance_report.sh html      # HTML only
# Output: /var/lib/patchpilot/reports/
```

---

## 🤖 Ansible Fleet Patching

### Prerequisites
```bash
pip install ansible
# Configure SSH key-based access to all hosts
```

### Edit Inventory
```ini
# ansible/inventory/hosts.ini
[webservers]
web01.example.com ansible_user=ubuntu
web02.example.com ansible_user=ubuntu
```

### Run Playbook
```bash
cd ansible/

# Full update on all servers (rolling 30%)
ansible-playbook patch_servers.yml

# Security only
ansible-playbook patch_servers.yml -e "security_only=true"

# Target specific group
ansible-playbook patch_servers.yml -e "target_hosts=webservers"

# Security + auto-reboot
ansible-playbook patch_servers.yml -e "security_only=true auto_reboot=true"

# Dry-run (check mode)
ansible-playbook patch_servers.yml --check

# Verbose output
ansible-playbook patch_servers.yml -v
```

---

## ⏱️ systemd Scheduling

```
Weekly Patch:  Every Sunday at 02:00 (±30 min jitter)
Daily Report:  Every day at 06:00
```

### Timer Commands
```bash
# View active timers
systemctl list-timers patchpilot*

# View patch service logs
journalctl -u patchpilot -f

# View report service logs
journalctl -u patchpilot-report -f

# Run patch now (don't wait for timer)
systemctl start patchpilot.service

# Disable timer
systemctl disable patchpilot.timer
```

---

## 📊 Compliance Scoring

| Score | Grade | Meaning |
|---|---|---|
| 90–100 | **A — Excellent** | Fully patched, no reboot pending |
| 75–89  | **B — Good** | Minor pending updates |
| 60–74  | **C — Fair** | Some security updates pending |
| 40–59  | **D — Poor** | Multiple security issues |
| 0–39   | **F — Critical** | Critical patches unaddressed |

**Deductions:**
- -20 pts: Any pending updates
- -30 pts: Pending security patches
- -20 pts: Reboot required
- -20 pts: >50 packages pending

---

## 📁 Log & Report Locations

```
/var/log/patchpilot/           ← All patch logs
/var/lib/patchpilot/reports/   ← JSON + HTML reports
  ├── patch_report_<host>_<ts>.json
  ├── reboot_check_<host>_<ts>.json
  ├── compliance_<host>_<ts>.json
  └── compliance_<host>_<ts>.html
```

Ansible also fetches reports to `./reports/<hostname>/` on the controller.

---

## 🔒 Security Considerations

- Scripts run as `root` via `sudo`; restrict sudo access to patch scripts only
- Use SSH key-based authentication for Ansible (no password auth)
- `PrivateTmp=true` in systemd unit isolates `/tmp`
- Rolling serial batches (30%) prevent fleet-wide outages
- DB servers default to `security_only=true`, `auto_reboot=false`

---

## 📚 Learning Outcomes (Course Alignment)

| Concept | Implementation |
|---|---|
| Package management | `apt`, `dnf` modules; `unattended-upgrades` |
| Shell scripting | Bash scripts with error handling, logging |
| Configuration management | Ansible roles, playbooks, templates |
| System scheduling | systemd `.service` + `.timer` units |
| Monitoring & reporting | JSON + HTML reports; compliance scoring |
| Security hardening | Security-only mode, privilege separation |

---

*PatchPilot — Linux Administration Course Project*
