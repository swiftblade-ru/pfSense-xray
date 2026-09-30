#!/bin/sh
#
# install.sh — Install pfSense Xray package.
#
# Run from the repository root on pfSense:
#   cd pfSense-xray
#   sh install.sh [command] [options]
#
# Binaries are installed from local folders next to this script:
#   xray-core/xray                    (required)
#   xray-core/geoip.dat               (optional)
#   xray-core/geosite.dat             (optional)
#   hev-socks5-tunnel/hev-socks5-tunnel   (required on amd64)
#   tun2socks/tun2socks                   (required on aarch64)
#
# No binaries are ever downloaded from GitHub.
#
# Commands:
#   install              Full install (default)
#   update               Re-deploy files + restart services
#   uninstall            Stop services, remove files, clean config
#   install-binaries     Install xray-core + tunnel binaries only
#
# Options:
#   --backend BACKEND    Force tunnel backend: 'hev' or 'tun2socks' (overrides arch detection)
#   --no-binaries        Skip binary install (use existing)

set -e
set -u

# ─── Defaults ─────────────────────────────────────────────────────────────────
COMMAND="install"
SKIP_BINARIES=0
FORCE_BACKEND=""

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        install|update|uninstall|install-binaries)
            COMMAND="$1"
            shift
            ;;
        --backend)
            FORCE_BACKEND="$2"
            case "${FORCE_BACKEND}" in
                hev|tun2socks) ;;
                *) echo "[ERROR] --backend must be 'hev' or 'tun2socks'" >&2; exit 1 ;;
            esac
            shift 2
            ;;
        --no-binaries)
            SKIP_BINARIES=1
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "==> $*"; }
ok()    { echo "    [OK] $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ─── Embedded binary folders (next to install.sh) ────────────────────────────
EMBED_XRAY_DIR="${REPO_ROOT}/xray-core"
EMBED_HEV_DIR="${REPO_ROOT}/hev-socks5-tunnel"
EMBED_T2S_DIR="${REPO_ROOT}/tun2socks"

# ─── Verify we're running on pfSense ─────────────────────────────────────────
if [ ! -f /etc/inc/config.inc ]; then
    die "This script must be run on pfSense (FreeBSD). /etc/inc/config.inc not found."
fi

# ─── Verify package files are present ────────────────────────────────────────
if [ ! -d "${REPO_ROOT}/files" ]; then
    die "Package files not found at ${REPO_ROOT}/files/. Run install.sh from the repository root."
fi

# ─── Architecture detection ───────────────────────────────────────────────────
ARCH=$(uname -m)
case "${ARCH}" in
    amd64)   HEV_ARCH="x86_64" ;;
    aarch64) HEV_ARCH="" ;;
    *)       die "Unsupported architecture: ${ARCH}" ;;
esac

# ─── Install xray-core from local folder ─────────────────────────────────────
install_xray_core() {
    mkdir -p /usr/local/etc/xray-core

    src=""
    for candidate in "${EMBED_XRAY_DIR}/xray" "${EMBED_XRAY_DIR}/xray-core"; do
        if [ -f "${candidate}" ]; then
            src="${candidate}"
            break
        fi
    done

    if [ -z "${src}" ]; then
        die "xray binary not found. Expected one of:
       ${EMBED_XRAY_DIR}/xray
       ${EMBED_XRAY_DIR}/xray-core"
    fi

    info "Installing xray-core from ${src}..."
    install -m 755 "${src}" /usr/local/bin/xray-core

    # Optional geo data files used by routing rules (geoip:xx, geosite:xx)
    for dat in geoip.dat geosite.dat; do
        if [ -f "${EMBED_XRAY_DIR}/${dat}" ]; then
            install -m 644 "${EMBED_XRAY_DIR}/${dat}" "/usr/local/etc/xray-core/${dat}"
        fi
    done

    # version.txt: try VERSION file first, else parse `xray-core version`
    if [ -f "${EMBED_XRAY_DIR}/VERSION" ]; then
        cp "${EMBED_XRAY_DIR}/VERSION" /usr/local/etc/xray-core/version.txt
    else
        _ver=$(/usr/local/bin/xray-core version 2>/dev/null | head -1 | awk '{print $2}')
        echo "${_ver:-embedded}" > /usr/local/etc/xray-core/version.txt
    fi

    ok "xray-core $(/usr/local/bin/xray-core version 2>/dev/null | head -1)"
}

