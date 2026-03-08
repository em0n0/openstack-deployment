#!/usr/bin/env bash
# =============================================================================
#   OpenStack Complete — Master Deployment Script  (v4.1)
#   Debian-based distros | OpenStack 2024.1 Caracal
#
#   USAGE:  sudo bash deploy.sh [FLAG]
#
#   FLAGS:
#     (none)        Interactive menu
#     --wizard      Re-run the Setup Wizard
#     --full        Deploy everything in main.env
#     --base        Base OpenStack only
#     --services    Extra services only
#     --resume      Continue an interrupted deployment
#     --multinode   Multi-node setup
#     --k8s         Deploy Kubernetes
#     --monitor     Health dashboard
#     --backup      Backup
#     --restore     Restore from backup
#     --harden      CIS security audit + auto-fix
#     --ssl         SSL certificate management
#     --verify      Health check all services
#     --config      Show current config
#     --quick       Wizard: accept auto-detected values, just set passwords
#     --rollback-step KEY  Roll back a single failed step (e.g. --rollback-step nova)
#     --dry-run     Preview all actions without executing
#     --help        Show this message
# =============================================================================

set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${PROJ}/configs/main.env"
LIB="${PROJ}/scripts/lib.sh"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_DIR="${PROJ}/logs"
LOG_FILE="${LOG_DIR}/deploy_${TIMESTAMP}.log"

# ─── PARSE FLAGS BEFORE SOURCING ──────────────────────────────────────────────
DRY_RUN=false
RESUME_MODE=false
QUICK_WIZARD=false
ROLLBACK_STEP_KEY=""
for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" ]]; then DRY_RUN=true; fi
    if [[ "${arg}" == "--resume"  ]]; then RESUME_MODE=true; fi
    if [[ "${arg}" == "--quick"   ]]; then QUICK_WIZARD=true; fi
done
# --rollback-step KEY: capture the key from the next argument
for i in "${!@}"; do
    if [[ "${!i:-}" == "--rollback-step" ]]; then
        next=$(( i + 1 ))
        ROLLBACK_STEP_KEY="${!next:-}"
    fi
done 2>/dev/null || true
export DRY_RUN QUICK_WIZARD

# ─── BOOTSTRAP ────────────────────────────────────────────────────────────────
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: configs/main.env not found."
    echo "Expected at: ${CONFIG}"
    echo "Make sure you run this script from inside the openstack-complete/ folder."
    exit 1
fi

if [[ ! -f "${LIB}" ]]; then
    echo "ERROR: scripts/lib.sh not found."
    echo "Expected at: ${LIB}"
    exit 1
fi

source "${CONFIG}"
source "${LIB}"

# Try to load encrypted/plain secrets file (optional, suppress all output on miss)
safe_source_secrets "${PROJ}/configs/.secrets.env" 2>/dev/null || true

mkdir -p "${LOG_DIR}"

# Colours already defined in lib.sh; re-declare DIM for safety
DIM='\033[2m'

# ─── CHECKPOINT FILE ──────────────────────────────────────────────────────────
CHECKPOINT_FILE="${LOG_DIR}/.deployment_checkpoint"
export CHECKPOINT_FILE

# ─── STEP PROGRESS COUNTERS ───────────────────────────────────────────────────
# Managed by run_step(). Shows [N/TOTAL] progress on each step banner.
DEPLOY_STEP_NUM=0
DEPLOY_TOTAL_STEPS=8   # updated by _run_base_steps / _run_service_steps

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════════════╗
  ║    ██████╗ ██████╗ ███████╗███╗  ██╗███████╗████████╗        ║
  ║   ██╔═══██╗██╔══██╗██╔════╝████╗ ██║██╔════╝╚══██╔══╝        ║
  ║   ██║   ██║██████╔╝█████╗  ██╔██╗██║███████╗   ██║           ║
  ║   ██║   ██║██╔═══╝ ██╔══╝  ██║╚████║╚════██║   ██║           ║
  ║   ╚██████╔╝██║     ███████╗██║ ╚███║███████║   ██║           ║
  ║    ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚══╝╚══════╝   ╚═╝           ║
  ║          C O M P L E T E   P R O J E C T   v4                ║
  ║         Debian-based  │  OpenStack 2024.1 Caracal             ║
  ╚═══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${YELLOW}${BOLD}  ── DRY-RUN MODE — no changes will be made ──${NC}"
        echo ""
    fi

    local ip_display="${HOST_IP}"
    if [[ "${HOST_IP}" == "__CHANGE_ME__" ]]; then
        ip_display="${RED}__CHANGE_ME__${NC}"
    fi

    if [[ -z "${DISTRO_ID:-}" ]]; then detect_distro; fi
    local hw="${HARDWARE_TYPE:-}"
    if [[ -z "${hw}" ]]; then
        hw=$(systemd-detect-virt 2>/dev/null || echo "unknown")
        if [[ "${hw}" == "none" ]]; then hw="physical"; fi
    fi

    echo -e "  ${DIM}Host: ${ip_display}  │  Mode: ${DEPLOY_MODE}  │  Region: ${REGION_NAME}${NC}"
    echo -e "  ${DIM}OS: ${DISTRO_ID:-unknown} ${DISTRO_VERSION:-}  │  HW: ${hw}  │  Kernel: $(uname -r)${NC}"
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
    echo -e "    --wizard       Run Setup Wizard (IP, interface, passwords, services)"
    echo -e "    --full         Deploy everything configured in main.env"
    echo -e "    --base         Base OpenStack only (Keystone → Horizon)"
    echo -e "    --services     Extra services only"
    echo -e "    --resume       Continue after a failed deployment"
    echo ""
    echo -e "  ${CYAN}Infrastructure${NC}"
    echo -e "    --multinode    Configure Controller / Compute / Storage nodes"
    echo -e "    --k8s          Deploy Kubernetes on OpenStack"
    echo ""
    echo -e "  ${CYAN}Operations${NC}"
    echo -e "    --monitor      Live health dashboard"
    echo -e "    --backup       Backup VMs, databases, configs"
    echo -e "    --restore      Restore from backup"
    echo ""
    echo -e "  ${CYAN}Security${NC}"
    echo -e "    --harden       CIS Benchmark audit + auto-fix"
    echo -e "    --ssl          Issue / renew Let's Encrypt certs"
    echo ""
    echo -e "  ${CYAN}Utility${NC}"
    echo -e "    --verify       Health check all services"
    echo -e "    --config       Show current configuration"
    echo -e "    --dry-run      Preview all actions without executing"
    echo -e "    --help         Show this message"
    echo ""
    echo -e "  ${DIM}No flag → interactive menu${NC}"
    echo ""
}

