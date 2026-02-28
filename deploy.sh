#!/usr/bin/env bash
# =============================================================================
#
#   OpenStack Complete — Master Deployment & Management Script  (v2)
#   Ubuntu Server 24.04 LTS | OpenStack 2024.1 Caracal
#
#   Everything in one place:
#     • Base OpenStack (Keystone → Horizon)
#     • Extra services (Cinder, Swift, Heat, Barbican, Designate…)
#     • Multi-node support (Controller / Compute / Storage)
#     • Health Dashboard & Alerts
#     • Backup & Disaster Recovery
#     • Kubernetes on OpenStack
#     • SSL Certificate Management
#     • Server Hardening & Security Audit
#
#   USAGE:  sudo bash deploy.sh [FLAGS]
#
#   FLAGS:
#     --wizard            Re-run the Setup Wizard
#     --full              Deploy everything configured in main.env
#     --base              Base OpenStack only
#     --services          Extra services only
#     --multinode         Multi-node setup
#     --k8s               Deploy Kubernetes
#     --monitor           Open health dashboard
#     --backup            Run a backup
#     --restore           Restore from backup
#     --harden            Harden + audit the server
#     --ssl               Manage SSL certificates
#     --verify            Check all services
#     --config            Show current configuration
#     --resume            Resume a previously interrupted deployment
#     --dry-run           Print every action without executing (can combine with others)
#     --help              Show this help text
#
# =============================================================================

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${PROJ}/configs/main.env"
LIB="${PROJ}/scripts/lib.sh"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="${PROJ}/logs"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"

# ─── DRY-RUN FLAG (must be parsed before sourcing lib.sh) ─────────────────────
DRY_RUN=false
RESUME_MODE=false
for arg in "$@"; do
    [[ "${arg}" == "--dry-run" ]] && DRY_RUN=true
    [[ "${arg}" == "--resume"  ]] && RESUME_MODE=true
done
export DRY_RUN

# ─── SOURCE CONFIG & LIBRARY ──────────────────────────────────────────────────
[[ -f "${CONFIG}" ]] || { echo "ERROR: configs/main.env not found."; exit 1; }
source "${CONFIG}"
source "${LIB}"

# ─── ATTEMPT TO LOAD SECRETS FILE ─────────────────────────────────────────────
# lib.sh v2 provides safe_source_secrets(). Loads .secrets.env or .secrets.enc
# if present, overriding the placeholder passwords in main.env.
safe_source_secrets "${PROJ}/configs/.secrets.env" 2>/dev/null || true

mkdir -p "${LOG_DIR}"

# ─── COLOURS (re-declare for safety, in case lib.sh wasn't sourced yet) ───────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── CHECKPOINT FILE (for --resume) ───────────────────────────────────────────
CHECKPOINT_FILE="${LOG_DIR}/.deployment_checkpoint"
export CHECKPOINT_FILE

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║                                                               ║
  ║    ██████╗ ██████╗ ███████╗███╗  ██╗███████╗████████╗        ║
  ║   ██╔═══██╗██╔══██╗██╔════╝████╗ ██║██╔════╝╚══██╔══╝        ║
  ║   ██║   ██║██████╔╝█████╗  ██╔██╗██║███████╗   ██║           ║
  ║   ██║   ██║██╔═══╝ ██╔══╝  ██║╚████║╚════██║   ██║           ║
  ║   ╚██████╔╝██║     ███████╗██║ ╚███║███████║   ██║           ║
  ║    ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚══╝╚══════╝   ╚═╝           ║
  ║                                                               ║
  ║          C O M P L E T E   P R O J E C T   v2                ║
  ║       Ubuntu 24.04 LTS  │  OpenStack 2024.1 Caracal          ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    # Show dry-run notice if active
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${YELLOW}${BOLD}  ── DRY-RUN MODE — no changes will be made ──${NC}"
        echo ""
    fi

    local ip_display="${HOST_IP}"
    [[ "${HOST_IP}" == "__CHANGE_ME__" ]] && ip_display="${RED}__CHANGE_ME__${NC}"

    # Detect distro + hardware if not already done
    [[ -z "${DISTRO_ID:-}" ]] && detect_distro
    [[ -z "${HARDWARE_TYPE:-}" ]] && { HARDWARE_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown"); [[ "${HARDWARE_TYPE}" == "none" ]] && HARDWARE_TYPE="physical"; }

    local hw_icon="☁"; [[ "${HARDWARE_TYPE}" == "physical" ]] && hw_icon="🖥"

    echo -e "  ${DIM}Host: ${ip_display}  │  Mode: ${DEPLOY_MODE}  │  Region: ${REGION_NAME}${NC}"
    echo -e "  ${DIM}OS: ${DISTRO_ID:-unknown} ${DISTRO_VERSION:-}  │  ${hw_icon} ${HARDWARE_TYPE:-unknown}  │  Kernel: $(uname -r)${NC}"
    echo ""
}

# =============================================================================
# HELP
# =============================================================================
show_help() {
    echo ""
    echo -e "  ${BOLD}Usage:${NC}  sudo bash deploy.sh [FLAG]"
    echo ""
    echo -e "  ${CYAN}Deployment${NC}"
    echo -e "    --wizard       Re-run Setup Wizard (IP, mode, services)"
    echo -e "    --full         Deploy everything in main.env"
    echo -e "    --base         Base OpenStack only"
    echo -e "    --services     Extra services only (Cinder, Swift, Heat…)"
    echo -e "    --resume       Resume a previously interrupted --full or --base run"
    echo ""
    echo -e "  ${CYAN}Infrastructure${NC}"
    echo -e "    --multinode    Configure Controller / Compute / Storage nodes"
    echo -e "    --k8s          Spin up a Kubernetes cluster inside your cloud"
    echo ""
    echo -e "  ${CYAN}Operations${NC}"
    echo -e "    --monitor      Live health dashboard"
    echo -e "    --backup       Back up VMs, databases, configs"
    echo -e "    --restore      Restore from a backup"
    echo ""
    echo -e "  ${CYAN}Security${NC}"
    echo -e "    --harden       CIS Benchmark audit & auto-fix"
    echo -e "    --ssl          Issue / renew Let's Encrypt certificates"
    echo ""
    echo -e "  ${CYAN}Utility${NC}"
    echo -e "    --verify       Run health checks on all services"
    echo -e "    --config       Show current configuration"
    echo -e "    --dry-run      Preview all actions without executing"
    echo -e "    --help         Show this message"
    echo ""
    echo -e "  ${DIM}No flag → interactive menu${NC}"
    echo ""
}