# ─── Install hev-socks5-tunnel from local folder (amd64) ─────────────────────
install_hev() {
    mkdir -p /usr/local/tun2socks

    src="${EMBED_HEV_DIR}/hev-socks5-tunnel"
    if [ ! -f "${src}" ]; then
        die "hev-socks5-tunnel binary not found at ${src}"
    fi

    info "Installing hev-socks5-tunnel from ${src}..."
    install -m 755 "${src}" /usr/local/tun2socks/hev-socks5-tunnel
    rm -f /usr/local/tun2socks/tun2socks
    echo "hev" > /usr/local/tun2socks/backend.txt
    ok "hev-socks5-tunnel $(/usr/local/tun2socks/hev-socks5-tunnel --version 2>/dev/null | head -1)"
}

# ─── Install tun2socks from local folder (aarch64) ───────────────────────────
install_tun2socks() {
    mkdir -p /usr/local/tun2socks

    src=""
    for candidate in "${EMBED_T2S_DIR}/tun2socks" "${EMBED_T2S_DIR}/tun2socks-freebsd-amd64" "${EMBED_T2S_DIR}/tun2socks-freebsd-arm64"; do
        if [ -f "${candidate}" ]; then
            src="${candidate}"
            break
        fi
    done

    if [ -z "${src}" ]; then
        die "tun2socks binary not found in ${EMBED_T2S_DIR}/"
    fi

    info "Installing tun2socks from ${src}..."
    install -m 755 "${src}" /usr/local/tun2socks/tun2socks
    rm -f /usr/local/tun2socks/hev-socks5-tunnel
    echo "tun2socks" > /usr/local/tun2socks/backend.txt
    ok "tun2socks $(/usr/local/tun2socks/tun2socks --version 2>/dev/null | head -1)"
}

# ─── Binary install dispatcher ────────────────────────────────────────────────
cmd_install_binaries() {
    install_xray_core

    # --backend override
    if [ "${FORCE_BACKEND}" = "tun2socks" ]; then
        HEV_ARCH=""
    elif [ "${FORCE_BACKEND}" = "hev" ] && [ -z "${HEV_ARCH}" ]; then
        die "hev-socks5-tunnel has no binary for ${ARCH}"
    fi

    if [ -n "${HEV_ARCH}" ]; then
        install_hev
    else
        install_tun2socks
    fi
}

