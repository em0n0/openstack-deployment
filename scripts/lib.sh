#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared Helper Library  (v4.1)
# Sourced by every script in the project. Never run directly.
#
# Changes vs v4.0:
#   • error()           — optional 2nd arg: fix-hint printed inline
#   • error_with_fix()  — bordered error+fix box for critical failures
#   • step_failed()     — dumps last N log lines + recovery menu
#   • progress_step()   — "[3/8] ▸ Nova" style progress banner
#   • register_rollback / run_rollbacks / rollback_step — undo registry
#   • validate_config() — groups all errors, shows exact fix commands
#   • require_debian_based() — kernel version warning made actionable
# =============================================================================

# ─── COLOURS ──────────────────────────────────────────────────────────────────
RED='\\033[0;31m'; GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'; CYAN='\\033[0;36m'; BOLD='\\033[1m'; DIM='\\033[2m'
MAGENTA='\\033[0;35m'; NC='\\033[0m'

# ─── DRY-RUN GLOBAL FLAG ──────────────────────────────────────────────────────
: "${DRY_RUN:=false}"

# ─── LOGGING ──────────────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()      { echo -e "${GREEN}  ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}▸ $1${NC}\n${CYAN}$(printf '─%.0s' {1..55})${NC}"; }

# error "message" ["fix hint"]
# Prints a red error. If a second argument is provided it prints a fix hint
# on the next line. Exits in sub-shells, returns 1 in the main shell.
error() {
    local msg="$1"
    local hint="${2:-}"
    echo -e "${RED}  ✖ ERROR:${NC} ${msg}" >&2
    if [[ -n "${hint}" ]]; then
        echo -e "${YELLOW}    ➜ Fix:${NC} ${hint}" >&2
    fi
    if (( BASH_SUBSHELL > 0 )); then
        exit 1
    else
        return 1
    fi
}

# error_with_fix "title" "detail" "fix command or instruction"
# Draws a bordered box — used for critical pre-flight failures where the user
# needs to read carefully before doing anything.
error_with_fix() {
    local title="$1"
    local detail="$2"
    local fix="$3"
    local width=60
    local bar; bar=$(printf '─%.0s' $(seq 1 ${width}))
    echo -e "${RED}"                                      >&2
    echo -e "  ┌${bar}┐"                                 >&2
    printf  "  │ %-${width}s│\n" "✖  ${title}"           >&2
    echo -e "  ├${bar}┤"                                 >&2
    # Word-wrap detail across multiple lines at width-2 chars
    local wrapped; wrapped=$(echo "${detail}" | fold -s -w $(( width - 2 )))
    while IFS= read -r line; do
        printf "  │ %-${width}s│\n" "${line}"            >&2
    done <<< "${wrapped}"
    echo -e "  ├${bar}┤"                                 >&2
    printf  "  │ ${YELLOW}➜ Fix:${RED} %-$(( width - 7 ))s│\n" "${fix}" >&2
    echo -e "  └${bar}┘"                                 >&2
    echo -e "${NC}"                                       >&2
}

# ─── PROGRESS STEP BANNER ─────────────────────────────────────────────────────
# progress_step CURRENT TOTAL LABEL
# Prints:  [ 3 / 8 ]  ▸  Nova (Compute)  ─────────────────────
# deploy.sh manages the counters; this just formats them.
progress_step() {
    local current="$1"
    local total="$2"
    local label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( current * 20 / total ))
    local empty=$(( 20 - filled ))
    local bar=""
    bar+=$(printf '█%.0s' $(seq 1 ${filled}))
    bar+=$(printf '░%.0s' $(seq 1 ${empty}))

    echo -e ""
    echo -e "${CYAN}${BOLD}  [ ${current} / ${total} ]  ▸  ${label}${NC}"
    echo -e "  ${BLUE}${bar}${NC}  ${pct}%"
    echo -e "  ${CYAN}$(printf '─%.0s' {1..55})${NC}"
}

# ─── STEP FAILURE HANDLER ─────────────────────────────────────────────────────
# step_failed STEP_KEY STEP_TITLE LOG_FILE
# Called when a deployment step exits non-zero. Shows the last lines of the
# log, explains what to do next, and offers rollback if registered.
step_failed() {
    local key="$1"
    local title="$2"
    local logfile="${3:-}"
    local lines="${4:-25}"

    echo -e "\n${RED}${BOLD}  ✖  Step failed: ${title}${NC}"
    echo -e "${RED}  $(printf '─%.0s' {1..55})${NC}"

    if [[ -n "${logfile}" && -f "${logfile}" ]]; then
        echo -e "\n${YELLOW}  Last ${lines} lines of log (${logfile}):${NC}\n"
        tail -n "${lines}" "${logfile}" | while IFS= read -r line; do
            # Highlight lines that look like errors
            if echo "${line}" | grep -qiE '(error|fail|fatal|exception|traceback|refused|denied|not found)'; then
                echo -e "  ${RED}${line}${NC}"
            else
                echo -e "  ${DIM}${line}${NC}"
            fi
        done
    fi

    echo -e "\n${YELLOW}  Recovery options:${NC}"
    echo -e "   ${BOLD}1${NC}  Fix the issue and resume:        ${CYAN}sudo bash deploy.sh --resume${NC}"
    echo -e "   ${BOLD}2${NC}  Roll back this step only:        ${CYAN}sudo bash deploy.sh --rollback-step ${key}${NC}"
    echo -e "   ${BOLD}3${NC}  View full log:                   ${CYAN}less ${logfile:-logs/deploy_latest.log}${NC}"
    echo -e "   ${BOLD}4${NC}  Run setup wizard again:          ${CYAN}sudo bash deploy.sh --wizard${NC}"
    echo -e "   ${BOLD}5${NC}  Check OpenStack docs:            ${CYAN}https://docs.openstack.org/caracal/${NC}"
    echo ""

    # Common pattern matching for known failure modes
    if [[ -n "${logfile}" && -f "${logfile}" ]]; then
        local last_errors; last_errors=$(tail -50 "${logfile}" | grep -iE '(error|fail)' | tail -5)
        if echo "${last_errors}" | grep -q "Unable to reach"; then
            warn "Looks like a network connectivity issue. Check: ping 8.8.8.8"
        fi
        if echo "${last_errors}" | grep -q "Access denied"; then
            warn "Database permission error. Verify DB_PASS in configs/main.env matches MariaDB root."
        fi
        if echo "${last_errors}" | grep -q "Address already in use"; then
            warn "Port conflict. Another service may be using a required port."
            warn "Check: sudo ss -tlnp | grep -E '(5000|8774|9292|9696)'"
        fi
        if echo "${last_errors}" | grep -q "No space left"; then
            warn "Disk full. OpenStack needs at least 20GB free."
            warn "Check: df -h /"
        fi
    fi
}

# ─── DRY-RUN WRAPPERS ─────────────────────────────────────────────────────────
run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

run_mysql() {
    local sql="$1"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] mysql:${NC} ${sql}"
        return 0
    fi
    mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS}") \
          -u root <<< "${sql}" 2>/dev/null
}