# =============================================================================
# SETUP WIZARD
# Steps: 1=IP  2=Interface  3=Admin password  4=DB password
#        5=Keystone endpoints  6=Extra services
# =============================================================================
run_setup_wizard() {
    show_banner
    detect_distro
    detect_hardware_type

    echo -e "  ${BOLD}${CYAN}Setup Wizard${NC}  — configure your deployment."
    echo -e "  ${DIM}Detected: ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME}) on ${HARDWARE_TYPE} hardware.${NC}"
    echo -e "  ${DIM}Answers are written to configs/main.env via Python (safe for all passwords).${NC}"
    if [[ "${QUICK_WIZARD}" == "true" || "${QUICK_SETUP:-false}" == "true" ]]; then
        echo -e "  ${GREEN}Quick mode:${NC} auto-detected IP and interface accepted. Only passwords required."
    fi
    echo ""

    # ── Step 1: Host IP ──────────────────────────────────────────────────────
    section "Step 1 of 6 — Host IP Address"

    local -a auto_ips=()
    while IFS= read -r line; do
        auto_ips+=("${line}")
    done < <(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.')

    if [[ "${HOST_IP}" != "__CHANGE_ME__" ]]; then
        echo -e "  ${GREEN}Auto-detected:${NC} ${BOLD}${HOST_IP}${NC}"
        echo -e "  ${DIM}Press Enter to accept, or pick/type a different one.${NC}"
    else
        echo -e "  ${YELLOW}Could not auto-detect IP.${NC} Please enter one below."
    fi

    if [[ ${#auto_ips[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}All addresses on this machine:${NC}"
        local idx=1
        for ip in "${auto_ips[@]}"; do
            local marker=""
            if [[ "${ip}" == "${HOST_IP}" ]]; then marker="  ${GREEN}← auto-detected${NC}"; fi
            echo -e "    ${BOLD}${idx}${NC}  ${ip}${marker}"
            idx=$(( idx + 1 ))
        done
        echo -e "  ${DIM}Enter a number, a custom IP, or blank to accept auto-detected.${NC}"
    fi
    echo ""

    local new_ip=""
    local ip_error=""

    # Quick mode: accept auto-detected IP without prompting
    if [[ "${QUICK_WIZARD}" == "true" || "${QUICK_SETUP:-false}" == "true" ]]; then
        if [[ "${HOST_IP}" != "__CHANGE_ME__" ]] && validate_ip "${HOST_IP}"; then
            new_ip="${HOST_IP}"
            ok "Quick mode: IP accepted as ${new_ip}"
        else
            echo -e "  ${YELLOW}Quick mode: IP not auto-detected. Please enter it manually.${NC}"
        fi
    fi

    while [[ -z "${new_ip}" ]]; do
        if [[ -n "${ip_error}" ]]; then
            echo -e "  ${RED}  ✖ ${ip_error}${NC}"
            ip_error=""
        fi
        echo -ne "  IP address [${HOST_IP}]: "
        read -r ip_input

        if [[ -z "${ip_input}" ]]; then
            new_ip="${HOST_IP}"
        elif [[ "${ip_input}" =~ ^[0-9]+$ ]] && \
             (( ip_input >= 1 && ip_input <= ${#auto_ips[@]} )); then
            new_ip="${auto_ips[$(( ip_input - 1 ))]}"
        else
            new_ip="${ip_input}"
        fi

        if [[ "${new_ip}" == "__CHANGE_ME__" ]]; then
            ip_error="Please enter a real IP address."
            continue
        fi

        if validate_ip "${new_ip}"; then
            break
        else
            ip_error="'${new_ip}' is not a valid IPv4 address."
        fi
    done
    ok "IP set to: ${BOLD}${new_ip}${NC}"

    # ── Step 2: Network interface ────────────────────────────────────────────
    section "Step 2 of 6 — Network Interface"
    echo -e "  ${DIM}Used by Neutron for VM traffic.${NC}"
    echo -e "  ${DIM}On bare-metal: use the NIC connected to your external/provider network.${NC}"
    echo ""

    detect_network_interfaces
    local new_iface="${INTERFACE_NAME}"

    if [[ ${#DETECTED_IFACES[@]} -eq 0 ]]; then
        warn "No physical NICs auto-detected. Enter the interface name manually."
        echo -ne "  Interface name [${INTERFACE_NAME}]: "
        read -r iface_input
        if [[ -n "${iface_input}" ]]; then new_iface="${iface_input}"; fi
    else
        # Show the auto-detected default prominently
        echo -e "  ${GREEN}Auto-detected:${NC} ${BOLD}${INTERFACE_NAME}${NC}"
        echo -e "  ${DIM}Press Enter to accept, or pick a different one below.${NC}"
        echo ""
        echo -e "  ${DIM}Available interfaces:${NC}"
        echo ""

        # Print menu with marker on the auto-detected one
        local i=1
        for iface in "${DETECTED_IFACES[@]}"; do
            local ip_addr; ip_addr=$(ip -4 addr show "${iface}" 2>/dev/null \
                | awk '/inet / {print $2}' | head -1)
            local state; state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
            local state_color="${GREEN}"
            if [[ "${state}" != "up" ]]; then state_color="${YELLOW}"; fi
            local auto_marker=""
            if [[ "${iface}" == "${INTERFACE_NAME}" ]]; then
                auto_marker="  ${GREEN}← auto-detected${NC}"
            fi
            printf "   ${BOLD}%d${NC}  %-12s  %b%-8s${NC}  %-18s%b\n" \
                "${i}" "${iface}" "${state_color}" "${state}" \
                "${ip_addr:-no IP assigned}" "${auto_marker}"
            i=$(( i + 1 ))
        done
        echo ""

        local default_idx=1
        for i in "${!DETECTED_IFACES[@]}"; do
            if [[ "${DETECTED_IFACES[$i]}" == "${INTERFACE_NAME}" ]]; then
                default_idx=$(( i + 1 ))
                break
            fi
        done

        local iface_error=""
        while true; do
            if [[ -n "${iface_error}" ]]; then
                echo -e "  ${RED}  ✖ ${iface_error}${NC}"
                iface_error=""
            fi
            echo -ne "  Choose interface [${default_idx}] or type name directly (blank = accept auto): "
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
                iface_error="'${iface_input}' is not a valid number or interface name."
            fi
        done
    fi

    # Warn if chosen interface already has an IP (SSH risk on bare-metal)
    local iface_ip
    iface_ip=$(ip -4 addr show "${new_iface}" 2>/dev/null | awk '/inet /{print $2}' | head -1 || true)
    if [[ -n "${iface_ip}" && "${HARDWARE_TYPE}" == "physical" ]]; then
        echo ""
        warn "${new_iface} has IP ${iface_ip} — Neutron will take control of this interface."
        warn "If this is your management/SSH interface, use a separate NIC for VM traffic."
        echo -ne "  Continue anyway? (y/N): "
        read -r proceed_iface
        if [[ ! "${proceed_iface}" =~ ^[Yy]$ ]]; then
            warn "Interface selection cancelled. Re-running wizard."
            run_setup_wizard
            return
        fi
    fi
    ok "Interface set to: ${BOLD}${new_iface}${NC}"

    # ── Step 3: Admin password ───────────────────────────────────────────────
    section "Step 3 of 6 — Admin Password"
    echo -e "  ${DIM}OpenStack admin account (Horizon dashboard + CLI).${NC}"
    echo -e "  ${DIM}Minimum 12 characters. Avoid: @ # \$ & ' \" \` ! \\${NC}"
    echo ""

    local new_admin_pass
    new_admin_pass=$(_prompt_password "Admin password" "${ADMIN_PASS}")
    ok "Admin password set.  $(_password_strength "${new_admin_pass}")"

    # ── Step 4: Database password ────────────────────────────────────────────
    section "Step 4 of 6 — Database (MariaDB) Password"
    echo -e "  ${DIM}Used for MariaDB root + all service databases.${NC}"
    echo -e "  ${DIM}Do not reuse your admin password.${NC}"
    echo ""

    local new_db_pass
    new_db_pass=$(_prompt_password "Database password" "${DB_PASS}")
    if [[ "${new_db_pass}" == "${new_admin_pass}" ]]; then
        warn "DB password matches admin password — not recommended."
    fi
    ok "DB password set.  $(_password_strength "${new_db_pass}")"

    # ── Step 5: Keystone service endpoints ──────────────────────────────────
    section "Step 5 of 6 — Keystone Service Endpoints"
    echo -e "  ${DIM}Choose which services get registered in the Keystone catalog.${NC}"
    echo -e "  ${DIM}Each gets public, internal, and admin endpoints.${NC}"
    echo -e "  ${DIM}Click a number to toggle. Keystone + Glance + Placement are always on.${NC}"
    echo ""
    echo -e "  ${YELLOW}Always on:${NC}  Keystone (5000)  Glance (9292)  Placement (8778)"
    echo ""

    local -a ks_keys=(    NOVA    NEUTRON  CINDER  SWIFT   HEAT    BARBICAN   DESIGNATE   OCTAVIA   MANILA   CEILOMETER )
    local -a ks_ports=(   8774    9696     8776    8080    8004    9311       9001        9876      8786     8777       )
    local -a ks_desc=(
        "Nova        — Compute API"
        "Neutron     — Networking API"
        "Cinder      — Block Storage"
        "Swift       — Object Storage"
        "Heat        — Orchestration"
        "Barbican    — Secrets Manager"
        "Designate   — DNS Service"
        "Octavia     — Load Balancer"
        "Manila      — Shared Filesystems"
        "Ceilometer  — Telemetry"
    )

    local -a ks_state=()
    for key in "${ks_keys[@]}"; do
        case "${key}" in
            NOVA|NEUTRON) ks_state+=("true") ;;
            *)
                local var="INSTALL_${key}"
                ks_state+=("${!var:-false}")
                ;;
        esac
    done

    local ks_done=false
    while [[ "${ks_done}" == "false" ]]; do
        echo ""
        for i in "${!ks_keys[@]}"; do
            local num=$(( i + 1 ))
            local icon
            if [[ "${ks_state[$i]}" == "true" ]]; then
                icon="${GREEN}[✔]${NC}"
            else
                icon="${RED}[✖]${NC}"
            fi
            local port="${ks_ports[$i]}"
            printf "   %b  ${BOLD}%2d${NC}  %-40s  %b\n" \
                "${icon}" "${num}" "${ks_desc[$i]}" \
                "$(if [[ "${ks_state[$i]}" == "true" ]]; then echo "${DIM}:${port}${NC}"; fi)"
        done
        echo ""
        echo -ne "  Toggle (1-${#ks_keys[@]}), ${BOLD}a${NC}=all on, ${BOLD}n${NC}=core only, ${BOLD}d${NC}=done: "
        read -r tog

        case "${tog}" in
            d|D) ks_done=true ;;
            a|A)
                for i in "${!ks_keys[@]}"; do ks_state[$i]="true"; done ;;
            n|N)
                for i in "${!ks_keys[@]}"; do
                    if [[ "${ks_keys[$i]}" == "NOVA" || "${ks_keys[$i]}" == "NEUTRON" ]]; then
                        ks_state[$i]="true"
                    else
                        ks_state[$i]="false"
                    fi
                done ;;
            [0-9]|1[0-9])
                local idx=$(( tog - 1 ))
                if (( idx >= 0 && idx < ${#ks_keys[@]} )); then
                    if [[ "${ks_keys[$idx]}" == "NOVA" || "${ks_keys[$idx]}" == "NEUTRON" ]]; then
                        warn "Nova and Neutron are required. Cannot disable."
                    elif [[ "${ks_state[$idx]}" == "true" ]]; then
                        ks_state[$idx]="false"
                    else
                        ks_state[$idx]="true"
                    fi
                else
                    warn "Invalid selection."
                fi ;;
            *) warn "Enter a number 1-${#ks_keys[@]}, a, n, or d." ;;
        esac
    done

    # ── Step 6: Extra services ───────────────────────────────────────────────
    section "Step 6 of 6 — Extra Services to Install"
    echo -e "  ${DIM}Pre-filled from your Keystone selections. Toggle to adjust.${NC}"
    echo ""

    local -a svc_keys=( CINDER   SWIFT    HEAT          CEILOMETER  BARBICAN  OCTAVIA         MANILA            DESIGNATE )
    local -a svc_desc=(
        "Cinder     — Block Storage (like AWS EBS)"
        "Swift      — Object Storage (like AWS S3)"
        "Heat       — Orchestration / IaC"
        "Ceilometer — Telemetry & Metrics (resource-heavy)"
        "Barbican   — Secrets Manager"
        "Octavia    — Load Balancer (needs Amphora image)"
        "Manila     — Shared Filesystems"
        "Designate  — DNS as a Service"
    )

    # Pre-fill from Keystone selections
    local -a svc_state=()
    for key in "${svc_keys[@]}"; do
        local pre="false"
        for i in "${!ks_keys[@]}"; do
            if [[ "${ks_keys[$i]}" == "${key}" ]]; then
                pre="${ks_state[$i]}"
                break
            fi
        done
        svc_state+=("${pre}")
    done

    local svc_done=false
    while [[ "${svc_done}" == "false" ]]; do
        echo ""
        for i in "${!svc_keys[@]}"; do
            local num=$(( i + 1 ))
            local icon
            if [[ "${svc_state[$i]}" == "true" ]]; then
                icon="${GREEN}[✔]${NC}"
            else
                icon="${RED}[✖]${NC}"
            fi
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
                    if [[ "${svc_state[$idx]}" == "true" ]]; then
                        svc_state[$idx]="false"
                    else
                        svc_state[$idx]="true"
                    fi
                else
                    warn "Invalid selection."
                fi ;;
            *) warn "Enter a number 1-${#svc_keys[@]}, a, n, or d." ;;
        esac
    done

    # ── Deploy mode ──────────────────────────────────────────────────────────
    echo ""
    echo -ne "  ${BOLD}Deployment mode${NC}  ${BOLD}1${NC} all-in-one  ${BOLD}2${NC} multi-node  [current: ${DEPLOY_MODE}]: "
    read -r mode_choice
    local new_mode="${DEPLOY_MODE}"
    case "${mode_choice}" in
        1) new_mode="all-in-one" ;;
        2) new_mode="multi-node" ;;
    esac

    # ── Build KEYSTONE_SERVICES_STR ──────────────────────────────────────────
    local ks_enabled_str="keystone glance placement"
    for i in "${!ks_keys[@]}"; do
        if [[ "${ks_state[$i]}" == "true" ]]; then
            ks_enabled_str+=" ${ks_keys[$i],,}"
        fi
    done

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    section "Summary — to be saved to configs/main.env"
    printf "    %-22s: %s\n"  "HOST_IP"          "${new_ip}"
    printf "    %-22s: %s\n"  "INTERFACE_NAME"   "${new_iface}"
    printf "    %-22s: %s\n"  "DEPLOY_MODE"      "${new_mode}"
    printf "    %-22s: %s\n"  "ADMIN_PASS"       "$(printf '%0.s*' $(seq 1 ${#new_admin_pass}))"
    printf "    %-22s: %s\n"  "DB_PASS"          "$(printf '%0.s*' $(seq 1 ${#new_db_pass}))"
    echo ""
    echo -e "  ${DIM}Keystone:${NC} ${ks_enabled_str}"
    echo ""
    for i in "${!svc_keys[@]}"; do
        local icon
        if [[ "${svc_state[$i]}" == "true" ]]; then
            icon="${GREEN}✔${NC}"
        else
            icon="${RED}✖${NC}"
        fi
        printf "    INSTALL_%-12s: %b%s%b\n" "${svc_keys[$i]}" "${icon}" "${svc_state[$i]}" "${NC}"
    done
    echo ""
    echo -ne "  ${BOLD}Save these settings to configs/main.env? (y/N):${NC} "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        warn "Wizard cancelled — no changes saved."
        press_enter
        show_menu
        return
    fi

    # ── Write to main.env using Python (safe for all password characters) ────
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would write settings to ${CONFIG}${NC}"
    else
        # Serialise INSTALL_ map as KEY=val pairs
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
            "${HARDWARE_TYPE:-unknown}" \
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
hw_type     = sys.argv[9]
install_raw = sys.argv[10]

# Parse comma-separated KEY=val pairs
install_map = {}
for entry in install_raw.rstrip(",").split(","):
    if "=" in entry:
        k, v = entry.split("=", 1)
        install_map[k.strip()] = v.strip()

# All values treated as plain strings — no sed special char issues
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
    "HARDWARE_TYPE":         hw_type,
    "CONFIG_VERSION":        "4.0",
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

# Append any keys not already in the file
for key, val in replacements.items():
    if key not in seen:
        new_lines.append(f'{key}="{val}"\n')

with open(cfg_path, "w") as f:
    f.writelines(new_lines)

print("  Settings written successfully.")
PYEOF

        source "${CONFIG}"
        ok "Settings saved to ${CONFIG}"
    fi

    echo ""
    echo -e "  ${DIM}Re-run this wizard any time: ${BOLD}sudo bash deploy.sh --wizard${NC}"
    press_enter
    show_menu
}

# ─── PASSWORD PROMPT ──────────────────────────────────────────────────────────
_prompt_password() {
    local label="$1"
    local current="${2:-}"
    local pw1 pw2

    while true; do
        echo -ne "  ${label} [blank = keep current]: "
        read -rs pw1; echo ""

        if [[ -z "${pw1}" ]]; then
            echo "${current}"
            return 0
        fi

        if [[ "${pw1}" =~ [\'\"\`\$\\\!\@\#\&] ]]; then
            warn "Avoid special chars: ' \" \` \$ \\ ! @ # & — they can break config parsing."
            continue
        fi

        if [[ "${#pw1}" -lt 12 ]]; then
            warn "Password is only ${#pw1} characters. 12 minimum, 16+ recommended."
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

# ─── PASSWORD STRENGTH METER ──────────────────────────────────────────────────
_password_strength() {
    local pw="$1"
    local score=0
    if (( ${#pw} >= 16 )); then score=$(( score + 1 )); fi
    if (( ${#pw} >= 24 )); then score=$(( score + 1 )); fi
    if [[ "${pw}" =~ [A-Z]       ]]; then score=$(( score + 1 )); fi
    if [[ "${pw}" =~ [0-9]       ]]; then score=$(( score + 1 )); fi
    if [[ "${pw}" =~ [^a-zA-Z0-9] ]]; then score=$(( score + 1 )); fi

    case "${score}" in
        5) echo -e "${GREEN}Strength: Very Strong ●●●●●${NC}" ;;
        4) echo -e "${GREEN}Strength: Strong      ●●●●○${NC}" ;;
        3) echo -e "${YELLOW}Strength: Medium      ●●●○○${NC}" ;;
        2) echo -e "${YELLOW}Strength: Weak        ●●○○○${NC}" ;;
        *) echo -e "${RED}Strength: Very Weak   ●○○○○${NC}" ;;
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
    echo -e "   ${BOLD}0${NC}  Setup Wizard            IP, interface, passwords, services"
    echo ""
    echo -e "  ${CYAN}── DEPLOYMENT ────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}1${NC}  Full Deployment         Everything in main.env"
    echo -e "   ${BOLD}2${NC}  Base OpenStack          Keystone → Nova → Neutron → Horizon"
    echo -e "   ${BOLD}3${NC}  Extra Services          Cinder, Swift, Heat, Barbican…"
    echo -e "   ${BOLD}4${NC}  Custom Selection        Pick individual services"
    echo -e "   ${BOLD}r${NC}  Resume Deployment       Continue after a failed run"
    echo ""
    echo -e "  ${CYAN}── INFRASTRUCTURE ────────────────────────────────────${NC}"
    echo -e "   ${BOLD}5${NC}  Multi-Node Setup        Controller / Compute / Storage"
    echo -e "   ${BOLD}6${NC}  Kubernetes on OpenStack K8s cluster inside your cloud"
    echo ""
    echo -e "  ${CYAN}── OPERATIONS ────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}7${NC}  Health Dashboard        Live monitoring"
    echo -e "   ${BOLD}8${NC}  Backup & DR             Backup VMs, databases, configs"
    echo -e "   ${BOLD}9${NC}  Restore                 Restore from a backup"
    echo ""
    echo -e "  ${CYAN}── SECURITY ──────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}10${NC}  Server Hardening        CIS Benchmark audit & auto-fix"
    echo -e "  ${BOLD}11${NC}  SSL Certificates        Let's Encrypt cert management"
    echo ""
    echo -e "  ${CYAN}── UTILITY ───────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}12${NC}  Verify Installation     Health check all services"
    echo -e "  ${BOLD}13${NC}  Show Config             Current configuration"
    echo -e "  ${BOLD}14${NC}  View Logs               Browse deployment logs"
    echo -e "   ${BOLD}q${NC}  Quit"
    echo ""
    echo -ne "  ${BOLD}Enter choice:${NC} "
    read -r choice
    handle_menu "${choice}"
}

handle_menu() {
    case "${1:-}" in
        0)   run_setup_wizard ;;
        1)   run_full_deployment ;;
        2)   run_base_openstack ;;
        3)   run_extra_services ;;
        4)   run_custom_selection ;;
        r|R) run_resume ;;
        5)   run_multinode_setup ;;
        6)   run_kubernetes ;;
        7)   run_health_dashboard ;;
        8)   run_backup ;;
        9)   run_restore ;;
        10)  run_hardening ;;
        11)  run_ssl ;;
        12)  run_verify ;;
        13)  show_config ;;
        14)  view_logs ;;
        q|Q|quit|exit) echo "Bye!"; exit 0 ;;
        *)   warn "Invalid choice: ${1:-}"; sleep 1; show_menu ;;
    esac
}