# =============================================================================
# SETUP WIZARD  (auto-runs on first launch; re-run with option 0 or --wizard)
#
# Steps:
#   1. Host IP address
#   2. Network interface  (auto-detected, numbered picker)
#   3. Admin password     (with confirmation + strength meter)
#   4. Database password  (with confirmation + strength meter)
#   5. Keystone services  (which OpenStack service endpoints to register)
#   6. Extra services     (Cinder, Swift, Heat, etc.)
# =============================================================================
run_setup_wizard() {
    show_banner
    detect_distro
    detect_hardware_type

    echo -e "  ${BOLD}${CYAN}Setup Wizard${NC}  — configure your deployment."
    echo -e "  ${DIM}Detected: ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME}) on ${HARDWARE_TYPE} hardware.${NC}"
    echo -e "  ${DIM}Answers are written directly to configs/main.env.${NC}"
    echo ""

    # ── Step 1: Host IP ──────────────────────────────────────────────────────
    section "Step 1 of 6 — Host IP Address"

    # Auto-detect all IPs on this machine and offer them as shortcuts
    local -a auto_ips=()
    while IFS= read -r line; do
        auto_ips+=("${line}")
    done < <(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.')

    echo -e "  Current value: ${BOLD}${HOST_IP}${NC}"
    if [[ ${#auto_ips[@]} -gt 0 ]]; then
        echo -e "  ${DIM}Addresses detected on this machine:${NC}"
        local idx=1
        for ip in "${auto_ips[@]}"; do
            echo -e "    ${BOLD}${idx}${NC}  ${ip}"
            (( idx++ ))
        done
        echo -e "  ${DIM}Enter a number to pick one, or type a custom IP.${NC}"
    else
        echo -e "  ${DIM}Tip: run  hostname -I  to find your IP.${NC}"
    fi
    echo ""

    local new_ip=""
    while true; do
        echo -ne "  IP address [${HOST_IP}]: "
        read -r ip_input

        # Blank → keep current
        if [[ -z "${ip_input}" ]]; then
            new_ip="${HOST_IP}"
        # Number → pick from auto-detected list
        elif [[ "${ip_input}" =~ ^[0-9]+$ ]] && (( ip_input >= 1 && ip_input <= ${#auto_ips[@]} )); then
            new_ip="${auto_ips[$(( ip_input - 1 ))]}"
        else
            new_ip="${ip_input}"
        fi

        [[ "${new_ip}" == "__CHANGE_ME__" ]] && { warn "Please enter a real IP address."; continue; }
        validate_ip "${new_ip}" && break || warn "'${new_ip}' is not a valid IPv4 address. Try again."
    done
    echo -e "  ${GREEN}✔${NC} IP set to: ${BOLD}${new_ip}${NC}"

    # ── Step 2: Network interface ────────────────────────────────────────────
    section "Step 2 of 6 — Network Interface"
    echo -e "  ${DIM}This interface is used by Neutron for VM traffic.${NC}"
    echo -e "  ${DIM}On bare-metal: use the NIC connected to your provider/external network.${NC}"
    echo ""

    detect_network_interfaces
    local new_iface="${INTERFACE_NAME}"

    if [[ ${#DETECTED_IFACES[@]} -eq 0 ]]; then
        warn "No physical NICs detected. You will need to enter the interface name manually."
        echo -ne "  Interface name [${INTERFACE_NAME}]: "
        read -r iface_input
        [[ -n "${iface_input}" ]] && new_iface="${iface_input}"
    else
        echo -e "  ${DIM}Available interfaces:${NC}"
        echo ""
        print_iface_menu
        echo ""
        # Find default: pick the current INTERFACE_NAME if it's in the list
        local default_idx=1
        for i in "${!DETECTED_IFACES[@]}"; do
            [[ "${DETECTED_IFACES[$i]}" == "${INTERFACE_NAME}" ]] && default_idx=$(( i + 1 )) && break
        done

        while true; do
            echo -ne "  Choose interface [${default_idx}] or type name directly: "
            read -r iface_input

            if [[ -z "${iface_input}" ]]; then
                new_iface="${DETECTED_IFACES[$(( default_idx - 1 ))]}"
                break
            elif [[ "${iface_input}" =~ ^[0-9]+$ ]] && \
                 (( iface_input >= 1 && iface_input <= ${#DETECTED_IFACES[@]} )); then
                new_iface="${DETECTED_IFACES[$(( iface_input - 1 ))]}"
                break
            elif ip link show "${iface_input}" &>/dev/null; then
                new_iface="${iface_input}"
                break
            else
                warn "'${iface_input}' is not a number in range or a known interface. Try again."
            fi
        done
    fi

    # Bare-metal warning: if the chosen interface has an IP, Neutron OVS will
    # take it over and the management connection may drop
    local iface_ip; iface_ip=$(ip -4 addr show "${new_iface}" 2>/dev/null | awk '/inet /{print $2}' | head -1)
    if [[ -n "${iface_ip}" && "${HARDWARE_TYPE}" == "physical" ]]; then
        echo ""
        warn "Interface ${new_iface} currently has IP ${iface_ip}."
        warn "Neutron (OVS/LinuxBridge) will manage this interface directly."
        warn "If this is your management/SSH interface, use a separate NIC for VM traffic."
        echo -ne "  Continue anyway? (y/N): "
        read -r proceed_iface
        [[ ! "${proceed_iface}" =~ ^[Yy]$ ]] && { warn "Interface selection cancelled."; run_setup_wizard; return; }
    fi
    echo -e "  ${GREEN}✔${NC} Interface set to: ${BOLD}${new_iface}${NC}"

    # ── Step 3: Admin password ───────────────────────────────────────────────
    section "Step 3 of 6 — Admin Password"
    echo -e "  ${DIM}This is the OpenStack admin account password (Horizon + CLI).${NC}"
    echo -e "  ${DIM}Rules: 12+ chars, avoid  @ # $ &  — they break config file parsing.${NC}"
    echo ""

    local new_admin_pass
    new_admin_pass=$(_prompt_password "Admin password" "${ADMIN_PASS}")
    echo -e "  ${GREEN}✔${NC} Admin password set.  $(_password_strength "${new_admin_pass}")"

    # ── Step 4: Database password ────────────────────────────────────────────
    section "Step 4 of 6 — Database (MariaDB) Password"
    echo -e "  ${DIM}This password is used for the MariaDB root account and all service DBs.${NC}"
    echo -e "  ${DIM}Different from the admin password — do not reuse.${NC}"
    echo ""

    local new_db_pass
    new_db_pass=$(_prompt_password "Database password" "${DB_PASS}")
    if [[ "${new_db_pass}" == "${new_admin_pass}" ]]; then
        warn "DB password is the same as admin password. Using the same password is not recommended."
    fi
    echo -e "  ${GREEN}✔${NC} DB password set.  $(_password_strength "${new_db_pass}")"

    # ── Step 5: Keystone service endpoints ──────────────────────────────────
    section "Step 5 of 6 — Keystone Service Endpoints"
    echo -e "  ${DIM}Keystone maintains a service catalog.  Each service you enable will have${NC}"
    echo -e "  ${DIM}public, internal, and admin endpoints registered automatically.${NC}"
    echo -e "  ${DIM}Toggle with a number. Press ${BOLD}d${NC}${DIM} when done.${NC}"
    echo ""
    echo -e "  ${YELLOW}Base services (Keystone itself + Glance + Placement) are always on.${NC}"
    echo ""

    # Keys map to the config var that controls whether that service's Keystone
    # entry gets registered. Base services are mandatory and not toggleable.
    local -a ks_keys=(  NOVA_KS    NEUTRON_KS  CINDER_KS   SWIFT_KS   HEAT_KS    BARBICAN_KS  DESIGNATE_KS  OCTAVIA_KS  MANILA_KS  CEILOMETER_KS )
    local -a ks_desc=(
        "Nova        — Compute API      (http://${new_ip}:8774/v2.1)"
        "Neutron     — Networking API   (http://${new_ip}:9696)"
        "Cinder      — Block Storage    (http://${new_ip}:8776/v3)"
        "Swift       — Object Storage   (http://${new_ip}:8080/v1)"
        "Heat        — Orchestration    (http://${new_ip}:8004/v1)"
        "Barbican    — Secrets          (http://${new_ip}:9311)"
        "Designate   — DNS              (http://${new_ip}:9001)"
        "Octavia     — Load Balancer    (http://${new_ip}:9876)"
        "Manila      — Shared FS        (http://${new_ip}:8786/v2)"
        "Ceilometer  — Telemetry        (http://${new_ip}:8777)"
    )

    # Map each Keystone toggle to its corresponding INSTALL_ flag so they stay in sync
    local -a ks_install_key=( NOVA NEUTRON CINDER SWIFT HEAT BARBICAN DESIGNATE OCTAVIA MANILA CEILOMETER )

    # Default states: on for services that are on by default, off for others
    local -a ks_state=()
    for key in "${ks_install_key[@]}"; do
        local var="INSTALL_${key}"
        # Nova + Neutron default on (they're part of base); rest follow INSTALL_ flags
        case "${key}" in
            NOVA|NEUTRON) ks_state+=("true") ;;
            *)            ks_state+=("${!var:-false}") ;;
        esac
    done

    local ks_done=false
    while ! "${ks_done}"; do
        echo ""
        echo -e "   ${GREEN}[✔]${NC}  ${BOLD}always${NC}  Keystone  — Identity         (http://${new_ip}:5000/v3)"
        echo -e "   ${GREEN}[✔]${NC}  ${BOLD}always${NC}  Glance    — Image Service    (http://${new_ip}:9292)"
        echo -e "   ${GREEN}[✔]${NC}  ${BOLD}always${NC}  Placement — Resource Tracker (http://${new_ip}:8778)"
        echo ""
        for i in "${!ks_keys[@]}"; do
            local num=$(( i + 1 ))
            local icon; [[ "${ks_state[$i]}" == "true" ]] && icon="${GREEN}[✔]${NC}" || icon="${RED}[✖]${NC}"
            printf "   %b  ${BOLD}%2d${NC}  %s\n" "${icon}" "${num}" "${ks_desc[$i]}"
        done
        echo ""
        echo -ne "  Toggle (1-${#ks_keys[@]}), ${BOLD}a${NC}=all on, ${BOLD}n${NC}=core only, ${BOLD}d${NC}=done: "
        read -r tog

        case "${tog}" in
            d|D) ks_done=true ;;
            a|A) for i in "${!ks_keys[@]}"; do ks_state[$i]="true";  done ;;
            n|N)
                # Core only = Nova + Neutron on, everything else off
                for i in "${!ks_keys[@]}"; do
                    case "${ks_install_key[$i]}" in
                        NOVA|NEUTRON) ks_state[$i]="true" ;;
                        *)            ks_state[$i]="false" ;;
                    esac
                done ;;
            [0-9]|1[0-9])
                local idx=$(( tog - 1 ))
                if (( idx >= 0 && idx < ${#ks_keys[@]} )); then
                    # Prevent disabling Nova or Neutron
                    if [[ "${ks_install_key[$idx]}" == "NOVA" || "${ks_install_key[$idx]}" == "NEUTRON" ]]; then
                        warn "Nova and Neutron are required for a functional cloud. Cannot disable."
                    else
                        [[ "${ks_state[$idx]}" == "true" ]] && ks_state[$idx]="false" || ks_state[$idx]="true"
                    fi
                else
                    warn "Invalid selection."
                fi ;;
            *) warn "Enter a number 1-${#ks_keys[@]}, a, n, or d." ;;
        esac
    done

    # ── Step 6: Extra services ───────────────────────────────────────────────
    section "Step 6 of 6 — Extra Services to Install"
    echo -e "  ${DIM}These must also be enabled in Keystone (Step 5) to be reachable.${NC}"
    echo -e "  ${DIM}Services already toggled on in Step 5 are pre-selected here.${NC}"
    echo -e "  ${DIM}Toggle with a number. Press ${BOLD}d${NC}${DIM} when done.${NC}"
    echo ""

    local -a svc_keys=( CINDER    SWIFT     HEAT          CEILOMETER  BARBICAN  OCTAVIA         MANILA            DESIGNATE )
    local -a svc_desc=(
        "Cinder     — Block Storage (like AWS EBS)"
        "Swift      — Object Storage (like AWS S3)"
        "Heat       — Orchestration / IaC (like CloudFormation)"
        "Ceilometer — Telemetry & Metrics (resource-heavy)"
        "Barbican   — Secrets Manager (like HashiCorp Vault)"
        "Octavia    — Load Balancer (needs Amphora image)"
        "Manila     — Shared Filesystems (like AWS EFS)"
        "Designate  — DNS as a Service (like Route 53)"
    )

    # Pre-fill svc_state from the Keystone selections made in Step 5
    local -a svc_state=()
    for key in "${svc_keys[@]}"; do
        # Find the matching ks_install_key index
        local pre_state="false"
        for i in "${!ks_install_key[@]}"; do
            if [[ "${ks_install_key[$i]}" == "${key}" ]]; then
                pre_state="${ks_state[$i]}"
                break
            fi
        done
        svc_state+=("${pre_state}")
    done

    local svc_done=false
    while ! "${svc_done}"; do
        echo ""
        for i in "${!svc_keys[@]}"; do
            local num=$(( i + 1 ))
            local icon; [[ "${svc_state[$i]}" == "true" ]] && icon="${GREEN}[✔]${NC}" || icon="${RED}[✖]${NC}"
            printf "   %b  ${BOLD}%d${NC}  %s\n" "${icon}" "${num}" "${svc_desc[$i]}"
        done
        echo ""
        echo -ne "  Toggle (1-${#svc_keys[@]}), ${BOLD}a${NC}=all on, ${BOLD}n${NC}=all off, ${BOLD}d${NC}=done: "
        read -r tog

        case "${tog}" in
            d|D) svc_done=true ;;
            a|A) for i in "${!svc_keys[@]}"; do svc_state[$i]="true";  done ;;
            n|N) for i in "${!svc_keys[@]}"; do svc_state[$i]="false"; done ;;
            [1-9])
                local idx=$(( tog - 1 ))
                if (( idx >= 0 && idx < ${#svc_keys[@]} )); then
                    [[ "${svc_state[$idx]}" == "true" ]] && svc_state[$idx]="false" || svc_state[$idx]="true"
                else
                    warn "Invalid selection."
                fi ;;
            *) warn "Enter a number 1-${#svc_keys[@]}, a, n, or d." ;;
        esac
    done

    # ── Deploy mode (quick ask, no dedicated step) ────────────────────────────
    echo ""
    echo -ne "  ${BOLD}Deployment mode${NC} — ${BOLD}1${NC} all-in-one  ${BOLD}2${NC} multi-node  [current: ${DEPLOY_MODE}]: "
    read -r mode_choice
    local new_mode="${DEPLOY_MODE}"
    case "${mode_choice}" in
        1) new_mode="all-in-one" ;;
        2) new_mode="multi-node" ;;
    esac

    # ── Build KEYSTONE_SERVICES_STR from selections ───────────────────────────
    # This string is stored in main.env and read by the Keystone registration
    # step to decide which service catalog entries to create.
    local ks_enabled_str="keystone glance placement"   # always-on base
    for i in "${!ks_keys[@]}"; do
        [[ "${ks_state[$i]}" == "true" ]] && ks_enabled_str+=" ${ks_install_key[$i],,}"
    done

    # ── Preview & confirm ────────────────────────────────────────────────────
    echo ""
    section "Summary — changes to be saved"
    printf "    %-20s: %s\n"  "HOST_IP"        "${new_ip}"
    printf "    %-20s: %s\n"  "INTERFACE_NAME" "${new_iface}"
    printf "    %-20s: %s\n"  "DEPLOY_MODE"    "${new_mode}"
    printf "    %-20s: %s\n"  "ADMIN_PASS"     "$(python3 -c "print('*' * len('${new_admin_pass}'))" 2>/dev/null || printf '%0.s*' $(seq 1 ${#new_admin_pass}))"
    printf "    %-20s: %s\n"  "DB_PASS"        "$(python3 -c "print('*' * len('${new_db_pass}'))" 2>/dev/null || printf '%0.s*' $(seq 1 ${#new_db_pass}))"
    echo ""
    echo -e "  ${DIM}Keystone services:${NC} ${ks_enabled_str}"
    echo ""
    for i in "${!svc_keys[@]}"; do
        local icon; [[ "${svc_state[$i]}" == "true" ]] && icon="${GREEN}✔${NC}" || icon="${RED}✖${NC}"
        printf "    INSTALL_%-12s: %b%s%b\n" "${svc_keys[$i]}" "${icon}" "${svc_state[$i]}" "${NC}"
    done
    echo ""
    echo -ne "  ${BOLD}Save these settings to configs/main.env? (y/N):${NC} "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        warn "Wizard cancelled — no changes saved."
        press_enter; show_menu; return
    fi

    # ── Write to main.env ─────────────────────────────────────────────────────
    # Python handles the file rewrite so passwords with special chars (* / & @ etc.)
    # never break sed's s|...|...| syntax.
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would write all settings to ${CONFIG}${NC}"
    else
        # Serialise the INSTALL_ selections as KEY=val pairs (comma-separated)
        local install_map=""
        for i in "${!svc_keys[@]}"; do
            install_map+="${svc_keys[$i]}=${svc_state[$i]},"
        done

        python3 - \
            "${CONFIG}" \
            "${new_ip}" \
            "${new_iface}" \
            "${new_mode}" \
            "${new_admin_pass}" \
            "${new_db_pass}" \
            "${ks_enabled_str}" \
            "${DISTRO_FAMILY:-debian}" \
            "${install_map}" \
            << 'PYEOF'
import sys, re

cfg_path    = sys.argv[1]
new_ip      = sys.argv[2]
new_iface   = sys.argv[3]
new_mode    = sys.argv[4]
admin_pass  = sys.argv[5]
db_pass     = sys.argv[6]
ks_str      = sys.argv[7]
distro_fam  = sys.argv[8]
install_raw = sys.argv[9]

# Parse comma-separated KEY=val pairs
install_map = {}
for entry in install_raw.rstrip(",").split(","):
    if "=" in entry:
        k, v = entry.split("=", 1)
        install_map[k.strip()] = v.strip()

# Map of config key -> new value (values treated as plain strings, not regex)
replacements = {
    "HOST_IP":               new_ip,
    "INTERFACE_NAME":        new_iface,
    "CONTROLLER_IFACE":      new_iface,
    "DEPLOY_MODE":           new_mode,
    "ADMIN_PASS":            admin_pass,
    "DB_PASS":               db_pass,
    "SERVICE_PASS":          db_pass,
    "RABBIT_PASS":           db_pass,
    "KEYSTONE_SERVICES_STR": ks_str,
    "DISTRO_FAMILY":         distro_fam,
}
if new_mode == "all-in-one":
    replacements["CONTROLLER_IP"] = new_ip

for k, v in install_map.items():
    replacements[f"INSTALL_{k}"] = v

with open(cfg_path, "r") as f:
    lines = f.readlines()

seen = set()
new_lines = []
for line in lines:
    matched = False
    for key, val in replacements.items():
        if re.match(rf'^{re.escape(key)}=', line):
            new_lines.append(f'{key}="{val}"\n')
            seen.add(key)
            matched = True
            break
    if not matched:
        new_lines.append(line)

# Append keys not found in existing file
for key, val in replacements.items():
    if key not in seen:
        new_lines.append(f'{key}="{val}"\n')

with open(cfg_path, "w") as f:
    f.writelines(new_lines)
PYEOF

        source "${CONFIG}"
        ok "Settings saved to ${CONFIG}"
    fi

    echo ""
    echo -e "  ${DIM}Re-run this wizard at any time via menu option ${BOLD}0${NC}${DIM} or: sudo bash deploy.sh --wizard${NC}"
    press_enter
    show_menu
}

# ─── PASSWORD PROMPT HELPER ───────────────────────────────────────────────────
# _prompt_password LABEL [CURRENT_VALUE]
# Prompts for a new password twice (confirmation), falls back to CURRENT_VALUE
# on blank input. Echoes the chosen password.
_prompt_password() {
    local label="$1"
    local current="${2:-}"
    local pw1 pw2

    while true; do
        echo -ne "  ${label} [leave blank to keep current]: "
        read -rs pw1; echo ""

        if [[ -z "${pw1}" ]]; then
            echo "${current}"
            return 0
        fi

        # Basic safety check: no shell-breaking special chars in passwords
        if [[ "${pw1}" =~ [\'\"\`\$\\\!] ]]; then
            warn "Password contains characters that may break config files (', \", \`, \$, \\, !). Choose another."
            continue
        fi

        if [[ "${#pw1}" -lt 12 ]]; then
            warn "Password is only ${#pw1} characters. 16+ recommended. Try again."
            continue
        fi

        echo -ne "  Confirm ${label}: "
        read -rs pw2; echo ""

        if [[ "${pw1}" != "${pw2}" ]]; then
            warn "Passwords do not match. Try again."
            continue
        fi

        echo "${pw1}"
        return 0
    done
}

# _password_strength PASSWORD → prints a coloured strength label
_password_strength() {
    local pw="$1"
    local len="${#pw}"
    local score=0

    (( len >= 16 ))             && (( score++ ))
    (( len >= 24 ))             && (( score++ ))
    [[ "${pw}" =~ [A-Z] ]]      && (( score++ ))
    [[ "${pw}" =~ [0-9] ]]      && (( score++ ))
    [[ "${pw}" =~ [^a-zA-Z0-9] ]] && (( score++ ))

    case "${score}" in
        5)   echo -e "${GREEN}Strength: Very Strong ●●●●●${NC}" ;;
        4)   echo -e "${GREEN}Strength: Strong      ●●●●○${NC}" ;;
        3)   echo -e "${YELLOW}Strength: Medium      ●●●○○${NC}" ;;
        2)   echo -e "${YELLOW}Strength: Weak        ●●○○○${NC}" ;;
        *)   echo -e "${RED}Strength: Very Weak   ●○○○○${NC}" ;;
    esac
}

# =============================================================================
# MENU
# =============================================================================
show_menu() {
    show_banner
    echo -e "  ${BOLD}Select what to deploy or manage:${NC}"
    echo ""
    echo -e "  ${CYAN}── SETUP ─────────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}0${NC}  Setup Wizard            Set IP address & choose services"
    echo ""
    echo -e "  ${CYAN}── DEPLOYMENT ────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}1${NC}  Full Deployment         Deploy everything in order"
    echo -e "   ${BOLD}2${NC}  Base OpenStack          Keystone → Nova → Neutron → Horizon"
    echo -e "   ${BOLD}3${NC}  Extra Services          Cinder, Swift, Heat, Barbican, Designate…"
    echo -e "   ${BOLD}4${NC}  Custom Selection        Pick individual services"
    echo -e "   ${BOLD}r${NC}  Resume Deployment       Continue after a failed run"
    echo ""
    echo -e "  ${CYAN}── INFRASTRUCTURE ────────────────────────────────────${NC}"
    echo -e "   ${BOLD}5${NC}  Multi-Node Setup        Configure Controller / Compute / Storage"
    echo -e "   ${BOLD}6${NC}  Kubernetes on OpenStack Spin up a K8s cluster inside your cloud"
    echo ""
    echo -e "  ${CYAN}── OPERATIONS ────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}7${NC}  Health Dashboard        Live monitoring dashboard"
    echo -e "   ${BOLD}8${NC}  Backup & DR             Backup VMs, databases, configs"
    echo -e "   ${BOLD}9${NC}  Restore                 Restore from a backup"
    echo ""
    echo -e "  ${CYAN}── SECURITY ──────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}10${NC}  Server Hardening        CIS Benchmark audit & auto-fix"
    echo -e "  ${BOLD}11${NC}  SSL Certificates        Issue/renew Let's Encrypt certs"
    echo ""
    echo -e "  ${CYAN}── UTILITY ───────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}12${NC}  Verify Installation     Run health checks on all services"
    echo -e "  ${BOLD}13${NC}  Show Config             Display current configuration"
    echo -e "  ${BOLD}14${NC}  View Logs               Browse deployment logs"
    echo -e "   ${BOLD}q${NC}  Quit"
    echo ""
    echo -ne "  ${BOLD}Enter choice:${NC} "
    read -r choice
    handle_menu "${choice}"
}

# =============================================================================
# MENU HANDLER
# =============================================================================
handle_menu() {
    case "${1:-}" in
        0)          run_setup_wizard ;;
        1)          run_full_deployment ;;
        2)          run_base_openstack ;;
        3)          run_extra_services ;;
        4)          run_custom_selection ;;
        r|R)        run_resume ;;
        5)          run_multinode_setup ;;
        6)          run_kubernetes ;;
        7)          run_health_dashboard ;;
        8)          run_backup ;;
        9)          run_restore ;;
        10)         run_hardening ;;
        11)         run_ssl ;;
        12)         run_verify ;;
        13)         show_config ;;
        14)         view_logs ;;
        q|Q|quit|exit) echo "Bye!"; exit 0 ;;
        *)  warn "Invalid choice: ${1:-}"; sleep 1; show_menu ;;
    esac
}