# ─── ROLLBACK REGISTRY ────────────────────────────────────────────────────────
# Each deployment step registers its undo command here before running.
# If a step fails, run_rollbacks can reverse what was done.
#
# Usage:
#   register_rollback "keystone" "apt-get purge -y keystone; rm -rf /etc/keystone"
#   rollback_step "keystone"         # undo one specific step
#   run_rollbacks                    # undo all registered steps (reverse order)

declare -a _ROLLBACK_KEYS=()
declare -A _ROLLBACK_CMDS=()

register_rollback() {
    local key="$1"
    local cmd="$2"
    _ROLLBACK_KEYS+=("${key}")
    _ROLLBACK_CMDS["${key}"]="${cmd}"
}

rollback_step() {
    local key="$1"
    if [[ -z "${_ROLLBACK_CMDS[${key}]:-}" ]]; then
        warn "No rollback registered for step '${key}'."
        return 0
    fi
    section "Rolling back: ${key}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would run: ${_ROLLBACK_CMDS[${key}]}${NC}"
        return 0
    fi
    log "Executing rollback for '${key}'..."
    eval "${_ROLLBACK_CMDS[${key}]}" 2>/dev/null || true
    # Remove from checkpoint file so the step can be re-run
    if [[ -f "${CHECKPOINT_FILE:-/tmp/.deployment_checkpoint}" ]]; then
        sed -i "/^${key}$/d" "${CHECKPOINT_FILE}" 2>/dev/null || true
    fi
    ok "Rollback complete for '${key}'."
}