# =============================================================================
# MODULE RUNNER
# =============================================================================
run_module() {
    local title="$1"; local script="$2"; shift 2
    local args=("$@")

    log "Script: ${script} ${args[*]:-}"
    log "Log:    ${LOG_FILE}"
    start_timer

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would run: bash ${script} ${args[*]:-}${NC}"
        ok "${title} (dry-run skipped)"
        return 0
    fi

    if bash "${script}" "${args[@]:-}" 2>&1 | tee -a "${LOG_FILE}"; then
        ok "${title} completed in $(elapsed_human)"
    else
        # Capture exit code before calling step_failed (which returns 0)
        step_failed "${title}" "${title}" "${LOG_FILE}" 30
        return 1
    fi
}

# Checkpoint-aware step runner with progress display and rollback registration
run_step() {
    local key="$1"; local title="$2"; local script="$3"; shift 3

    if step_ran "${key}"; then
        echo -e "  ${DIM}⏭  Skipping '${title}' (already completed).${NC}"
        DEPLOY_STEP_NUM=$(( DEPLOY_STEP_NUM + 1 ))
        return 0
    fi

    DEPLOY_STEP_NUM=$(( DEPLOY_STEP_NUM + 1 ))
    progress_step "${DEPLOY_STEP_NUM}" "${DEPLOY_TOTAL_STEPS}" "${title}"

    # Register rollback before running — so if it fails we can clean up
    _register_step_rollback "${key}"

    run_module "${title}" "${script}" "$@"
    step_done "${key}"
}