# ─── Deploy package files ────────────────────────────────────────────────────
cmd_deploy_files() {
    info "Deploying package files..."

    mkdir -p /usr/local/scripts/xray
    mkdir -p /usr/local/www/xray
    mkdir -p /usr/local/pkg/xray/includes
    mkdir -p /usr/local/etc/rc.d
    chmod 750 /usr/local/etc/xray-core 2>/dev/null || true
    chmod 750 /usr/local/tun2socks      2>/dev/null || true
    chmod 755 /usr/local/scripts/xray

    cp "${REPO_ROOT}/files/usr/local/scripts/xray/"*.php /usr/local/scripts/xray/
    cp "${REPO_ROOT}/files/usr/local/scripts/xray/"*.inc /usr/local/scripts/xray/
    chmod +x /usr/local/scripts/xray/*.php

    cp "${REPO_ROOT}/files/usr/local/etc/rc.d/xray.sh" /usr/local/etc/rc.d/xray.sh
    chmod +x /usr/local/etc/rc.d/xray.sh

    cp "${REPO_ROOT}/files/usr/local/pkg/xray/includes/"* /usr/local/pkg/xray/includes/

    cp "${REPO_ROOT}/files/usr/local/www/xray/"*.php /usr/local/www/xray/

    ok "Files deployed"
}

# ─── System configuration ─────────────────────────────────────────────────────
cmd_configure_system() {
    info "Configuring system..."

    kldload if_tun 2>/dev/null || true
    ok "if_tun kernel module loaded"

    mkdir -p /etc/newsyslog.conf.d
    cat > /etc/newsyslog.conf.d/xray.conf << 'EOF'
/var/log/xray-core.log      root:wheel  644  3  600  *  JG
/var/log/xray-watchdog.log  root:wheel  644  3  200  *  JG
EOF
    ok "Log rotation configured"
}

# ─── Register package in pfSense config ───────────────────────────────────────
cmd_register_package() {
    info "Registering package in pfSense..."

    STUB_DIR="/tmp/xray-inc-stub-$$"
    mkdir -p "${STUB_DIR}"
    printf '<?php\n' > "${STUB_DIR}/services_dhcp.inc"

    PHP_SCRIPT="/tmp/xray-register-$$.php"
    cat > "${PHP_SCRIPT}" << 'PHPEOF'
<?php
set_include_path('/etc/inc' . PATH_SEPARATOR . '/usr/local/share/pear' . PATH_SEPARATOR . ini_get('include_path'));
require_once('globals.inc');
require_once('config.inc');
require_once('/usr/local/pkg/xray/includes/xray.inc');
xray_install();
write_config('Xray: package installed');
echo 'done' . PHP_EOL;
PHPEOF

    if php -d "include_path=${STUB_DIR}:/etc/inc:/usr/local/share/pear" "${PHP_SCRIPT}"; then
        rm -f "${PHP_SCRIPT}"
        rm -rf "${STUB_DIR}"
    else
        rm -f "${PHP_SCRIPT}"
        rm -rf "${STUB_DIR}"
        die "Failed to register package"
    fi

    ok "Package registered (VPN → Xray menu added)"
}

# ─── Stop all xray instances ──────────────────────────────────────────────────
cmd_stop_all() {
    if [ -f /usr/local/scripts/xray/xray-service-control.php ]; then
        info "Stopping all Xray instances..."
        php /usr/local/scripts/xray/xray-service-control.php stop 2>/dev/null || true
        ok "Instances stopped"
    fi
}

# ─── Deregister package from pfSense config ───────────────────────────────────
cmd_deregister_package() {
    info "Removing package from pfSense config..."

    STUB_DIR="/tmp/xray-inc-stub-$$"
    mkdir -p "${STUB_DIR}"
    printf '<?php\n' > "${STUB_DIR}/services_dhcp.inc"

    PHP_SCRIPT="/tmp/xray-deregister-$$.php"
    cat > "${PHP_SCRIPT}" << 'PHPEOF'
<?php
set_include_path('/etc/inc' . PATH_SEPARATOR . '/usr/local/share/pear' . PATH_SEPARATOR . ini_get('include_path'));
require_once('globals.inc');
require_once('config.inc');
require_once('/usr/local/pkg/xray/includes/xray.inc');
xray_deinstall();
write_config('Xray: package removed');
echo 'done' . PHP_EOL;
PHPEOF

    php -d "include_path=${STUB_DIR}:/etc/inc:/usr/local/share/pear" "${PHP_SCRIPT}" 2>/dev/null || true
    rm -f "${PHP_SCRIPT}"
    rm -rf "${STUB_DIR}"

    ok "Package deregistered"
}

# ─── Remove files ─────────────────────────────────────────────────────────────
cmd_remove_files() {
    info "Removing package files..."

    rm -rf /usr/local/www/xray
    rm -rf /usr/local/scripts/xray
    rm -rf /usr/local/pkg/xray
    rm -f  /usr/local/etc/rc.d/xray.sh
    rm -f  /etc/newsyslog.conf.d/xray.conf
    rm -f  /var/log/xray-core.log
    rm -f  /var/log/xray-watchdog.log

    ok "Package files removed"
}

cmd_remove_binaries() {
    info "Removing binaries..."

    rm -f  /usr/local/bin/xray-core
    rm -rf /usr/local/tun2socks
    rm -rf /usr/local/etc/xray-core

    ok "Binaries removed"
}

# ─── Commands ─────────────────────────────────────────────────────────────────
case "${COMMAND}" in

    install)
        info "Installing pfSense Xray package..."
        echo ""

        if [ "${SKIP_BINARIES}" -eq 0 ]; then
            cmd_install_binaries
        fi

        cmd_deploy_files
        cmd_configure_system
        cmd_register_package

        echo ""
        info "Installation complete!"
        echo ""
        echo "  Next steps:"
        echo "  1. Go to VPN → Xray → Settings and enable the package"
        echo "  2. Go to VPN → Xray → Instances → Add to create a tunnel"
        echo "  3. After starting an instance, add a Gateway in"
        echo "     System → Routing → Gateways pointing to the TUN interface"
        echo ""
        ;;

    update)
        info "Updating pfSense Xray package..."
        echo ""

        cmd_stop_all

        if [ "${SKIP_BINARIES}" -eq 0 ]; then
            cmd_install_binaries
        fi

        cmd_deploy_files

        info "Restarting instances..."
        php /usr/local/scripts/xray/xray-service-control.php start 2>/dev/null || true
        ok "Instances restarted"

        echo ""
        info "Update complete!"
        ;;

    uninstall)
        info "Uninstalling pfSense Xray package..."
        echo ""

        cmd_stop_all
        cmd_deregister_package
        cmd_remove_files
        cmd_remove_binaries

        echo ""
        info "Uninstall complete. Config data removed from pfSense."
        echo "  Note: manually remove Gateway and Firewall Rules if you added them."
        echo ""
        ;;

    install-binaries)
        cmd_install_binaries
        ;;

esac