run_rollbacks() {
    local i
    if [[ ${#_ROLLBACK_KEYS[@]} -eq 0 ]]; then
        warn "No rollbacks registered."
        return 0
    fi
    section "Running all rollbacks (reverse order)"
    for (( i=${#_ROLLBACK_KEYS[@]}-1; i>=0; i-- )); do
        rollback_step "${_ROLLBACK_KEYS[$i]}"
    done
    ok "All rollbacks complete."
}

# ─── DISTRO DETECTION ─────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
        local id_like="${ID_LIKE:-}"
        if [[ "${DISTRO_ID}" == "debian" || "${id_like}" == *"debian"* || "${id_like}" == *"ubuntu"* ]]; then
            DISTRO_FAMILY="debian"
        else
            DISTRO_FAMILY="${DISTRO_ID}"
        fi
    else
        DISTRO_ID="unknown"; DISTRO_VERSION="unknown"
        DISTRO_CODENAME="unknown"; DISTRO_FAMILY="unknown"
    fi
    export DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_FAMILY
}

# ─── HARDWARE DETECTION ───────────────────────────────────────────────────────
detect_hardware_type() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt; virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        case "${virt}" in
            none)                                                         HARDWARE_TYPE="physical" ;;
            kvm|qemu|vmware|virtualbox|xen|hyperv|parallels|bhyve)      HARDWARE_TYPE="vm" ;;
            docker|lxc*|openvz|podman|systemd-nspawn)                   HARDWARE_TYPE="container" ;;
            *)                                                            HARDWARE_TYPE="vm" ;;
        esac
    else
        HARDWARE_TYPE="unknown"
    fi
    export HARDWARE_TYPE

    if [[ "${HARDWARE_TYPE}" == "physical" ]]; then
        echo -e "\n${YELLOW}${BOLD}  ── Bare-Metal Deployment Detected ──${NC}"
        echo -e "  ${DIM}Verify before deploying on real hardware:${NC}"
        echo -e "   ${CYAN}•${NC} CPU virtualisation (VT-x / AMD-V) enabled in BIOS/UEFI"
        echo -e "   ${CYAN}•${NC} 2 NICs recommended — one management, one for VM traffic"
        echo -e "   ${CYAN}•${NC} NTP reachable — clock skew breaks Keystone token validation"
        echo -e "   ${CYAN}•${NC} IOMMU enabled for GPU/SR-IOV passthrough (optional)"
        echo ""
    fi
}

# ─── NETWORK INTERFACE DISCOVERY ──────────────────────────────────────────────
detect_network_interfaces() {
    DETECTED_IFACES=()
    local -a skip_prefixes=( lo docker virbr veth tun tap br- lxc lxd vnet dummy )

    while IFS= read -r iface; do
        local skip=false
        for pfx in "${skip_prefixes[@]}"; do
            if [[ "${iface}" == "${pfx}"* ]]; then
                skip=true
                break
            fi
        done
        if ${skip}; then continue; fi

        if [[ -e "/sys/class/net/${iface}/device" ]] || \
           [[ "$(cat /sys/class/net/${iface}/type 2>/dev/null)" == "1" ]]; then
            DETECTED_IFACES+=("${iface}")
        fi
    done < <(ls /sys/class/net/ 2>/dev/null | sort)

    export DETECTED_IFACES
    return 0   # always return 0 — non-zero would trigger set -e
}

