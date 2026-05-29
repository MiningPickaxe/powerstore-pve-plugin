#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# PowerStore PVE Plugin — Interactive Installer
# Installs, updates, removes, and health-checks the plugin on Proxmox VE nodes.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PLUGIN_NAME="powerstore-pve-plugin"
PLUGIN_PM="PowerStorePlugin.pm"
PLUGIN_DEST="/usr/share/perl5/PVE/Storage/Custom/PowerStorePlugin.pm"
STORAGE_CFG="/etc/pve/storage.cfg"
BACKUP_DIR="/var/backups/${PLUGIN_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(grep -Po 'our \$VERSION\s*=\s*['"'"'"]\K[^'"'"'"]+' "${SCRIPT_DIR}/${PLUGIN_PM}" 2>/dev/null || echo "unknown")

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn_()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }
die_()    { fail "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die_ "This script must be run as root."
}

installed_version() {
    grep -Po 'our \$VERSION\s*=\s*['"'"'"]\K[^'"'"'"]+' "${PLUGIN_DEST}" 2>/dev/null || echo "not installed"
}

# ---------------------------------------------------------------------------
# Install / Update
# ---------------------------------------------------------------------------
do_install() {
    header "Installing ${PLUGIN_NAME} v${VERSION}"
    require_root

    # Dependencies
    info "Checking dependencies..."
    local missing=()
    for pkg in libwww-perl liblwp-protocol-https-perl libjson-perl \
                libio-socket-ssl-perl open-iscsi; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing[*]}"
        apt-get install -y "${missing[@]}"
    else
        ok "All dependencies present."
    fi

    # Syntax check before installing
    info "Validating plugin syntax..."
    perl -c "${SCRIPT_DIR}/${PLUGIN_PM}" \
        || die_ "Perl syntax check failed — aborting install."
    ok "Syntax OK."

    # Backup existing install
    if [[ -f "${PLUGIN_DEST}" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local bak="${BACKUP_DIR}/${PLUGIN_PM}.$(date +%Y%m%d%H%M%S).bak"
        cp "${PLUGIN_DEST}" "${bak}"
        info "Backed up existing plugin to ${bak}"
    fi

    # Install
    install -D -m 0644 "${SCRIPT_DIR}/${PLUGIN_PM}" "${PLUGIN_DEST}"
    ok "Plugin installed to ${PLUGIN_DEST}"

    # Restart PVE services
    info "Restarting Proxmox services..."
    systemctl restart pvedaemon  && ok "pvedaemon restarted." || warn_ "pvedaemon restart failed."
    systemctl restart pvestatd   && ok "pvestatd restarted."  || warn_ "pvestatd restart failed."

    echo
    ok "Installation complete. Installed version: ${VERSION}"
    echo -e "  Next step: Add a storage entry to ${STORAGE_CFG}"
    echo -e "  See storage.cfg.example for configuration reference."
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
do_remove() {
    header "Removing ${PLUGIN_NAME}"
    require_root

    if [[ ! -f "${PLUGIN_DEST}" ]]; then
        warn_ "Plugin is not installed — nothing to remove."
        return
    fi

    # Backup storage.cfg
    if [[ -f "${STORAGE_CFG}" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local bak="${BACKUP_DIR}/storage.cfg.$(date +%Y%m%d%H%M%S).bak"
        cp "${STORAGE_CFG}" "${bak}"
        warn_ "storage.cfg backed up to ${bak}"
        warn_ "Remove any 'powerstoreplugin:' entries from ${STORAGE_CFG} manually."
    fi

    rm -f "${PLUGIN_DEST}"
    ok "Plugin removed."

    info "Restarting Proxmox services..."
    systemctl restart pvedaemon 2>/dev/null || true
    systemctl restart pvestatd  2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
do_health_check() {
    header "Health Check"
    local pass=0 fail_count=0

    _chk() {
        local label="$1" result="$2" detail="${3:-}"
        printf "  %-45s" "${label}..."
        if [[ "$result" == "ok" ]]; then
            echo -e "${GREEN}OK${RESET}"
            (( pass++ )) || true
        else
            echo -e "${RED}FAIL${RESET}  ${detail}"
            (( fail_count++ )) || true
        fi
    }

    # 1. PVE installed
    command -v pvesm &>/dev/null \
        && _chk "Proxmox VE installed" "ok" \
        || _chk "Proxmox VE installed" "fail" "pvesm not found"

    # 2. PVE version >= 8
    local pve_ver
    pve_ver=$(pveversion 2>/dev/null | grep -Po 'pve-manager/\K[0-9]+' || echo 0)
    [[ "$pve_ver" -ge 8 ]] \
        && _chk "PVE version >= 8 (found $pve_ver)" "ok" \
        || _chk "PVE version >= 8 (found $pve_ver)" "fail" "Upgrade Proxmox VE"

    # 3. Plugin installed
    [[ -f "${PLUGIN_DEST}" ]] \
        && _chk "Plugin file present" "ok" \
        || _chk "Plugin file present" "fail" "${PLUGIN_DEST} not found"

    # 4. Perl syntax
    perl -c "${PLUGIN_DEST}" &>/dev/null \
        && _chk "Plugin Perl syntax" "ok" \
        || _chk "Plugin Perl syntax" "fail" "Run: perl -c ${PLUGIN_DEST}"

    # 5. Required Perl modules
    for mod in LWP::UserAgent JSON MIME::Base64 IO::Socket::SSL; do
        perl -e "use ${mod};" &>/dev/null \
            && _chk "Perl module: ${mod}" "ok" \
            || _chk "Perl module: ${mod}" "fail" "apt install the missing package"
    done

    # 6. open-iscsi
    command -v iscsiadm &>/dev/null \
        && _chk "iscsiadm available" "ok" \
        || _chk "iscsiadm available" "fail" "apt install open-iscsi"

    # 7. iSCSI initiatorname
    [[ -f /etc/iscsi/initiatorname.iscsi ]] \
        && _chk "iSCSI initiatorname file" "ok" \
        || _chk "iSCSI initiatorname file" "fail" "/etc/iscsi/initiatorname.iscsi missing"

    # 8. iscsid running
    systemctl is-active --quiet iscsid \
        && _chk "iscsid service running" "ok" \
        || _chk "iscsid service running" "fail" "systemctl start iscsid"

    # 9. pvedaemon running
    systemctl is-active --quiet pvedaemon \
        && _chk "pvedaemon running" "ok" \
        || _chk "pvedaemon running" "fail"

    echo
    echo -e "  Results: ${GREEN}${pass} passed${RESET}, ${RED}${fail_count} failed${RESET}"
    [[ $fail_count -eq 0 ]] && ok "All checks passed." || warn_ "Some checks failed."
}

# ---------------------------------------------------------------------------
# Configuration wizard
# ---------------------------------------------------------------------------
do_configure() {
    header "Configuration Wizard"
    require_root

    echo "This wizard appends a new powerstoreplugin storage entry to ${STORAGE_CFG}."
    echo

    read -rp "  Storage ID (e.g. ps-prod): " storage_id
    [[ -n "$storage_id" ]] || die_ "Storage ID cannot be empty."

    read -rp "  PowerStore management IP/hostname: " api_host
    [[ -n "$api_host" ]] || die_ "api_host cannot be empty."

    read -rp "  Management username [admin]: " api_user
    api_user="${api_user:-admin}"

    read -rsp "  Management password: " api_password
    echo
    [[ -n "$api_password" ]] || die_ "Password cannot be empty."

    read -rp "  Storage pool ID (UUID): " pool_id
    [[ -n "$pool_id" ]] || die_ "pool_id cannot be empty."

    read -rp "  iSCSI portal IP [same as api_host]: " portal
    portal="${portal:-$api_host}"

    read -rp "  Nodes (comma-separated, leave blank for all): " nodes

    # Build stanza
    local stanza="
powerstoreplugin: ${storage_id}
        api_host        ${api_host}
        api_user        ${api_user}
        api_password    ${api_password}
        pool_id         ${pool_id}
        portal          ${portal}
        content         images
        shared          1"

    [[ -n "$nodes" ]] && stanza+="
        nodes           ${nodes}"

    # Backup and append
    mkdir -p "${BACKUP_DIR}"
    cp "${STORAGE_CFG}" "${BACKUP_DIR}/storage.cfg.$(date +%Y%m%d%H%M%S).bak"
    echo "${stanza}" >> "${STORAGE_CFG}"

    ok "Storage entry '${storage_id}' added to ${STORAGE_CFG}"
    echo
    info "Verify with: pvesm status --storage ${storage_id}"
}

# ---------------------------------------------------------------------------
# Show installed version
# ---------------------------------------------------------------------------
do_version() {
    echo "  Package version:   ${VERSION}"
    echo "  Installed version: $(installed_version)"
    if [[ -f "${PLUGIN_DEST}" ]]; then
        local pve_ver
        pve_ver=$(pveversion 2>/dev/null | grep -Po 'pve-manager/\K[0-9.]+' || echo unknown)
        echo "  Proxmox VE:        ${pve_ver}"
    fi
}

# ---------------------------------------------------------------------------
# Cluster-wide install
# ---------------------------------------------------------------------------
do_cluster_install() {
    header "Cluster-wide Installation"
    require_root

    if ! command -v pvecm &>/dev/null; then
        warn_ "pvecm not found — single-node install only."
        do_install
        return
    fi

    local nodes
    nodes=$(pvecm nodes 2>/dev/null | awk 'NR>1 && NF>=2 {print $3}' | grep -v "$(hostname -s)")

    if [[ -z "$nodes" ]]; then
        info "No additional cluster nodes found. Installing locally only."
        do_install
        return
    fi

    # Install locally first
    do_install

    # Then push to each other node
    for node in $nodes; do
        info "Installing on node: ${node}"
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${node}" true 2>/dev/null; then
            scp "${SCRIPT_DIR}/${PLUGIN_PM}" "root@${node}:/tmp/${PLUGIN_PM}"
            ssh "root@${node}" \
                "install -D -m 0644 /tmp/${PLUGIN_PM} ${PLUGIN_DEST} \
                 && systemctl restart pvedaemon pvestatd \
                 && rm /tmp/${PLUGIN_PM}"
            ok "  ${node}: installed"
        else
            warn_ "  ${node}: SSH failed — install manually with: install.sh install"
        fi
    done
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    while true; do
        echo
        echo -e "${BOLD}PowerStore PVE Plugin Installer v${VERSION}${RESET}"
        echo "  Installed: $(installed_version)"
        echo
        echo "  1) Install / Update"
        echo "  2) Remove"
        echo "  3) Health check"
        echo "  4) Configuration wizard"
        echo "  5) Cluster-wide install"
        echo "  6) Show version info"
        echo "  q) Quit"
        echo
        read -rp "Choice: " choice
        case "$choice" in
            1) do_install ;;
            2) do_remove ;;
            3) do_health_check ;;
            4) do_configure ;;
            5) do_cluster_install ;;
            6) do_version ;;
            q|Q) echo "Bye."; exit 0 ;;
            *) warn_ "Unknown option '$choice'" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-menu}" in
    install)           do_install ;;
    remove|uninstall)  do_remove ;;
    health|check)      do_health_check ;;
    configure)         do_configure ;;
    cluster-install)   do_cluster_install ;;
    version)           do_version ;;
    menu|"")           interactive_menu ;;
    *)
        echo "Usage: $0 {install|remove|health|configure|cluster-install|version|menu}"
        exit 1
        ;;
esac