# Built-in rollback commands for each known step.
# These are conservative: they remove what a step installs without touching
# anything that was already there before the step ran.
_register_step_rollback() {
    local key="$1"
    case "${key}" in
        prerequisites)
            register_rollback "${key}"                 "apt-get purge -y mariadb-server rabbitmq-server memcached etcd 2>/dev/null || true; apt-get autoremove -y 2>/dev/null || true"
            ;;
        keystone)
            register_rollback "${key}"                 "apt-get purge -y keystone 2>/dev/null || true; rm -rf /etc/keystone /var/lib/keystone /var/log/keystone; mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "\${DB_PASS}") -u root -e 'DROP DATABASE IF EXISTS keystone;' 2>/dev/null || true"
            ;;
        glance)
            register_rollback "${key}"                 "apt-get purge -y glance 2>/dev/null || true; rm -rf /etc/glance /var/lib/glance /var/log/glance; mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "\${DB_PASS}") -u root -e 'DROP DATABASE IF EXISTS glance;' 2>/dev/null || true"
            ;;
        placement)
            register_rollback "${key}"                 "apt-get purge -y placement-api 2>/dev/null || true; rm -rf /etc/placement /var/lib/placement; mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "\${DB_PASS}") -u root -e 'DROP DATABASE IF EXISTS placement;' 2>/dev/null || true"
            ;;
        nova)
            register_rollback "${key}"                 "apt-get purge -y nova-api nova-conductor nova-scheduler nova-compute nova-novncproxy 2>/dev/null || true; rm -rf /etc/nova /var/lib/nova /var/log/nova; mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "\${DB_PASS}") -u root -e 'DROP DATABASE IF EXISTS nova; DROP DATABASE IF EXISTS nova_api; DROP DATABASE IF EXISTS nova_cell0;' 2>/dev/null || true"
            ;;
        neutron)
            register_rollback "${key}"                 "apt-get purge -y neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent 2>/dev/null || true; rm -rf /etc/neutron /var/lib/neutron /var/log/neutron; mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "\${DB_PASS}") -u root -e 'DROP DATABASE IF EXISTS neutron;' 2>/dev/null || true"
            ;;
        horizon)
            register_rollback "${key}"                 "apt-get purge -y openstack-dashboard 2>/dev/null || true; rm -rf /etc/openstack-dashboard; systemctl reload apache2 2>/dev/null || true"
            ;;
        *)
            # Generic: remove any packages installed in the step (best-effort)
            register_rollback "${key}" "echo 'No specific rollback defined for step: ${key}'"
            ;;
    esac
}