print_iface_menu() {
    local i=1
    for iface in "${DETECTED_IFACES[@]}"; do
        local ip_addr; ip_addr=$(ip -4 addr show "${iface}" 2>/dev/null \
            | awk '/inet / {print $2}' | head -1)
        local state; state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        local state_color="${GREEN}"
        if [[ "${state}" != "up" ]]; then state_color="${YELLOW}"; fi
        printf "   ${BOLD}%d${NC}  %-12s  %b%-8s${NC}  %s\n" \
            "${i}" "${iface}" "${state_color}" "${state}" "${ip_addr:-no IP assigned}"
        i=$(( i + 1 ))
    done
}

# ─── DISTRO-AWARE PACKAGE NAMES ───────────────────────────────────────────────
get_os_pkg() {
    local logical="$1"
    case "${logical}" in
        mariadb-server)          echo "mariadb-server" ;;
        python3-openstackclient) echo "python3-openstackclient" ;;
        openstack-dashboard)     echo "openstack-dashboard" ;;
        *)                       echo "${logical}" ;;
    esac
}

# ─── GUARDS ───────────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error_with_fix \
            "Must run as root" \
            "This script modifies system packages, databases, and services. Root access is required." \
            "sudo bash $0 $*"
        return 1
    fi
}

require_debian_based() {
    detect_distro

    if [[ "${DISTRO_FAMILY}" != "debian" ]]; then
        error_with_fix \
            "Unsupported distribution: ${DISTRO_ID}" \
            "This project requires a Debian-based distro (Ubuntu 20.04+, Debian 11+, or Linux Mint 21+). Detected: ${DISTRO_ID} (family: ${DISTRO_FAMILY})." \
            "Install on Ubuntu 22.04 LTS or Ubuntu 24.04 LTS for best results."
        return 1
    fi

    if ! command -v apt-get &>/dev/null; then
        error_with_fix "apt-get not found" \
            "apt-get is required to install OpenStack packages." \
            "Ensure you are on a Debian-based system with apt installed."
        return 1
    fi

    if ! command -v systemctl &>/dev/null; then
        error_with_fix "systemd not found" \
            "systemd is required to manage OpenStack services." \
            "This project does not support SysV init or OpenRC."
        return 1
    fi

    local kernel_major kernel_minor
    IFS='.' read -r kernel_major kernel_minor _ <<< "$(uname -r)"
    if (( kernel_major < 5 || ( kernel_major == 5 && kernel_minor < 4 ) )); then
        warn "Kernel $(uname -r) is older than 5.4. Some Neutron features may not work."
        warn "Upgrade with: sudo apt-get install --install-recommends linux-generic"
    fi

    case "${DISTRO_ID}" in
        ubuntu)
            local major="${DISTRO_VERSION%%.*}"
            if (( major < 20 )); then
                error_with_fix \
                    "Ubuntu ${DISTRO_VERSION} is too old" \
                    "Ubuntu 20.04 or newer is required. Older releases do not have the required OpenStack package versions." \
                    "Upgrade to Ubuntu 22.04 LTS: https://ubuntu.com/server/docs/upgrade-introduction"
                return 1
            fi ;;
        debian)
            local major="${DISTRO_VERSION%%.*}"
            if (( major < 11 )); then
                warn "Debian ${DISTRO_VERSION} is old. Debian 11 (Bullseye) or newer is recommended."
            fi ;;
        linuxmint|pop|elementary|zorin)
            warn "${DISTRO_ID} ${DISTRO_VERSION} — community-supported, not fully tested." ;;
        raspbian|raspi)
            warn "Raspberry Pi OS — ARM64 with 8 GB+ RAM recommended. Expect slower build times." ;;
    esac

    ok "Distro: ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME}) [${DISTRO_FAMILY}]"
}