# =============================================================================
# RUNNER — executes a module script, tees output to the log, tracks time
# =============================================================================
run_module() {
    local title="$1"; local script="$2"; shift 2
    local args=("$@")

    section "${title}"
    log "Running: ${script} ${args[*]:-}"
    log "Log: ${LOG_FILE}"
    start_timer

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would run: bash ${script} ${args[*]:-}${NC}"
        ok "${title} (dry-run) — skipped"
        return 0
    fi

    if bash "${script}" "${args[@]:-}" 2>&1 | tee -a "${LOG_FILE}"; then
        ok "${title} completed in $(elapsed)"
    else
        error "${title} FAILED after $(elapsed). Check: ${LOG_FILE}"
    fi
}

# =============================================================================
# CHECKPOINT-AWARE STEP RUNNER
# =============================================================================
# run_step CHECKPOINT_KEY TITLE SCRIPT [ARGS...]
# Skips the step if checkpoint already recorded (for --resume).
run_step() {
    local key="$1"; local title="$2"; local script="$3"; shift 3

    if step_ran "${key}"; then
        echo -e "  ${DIM}⏭  Skipping '${title}' (already completed).${NC}"
        return 0
    fi

    run_module "${title}" "${script}" "$@" && step_done "${key}"
}

# =============================================================================
# MODULE: FULL DEPLOYMENT
# =============================================================================
run_full_deployment() {
    show_banner

    # Validate config before doing anything irreversible
    validate_config

    echo -e "  ${BOLD}Full Deployment — installing everything configured in main.env${NC}"
    echo ""
    echo -e "  ${DIM}Services to install:${NC}"
    echo "    Base OpenStack (Keystone, Glance, Placement, Nova, Neutron, Horizon)"
    [[ "${INSTALL_CINDER}"     == "true" ]] && echo "    + Cinder (Block Storage)"
    [[ "${INSTALL_SWIFT}"      == "true" ]] && echo "    + Swift (Object Storage)"
    [[ "${INSTALL_HEAT}"       == "true" ]] && echo "    + Heat (Orchestration)"
    [[ "${INSTALL_CEILOMETER}" == "true" ]] && echo "    + Ceilometer (Telemetry)"
    [[ "${INSTALL_BARBICAN}"   == "true" ]] && echo "    + Barbican (Secrets)"
    [[ "${INSTALL_OCTAVIA}"    == "true" ]] && echo "    + Octavia (Load Balancer)"
    [[ "${INSTALL_MANILA}"     == "true" ]] && echo "    + Manila (Shared Filesystems)"
    [[ "${INSTALL_DESIGNATE}"  == "true" ]] && echo "    + Designate (DNS)"
    echo ""

if [[ "${DRY_RUN}" != "true" ]]; then
        require_root; require_debian_based; require_internet
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        echo -ne "  ${BOLD}Proceed? This takes 20-40 minutes. (y/N):${NC} "
        read -r confirm; [[ "${confirm}" =~ ^[Yy]$ ]] || { show_menu; return; }
    fi

    # Clear checkpoints for a fresh run (not a resume)
    [[ "${RESUME_MODE}" != "true" ]] && clear_checkpoints

    DEPLOY_START=$(date +%s)

    _run_base_steps
    _run_service_steps

    if [[ "${DRY_RUN}" != "true" ]] && ask_yes "Run server hardening now?"; then
        run_step "hardening" "Server Hardening" "${PROJ}/scripts/hardening/server-harden.sh"
    fi

    DEPLOY_END=$(date +%s)
    TOTAL_TIME=$(( DEPLOY_END - DEPLOY_START ))

    # Prune old deployment logs
    prune_old_logs

    section "🎉 Full Deployment Complete"
    echo -e "${GREEN}${BOLD}"
    echo "  ✔ OpenStack is ready!"
    echo ""
    echo "  Dashboard   :  http://${HOST_IP}/horizon"
    echo "  Username    :  admin"
    echo "  Password    :  (ADMIN_PASS from configs/main.env or .secrets.env)"
    echo ""
    echo "  CLI access  :  source configs/admin-openrc.sh"
    echo ""
    printf "  Total time  :  %dm %ds\n" $(( TOTAL_TIME/60 )) $(( TOTAL_TIME%60 ))
    echo "  Full log    :  ${LOG_FILE}"
    echo -e "${NC}"

    press_enter
    show_menu
}