# =============================================================================
# FULL DEPLOYMENT
# =============================================================================
run_full_deployment() {
    show_banner
    validate_config

    echo -e "  ${BOLD}Full Deployment${NC}"
    echo ""
    echo "    Base: Keystone  Glance  Placement  Nova  Neutron  Horizon"
    if [[ "${INSTALL_CINDER}"     == "true" ]]; then echo "    + Cinder (Block Storage)"; fi
    if [[ "${INSTALL_SWIFT}"      == "true" ]]; then echo "    + Swift (Object Storage)"; fi
    if [[ "${INSTALL_HEAT}"       == "true" ]]; then echo "    + Heat (Orchestration)"; fi
    if [[ "${INSTALL_CEILOMETER}" == "true" ]]; then echo "    + Ceilometer (Telemetry)"; fi
    if [[ "${INSTALL_BARBICAN}"   == "true" ]]; then echo "    + Barbican (Secrets)"; fi
    if [[ "${INSTALL_OCTAVIA}"    == "true" ]]; then echo "    + Octavia (Load Balancer)"; fi
    if [[ "${INSTALL_MANILA}"     == "true" ]]; then echo "    + Manila (Shared Filesystems)"; fi
    if [[ "${INSTALL_DESIGNATE}"  == "true" ]]; then echo "    + Designate (DNS)"; fi
    echo ""

    if [[ "${DRY_RUN}" != "true" ]]; then
        require_root
        require_debian_based
        require_internet
        require_disk_space 20
        require_ram 8
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        echo -ne "  ${BOLD}Proceed? Takes 20–40 minutes. (y/N):${NC} "
        read -r confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            show_menu
            return
        fi
    fi

    if [[ "${RESUME_MODE}" != "true" ]]; then
        clear_checkpoints
    fi

    local deploy_start; deploy_start=$(date +%s)

    _run_base_steps
    _run_service_steps

    if [[ "${DRY_RUN}" != "true" ]] && ask_yes "Run server hardening now?"; then
        run_step "hardening" "Server Hardening" "${PROJ}/scripts/hardening/server-harden.sh"
    fi

    local total=$(( $(date +%s) - deploy_start ))
    prune_old_logs

    # Run health check before the success banner
    health_check_table

    section "🎉 Full Deployment Complete"
    echo -e "${GREEN}${BOLD}"
    echo "  ✔ OpenStack is ready!"
    echo ""
    echo -e "${NC}  ${BOLD}Access your cloud:${NC}"
    echo ""
    echo -e "   ${CYAN}Dashboard${NC}    http://${HOST_IP}/horizon"
    echo -e "   ${CYAN}Username${NC}     admin"
    echo -e "   ${CYAN}Password${NC}     (your ADMIN_PASS from configs/main.env)"
    echo ""
    echo -e "   ${CYAN}CLI access${NC}   source configs/main.env"
    echo -e "                then: openstack server list"
    echo ""
    echo -e "   ${CYAN}Total time${NC}   $(printf "%dm %ds" $(( total/60 )) $(( total%60 )))"
    echo -e "   ${CYAN}Full log${NC}     ${LOG_FILE}"
    echo ""
    echo -e "   ${DIM}Re-run health check any time:  sudo bash deploy.sh --verify${NC}"
    echo ""

    press_enter
    show_menu
}