require_internet() {
    local connected=false
    for host in 8.8.8.8 1.1.1.1 9.9.9.9; do
        if ping -c 1 -W 3 "${host}" &>/dev/null; then
            connected=true
            break
        fi
    done
    if [[ "${connected}" != "true" ]]; then
        error_with_fix \
            "No internet connection detected" \
            "OpenStack packages are downloaded from apt repositories during installation. An internet connection is required." \
            "Check your network: ip route show default && ping -c 3 8.8.8.8"
        return 1
    fi
}

require_disk_space() {
    local min_gb="${1:-20}"
    local avail_kb; avail_kb=$(df / --output=avail 2>/dev/null | tail -1 | tr -d ' ')
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < min_gb )); then
        error_with_fix \
            "Insufficient disk space: ${avail_gb}GB available, ${min_gb}GB required" \
            "OpenStack packages, images, and databases require significant disk space. The base installation alone uses ~8GB." \
            "Free up space or add storage: df -h / && du -sh /var/log/* /tmp/* 2>/dev/null | sort -rh | head -20"
        return 1
    fi
    ok "Disk: ${avail_gb}GB available (minimum ${min_gb}GB required)"
}

require_ram() {
    local min_gb="${1:-8}"
    local avail_kb; avail_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < min_gb )); then
        warn "RAM: ${avail_gb}GB detected. ${min_gb}GB recommended for stable operation."
        warn "With less than ${min_gb}GB some services (especially Nova/Ceilometer) may OOM-kill."
    else
        ok "RAM: ${avail_gb}GB available"
    fi
}