# =============================================================================
# MODULE: BASE OPENSTACK (internal step runner, also called stand-alone)
# =============================================================================
_run_base_steps() {
    local base="${PROJ}/scripts/base"
    run_step "prerequisites"  "System Prerequisites"     "${base}/01_prerequisites.sh"
    run_step "keystone"       "Keystone (Identity)"      "${base}/02_keystone.sh"
    run_step "glance"         "Glance (Images)"          "${base}/03_glance.sh"
    run_step "placement"      "Placement"                "${base}/04_placement.sh"
    run_step "nova"           "Nova (Compute)"           "${base}/05_nova.sh"
    run_step "neutron"        "Neutron (Networking)"     "${base}/06_neutron.sh"
    run_step "horizon"        "Horizon (Dashboard)"      "${base}/07_horizon.sh"
    run_step "verify_base"    "Verification"             "${base}/08_verify.sh"
}

run_base_openstack() {
    validate_config
    section "Base OpenStack Deployment"
    if [[ "${DRY_RUN}" != "true" ]]; then require_root; fi
    [[ "${RESUME_MODE}" != "true" ]] && clear_checkpoints
    _run_base_steps
}

# =============================================================================
# MODULE: EXTRA SERVICES (internal step runner, also called stand-alone)
# =============================================================================
_run_service_steps() {
    local svc="${PROJ}/scripts/services"
    [[ "${INSTALL_CINDER}"     == "true" ]] && run_step "cinder"     "Cinder (Block Storage)"     "${svc}/09_cinder.sh"
    [[ "${INSTALL_SWIFT}"      == "true" ]] && run_step "swift"      "Swift (Object Storage)"     "${svc}/10_swift.sh"
    [[ "${INSTALL_HEAT}"       == "true" ]] && run_step "heat"       "Heat (Orchestration)"       "${svc}/11_heat.sh"
    [[ "${INSTALL_CEILOMETER}" == "true" ]] && run_step "ceilometer" "Ceilometer (Telemetry)"     "${svc}/12_ceilometer.sh"
    [[ "${INSTALL_BARBICAN}"   == "true" ]] && run_step "barbican"   "Barbican (Secrets)"         "${svc}/13_barbican.sh"
    [[ "${INSTALL_OCTAVIA}"    == "true" ]] && run_step "octavia"    "Octavia (Load Balancer)"    "${svc}/14_octavia.sh"
    [[ "${INSTALL_MANILA}"     == "true" ]] && run_step "manila"     "Manila (Shared Filesystems)""${svc}/15_manila.sh"
    [[ "${INSTALL_DESIGNATE}"  == "true" ]] && run_step "designate"  "Designate (DNS)"            "${svc}/16_designate.sh"
    ok "All enabled extra services installed."
}