_run_base_steps() {
    # Count enabled extra services to set accurate total
    local extras=0
    for flag in INSTALL_CINDER INSTALL_SWIFT INSTALL_HEAT INSTALL_CEILOMETER                 INSTALL_BARBICAN INSTALL_OCTAVIA INSTALL_MANILA INSTALL_DESIGNATE; do
        if [[ "${!flag:-false}" == "true" ]]; then
            extras=$(( extras + 1 ))
        fi
    done
    DEPLOY_TOTAL_STEPS=$(( 8 + extras ))

    local base="${PROJ}/scripts/base"
    run_step "prerequisites" "System Prerequisites"  "${base}/01_prerequisites.sh"
    run_step "keystone"      "Keystone (Identity)"   "${base}/02_keystone.sh"
    run_step "glance"        "Glance (Images)"       "${base}/03_glance.sh"
    run_step "placement"     "Placement"             "${base}/04_placement.sh"
    run_step "nova"          "Nova (Compute)"        "${base}/05_nova.sh"
    run_step "neutron"       "Neutron (Networking)"  "${base}/06_neutron.sh"
    run_step "horizon"       "Horizon (Dashboard)"   "${base}/07_horizon.sh"
    run_step "verify_base"   "Base Verification"     "${base}/08_verify.sh"
}

_run_service_steps() {
    local svc="${PROJ}/scripts/services"
    if [[ "${INSTALL_CINDER}"     == "true" ]]; then run_step "cinder"     "Cinder (Block Storage)"     "${svc}/09_cinder.sh"; fi
    if [[ "${INSTALL_SWIFT}"      == "true" ]]; then run_step "swift"      "Swift (Object Storage)"     "${svc}/10_swift.sh"; fi
    if [[ "${INSTALL_HEAT}"       == "true" ]]; then run_step "heat"       "Heat (Orchestration)"       "${svc}/11_heat.sh"; fi
    if [[ "${INSTALL_CEILOMETER}" == "true" ]]; then run_step "ceilometer" "Ceilometer (Telemetry)"     "${svc}/12_ceilometer.sh"; fi
    if [[ "${INSTALL_BARBICAN}"   == "true" ]]; then run_step "barbican"   "Barbican (Secrets)"         "${svc}/13_barbican.sh"; fi
    if [[ "${INSTALL_OCTAVIA}"    == "true" ]]; then run_step "octavia"    "Octavia (Load Balancer)"    "${svc}/14_octavia.sh"; fi
    if [[ "${INSTALL_MANILA}"     == "true" ]]; then run_step "manila"     "Manila (Shared Filesystems)" "${svc}/15_manila.sh"; fi
    if [[ "${INSTALL_DESIGNATE}"  == "true" ]]; then run_step "designate"  "Designate (DNS)"            "${svc}/16_designate.sh"; fi
    ok "All enabled extra services installed."
}

run_base_openstack() {
    validate_config
    section "Base OpenStack Deployment"
    if [[ "${DRY_RUN}" != "true" ]]; then require_root; fi
    if [[ "${RESUME_MODE}" != "true" ]]; then clear_checkpoints; fi
    _run_base_steps
}

run_extra_services() {
    validate_config
    section "Extra OpenStack Services"
    _run_service_steps
}

# =============================================================================
# RESUME
# =============================================================================
run_resume() {
    if [[ ! -f "${CHECKPOINT_FILE}" ]]; then
        warn "No checkpoint file found. Nothing to resume."
        press_enter
        show_menu
        return
    fi

    show_banner
    echo -e "  ${BOLD}Resume Deployment${NC}"
    echo ""
    echo -e "  ${DIM}Steps already completed:${NC}"
    while IFS= read -r line; do
        echo -e "    ${GREEN}✔${NC}  ${line}"
    done < "${CHECKPOINT_FILE}"
    echo ""
    echo -ne "  ${BOLD}Continue from here? (y/N):${NC} "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        show_menu
        return
    fi

    RESUME_MODE=true
    run_full_deployment
}

# =============================================================================
# CUSTOM SELECTION
# =============================================================================
run_custom_selection() {
    show_banner
    echo -e "  ${BOLD}Custom Service Selection${NC}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Base OpenStack (required)"
    echo -e "   ${BOLD}2${NC}  Cinder — Block Storage"
    echo -e "   ${BOLD}3${NC}  Swift — Object Storage"
    echo -e "   ${BOLD}4${NC}  Heat — Orchestration"
    echo -e "   ${BOLD}5${NC}  Ceilometer — Telemetry"
    echo -e "   ${BOLD}6${NC}  Barbican — Secrets Manager"
    echo -e "   ${BOLD}7${NC}  Octavia — Load Balancer"
    echo -e "   ${BOLD}8${NC}  Manila — Shared Filesystems"
    echo -e "   ${BOLD}9${NC}  Designate — DNS Service"
    echo ""
    echo -ne "  Enter numbers to install (e.g. 1 2 6): "
    read -ra selections

    local svc="${PROJ}/scripts/services"
    for sel in "${selections[@]}"; do
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

    press_enter
    show_menu
}

# =============================================================================
# MULTI-NODE
# =============================================================================
run_multinode_setup() {
    show_banner
    echo -e "  ${BOLD}Multi-Node Setup${NC}"
    echo ""
    echo -e "  Controller : ${CONTROLLER_IP}"
    for ip in ${COMPUTE_IPS_STR}; do
        echo -e "  Compute    : ${ip}"
    done
    echo -e "  Storage    : ${STORAGE_IP}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Preflight — controller node"
    echo -e "   ${BOLD}2${NC}  Preflight — compute node"
    echo -e "   ${BOLD}3${NC}  Preflight — storage node"
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

    press_enter
    run_multinode_setup
}