# ─── CONFIG VALIDATION ────────────────────────────────────────────────────────
# Rewrites v4.0 validate_config() with:
#   • grouped output (collect all errors, show them all at once)
#   • exact fix commands printed inline
#   • actionable hints per error type
validate_config() {
    section "Pre-flight config validation"
    local -a errors=()
    local -a warnings=()

    # ── HOST_IP ──────────────────────────────────────────────────────────────
    if [[ -z "${HOST_IP:-}" ]]; then
        errors+=("HOST_IP is empty → Run: sudo bash deploy.sh --wizard")
    elif [[ "${HOST_IP}" == "__CHANGE_ME__" ]]; then
        errors+=("HOST_IP was not auto-detected → Run: sudo bash deploy.sh --wizard  (Step 1 will list all IPs)")
    elif ! validate_ip "${HOST_IP}"; then
        errors+=("HOST_IP '${HOST_IP}' is not a valid IPv4 address → Edit configs/main.env and correct HOST_IP")
    fi

    # ── DEPLOY_MODE ───────────────────────────────────────────────────────────
    if [[ ! "${DEPLOY_MODE:-}" =~ ^(all-in-one|multi-node)$ ]]; then
        errors+=("DEPLOY_MODE='${DEPLOY_MODE:-unset}' must be 'all-in-one' or 'multi-node' → Edit configs/main.env")
    fi

    # ── PASSWORDS ─────────────────────────────────────────────────────────────
    for var in ADMIN_PASS DB_PASS RABBIT_PASS SERVICE_PASS; do
        local val="${!var:-}"
        if [[ -z "${val}" ]]; then
            errors+=("${var} is not set → Run: sudo bash deploy.sh --wizard  (Steps 3 & 4)")
        elif [[ "${val}" == "REPLACE_WITH_STRONG_PASSWORD" ]]; then
            errors+=("${var} is still the placeholder → Run: sudo bash deploy.sh --wizard  (Steps 3 & 4)")
        elif [[ "${#val}" -lt 12 ]]; then
            warnings+=("${var} is only ${#val} chars — 16+ recommended")
        fi
    done

    # ── INTERFACE NAME ────────────────────────────────────────────────────────
    if [[ -z "${INTERFACE_NAME:-}" ]]; then
        errors+=("INTERFACE_NAME is empty → Run: sudo bash deploy.sh --wizard  (Step 2)")
    fi

    # ── CONFIG VERSION ────────────────────────────────────────────────────────
    local expected_version="4.0"
    if [[ "${CONFIG_VERSION:-0}" != "${expected_version}" ]]; then
        warnings+=("CONFIG_VERSION='${CONFIG_VERSION:-unset}', expected '${expected_version}' — re-run wizard if settings look wrong")
    fi

    # ── OPTIONAL ALERTS ───────────────────────────────────────────────────────
    if [[ -n "${ACME_EMAIL:-}" && "${ACME_EMAIL}" != *@* ]]; then
        warnings+=("ACME_EMAIL='${ACME_EMAIL}' doesn't look like a valid email")
    fi

    # ── DISPLAY ALL WARNINGS ─────────────────────────────────────────────────
    for w in "${warnings[@]}"; do
        warn "${w}"
    done

    # ── DISPLAY ALL ERRORS AND FAIL ───────────────────────────────────────────
    if (( ${#errors[@]} > 0 )); then
        echo -e "\n${RED}${BOLD}  Validation failed — ${#errors[@]} error(s):${NC}\n"
        for err in "${errors[@]}"; do
            echo -e "  ${RED}  ✖${NC} ${err}"
        done
        echo ""
        error "Fix the above errors before deploying." \
              "Edit configs/main.env  OR  re-run the Setup Wizard: sudo bash deploy.sh --wizard"
        return 1
    fi

    ok "Config validation passed."
}

# ─── SECRETS LOADER ───────────────────────────────────────────────────────────
safe_source_secrets() {
    local path="${1:-${PROJ:-$(pwd)}/configs/.secrets.env}"
    local enc_path="${path%.env}.enc"

    if [[ -f "${path}" ]]; then
        local perms
        perms=$(stat -c "%a" "${path}" 2>/dev/null || stat -f "%Lp" "${path}" 2>/dev/null)
        if [[ "${perms}" != "600" ]]; then
            warn "Secrets file permissions are ${perms} — fixing to 600 (owner read/write only)..."
            chmod 600 "${path}"
        fi
        # shellcheck disable=SC1090
        source "${path}"
        ok "Secrets loaded from ${path}"
    elif [[ -f "${enc_path}" ]]; then
        log "Encrypted secrets found. Enter master password to decrypt."
        local decrypted
        if ! decrypted=$(openssl enc -aes-256-cbc -pbkdf2 -d -in "${enc_path}" 2>/dev/null); then
            error_with_fix \
                "Failed to decrypt ${enc_path}" \
                "The decryption password was incorrect, or the file is corrupted." \
                "Re-encrypt your secrets: sudo bash deploy.sh --wizard  then choose 'Encrypt secrets file'"
            return 1
        fi
        # shellcheck disable=SC1090
        source <(echo "${decrypted}")
        ok "Secrets decrypted and loaded from ${enc_path}"
    else
        warn "No secrets file at ${path}. Using passwords from main.env."
        warn "For better security, move passwords to configs/.secrets.env (chmod 600)."
    fi
}

# ─── DATABASE HELPERS ─────────────────────────────────────────────────────────
create_db() {
    local db="$1"
    log "Creating database: ${db}..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would create DB '${db}'.${NC}"
        return 0
    fi

    mysql --defaults-extra-file=<(printf '[client]\npassword=%s\n' "${DB_PASS}") \
          -u root 2>/dev/null << EOF
CREATE DATABASE IF NOT EXISTS ${db};
GRANT ALL PRIVILEGES ON ${db}.* TO '${db}'@'localhost' IDENTIFIED BY '${SERVICE_PASS}';
GRANT ALL PRIVILEGES ON ${db}.* TO '${db}'@'%'         IDENTIFIED BY '${SERVICE_PASS}';
FLUSH PRIVILEGES;
EOF
    ok "Database '${db}' ready."
}

# ─── KEYSTONE HELPERS ─────────────────────────────────────────────────────────
register_service() {
    local user="$1"; local type="$2"; local desc="$3"; local url="$4"
    log "Registering '${user}' in Keystone..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "  ${DIM}[DRY-RUN] Would register '${user}' (${type}).${NC}"
        return 0
    fi

    openstack user create --domain default --password "${SERVICE_PASS}" "${user}" 2>/dev/null \
        || warn "User '${user}' already exists."
    openstack role add --project service --user "${user}" admin 2>/dev/null || true
    openstack service create --name "${user}" --description "${desc}" "${type}" 2>/dev/null \
        || warn "Service '${user}' already registered."

    for endpoint_type in public internal admin; do
        openstack endpoint create --region "${REGION_NAME}" \
            "${type}" "${endpoint_type}" "${url}" 2>/dev/null || true
    done
    ok "Keystone registration done for '${user}'."
}

# ─── SYSTEMD HELPERS ──────────────────────────────────────────────────────────
: "${SERVICE_START_TIMEOUT:=15}"

start_services() {
    for svc in "$@"; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            echo -e "  ${DIM}[DRY-RUN] Would start: ${svc}${NC}"
            continue
        fi

        systemctl enable "${svc}" 2>/dev/null || true

        local attempt
        for attempt in 1 2 3; do
            if systemctl restart "${svc}" 2>/dev/null; then
                break
            fi
            warn "Attempt ${attempt}/3 failed for ${svc}, retrying in 3s..."
            sleep 3
        done

        local elapsed=0
        while ! systemctl is-active --quiet "${svc}"; do
            sleep 1
            elapsed=$(( elapsed + 1 ))
            if (( elapsed >= SERVICE_START_TIMEOUT )); then
                warn "'${svc}' did not become active within ${SERVICE_START_TIMEOUT}s."
                warn "Diagnose with: journalctl -u ${svc} -n 40 --no-pager"
                break
            fi
        done

        if systemctl is-active --quiet "${svc}"; then
            ok "Service started: ${svc}"
        else
            warn "Could not start '${svc}'. Check: journalctl -u ${svc} -n 40 --no-pager"
        fi
    done
}

# ─── PROGRESS SPINNER ─────────────────────────────────────────────────────────
spinner() {
    local pid=$1; local msg="${2:-Working...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    trap 'printf "\r\033[K"; trap - INT TERM RETURN' INT TERM RETURN
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:i++%${#spin}:1}${NC}  ${msg}"
        sleep 0.1
    done
    printf "\r\033[K"
    trap - INT TERM RETURN
}

# ─── DEPLOYMENT CHECKPOINTS ───────────────────────────────────────────────────
: "${CHECKPOINT_FILE:=${LOG_DIR:-/tmp}/.deployment_checkpoint}"

step_done() { echo "$1" >> "${CHECKPOINT_FILE}"; }

step_ran() {
    if grep -qxF "$1" "${CHECKPOINT_FILE}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

clear_checkpoints() {
    if [[ -f "${CHECKPOINT_FILE}" ]]; then
        rm "${CHECKPOINT_FILE}"
    fi
    log "Checkpoint file cleared."
}

list_completed_steps() {
    if [[ ! -f "${CHECKPOINT_FILE}" ]]; then
        echo "  (no steps completed yet)"
        return 0
    fi
    while IFS= read -r line; do
        echo -e "  ${GREEN}✔${NC}  ${line}"
    done < "${CHECKPOINT_FILE}"
}

# ─── HOSTNAME CONFIRMATION (for destructive ops) ───────────────────────────────
confirm_hostname() {
    local current; current=$(hostname)
    echo -e "  ${YELLOW}Destructive operation on: ${BOLD}${current}${NC}"
    echo -ne "  Type this server's hostname to confirm: "
    read -r input
    if [[ "${input}" != "${current}" ]]; then
        echo "Hostname mismatch. Aborted."
        exit 1
    fi
}

# ─── TIMER ────────────────────────────────────────────────────────────────────
STEP_START=0
start_timer() { STEP_START=$(date +%s); }
elapsed()      { echo "$(( $(date +%s) - STEP_START ))s"; }

elapsed_human() {
    local secs=$(( $(date +%s) - STEP_START ))
    if (( secs < 60 )); then
        echo "${secs}s"
    else
        printf "%dm %ds" $(( secs / 60 )) $(( secs % 60 ))
    fi
}

# ─── IP VALIDATION ────────────────────────────────────────────────────────────
validate_ip() {
    local ip="$1"
    local IFS='.'
    read -ra parts <<< "${ip}"
    if [[ ${#parts[@]} -ne 4 ]]; then return 1; fi
    for part in "${parts[@]}"; do
        if [[ ! "${part}" =~ ^[0-9]+$ ]]; then return 1; fi
        if (( part < 0 || part > 255 )); then return 1; fi
    done
    return 0
}

# ─── POST-DEPLOYMENT HEALTH CHECK ─────────────────────────────────────────────
# Prints a status table showing each service endpoint and whether it responds.
# Called at the end of a full deployment and from --verify.
health_check_table() {
    section "Service Health Check"
    local host="${HOST_IP:-localhost}"

    # Each entry: "Service Name" "test_command" "port" "endpoint"
    local -a checks=(
        "Keystone (Identity)|openstack token issue &>/dev/null|5000|http://${host}:5000/v3"
        "Glance (Images)|openstack image list &>/dev/null|9292|http://${host}:9292"
        "Placement|curl -s http://${host}:8778 &>/dev/null|8778|http://${host}:8778"
        "Nova (Compute)|openstack server list &>/dev/null|8774|http://${host}:8774"
        "Neutron (Network)|openstack network list &>/dev/null|9696|http://${host}:9696"
        "Horizon (Dashboard)|curl -s http://${host}/horizon &>/dev/null|80|http://${host}/horizon"
        "MariaDB|mysqladmin ping --silent 2>/dev/null|3306|localhost:3306"
        "RabbitMQ|rabbitmqctl status &>/dev/null|5672|localhost:5672"
        "Memcached|echo stats | nc -w 1 ${host} 11211 &>/dev/null|11211|localhost:11211"
    )

    printf "\n  %-24s  %-8s  %-6s  %s\n" "Service" "Status" "Port" "Endpoint"
    printf "  %-24s  %-8s  %-6s  %s\n" "$(printf '─%.0s' {1..24})" "$(printf '─%.0s' {1..8})" "------" "$(printf '─%.0s' {1..30})"

    local ok_count=0
    local fail_count=0
    for entry in "${checks[@]}"; do
        IFS='|' read -r name cmd port url <<< "${entry}"
        local status_str status_col
        if eval "${cmd}" 2>/dev/null; then
            status_str="● OK"
            status_col="${GREEN}"
            ok_count=$(( ok_count + 1 ))
        else
            status_str="○ DOWN"
            status_col="${RED}"
            fail_count=$(( fail_count + 1 ))
        fi
        printf "  %-24s  %b%-8s${NC}  %-6s  %s\n" \
            "${name}" "${status_col}" "${status_str}" "${port}" "${url}"
    done

    echo ""
    if (( fail_count == 0 )); then
        ok "All ${ok_count} services are responding."
    else
        warn "${ok_count} services OK · ${fail_count} not responding"
        warn "Services marked DOWN may still be starting. Wait 30s and re-run: sudo bash deploy.sh --verify"
    fi
}

# ─── OPENSTACK SERVICE VERIFICATION (lightweight) ─────────────────────────────
verify_service() {
    local name="$1"; local cmd="$2"
    if eval "${cmd}" &>/dev/null; then
        ok "${name} — OK"
    else
        warn "${name} — not responding (may still be starting)"
    fi
}