run_extra_services() {
    validate_config
    section "Extra OpenStack Services"
    _run_service_steps
}

# =============================================================================
# MODULE: RESUME
# =============================================================================
run_resume() {
    if [[ ! -f "${CHECKPOINT_FILE}" ]]; then
        warn "No checkpoint file found at ${CHECKPOINT_FILE}."
        warn "Nothing to resume — start a fresh deployment instead."
        press_enter; show_menu; return
    fi

    show_banner
    echo -e "  ${BOLD}Resume Deployment${NC}"
    echo ""
    echo -e "  ${DIM}Steps already completed:${NC}"
    while IFS= read -r line; do
        echo -e "    ${GREEN}✔${NC}  ${line}"
    done < "${CHECKPOINT_FILE}"
    echo ""
    echo -ne "  ${BOLD}Continue from where it left off? (y/N):${NC} "
    read -r confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { show_menu; return; }

    RESUME_MODE=true
    run_full_deployment
}

# =============================================================================
# MODULE: CUSTOM SERVICE SELECTION
# =============================================================================
run_custom_selection() {
    show_banner
    echo -e "  ${BOLD}Custom Service Selection${NC}"
    echo ""

    local -A SERVICES=(
        [1]="base:Base OpenStack (required)"
        [2]="cinder:Cinder — Block Storage"
        [3]="swift:Swift — Object Storage"
        [4]="heat:Heat — Orchestration"
        [5]="ceilometer:Ceilometer — Telemetry"
        [6]="barbican:Barbican — Secrets Manager"
        [7]="octavia:Octavia — Load Balancer"
        [8]="manila:Manila — Shared Filesystems"
        [9]="designate:Designate — DNS Service"
    )

    for i in $(seq 1 9); do
        local desc="${SERVICES[$i]##*:}"
        echo -e "   ${BOLD}${i}${NC}  ${desc}"
    done
    echo ""
    echo -ne "  Enter numbers to install (e.g. 1 2 4 6): "
    read -ra selections

    for sel in "${selections[@]}"; do
        local svc="${PROJ}/scripts/services"
        case "${sel}" in
            1) run_base_openstack ;;
            2) run_step "cinder"     "Cinder"      "${svc}/09_cinder.sh" ;;
            3) run_step "swift"      "Swift"       "${svc}/10_swift.sh" ;;
            4) run_step "heat"       "Heat"        "${svc}/11_heat.sh" ;;
            5) run_step "ceilometer" "Ceilometer"  "${svc}/12_ceilometer.sh" ;;
            6) run_step "barbican"   "Barbican"    "${svc}/13_barbican.sh" ;;
            7) run_step "octavia"    "Octavia"     "${svc}/14_octavia.sh" ;;
            8) run_step "manila"     "Manila"      "${svc}/15_manila.sh" ;;
            9) run_step "designate"  "Designate"   "${svc}/16_designate.sh" ;;
            *) warn "Unknown selection: ${sel}" ;;
        esac
    done

    press_enter; show_menu
}