# =============================================================================
# KUBERNETES
# =============================================================================
run_kubernetes() {
    show_banner
    echo -e "  ${BOLD}Kubernetes on OpenStack${NC}"
    echo ""
    echo -e "  Workers   : ${K8S_WORKER_COUNT}"
    echo -e "  Network   : ${K8S_EXTERNAL_NETWORK}"
    echo -e "  Pod CIDR  : ${K8S_POD_CIDR}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Deploy K8s cluster"
    echo -e "   ${BOLD}2${NC}  Destroy K8s cluster"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    case "${choice}" in
        1) run_module "Kubernetes Deployment" "${PROJ}/scripts/k8s/deploy-k8s.sh" "--workers" "${K8S_WORKER_COUNT}" ;;
        2) run_module "Kubernetes Destroy"    "${PROJ}/scripts/k8s/deploy-k8s.sh" "--destroy" ;;
        b|B) show_menu; return ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# HEALTH DASHBOARD
# =============================================================================
run_health_dashboard() {
    show_banner
    echo -e "  ${BOLD}Health Dashboard${NC}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Run once"
    echo -e "   ${BOLD}2${NC}  Live watch (refresh every ${MONITOR_INTERVAL}s)"
    echo -e "   ${BOLD}3${NC}  Run + send alerts if anything is down"
    echo -e "   ${BOLD}4${NC}  Install monitoring cron (every 5 min)"
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

    press_enter
    show_menu
}

# =============================================================================
# BACKUP
# =============================================================================
run_backup() {
    show_banner
    echo -e "  ${BOLD}Backup${NC}"
    echo ""
    echo -e "  Destination : ${BACKUP_PATH}"
    echo -e "  Retention   : ${BACKUP_KEEP_DAYS} days"
    echo ""
    echo -e "   ${BOLD}1${NC}  Full backup"
    echo -e "   ${BOLD}2${NC}  Databases only"
    echo -e "   ${BOLD}3${NC}  Config files only"
    echo -e "   ${BOLD}4${NC}  Glance images only"
    echo -e "   ${BOLD}5${NC}  VM snapshots only"
    echo -e "   ${BOLD}6${NC}  Install daily cron (2am)"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local bk="${PROJ}/scripts/backup/backup.sh"
    case "${choice}" in
        1) run_module "Full Backup"   "${bk}" ;;
        2) run_module "DB Backup"     "${bk}" --db-only ;;
        3) run_module "Config Backup" "${bk}" --configs ;;
        4) run_module "Image Backup"  "${bk}" --images ;;
        5) run_module "VM Backup"     "${bk}" --vms-only ;;
        6)
            echo "0 2 * * * root bash ${bk} >> ${LOG_DIR}/backup.log 2>&1" \
                | tee /etc/cron.d/openstack-backup
            ok "Backup cron installed."
            ;;
        b|B) show_menu; return ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# RESTORE
# =============================================================================
run_restore() {
    show_banner
    echo -e "  ${BOLD}Restore from Backup${NC}"
    echo ""
    bash "${PROJ}/scripts/backup/restore.sh" --list 2>/dev/null \
        || warn "No backups found at ${BACKUP_PATH}."
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
        1) echo -ne "  Backup timestamp: "; read -r ts
           run_module "DB Restore"     "${rs}" --db "${ts}" ;;
        2) echo -ne "  Backup timestamp: "; read -r ts
           run_module "Config Restore" "${rs}" --configs "${ts}" ;;
        3) echo -ne "  VM name: "; read -r vm_name
           echo -ne "  Snapshot file: "; read -r snap_file
           run_module "VM Restore"     "${rs}" --vm "${vm_name}" "${snap_file}" ;;
        4) echo -ne "  Backup timestamp: "; read -r ts
           run_module "Full Restore"   "${rs}" --full "${ts}" ;;
        b|B) show_menu; return ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# HARDENING
# =============================================================================
run_hardening() {
    show_banner
    echo -e "  ${BOLD}Server Hardening & Security Audit${NC}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Audit only   (check, no changes)"
    echo -e "   ${BOLD}2${NC}  Harden       (check + auto-fix)"
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
                warn "No reports found. Run an audit first."
            fi ;;
        b|B) show_menu; return ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# SSL
# =============================================================================
run_ssl() {
    show_banner
    echo -e "  ${BOLD}SSL Certificate Management${NC}"
    echo ""
    echo -e "  ACME Email : ${ACME_EMAIL}"
    echo -e "  Domain     : ${OPENSTACK_DOMAIN}"
    echo ""
    echo -e "   ${BOLD}1${NC}  Issue cert for a domain"
    echo -e "   ${BOLD}2${NC}  Renew all expiring certs"
    echo -e "   ${BOLD}3${NC}  Show cert status & expiry"
    echo -e "   ${BOLD}4${NC}  Secure OpenStack endpoints"
    echo -e "   ${BOLD}5${NC}  Install auto-renewal cron"
    echo -e "   ${BOLD}b${NC}  Back"
    echo ""
    echo -ne "  Choice: "; read -r choice

    local ssl="${PROJ}/scripts/ssl/ssl-manager.sh"
    case "${choice}" in
        1) echo -ne "  Domains (space-separated): "; read -ra domains
           bash "${ssl}" --issue "${domains[@]}" ;;
        2) bash "${ssl}" --renew-all ;;
        3) bash "${ssl}" --status ;;
        4) bash "${ssl}" --openstack-endpoints ;;
        5) bash "${ssl}" --install-cron ;;
        b|B) show_menu; return ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# VERIFY
# =============================================================================
run_verify() {
    run_module "Full Verification" "${PROJ}/scripts/base/08_verify.sh"
    press_enter
    show_menu
}

