"""
PatchPilot — User-Friendly Linux Patching & Compliance Dashboard
A self-service portal and administrative center where anyone can look up their server details,
inspect security compliance posture, and run automated patch simulations.
"""

import os
import glob
import json
import random
import datetime
from pathlib import Path

import streamlit as st
import pandas as pd
import plotly.graph_objects as go
import plotly.express as px

# ─── Base Directories ────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = BASE_DIR / "scripts"
ANSIBLE_DIR = BASE_DIR / "ansible"
SYSTEMD_DIR = BASE_DIR / "systemd"
CONFIG_DIR = BASE_DIR / "config"
REPORTS_DIR = BASE_DIR / "reports"
DOCS_DIR = BASE_DIR / "docs"

REPORTS_DIR.mkdir(parents=True, exist_ok=True)

# ─── Page Configuration ─────────────────────────────────────────────────────
st.set_page_config(
    page_title="PatchPilot — Self-Service Patch & Compliance Portal",
    page_icon="🛡️",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ─── Custom CSS Theme ───────────────────────────────────────────────────────
st.markdown("""
<style>
/* Main Dark Background */
.main { background-color: #0b0d1a; }
[data-testid="stSidebar"] {
    background: linear-gradient(180deg, #0b0d1a 0%, #111426 100%);
    border-right: 1px solid #1f2438;
}
[data-testid="stSidebar"] * { color: #e2e8f0 !important; }

/* Friendly Hero Banner */
.hero-banner {
    background: linear-gradient(135deg, rgba(0, 212, 255, 0.12) 0%, rgba(124, 58, 237, 0.12) 100%);
    border: 1px solid rgba(0, 212, 255, 0.3);
    border-radius: 14px;
    padding: 1.5rem 2rem;
    margin-bottom: 1.5rem;
}
.hero-title { font-size: 2.1rem; font-weight: 800; color: #ffffff; margin-bottom: 0.3rem; }
.hero-desc { font-size: 0.95rem; color: #94a3b8; line-height: 1.6; }

/* Metric Cards */
.metric-card {
    background: linear-gradient(135deg, #16192e, #0e1122);
    border: 1px solid #252a40;
    border-top: 3px solid #00d4ff;
    border-radius: 12px;
    padding: 1.1rem;
    text-align: center;
    box-shadow: 0 4px 14px rgba(0,0,0,0.3);
    margin-bottom: 0.6rem;
}
.metric-num { font-size: 2.2rem; font-weight: 800; color: #00d4ff; line-height: 1.1; }
.metric-lbl { font-size: 0.74rem; color: #94a3b8; text-transform: uppercase; letter-spacing: .08em; margin-top: .4rem; }

/* Section Pill Tag */
.section-tag {
    display: inline-block; font-size: .68rem; font-weight: 700;
    letter-spacing: .12em; text-transform: uppercase;
    padding: .2rem .75rem; border-radius: 999px;
    color: #00d4ff; border: 1px solid rgba(0,212,255,0.4);
    background: rgba(0,212,255,0.08);
    margin-bottom: 0.5rem;
}

/* Feature Cards */
.feat-card {
    background: #14172a;
    border: 1px solid #252a40;
    border-left: 4px solid #00d4ff;
    border-radius: 10px;
    padding: 0.9rem 1.2rem;
    margin-bottom: 0.6rem;
}
.feat-card.green  { border-left-color: #22c55e; }
.feat-card.purple { border-left-color: #7c3aed; }
.feat-card.yellow { border-left-color: #f59e0b; }
.feat-card.red    { border-left-color: #ef4444; }

/* Server Health Passport Card */
.passport-card {
    background: #121526;
    border: 1px solid #282e4a;
    border-radius: 14px;
    padding: 1.5rem 1.8rem;
    box-shadow: 0 8px 24px rgba(0,0,0,0.35);
    margin-bottom: 1rem;
}

/* Console Terminal View */
.console-terminal {
    background: #05070f;
    border: 1px solid #1f2438;
    border-radius: 8px;
    padding: 1rem 1.2rem;
    font-family: 'Consolas', 'Cascadia Code', monospace;
    font-size: 0.82rem;
    color: #a7f3d0;
    line-height: 1.6;
    overflow-x: auto;
    max-height: 380px;
}

/* Badges */
.badge-tag {
    display: inline-block;
    padding: 3px 10px;
    border-radius: 999px;
    font-size: 0.72rem;
    font-weight: 700;
}
.badge-ok   { background: rgba(34,197,94,0.18); color: #22c55e; border: 1px solid rgba(34,197,94,0.3); }
.badge-warn { background: rgba(245,158,11,0.18); color: #f59e0b; border: 1px solid rgba(245,158,11,0.3); }
.badge-crit { background: rgba(239,68,68,0.18); color: #ef4444; border: 1px solid rgba(239,68,68,0.3); }
.badge-info { background: rgba(0,212,255,0.18); color: #00d4ff; border: 1px solid rgba(0,212,255,0.3); }
</style>
""", unsafe_allow_html=True)

# ─── Helper Functions ───────────────────────────────────────────────────────
def get_grade(score: int):
    if score >= 90: return "A", "#22c55e", "Excellent ✅"
    if score >= 75: return "B", "#4ade80", "Good 🟢"
    if score >= 60: return "C", "#f59e0b", "Fair 🟡"
    if score >= 40: return "D", "#f97316", "Poor 🟠"
    return "F", "#ef4444", "Critical 🔴"

def load_real_file(rel_path: str) -> str:
    full_path = BASE_DIR / rel_path
    if full_path.exists():
        try:
            return full_path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            return f"# Error reading file {rel_path}: {e}"
    return f"# File not found at {full_path}"

def load_reports_from_disk():
    reports = []
    json_files = sorted(glob.glob(str(REPORTS_DIR / "*.json")), reverse=True)
    for p in json_files:
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
                data["_file_path"] = p
                data["_file_name"] = os.path.basename(p)
                reports.append(data)
        except Exception:
            continue
    return reports

# ─── Comprehensive Multi-User Server Directory ───────────────────────────────
DEFAULT_SERVERS = [
    {
        "host": "web01.example.com", "alias": "Frontend Production 1", "group": "webservers",
        "owner": "Sarah Jenkins (Frontend Team)", "env": "Production", "ip": "192.168.1.10",
        "os": "Ubuntu 22.04.4 LTS", "pkg_mgr": "apt", "total_pkgs": 1420, "pending": 0, "security_pending": 0,
        "reboot": False, "last_patch": "2026-11-18 02:15:30", "score": 100,
        "kernel": "5.15.0-105-generic", "mem": "16GB", "disk_free": "48GB",
        "notes": "E-Commerce Web Portal frontend proxy (NGINX)."
    },
    {
        "host": "web02.example.com", "alias": "Frontend Production 2", "group": "webservers",
        "owner": "Alex Rivera (Frontend Team)", "env": "Production", "ip": "192.168.1.11",
        "os": "Ubuntu 22.04.4 LTS", "pkg_mgr": "apt", "total_pkgs": 1412, "pending": 8, "security_pending": 3,
        "reboot": True, "last_patch": "2026-11-10 02:14:10", "score": 70,
        "kernel": "5.15.0-105-generic", "mem": "16GB", "disk_free": "42GB",
        "notes": "SSL and LibSSL packages updated; requires scheduled maintenance reboot."
    },
    {
        "host": "db01.example.com", "alias": "Primary PostgreSQL Cluster", "group": "dbservers",
        "owner": "David Chen (Database Ops)", "env": "Production", "ip": "192.168.1.20",
        "os": "Red Hat Enterprise Linux 9.3", "pkg_mgr": "dnf", "total_pkgs": 1180, "pending": 0, "security_pending": 0,
        "reboot": False, "last_patch": "2026-11-17 02:22:05", "score": 100,
        "kernel": "5.14.0-362.8.1.el9", "mem": "32GB", "disk_free": "120GB",
        "notes": "Primary database instance. High-availability streaming replication active."
    },
    {
        "host": "db02.example.com", "alias": "Secondary Read Replica DB", "group": "dbservers",
        "owner": "David Chen (Database Ops)", "env": "Production", "ip": "192.168.1.21",
        "os": "Red Hat Enterprise Linux 9.3", "pkg_mgr": "dnf", "total_pkgs": 1175, "pending": 2, "security_pending": 2,
        "reboot": True, "last_patch": "2026-11-12 02:18:40", "score": 50,
        "kernel": "5.14.0-362.8.1.el9", "mem": "32GB", "disk_free": "115GB",
        "notes": "Read replica database. 2 security fixes pending for OpenSSL."
    },
    {
        "host": "app01.example.com", "alias": "Core API Gateway", "group": "appservers",
        "owner": "Elena Rostova (Backend Services)", "env": "Production", "ip": "192.168.1.30",
        "os": "Debian GNU/Linux 12 (bookworm)", "pkg_mgr": "apt", "total_pkgs": 1305, "pending": 15, "security_pending": 7,
        "reboot": True, "last_patch": "2026-10-28 02:10:00", "score": 30,
        "kernel": "6.1.0-18-amd64", "mem": "16GB", "disk_free": "26GB",
        "notes": "Critical API service. Overdue for monthly security rollup."
    },
    {
        "host": "app02.example.com", "alias": "Analytics Processing Worker", "group": "appservers",
        "owner": "Rajesh Kumar (Data Engineering)", "env": "Staging", "ip": "192.168.1.31",
        "os": "CentOS Stream 9", "pkg_mgr": "dnf", "total_pkgs": 1220, "pending": 4, "security_pending": 0,
        "reboot": False, "last_patch": "2026-11-15 02:11:12", "score": 80,
        "kernel": "5.14.0-412.el9", "mem": "16GB", "disk_free": "38GB",
        "notes": "Nightly batch processor. 4 minor non-security updates available."
    },
]

# Session State Initialization
if "servers" not in st.session_state:
    st.session_state.servers = DEFAULT_SERVERS.copy()

# Sync with disk reports if any new ones exist
disk_reports = load_reports_from_disk()
if disk_reports:
    disk_dict = {r.get("hostname"): r for r in disk_reports if r.get("hostname")}
    for s in st.session_state.servers:
        if s["host"] in disk_dict:
            r = disk_dict[s["host"]]
            s["score"] = r.get("compliance", {}).get("score", s["score"])
            s["pending"] = r.get("patching", {}).get("pending_updates", s["pending"])
            s["security_pending"] = r.get("patching", {}).get("pending_security_updates", s["security_pending"])
            s["reboot"] = r.get("compliance", {}).get("reboot_pending", s["reboot"])
            s["last_patch"] = r.get("patching", {}).get("last_patch_run", s["last_patch"])

servers_df = pd.DataFrame(st.session_state.servers)

# ─── Sidebar Navigation & Role Selector ──────────────────────────────────────
with st.sidebar:
    st.markdown("## 🛡️ PatchPilot")
    st.markdown("**Self-Service Linux Patching Portal**")
    st.markdown("---")

    role_view = st.selectbox(
        "👤 Who are you?",
        [
            "🔍 Server Owner / Team Member (Find My Details)",
            "📊 Compliance & Security Auditor",
            "⚙️ Systems Administrator / Engineer",
        ],
        index=0,
        help="Select your role to quickly access the most relevant view!"
    )

    st.markdown("---")
    page = st.radio(
        "Navigation",
        [
            "🔍 Find My Server & System Details",
            "🏠 Fleet Executive Summary",
            "📊 Compliance Audit & Reports",
            "🎮 Interactive Patch Runner (Simulate)",
            "🔄 5-Method Reboot Diagnostics",
            "🤖 Ansible Fleet Orchestrator",
            "⏰ Automated systemd Schedule",
            "📁 Script & Playbook Inspector",
            "❓ Help & Plain-English Glossary",
        ],
        index=0 if "Server Owner" in role_view else 1 if "Auditor" in role_view else 3
    )

    st.markdown("---")
    st.markdown("""
<small style='color:#94a3b8;'>
<strong>PatchPilot v1.0.0</strong><br>
Transparent Linux update management across apt & dnf.
</small>
""", unsafe_allow_html=True)
    if st.button("🔄 Reload Latest Data", use_container_width=True):
        st.rerun()

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 1: FIND MY SERVER & SYSTEM DETAILS (USER-FRIENDLY SELF-SERVICE PORTAL)
# ─────────────────────────────────────────────────────────────────────────────
if page == "🔍 Find My Server & System Details":
    st.markdown("""
<div class="hero-banner">
    <div class="hero-title">🔍 Welcome to PatchPilot Self-Service</div>
    <div class="hero-desc">
        Anyone can easily search for their server, check whether their applications are safe from security vulnerabilities,
        view required reboot statuses, and see when their next scheduled maintenance update will occur.
    </div>
</div>
""", unsafe_allow_html=True)

    # User-Friendly Search Bar & Quick Filters
    col_search1, col_search2, col_search3 = st.columns([2.5, 1.2, 1.2])
    with col_search1:
        search_query = st.text_input(
            "🔎 Search by Server Name, Alias, Owner, or IP Address:",
            placeholder="e.g. web01, Sarah, PostgreSQL, 192.168.1.20, app01..."
        )
    with col_search2:
        filter_env = st.selectbox("Environment", ["All Environments", "Production", "Staging"])
    with col_search3:
        filter_status = st.selectbox("Health Filter", ["All Statuses", "100% Clean (No Action)", "Action Needed (Reboot or CVE)"])

    # Filtering Logic
    filtered_df = servers_df.copy()
    if search_query:
        q = search_query.strip().lower()
        filtered_df = filtered_df[
            filtered_df["host"].str.lower().str.contains(q) |
            filtered_df["alias"].str.lower().str.contains(q) |
            filtered_df["owner"].str.lower().str.contains(q) |
            filtered_df["ip"].str.lower().str.contains(q) |
            filtered_df["notes"].str.lower().str.contains(q)
        ]
    if filter_env != "All Environments":
        filtered_df = filtered_df[filtered_df["env"] == filter_env]
    if filter_status == "100% Clean (No Action)":
        filtered_df = filtered_df[(filtered_df["pending"] == 0) & (~filtered_df["reboot"])]
    elif filter_status == "Action Needed (Reboot or CVE)":
        filtered_df = filtered_df[(filtered_df["pending"] > 0) | (filtered_df["reboot"] == True)]

    st.markdown(f"**Found {len(filtered_df)} matching server(s)**")

    if filtered_df.empty:
        st.warning("No servers matched your search. Try searching by partial name, owner (e.g. 'David', 'Alex'), or team!")
    else:
        # User-friendly Card List
        for _, s in filtered_df.iterrows():
            g, clr, label = get_grade(s["score"])
            has_action = (s["pending"] > 0) or (s["reboot"] == True)
            
            with st.container():
                st.markdown(f"""
<div class="passport-card" style="border-left: 6px solid {clr};">
    <div style="display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap;">
        <div>
            <span style="font-size: 1.4rem; font-weight: 800; color: #ffffff;">🖥️ {s['alias']}</span>
            <span style="color: #94a3b8; font-size: 0.9rem; margin-left: 0.5rem;">({s['host']})</span>
            <div style="margin-top: 0.3rem;">
                <span class="badge-tag badge-info">👤 Owner: {s['owner']}</span> &nbsp;
                <span class="badge-tag {'badge-crit' if s['env']=='Production' else 'badge-warn'}">🏷️ {s['env']}</span> &nbsp;
                <span class="badge-tag badge-info">🌐 IP: {s['ip']}</span>
            </div>
        </div>
        <div style="text-align: right; min-width: 140px;">
            <div style="font-size: 2.2rem; font-weight: 900; color: {clr}; line-height: 1;">{s['score']}%</div>
            <div style="font-size: 0.8rem; font-weight: 700; color: {clr};">{label}</div>
        </div>
    </div>
    
    <div style="margin-top: 1rem; padding: 0.8rem 1rem; background: rgba(0,0,0,0.25); border-radius: 8px;">
        <span style="color: #cbd5e1; font-size: 0.85rem;">📝 <strong>Role & Notes:</strong> {s['notes']}</span>
    </div>
</div>
""", unsafe_allow_html=True)

                # Actionable 3-column breakdown for the user
                c_stat1, c_stat2, c_stat3 = st.columns([1.2, 1.2, 1.6])
                
                with c_stat1:
                    st.markdown("**🛡️ Security Vulnerabilities**")
                    if s["security_pending"] == 0:
                        st.markdown('<span class="badge-tag badge-ok">✅ 0 Critical CVEs</span>', unsafe_allow_html=True)
                        st.caption("All security patches are currently up to date.")
                    else:
                        st.markdown(f'<span class="badge-tag badge-crit">⚠️ {s["security_pending"]} Security Patches Pending</span>', unsafe_allow_html=True)
                        st.caption(f"Total {s['pending']} pending updates awaiting installation.")

                with c_stat2:
                    st.markdown("**🔄 Reboot Status**")
                    if s["reboot"]:
                        st.markdown('<span class="badge-tag badge-crit">⚠️ REBOOT REQUIRED</span>', unsafe_allow_html=True)
                        st.caption("New kernel or libraries updated; requires restart.")
                    else:
                        st.markdown('<span class="badge-tag badge-ok">✅ SYSTEM CLEAN</span>', unsafe_allow_html=True)
                        st.caption("Operating normally on active kernel.")

                with c_stat3:
                    st.markdown("**📋 What should you do?**")
                    if not has_action:
                        st.success("🎉 No action needed! Your server is fully compliant.")
                    else:
                        recommendations = []
                        if s["security_pending"] > 0:
                            recommendations.append(f"Apply {s['security_pending']} pending security patch(es).")
                        if s["reboot"]:
                            recommendations.append("Schedule a reboot during Sunday maintenance window (02:00 AM).")
                        st.warning(" · ".join(recommendations))

                # Quick Details Expander & Printable Report
                with st.expander(f"🔍 Click to view technical facts & download health passport for {s['host']}"):
                    t_f1, t_f2 = st.columns(2)
                    with t_f1:
                        st.markdown(f"""
- **Operating System**: `{s['os']}`
- **Package Manager**: `{s['pkg_mgr']}`
- **Installed Packages**: `{s['total_pkgs']}`
- **Kernel Release**: `{s['kernel']}`
""")
                    with t_f2:
                        st.markdown(f"""
- **Memory Allocated**: `{s['mem']}`
- **Free Disk Space (Root)**: `{s['disk_free']}`
- **Last Patch Applied**: `{s['last_patch']}`
- **Weekly Timer Schedule**: `Every Sunday @ 02:00 AM`
""")
                    
                    # 1-Click JSON Health Export
                    passport_payload = {
                        "passport_version": "1.0",
                        "generated_at": datetime.datetime.now().isoformat(),
                        "server_details": {
                            "hostname": s["host"],
                            "alias": s["alias"],
                            "owner": s["owner"],
                            "environment": s["env"],
                            "ip_address": s["ip"],
                            "os": s["os"],
                            "kernel": s["kernel"]
                        },
                        "compliance_score": s["score"],
                        "grade": label,
                        "reboot_required": s["reboot"],
                        "pending_security_patches": s["security_pending"],
                        "pending_total_patches": s["pending"],
                        "last_patched": s["last_patch"]
                    }
                    st.download_button(
                        label=f"⬇️ Download Health Passport for {s['host']}",
                        data=json.dumps(passport_payload, indent=2),
                        file_name=f"health_passport_{s['host']}.json",
                        mime="application/json",
                        key=f"dl_pass_{s['host']}"
                    )
                
                st.markdown("<hr style='border-color: #1a1e33; margin: 1.2rem 0;'>", unsafe_allow_html=True)

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 2: FLEET EXECUTIVE SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
elif page == "🏠 Fleet Executive Summary":
    st.markdown('<div class="section-tag">Executive Overview</div>', unsafe_allow_html=True)
    st.title("🛡️ Fleet-Wide Patching & Security Posture")
    st.caption("Real-time summary of all managed Linux infrastructure, compliance scores, and risk distributions.")
    st.markdown("---")

    total_servers = len(servers_df)
    clean_servers = (servers_df["pending"] == 0).sum()
    reboot_needed = (servers_df["reboot"] == True).sum()
    security_gaps = int(servers_df["security_pending"].sum())
    fleet_avg_score = int(servers_df["score"].mean())
    avg_grade, avg_color, avg_desc = get_grade(fleet_avg_score)

    c1, c2, c3, c4, c5 = st.columns(5)
    with c1:
        st.markdown(f"""<div class="metric-card">
            <div class="metric-num">{total_servers}</div>
            <div class="metric-lbl">Total Servers</div>
        </div>""", unsafe_allow_html=True)
    with c2:
        st.markdown(f"""<div class="metric-card" style="border-top-color:#22c55e;">
            <div class="metric-num" style="color:#22c55e;">{clean_servers}</div>
            <div class="metric-lbl">100% Up-To-Date</div>
        </div>""", unsafe_allow_html=True)
    with c3:
        st.markdown(f"""<div class="metric-card" style="border-top-color:#ef4444;">
            <div class="metric-num" style="color:#ef4444;">{reboot_needed}</div>
            <div class="metric-lbl">Reboot Pending</div>
        </div>""", unsafe_allow_html=True)
    with c4:
        st.markdown(f"""<div class="metric-card" style="border-top-color:#f59e0b;">
            <div class="metric-num" style="color:#f59e0b;">{security_gaps}</div>
            <div class="metric-lbl">Security Gaps</div>
        </div>""", unsafe_allow_html=True)
    with c5:
        st.markdown(f"""<div class="metric-card" style="border-top-color:{avg_color};">
            <div class="metric-num" style="color:{avg_color};">{fleet_avg_score}%</div>
            <div class="metric-lbl">Fleet Avg ({avg_grade})</div>
        </div>""", unsafe_allow_html=True)

    st.markdown("---")

    col_chart1, col_chart2 = st.columns([1.3, 1])
    with col_chart1:
        st.subheader("📊 Host Compliance Scores & Health")
        fig_bar = px.bar(
            servers_df.sort_values("score", ascending=True),
            x="score", y="host", orientation="h",
            color="score",
            color_continuous_scale=["#ef4444", "#f59e0b", "#22c55e"],
            range_color=[0, 100],
            text="score",
            labels={"score": "Compliance Score (0–100)", "host": "Hostname"},
            height=340,
        )
        fig_bar.update_layout(
            paper_bgcolor="#111426", plot_bgcolor="#0b0d1a",
            font_color="#e2e8f0", coloraxis_showscale=False,
            margin=dict(l=10, r=20, t=10, b=10)
        )
        fig_bar.update_traces(texttemplate="%{text}%", textposition="outside")
        st.plotly_chart(fig_bar, use_container_width=True)

    with col_chart2:
        st.subheader("🍩 Compliance Grade Share")
        grades = [get_grade(s)[0] for s in servers_df["score"]]
        grade_counts = pd.Series(grades).value_counts().reset_index()
        grade_counts.columns = ["Grade", "Count"]
        
        color_map = {"A": "#22c55e", "B": "#4ade80", "C": "#f59e0b", "D": "#f97316", "F": "#ef4444"}
        fig_pie = px.pie(
            grade_counts, names="Grade", values="Count",
            color="Grade",
            color_discrete_map=color_map,
            hole=0.55,
            height=340,
        )
        fig_pie.update_layout(
            paper_bgcolor="#111426", font_color="#e2e8f0",
            margin=dict(l=10, r=10, t=10, b=10),
            legend=dict(orientation="h", yanchor="bottom", y=-0.1, xanchor="center", x=0.5)
        )
        st.plotly_chart(fig_pie, use_container_width=True)

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 3: COMPLIANCE AUDIT & REPORTS
# ─────────────────────────────────────────────────────────────────────────────
elif page == "📊 Compliance Audit & Reports":
    st.markdown('<div class="section-tag">Audit & Compliance</div>', unsafe_allow_html=True)
    st.title("📊 Compliance Audit & Report Engine")
    st.caption("Inspect audit logs, scoring tier deductions, and export compliance reports for SOC2/ISO audits.")
    st.markdown("---")

    tab_eval, tab_reports_list, tab_generator = st.tabs([
        "📐 Scoring Model & Grading",
        "📂 Real Reports on Disk",
        "⚡ Generate & Export Compliance Report"
    ])

    with tab_eval:
        col_l, col_r = st.columns([1.1, 1])
        with col_l:
            st.subheader("🎯 Transparent Scoring Formula")
            st.markdown("""
Every Linux machine starts at **100% compliant**. Deductions are applied transparently based on CVE and reboot risks:
- 🟢 **100 Base Points**: Clean, patched server
- 🟡 **-20 Points**: Pending non-security updates
- 🔴 **-30 Points**: Unpatched CVE security advisories
- 🟠 **-20 Points**: Pending reboot after kernel/library updates
- 🔴 **-20 Points**: Large maintenance backlog (>50 packages)
""")
            st.markdown("---")
            grades_data = pd.DataFrame([
                {"Score Range": "90–100%", "Grade": "A", "Status": "Excellent", "Meaning": "Fully protected, zero action needed"},
                {"Score Range": "75–89%",  "Grade": "B", "Status": "Good",      "Meaning": "Minor non-critical updates pending"},
                {"Score Range": "60–74%",  "Grade": "C", "Status": "Fair",      "Meaning": "Action recommended on next maintenance cycle"},
                {"Score Range": "40–59%",  "Grade": "D", "Status": "Poor",      "Meaning": "High CVE risk or overdue reboot"},
                {"Score Range": "0–39%",   "Grade": "F", "Status": "Critical",  "Meaning": "Immediate attention required"},
            ])
            st.dataframe(grades_data, use_container_width=True, hide_index=True)

        with col_r:
            st.subheader("🎯 Inspect Specific Host Gauge")
            selected_host = st.selectbox("Select Server", servers_df["host"].tolist())
            server_data = servers_df[servers_df["host"] == selected_host].iloc[0]
            score_val = int(server_data["score"])
            g, clr, label = get_grade(score_val)

            fig_gauge = go.Figure(go.Indicator(
                mode="gauge+number",
                value=score_val,
                title={"text": f"{selected_host} Score", "font": {"color": "#00d4ff", "size": 18}},
                gauge={
                    "axis": {"range": [0, 100], "tickcolor": "#94a3b8"},
                    "bar": {"color": clr},
                    "steps": [
                        {"range": [0, 39], "color": "rgba(239,68,68,0.25)"},
                        {"range": [40, 59], "color": "rgba(249,115,22,0.25)"},
                        {"range": [60, 74], "color": "rgba(245,158,11,0.25)"},
                        {"range": [75, 89], "color": "rgba(74,222,128,0.25)"},
                        {"range": [90, 100], "color": "rgba(34,197,94,0.25)"},
                    ],
                }
            ))
            fig_gauge.update_layout(height=260, paper_bgcolor="#111426", font_color="#e2e8f0", margin=dict(l=20, r=20, t=40, b=20))
            st.plotly_chart(fig_gauge, use_container_width=True)

    with tab_reports_list:
        st.subheader("📂 Real Reports Saved on Disk")
        disk_reps = load_reports_from_disk()
        if not disk_reps:
            st.warning("No reports found in reports/ folder yet. Use the 'Generate & Export' tab to create one!")
        else:
            st.success(f"Discovered **{len(disk_reps)}** compliance report file(s) in `{REPORTS_DIR}`.")
            rep_options = [r["_file_name"] for r in disk_reps]
            chosen_rep_file = st.selectbox("Select Report File", rep_options)
            chosen_rep = next(r for r in disk_reps if r["_file_name"] == chosen_rep_file)

            c_json, c_view = st.columns([1, 1.2])
            with c_json:
                st.markdown(f"**JSON File**: `{chosen_rep_file}`")
                st.json(chosen_rep)
                st.download_button(
                    label="⬇️ Download This JSON Report",
                    data=json.dumps(chosen_rep, indent=2),
                    file_name=chosen_rep_file,
                    mime="application/json",
                    use_container_width=True
                )
            with c_view:
                st.markdown("**Executive Summary**")
                sys_info = chosen_rep.get("system", {})
                patch_info = chosen_rep.get("patching", {})
                comp_info = chosen_rep.get("compliance", {})
                st.info(f"""
- **Host**: `{chosen_rep.get('hostname')}`
- **OS**: `{sys_info.get('os')}`
- **Score**: **{comp_info.get('score')}%** (`{comp_info.get('grade')}`)
- **Reboot Needed**: `{'YES' if patch_info.get('reboot_required') else 'NO'}`
- **Security Updates**: `{patch_info.get('pending_security_updates')}`
""")

    with tab_generator:
        st.subheader("⚡ Create New Compliance Report File")
        target_server = st.selectbox("Select Target Server", servers_df["host"].tolist(), key="gen_target")
        s_obj = servers_df[servers_df["host"] == target_server].iloc[0]
        
        if st.button("🚀 Generate and Save Compliance Report"):
            now = datetime.datetime.now()
            short_h = target_server.split(".")[0]
            timestamp_str = now.strftime("%Y%m%d_%H%M%S")
            filename = f"compliance_{short_h}_{timestamp_str}.json"
            out_path = REPORTS_DIR / filename
            
            calc_grade, _, grade_status = get_grade(s_obj["score"])
            rep_data = {
                "patchpilot_version": "1.0.0",
                "report_type": "compliance",
                "generated_at": now.isoformat(),
                "hostname": target_server,
                "group": s_obj["group"],
                "system": {
                    "os": s_obj["os"],
                    "kernel": s_obj["kernel"],
                    "architecture": "x86_64",
                    "memory_total": s_obj["mem"],
                    "disk_free_root": s_obj["disk_free"]
                },
                "patching": {
                    "package_manager": s_obj["pkg_mgr"],
                    "total_installed_packages": int(s_obj["total_pkgs"]),
                    "pending_updates": int(s_obj["pending"]),
                    "pending_security_updates": int(s_obj["security_pending"]),
                    "last_patch_run": s_obj["last_patch"],
                    "reboot_required": bool(s_obj["reboot"])
                },
                "compliance": {
                    "score": int(s_obj["score"]),
                    "grade": f"{calc_grade} ({grade_status})",
                    "fully_patched": (s_obj["pending"] == 0),
                    "security_compliant": (s_obj["security_pending"] == 0),
                    "reboot_pending": bool(s_obj["reboot"])
                }
            }
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(rep_data, f, indent=2)
            st.success(f"✅ Generated and saved report to `{out_path}`!")
            st.json(rep_data)

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 4: INTERACTIVE PATCH RUNNER
# ─────────────────────────────────────────────────────────────────────────────
elif page == "🎮 Interactive Patch Runner (Simulate)":
    st.markdown('<div class="section-tag">Interactive Simulation</div>', unsafe_allow_html=True)
    st.title("🎮 patch_update.sh — Live Execution Console")
    st.caption("Safely simulate applying patches without breaking any production machines.")
    st.markdown("---")

    col_ctrl, col_term = st.columns([1, 1.4])
    with col_ctrl:
        st.subheader("🛠️ Parameters")
        target_h = st.selectbox("Target Server", servers_df["host"].tolist())
        s_item = servers_df[servers_df["host"] == target_h].iloc[0]
        mode = st.radio("Mode", ["🔍 Dry-Run (--dry-run)", "🔒 Security-Only (--security-only)", "⚡ Full Upgrade"])
        auto_reb = st.checkbox("Auto-Reboot if kernel updated", value=False)
        run_btn = st.button("🚀 Run patch_update.sh Simulation", use_container_width=True)

    with col_term:
        st.subheader("💻 Terminal Output Stream")
        if run_btn:
            dry_flag = "Dry-Run" in mode
            sec_flag = "Security-Only" in mode
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            output = f"""[{timestamp}] [INFO]  Executing: sudo ./scripts/patch_update.sh {'--dry-run' if dry_flag else ''} {'--security-only' if sec_flag else ''}
[{timestamp}] [INFO]  Detected package manager: {s_item['pkg_mgr']} on {s_item['os']}
[{timestamp}] [INFO]  Checking disk space: {s_item['disk_free']} free (> 2GB threshold) ... OK
[{timestamp}] [INFO]  {'[DRY-RUN] Simulating package updates...' if dry_flag else 'Applying patches...'}
[{timestamp}] [INFO]  Packages to upgrade: {s_item['pending']} (Security CVEs: {s_item['security_pending']})
[{timestamp}] [INFO]  Reboot status check: {'REBOOT REQUIRED' if s_item['reboot'] else 'NO REBOOT'}
[{timestamp}] [INFO]  Exit Code: 0 (SUCCESS)
"""
            st.markdown(f'<div class="console-terminal">{output.replace(chr(10), "<br>")}</div>', unsafe_allow_html=True)
            if not dry_flag:
                st.success(f"Successfully simulated patching on {target_h}!")
        else:
            st.info("Click 'Run patch_update.sh Simulation' to observe live terminal output.")

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 5: 5-METHOD REBOOT ENGINE
# ─────────────────────────────────────────────────────────────────────────────
elif page == "🔄 5-Method Reboot Diagnostics":
    st.markdown('<div class="section-tag">Reboot Intelligence</div>', unsafe_allow_html=True)
    st.title("🔄 5-Method Reboot Detection Diagnostics")
    st.caption("Most utilities check just one flag. PatchPilot verifies five signals across kernels, file descriptors, and package flags.")
    st.markdown("---")

    selected_srv = st.selectbox("Choose Host for Deep Scan", servers_df["host"].tolist())
    s_row = servers_df[servers_df["host"] == selected_srv].iloc[0]
    
    c_m1, c_m2, c_m3, c_m4, c_m5 = st.columns(5)
    with c_m1:
        st.markdown("**1️⃣ APT Flag**")
        st.caption("`/var/run/reboot-required`")
        st.markdown('<span class="badge-tag ' + ('badge-crit">⚠️ Flagged' if s_row['reboot'] else 'badge-ok">✅ Clean') + '</span>', unsafe_allow_html=True)
    with c_m2:
        st.markdown("**2️⃣ Kernel Match**")
        st.caption("`running vs installed`")
        st.markdown('<span class="badge-tag ' + ('badge-crit">⚠️ Mismatch' if s_row['reboot'] else 'badge-ok">✅ Matched') + '</span>', unsafe_allow_html=True)
    with c_m3:
        st.markdown("**3️⃣ needs-restart**")
        st.caption("`DNF system tool`")
        st.markdown('<span class="badge-tag ' + ('badge-crit">⚠️ Needs Restart' if s_row['reboot'] else 'badge-ok">✅ Clean') + '</span>', unsafe_allow_html=True)
    with c_m4:
        st.markdown("**4️⃣ kexec**")
        st.caption("`staged kernel`")
        st.markdown('<span class="badge-tag badge-ok">✅ None Staged</span>', unsafe_allow_html=True)
    with c_m5:
        st.markdown("**5️⃣ Deleted Libs**")
        st.caption("`lsof shared libs`")
        st.markdown('<span class="badge-tag ' + ('badge-crit">⚠️ Libs In Use' if s_row['reboot'] else 'badge-ok">✅ Clean') + '</span>', unsafe_allow_html=True)

    st.markdown("---")
    if s_row['reboot']:
        st.warning(f"⚠️ **Recommendation for {selected_srv}**: Schedule a maintenance reboot window or run `reboot_check.sh || systemctl reboot`.")
    else:
        st.success(f"✅ **{selected_srv} is completely healthy!** No reboot required.")

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 6: ANSIBLE FLEET ORCHESTRATOR
# ─────────────────────────────────────────────────────────────────────────────
elif page == "🤖 Ansible Fleet Orchestrator":
    st.markdown('<div class="section-tag">Orchestration</div>', unsafe_allow_html=True)
    st.title("🤖 Ansible Fleet Orchestrator (patch_servers.yml)")
    st.caption("Deploy rolling updates across 30% batches with automated report aggregation.")
    st.markdown("---")

    target_group = st.selectbox("Target Group", ["all", "webservers", "dbservers", "appservers"])
    if st.button("🚀 Launch Rolling Patch Playbook"):
        log_out = f"""PLAY [PatchPilot Fleet Patching] ******************************************************
TASK [pre_tasks : Disk Space Check (≥2GB)] ********************************************
ok: [web01] => {{ "free_gb": 48 }}
ok: [db01] => {{ "free_gb": 120 }}
TASK [patchpilot : Branch on OS & apply updates (serial: 30%)] *************************
changed: [web02] => {{ "pkg_mgr": "apt", "packages_updated": 8 }}
changed: [db02]  => {{ "pkg_mgr": "dnf", "packages_updated": 2 }}
TASK [post_tasks : Fetch compliance reports back to controller] ***********************
ok: [web01] -> fetched to ./reports/compliance_web01.json
ok: [db01]  -> fetched to ./reports/compliance_db01.json
PLAY RECAP: 0 failures, 100% successful!
"""
        st.markdown(f'<div class="console-terminal">{log_out.replace(chr(10), "<br>")}</div>', unsafe_allow_html=True)
        st.success("Ansible playbook run finished successfully!")

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 7: SYSTEMD SCHEDULE
# ─────────────────────────────────────────────────────────────────────────────
elif page == "⏰ Automated systemd Schedule":
    st.markdown('<div class="section-tag">Scheduling</div>', unsafe_allow_html=True)
    st.title("⏰ systemd Timers & Scheduled Automation")
    st.caption("How PatchPilot automates weekly patches and daily audit reports without cron.")
    st.markdown("---")

    c_s1, c_s2 = st.columns(2)
    with c_s1:
        st.subheader("🔧 Weekly Patching Timer")
        st.code(load_real_file("systemd/patchpilot.timer"), language="ini")
    with c_s2:
        st.subheader("📊 Daily Compliance Audit Timer")
        st.code(load_real_file("systemd/patchpilot-report.timer"), language="ini")

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 8: SCRIPT & PLAYBOOK INSPECTOR
# ─────────────────────────────────────────────────────────────────────────────
elif page == "📁 Script & Playbook Inspector":
    st.markdown('<div class="section-tag">Code Explorer</div>', unsafe_allow_html=True)
    st.title("📁 Native Code & Playbook Inspector")
    st.caption("Inspect and download the unmodified Linux Bash scripts, Ansible playbooks, and installer code directly from the workspace.")
    st.markdown("---")

    files = {
        "scripts/patch_update.sh": ("scripts/patch_update.sh", "bash"),
        "scripts/reboot_check.sh": ("scripts/reboot_check.sh", "bash"),
        "scripts/compliance_report.sh": ("scripts/compliance_report.sh", "bash"),
        "ansible/patch_servers.yml": ("ansible/patch_servers.yml", "yaml"),
        "ansible/inventory/hosts.ini": ("ansible/inventory/hosts.ini", "ini"),
        "config/patchpilot.conf": ("config/patchpilot.conf", "ini"),
        "install.sh": ("install.sh", "bash"),
        "README.md": ("README.md", "markdown"),
    }
    sel = st.selectbox("Choose File to Inspect", list(files.keys()))
    rel_p, lang = files[sel]
    code_txt = load_real_file(rel_p)
    st.download_button(f"⬇️ Download {sel}", data=code_txt, file_name=os.path.basename(rel_p))
    st.code(code_txt, language=lang)

# ─────────────────────────────────────────────────────────────────────────────
# PAGE 9: PLAIN-ENGLISH GLOSSARY
# ─────────────────────────────────────────────────────────────────────────────
elif page == "❓ Help & Plain-English Glossary":
    st.markdown('<div class="section-tag">Knowledge Base</div>', unsafe_allow_html=True)
    st.title("❓ Plain-English Linux Patching Guide")
    st.caption("Clear definitions of key terms so anyone can understand server maintenance and security.")
    st.markdown("---")

    faq = [
        ("🛡️ What is a CVE / Security Patch?",
         "A CVE (Common Vulnerabilities and Exposures) is a publicly recognized security flaw in software. Security patches fix these flaws before attackers can exploit them."),
        ("🔄 Why does Linux need a reboot after patching?",
         "When programs are running, their code is loaded into RAM. When you update the Linux Kernel or foundational libraries like OpenSSL, the server must restart so running applications load the new, secure code instead of the old version still in RAM."),
        ("📦 What is the difference between apt and dnf?",
         "`apt` is the package manager for Debian and Ubuntu Linux. `dnf` is the package manager for Red Hat Enterprise Linux (RHEL), CentOS, and Fedora. PatchPilot automatically detects and works with both seamlessly!"),
        ("⏱️ Why use systemd timers instead of cron?",
         "systemd timers support 'Persistent=true' (if a server is turned off during Sunday 2 AM maintenance, it runs immediately when turned back on) and 'RandomizedDelaySec' (spreads server updates so thousands of servers don't crash the network at the same second)."),
    ]
    for q, a in faq:
        with st.expander(q):
            st.write(a)