# =============================================================================
# MODULE: MULTI-NODE SETUP
# =============================================================================
run_multinode_setup() {
    show_banner
    echo -e "  ${BOLD}Multi-Node Setup${NC}"
    echo ""
    echo -e "  Architecture:"
    echo -e "    Controller : ${CONTROLLER_IP}"
    # COMPUTE_IPS_STR replaces the unexportable bash array
    for ip in ${COMPUTE_IPS_STR}; do
        echo -e "    Compute    : ${ip}"
    done
    echo -e "    Storage    : ${STORAGE_IP}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Run preflight on this node (controller)"
    echo -e "   ${BOLD}2${NC}  Run preflight on this node (compute)"
    echo -e "   ${BOLD}3${NC}  Run preflight on this node (storage)"
    echo -e "   ${BOLD}4${NC}  Install compute node services"
    echo -e "   ${BOLD}5${NC}  Install storage node services"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local mn="${PROJ}/scripts/multinode"
    case "${choice}" in
        1) run_module "Preflight (Controller)" "${mn}/00_preflight.sh" "controller" ;;
        2) run_module "Preflight (Compute)"    "${mn}/00_preflight.sh" "compute" ;;
        3) run_module "Preflight (Storage)"    "${mn}/00_preflight.sh" "storage" ;;
        4) run_module "Compute Node"           "${mn}/02_compute.sh" ;;
        5) run_module "Storage Node"           "${mn}/03_storage.sh" ;;
        b|B) show_menu; return ;;
    esac

    press_enter; run_multinode_setup
}