# =============================================================================
# SHOW CONFIG
# =============================================================================
show_config() {
    show_banner
    echo -e "  ${BOLD}Current Configuration${NC}  (${CONFIG})"
    echo ""
    echo -e "  ${CYAN}Node${NC}"
    local ip_disp="${HOST_IP}"
    if [[ "${HOST_IP}" == "__CHANGE_ME__" ]]; then
        ip_disp="${RED}⚠  NOT SET — run Setup Wizard${NC}"
    fi
    echo -e "    Deploy Mode  : ${DEPLOY_MODE}"
    echo -e "    Host IP      : ${ip_disp}"
    echo -e "    Interface    : ${INTERFACE_NAME}"
    echo -e "    Region       : ${REGION_NAME}"
    echo -e "    Config Ver   : ${CONFIG_VERSION:-unset}"
    echo -e "    Distro       : ${DISTRO_ID:-unknown} ${DISTRO_VERSION:-}"
    echo -e "    Hardware     : ${HARDWARE_TYPE:-unknown}"
    echo ""

    echo -e "  ${CYAN}Secrets source${NC}"
    if [[ -f "${PROJ}/configs/.secrets.enc" ]]; then
        echo -e "    ${GREEN}.secrets.enc (encrypted)${NC}"
    elif [[ -f "${PROJ}/configs/.secrets.env" ]]; then
        echo -e "    ${YELLOW}.secrets.env (plain — consider encrypting)${NC}"
    else
        echo -e "    ${RED}main.env (not recommended for production)${NC}"
    fi
    echo ""

    echo -e "  ${CYAN}Extra Services${NC}"
    for svc in CINDER SWIFT HEAT CEILOMETER BARBICAN OCTAVIA MANILA DESIGNATE; do
        local var="INSTALL_${svc}"
        local val="${!var:-false}"
        local icon
        if [[ "${val}" == "true" ]]; then icon="${GREEN}✔${NC}"; else icon="${RED}✖${NC}"; fi
        printf "    %-16s : %b%s%b\n" "${svc}" "${icon}" "${val}" "${NC}"
    done
    echo ""

    echo -e "  ${CYAN}Operations${NC}"
    echo -e "    Backup Path  : ${BACKUP_PATH}"
    echo -e "    Backup Retain: ${BACKUP_KEEP_DAYS} days"
    echo -e "    Log Retain   : ${LOG_KEEP_DAYS:-30} days"
    echo -e "    Slack Alerts : $(if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then echo "configured"; else echo "not set"; fi)"
    echo -e "    Alert Email  : $(if [[ -n "${ALERT_EMAIL}" ]]; then echo "${ALERT_EMAIL}"; else echo "not set"; fi)"
    echo ""

    echo -e "  ${DIM}Edit: nano ${CONFIG}${NC}"
    echo ""
    press_enter
    show_menu
}

# =============================================================================
# VIEW LOGS
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
        press_enter
        show_menu
        return
    fi

    local i=1
    for f in "${logs[@]:0:10}"; do
        local size; size=$(du -sh "${f}" 2>/dev/null | cut -f1)
        printf "   ${BOLD}%2d${NC}  %-45s  %s\n" "${i}" "$(basename "${f}")" "${size}"
        i=$(( i + 1 ))
    done
    echo ""
    echo -ne "  Log number (Enter = latest): "
    read -r log_choice

    local chosen="${logs[0]}"
    if [[ -n "${log_choice}" ]] && \
       [[ "${log_choice}" =~ ^[0-9]+$ ]] && \
       (( log_choice >= 1 && log_choice <= ${#logs[@]} )); then
        chosen="${logs[$(( log_choice - 1 ))]}"
    fi

    echo ""
    echo -e "   ${BOLD}1${NC}  Page (less)    ${BOLD}2${NC}  Last 100 lines    ${BOLD}3${NC}  Search"
    echo -ne "  View mode: "
    read -r view_mode

    case "${view_mode}" in
        2) tail -100 "${chosen}" | less ;;
        3) echo -ne "  Search for: "; read -r pattern
           grep --color=always -i "${pattern}" "${chosen}" | less -R ;;
        *) less "${chosen}" ;;
    esac

    press_enter
    show_menu
}

# =============================================================================
# UTILITIES
# =============================================================================
ask_yes() {
    echo -ne "  ${YELLOW}$1${NC} (y/N): "
    read -r ans
    [[ "${ans}" =~ ^[Yy]$ ]]
}

press_enter() {
    echo ""
    echo -ne "  ${DIM}Press Enter to continue...${NC}"
    read -r
}

prune_old_logs() {
    local keep="${LOG_KEEP_DAYS:-30}"
    local pruned=0
    while IFS= read -r -d '' f; do
        rm -f "${f}"
        pruned=$(( pruned + 1 ))
    done < <(find "${LOG_DIR}" -maxdepth 1 -name "deploy_*.log" -mtime "+${keep}" -print0 2>/dev/null)
    if (( pruned > 0 )); then
        log "Pruned ${pruned} log file(s) older than ${keep} days."
    fi
}

# =============================================================================
# ROLLBACK SINGLE STEP
# =============================================================================
run_rollback_step_cmd() {
    local key="${1:-}"
    show_banner
    if [[ -z "${key}" ]]; then
        echo -e "  ${YELLOW}Usage:${NC} sudo bash deploy.sh --rollback-step KEY"
        echo ""
        echo -e "  ${BOLD}Available step keys:${NC}"
        echo -e "   prerequisites  keystone  glance  placement"
        echo -e "   nova  neutron  horizon  verify_base"
        echo -e "   cinder  swift  heat  ceilometer  barbican  octavia  manila  designate"
        echo ""
        echo -e "  ${DIM}This removes what a single step installed and clears its checkpoint,${NC}"
        echo -e "  ${DIM}so you can re-run --resume after fixing the underlying issue.${NC}"
        press_enter
        show_menu
        return
    fi

    echo -e "  ${YELLOW}${BOLD}Rollback: ${key}${NC}"
    echo ""
    echo -e "  This will:"
    echo -e "   • Run the rollback command for step '${key}'"
    echo -e "   • Remove '${key}' from the checkpoint file"
    echo -e "   • Let you re-run this step with:  sudo bash deploy.sh --resume"
    echo ""
    echo -ne "  ${BOLD}Proceed? (y/N):${NC} "
    read -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        show_menu
        return
    fi

    # Register and immediately execute the rollback for this step
    _register_step_rollback "${key}"
    rollback_step "${key}"

    echo ""
    echo -e "  ${GREEN}Rollback complete.${NC}"
    echo -e "  Fix the issue, then resume with:  ${CYAN}sudo bash deploy.sh --resume${NC}"
    press_enter
    show_menu
}

# =============================================================================
# ENTRY POINT
# =============================================================================

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

require_root

# Auto-run wizard only if IP genuinely could not be detected
if [[ "${HOST_IP}" == "__CHANGE_ME__" ]] && \
   [[ "${1:-}" != "--config" ]] && \
   [[ "${1:-}" != "--verify" ]] && \
   [[ "${1:-}" != "--dry-run" ]]; then
    echo -e "\n${YELLOW}  ⚠  Could not auto-detect HOST_IP.${NC}"
    echo -e "  The ${BOLD}Setup Wizard${NC} will guide you through configuration.\n"
    sleep 1
    run_setup_wizard
fi

case "${1:-}" in
    --wizard)        run_setup_wizard ;;
    --quick)         QUICK_WIZARD=true; run_setup_wizard ;;
    --menu)          show_menu ;;
    --full)          run_full_deployment ;;
    --base)          run_base_openstack ;;
    --services)      run_extra_services ;;
    --resume)        RESUME_MODE=true; run_resume ;;
    --rollback-step) run_rollback_step_cmd "${2:-}" ;;
    --multinode)     run_multinode_setup ;;
    --k8s)           run_kubernetes ;;
    --monitor)       run_health_dashboard ;;
    --backup)        run_backup ;;
    --restore)       run_restore ;;
    --harden)        run_hardening ;;
    --ssl)           run_ssl ;;
    --verify)        run_verify ;;
    --config)        show_config ;;
    --dry-run)       show_menu ;;
    *)               show_menu ;;
esac