# =============================================================================
# MODULE: KUBERNETES
# =============================================================================
run_kubernetes() {
    show_banner
    echo -e "  ${BOLD}Kubernetes on OpenStack${NC}"
    echo ""
    echo -e "  Will create:"
    echo -e "    1 x Master VM (k8s-master)"
    echo -e "    ${K8S_WORKER_COUNT} x Worker VM(s)"
    echo -e "    Private network, router, security group, floating IPs"
    echo -e "    Kubernetes ${K8S_WORKER_COUNT}-node cluster with Calico CNI"
    echo ""
    echo -e "   ${BOLD}1${NC}  Deploy K8s cluster (${K8S_WORKER_COUNT} workers)"
    echo -e "   ${BOLD}2${NC}  Destroy K8s cluster"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    case "${choice}" in
        1) run_module "Kubernetes Deployment" "${PROJ}/scripts/k8s/deploy-k8s.sh" "--workers" "${K8S_WORKER_COUNT}" ;;
        2) run_module "Kubernetes Destroy"    "${PROJ}/scripts/k8s/deploy-k8s.sh" "--destroy" ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: HEALTH DASHBOARD
# =============================================================================
run_health_dashboard() {
    show_banner
    echo -e "  ${BOLD}Health Dashboard${NC}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Run once (print current status)"
    echo -e "   ${BOLD}2${NC}  Live watch mode (refresh every ${MONITOR_INTERVAL}s)"
    echo -e "   ${BOLD}3${NC}  Run once + send alerts if anything is down"
    echo -e "   ${BOLD}4${NC}  Install cron (checks every 5 minutes)"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local mon="${PROJ}/scripts/monitoring/monitor.sh"
    case "${choice}" in
        1) bash "${mon}" ;;
        2) bash "${mon}" --watch ;;
        3) bash "${mon}" --alert ;;
        4) bash "${PROJ}/scripts/monitoring/install-cron.sh" ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: BACKUP
# =============================================================================
run_backup() {
    show_banner
    echo -e "  ${BOLD}Backup${NC}"
    echo ""
    echo -e "  Backup destination : ${BACKUP_PATH}"
    echo -e "  Retention          : ${BACKUP_KEEP_DAYS} days"
    echo -e "  Swift offsite      : ${SWIFT_BACKUP_ENABLED}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Full backup (databases + configs + images + VMs)"
    echo -e "   ${BOLD}2${NC}  Databases only"
    echo -e "   ${BOLD}3${NC}  Config files only"
    echo -e "   ${BOLD}4${NC}  Glance images only"
    echo -e "   ${BOLD}5${NC}  VM snapshots only"
    echo -e "   ${BOLD}6${NC}  Install backup cron (daily at 2am)"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local bk="${PROJ}/scripts/backup/backup.sh"
    case "${choice}" in
        1) run_module "Full Backup"    "${bk}" ;;
        2) run_module "DB Backup"      "${bk}" --db-only ;;
        3) run_module "Config Backup"  "${bk}" --configs ;;
        4) run_module "Image Backup"   "${bk}" --images ;;
        5) run_module "VM Backup"      "${bk}" --vms-only ;;
        6)
            echo "0 2 * * * root bash ${bk} >> ${LOG_DIR}/backup.log 2>&1" \
                | tee /etc/cron.d/openstack-backup  # openstack-complete
            ok "Backup cron installed (daily 2am)."
            ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: RESTORE
# =============================================================================
run_restore() {
    show_banner
    echo -e "  ${BOLD}Restore from Backup${NC}"
    echo ""
    bash "${PROJ}/scripts/backup/restore.sh" --list 2>/dev/null || \
        warn "No backups found at ${BACKUP_PATH}."
    echo ""
    echo -e "   ${BOLD}1${NC}  Restore databases"
    echo -e "   ${BOLD}2${NC}  Restore config files"
    echo -e "   ${BOLD}3${NC}  Restore a VM from snapshot"
    echo -e "   ${BOLD}4${NC}  Full restore (DB + configs)"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local rs="${PROJ}/scripts/backup/restore.sh"
    case "${choice}" in
        1)
            echo -ne "  Backup timestamp (e.g. 20240101_120000): "; read -r ts
            run_module "DB Restore" "${rs}" --db "${ts}" ;;
        2)
            echo -ne "  Backup timestamp: "; read -r ts
            run_module "Config Restore" "${rs}" --configs "${ts}" ;;
        3)
            echo -ne "  VM name: "; read -r vm_name
            echo -ne "  Path to snapshot file: "; read -r snap_file
            run_module "VM Restore" "${rs}" --vm "${vm_name}" "${snap_file}" ;;
        4)
            echo -ne "  Backup timestamp: "; read -r ts
            run_module "Full Restore" "${rs}" --full "${ts}" ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: HARDENING
# =============================================================================
run_hardening() {
    show_banner
    echo -e "  ${BOLD}Server Hardening & Security Audit${NC}"
    echo ""
    echo -e "  Covers: SSH, firewall, kernel params, fail2ban, auditd,"
    echo -e "          auto-updates, file permissions, user policy, services"
    echo ""
    echo -e "   ${BOLD}1${NC}  Audit only   (check — no changes made)"
    echo -e "   ${BOLD}2${NC}  Harden       (check + auto-fix everything)"
    echo -e "   ${BOLD}3${NC}  View last report"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local hd="${PROJ}/scripts/hardening/server-harden.sh"
    case "${choice}" in
        1) HARDENING_AUDIT_ONLY="true"  bash "${hd}" ;;
        2) HARDENING_AUDIT_ONLY="false" bash "${hd}" ;;
        3)
            local last_report
            last_report=$(ls -t "${PROJ}/scripts/hardening/reports/"*.txt 2>/dev/null | head -1 || echo "")
            if [[ -n "${last_report}" ]]; then
                less "${last_report}"
            else
                warn "No reports found yet. Run an audit first."
            fi
            ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: SSL
# =============================================================================
run_ssl() {
    show_banner
    echo -e "  ${BOLD}SSL Certificate Management${NC}"
    echo ""
    echo -e "  ACME Email : ${ACME_EMAIL}"
    echo -e "  OS Domain  : ${OPENSTACK_DOMAIN}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Issue cert for a domain"
    echo -e "   ${BOLD}2${NC}  Renew all expiring certs"
    echo -e "   ${BOLD}3${NC}  Show cert status & expiry dates"
    echo -e "   ${BOLD}4${NC}  Secure OpenStack endpoints with HTTPS"
    echo -e "   ${BOLD}5${NC}  Install auto-renewal cron"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local ssl="${PROJ}/scripts/ssl/ssl-manager.sh"
    case "${choice}" in
        1)
            echo -ne "  Domains (space-separated): "; read -ra domains
            bash "${ssl}" --issue "${domains[@]}" ;;
        2) bash "${ssl}" --renew-all ;;
        3) bash "${ssl}" --status ;;
        4) bash "${ssl}" --openstack-endpoints ;;
        5) bash "${ssl}" --install-cron ;;
        b|B) show_menu; return ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# MODULE: VERIFY
# =============================================================================
run_verify() {
    run_module "Full Verification" "${PROJ}/scripts/base/08_verify.sh"
    press_enter; show_menu
}

# =============================================================================
# UTILITY: SHOW CONFIG
# =============================================================================
show_config() {
    show_banner
    echo -e "  ${BOLD}Current Configuration (configs/main.env)${NC}"
    echo ""
    echo -e "  ${CYAN}Node Settings${NC}"
    echo "    Deploy Mode    : ${DEPLOY_MODE}"
    local ip_disp="${HOST_IP}"
    [[ "${HOST_IP}" == "__CHANGE_ME__" ]] && ip_disp="⚠  NOT SET — run the Setup Wizard first"
    echo "    Host IP        : ${ip_disp}"
    echo "    Region         : ${REGION_NAME}"
    echo "    OS Release     : ${OS_RELEASE}"
    echo "    Config Version : ${CONFIG_VERSION:-unset}"
    echo ""
    echo -e "  ${CYAN}Extra Services${NC}"
    for svc in CINDER SWIFT HEAT CEILOMETER BARBICAN OCTAVIA MANILA DESIGNATE; do
        local var="INSTALL_${svc}"
        local val="${!var}"
        local icon; [[ "${val}" == "true" ]] && icon="${GREEN}✔${NC}" || icon="${RED}✖${NC}"
        printf "    %-16s : %b%s%b\n" "${svc}" "${icon}" "${val}" "${NC}"
    done
    echo ""
    echo -e "  ${CYAN}Secrets${NC}"
    local secrets_file="${PROJ}/configs/.secrets.env"
    local secrets_enc="${PROJ}/configs/.secrets.enc"
    if [[ -f "${secrets_enc}" ]]; then
        echo -e "    Source         : ${GREEN}.secrets.enc (encrypted)${NC}"
    elif [[ -f "${secrets_file}" ]]; then
        echo -e "    Source         : ${YELLOW}.secrets.env (plain — consider encrypting)${NC}"
    else
        echo -e "    Source         : ${RED}main.env (not recommended for production)${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}Operations${NC}"
    echo "    Backup Path    : ${BACKUP_PATH}"
    echo "    Backup Retain  : ${BACKUP_KEEP_DAYS} days"
    echo "    Log Retain     : ${LOG_KEEP_DAYS:-30} days"
    echo "    Swift Offsite  : ${SWIFT_BACKUP_ENABLED}"
    echo "    Slack Alerts   : $([ -n "${SLACK_WEBHOOK_URL}" ] && echo "configured" || echo "not set")"
    echo "    Alert Email    : $([ -n "${ALERT_EMAIL}" ] && echo "${ALERT_EMAIL}" || echo "not set")"
    echo "    SMTP Host      : $([ -n "${SMTP_HOST:-}" ] && echo "${SMTP_HOST}" || echo "not set")"
    echo ""
    echo -e "  ${CYAN}Security${NC}"
    echo "    Audit Only     : ${HARDENING_AUDIT_ONLY}"
    echo "    ACME Email     : ${ACME_EMAIL}"
    echo "    OS Domain      : ${OPENSTACK_DOMAIN}"
    echo ""
    echo -e "  ${DIM}Edit: nano ${CONFIG}${NC}"
    echo ""
    press_enter; show_menu
}

# =============================================================================
# UTILITY: VIEW LOGS
# =============================================================================
view_logs() {
    show_banner
    echo -e "  ${BOLD}Deployment Logs${NC}"
    echo ""

    local logs=()
    while IFS= read -r -d '' f; do
        logs+=("$f")
    done < <(find "${LOG_DIR}" -maxdepth 1 -name "deploy_*.log" -print0 2>/dev/null | sort -rz)

    if [[ ${#logs[@]} -eq 0 ]]; then
        warn "No logs found yet."
        press_enter; show_menu; return
    fi

    echo -e "  ${DIM}Recent logs (newest first):${NC}"
    echo ""
    local i=1
    for f in "${logs[@]:0:10}"; do
        local size; size=$(du -sh "${f}" 2>/dev/null | cut -f1)
        printf "   ${BOLD}%2d${NC}  %-45s  %s\n" "${i}" "$(basename "${f}")" "${size}"
        (( i++ ))
    done
    echo ""
    echo -ne "  Choose log number to view (or Enter for latest): "
    read -r log_choice

    local chosen
    if [[ -z "${log_choice}" ]]; then
        chosen="${logs[0]}"
    elif [[ "${log_choice}" =~ ^[0-9]+$ ]] && (( log_choice >= 1 && log_choice <= ${#logs[@]} )); then
        chosen="${logs[$(( log_choice - 1 ))]}"
    else
        warn "Invalid selection."
        press_enter; show_menu; return
    fi

    echo ""
    echo -e "   ${BOLD}1${NC}  Page through full log (less)"
    echo -e "   ${BOLD}2${NC}  Tail last 100 lines"
    echo -e "   ${BOLD}3${NC}  Search log (grep)"
    echo -ne "  Choice: "
    read -r view_mode

    case "${view_mode}" in
        1) less "${chosen}" ;;
        2) tail -100 "${chosen}" | less ;;
        3)
            echo -ne "  Search for: "
            read -r pattern
            grep --color=always -i "${pattern}" "${chosen}" | less -R
            ;;
        *) tail -50 "${chosen}" ;;
    esac

    press_enter; show_menu
}

# =============================================================================
# UTILITY: PRUNE OLD LOGS
# =============================================================================
prune_old_logs() {
    local keep="${LOG_KEEP_DAYS:-30}"
    local pruned=0
    while IFS= read -r -d '' f; do
        rm -f "${f}"
        (( pruned++ ))
    done < <(find "${LOG_DIR}" -maxdepth 1 -name "deploy_*.log" -mtime "+${keep}" -print0 2>/dev/null)

    (( pruned > 0 )) && log "Pruned ${pruned} log file(s) older than ${keep} days."
}

# =============================================================================
# HELPERS
# =============================================================================
ask_yes() {
    echo -ne "  ${YELLOW}$1${NC} (y/N): "
    read -r ans; [[ "${ans}" =~ ^[Yy]$ ]]
}

press_enter() {
    echo ""
    echo -ne "  ${DIM}Press Enter to continue...${NC}"
    read -r
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# --help can run without root
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help; exit 0
fi

require_root

# Auto-run the Setup Wizard if HOST_IP is still the factory sentinel.
if [[ "${HOST_IP}" == "__CHANGE_ME__" && \
      "${1:-}" != "--config" && \
      "${1:-}" != "--verify" && \
      "${1:-}" != "--dry-run" ]]; then
    echo -e "\n${YELLOW}  ⚠  It looks like this is your first run — HOST_IP has not been set.${NC}"
    echo -e "  The ${BOLD}Setup Wizard${NC} will guide you through IP and service selection.\n"
    sleep 1
    run_setup_wizard
fi

case "${1:-}" in
    --wizard)       run_setup_wizard ;;
    --menu)         show_menu ;;
    --full)         run_full_deployment ;;
    --base)         run_base_openstack ;;
    --services)     run_extra_services ;;
    --multinode)    run_multinode_setup ;;
    --k8s)          run_kubernetes ;;
    --monitor)      run_health_dashboard ;;
    --backup)       run_backup ;;
    --restore)      run_restore ;;
    --harden)       run_hardening ;;
    --ssl)          run_ssl ;;
    --verify)       run_verify ;;
    --config)       show_config ;;
    --resume)       RESUME_MODE=true; run_resume ;;
    --dry-run)      show_menu ;;   # --dry-run alone → show menu in dry-run mode
    *)              show_menu ;;
esac
