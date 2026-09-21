#!/usr/bin/env bash
#
# ============================================================
# FreeBoot Deployment / PXE Server
# Debian 13
# ============================================================
#
# BELANGRIJK
#
# Dit script WIJZIGT GEEN NETWERKCONFIGURATIE.
#
# Het script:
#   - verandert geen IP-adres
#   - verandert geen gateway
#   - verandert geen routes
#   - verandert geen DNS van de server
#   - wijzigt /etc/network/interfaces niet
#   - gebruikt geen nmcli
#
# De server kan dit script dus veilig uitvoeren terwijl hij
# nog op het productienetwerk zit.
#
# Na uitvoering:
#
#   1. Server uitschakelen
#   2. Netwerkkabel naar deploymentnetwerk
#   3. Server starten
#   4. Controleren via 10.90.90.10
#
# ============================================================

set -euo pipefail

# ============================================================
# INSTELLINGEN
# ============================================================

HOSTNAME="deployment-server"
INTERFACE="eno1"

SERVER_IP="10.90.90.10"
CIDR="24"
GATEWAY="10.90.90.1"

DHCP_START="10.90.90.100"
DHCP_END="10.90.90.200"
DHCP_LEASE="12h"

DNS1="9.9.9.9"
DNS2="1.1.1.1"

NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:latest"

NETBOOT_DIR="/opt/netbootxyz"
NETBOOT_CONFIG="${NETBOOT_DIR}/config"
NETBOOT_ASSETS="${NETBOOT_DIR}/assets"

DNSMASQ_CONFIG="/etc/dnsmasq.d/freeboot-pxe.conf"
SYSTEMD_SERVICE="/etc/systemd/system/netbootxyz.service"

# ============================================================
# FUNCTIES
# ============================================================

info() {
    echo
    echo "==> $1"
}

error() {
    echo
    echo "FOUT: $1" >&2
    exit 1
}

# ============================================================
# ROOT
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "Voer dit script uit als root."
fi

# ============================================================
# DEBIAN CONTROLEREN
# ============================================================

info "Debian controleren"

if [[ ! -f /etc/debian_version ]]; then
    error "Dit script is bedoeld voor Debian."
fi

# ============================================================
# NETWERK ALLEEN CONTROLEREN
# ============================================================

info "Netwerkinterface controleren"

if ! ip link show "${INTERFACE}" >/dev/null 2>&1; then
    error "Interface ${INTERFACE} bestaat niet."
fi

echo
echo "Huidige netwerkconfiguratie:"
echo

ip -4 addr show dev "${INTERFACE}" || true

echo
ip route || true

echo
echo "LET OP:"
echo "Dit script verandert bovenstaande netwerkconfiguratie NIET."

# ============================================================
# BESTAANDE SOFTWARE CONTROLEREN
# ============================================================

info "Bestaande installatie controleren"

if ! command -v podman >/dev/null 2>&1; then
    error "Podman is niet geïnstalleerd."
fi

if ! command -v ufw >/dev/null 2>&1; then
    error "UFW is niet geïnstalleerd."
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd is niet beschikbaar."
fi

# ============================================================
# HOSTNAME
# ============================================================

info "Hostname instellen"

hostnamectl set-hostname "${HOSTNAME}"

# ============================================================
# BENODIGDE PAKKETTEN
# ============================================================

info "Benodigde pakketten installeren"

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    tar \
    dnsmasq

# ============================================================
# NETBOOT DIRECTORIES
# ============================================================

info "Netboot directories aanmaken"

mkdir -p "${NETBOOT_CONFIG}"
mkdir -p "${NETBOOT_ASSETS}"

# ============================================================
# BESTAANDE NETBOOT.XYZ CONTAINER
# ============================================================

info "Bestaande netboot.xyz container controleren"

if podman container exists netbootxyz; then
    echo "Bestaande container gevonden."

    podman stop netbootxyz 2>/dev/null || true
    podman rm netbootxyz 2>/dev/null || true
fi

# ============================================================
# NETBOOT.XYZ IMAGE
# ============================================================

info "netboot.xyz image ophalen"

podman pull "${NETBOOT_IMAGE}"

# ============================================================
# SYSTEMD SERVICE
# ============================================================

info "netboot.xyz systemd service maken"

cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=FreeBoot netboot.xyz PXE/iPXE Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStart=/usr/bin/podman run \\
    --name netbootxyz \\
    --rm \\
    --net=host \\
    -e TFTPD_OPTS=--tftp-single-port \\
    -v ${NETBOOT_CONFIG}:/config:Z \\
    -v ${NETBOOT_ASSETS}:/assets:Z \\
    ${NETBOOT_IMAGE}

ExecStop=/usr/bin/podman stop -t 10 netbootxyz

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable netbootxyz.service

# ============================================================
# DNSMASQ DHCP/PXE
# ============================================================

info "dnsmasq configureren"

if [[ -f "${DNSMASQ_CONFIG}" ]]; then
    cp "${DNSMASQ_CONFIG}" \
       "${DNSMASQ_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > "${DNSMASQ_CONFIG}" <<EOF
# ============================================================
# FreeBoot PXE DHCP
# ============================================================

# Alleen DHCP/PXE
port=0

# Deployment interface
interface=${INTERFACE}
bind-interfaces

# DHCP
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,${DHCP_LEASE}

# Gateway
dhcp-option=3,${GATEWAY}

# DNS
dhcp-option=6,${DNS1},${DNS2}

# ============================================================
# PXE architectuur
# ============================================================

# BIOS / Legacy
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,netboot.xyz.kpxe

# UEFI x86_64
dhcp-match=set:efi64,option:client-arch,7
dhcp-boot=tag:efi64,netboot.xyz.efi

# UEFI x86_64
dhcp-match=set:efi64old,option:client-arch,9
dhcp-boot=tag:efi64old,netboot.xyz.efi

# UEFI ARM64
dhcp-match=set:efiarm64,option:client-arch,11
dhcp-boot=tag:efiarm64,netboot.xyz-arm64.efi
EOF

# ============================================================
# DNSMASQ TESTEN
# ============================================================

info "dnsmasq configuratie testen"

dnsmasq --test

# ============================================================
# DNSMASQ STARTEN
# ============================================================

info "dnsmasq activeren"

systemctl enable dnsmasq
systemctl restart dnsmasq

if ! systemctl is-active --quiet dnsmasq; then
    error "dnsmasq is niet actief."
fi

# ============================================================
# NETBOOT.XYZ STARTEN
# ============================================================

info "netboot.xyz starten"

systemctl restart netbootxyz.service

sleep 3

if ! systemctl is-active --quiet netbootxyz.service; then
    echo
    systemctl status netbootxyz.service --no-pager
    error "netboot.xyz is niet actief."
fi

# ============================================================
# UFW
# ============================================================

info "UFW-regels instellen"

ufw allow 67/udp
ufw allow 69/udp
ufw allow 80/tcp
ufw allow 3000/tcp
ufw allow 9090/tcp

# ============================================================
# UFW STATUS
# ============================================================

info "UFW controleren"

ufw status verbose

# ============================================================
# SERVICES
# ============================================================

info "Services controleren"

echo
echo "--- dnsmasq ---"
systemctl status dnsmasq --no-pager | sed -n '1,15p'

echo
echo "--- netbootxyz ---"
systemctl status netbootxyz.service --no-pager | sed -n '1,20p'

# ============================================================
# PODMAN
# ============================================================

info "Podman controleren"

podman ps --filter name=netbootxyz

# ============================================================
# EINDSAMENVATTING
# ============================================================

echo
echo "============================================================"
echo " FreeBoot Deployment / PXE Server"
echo " configuratie voltooid"
echo "============================================================"
echo
echo "Server:"
echo "  ${SERVER_IP}/${CIDR}"
echo
echo "Gateway:"
echo "  ${GATEWAY}"
echo
echo "DHCP:"
echo "  ${DHCP_START} - ${DHCP_END}"
echo
echo "Lease:"
echo "  ${DHCP_LEASE}"
echo
echo "DNS:"
echo "  ${DNS1}"
echo "  ${DNS2}"
echo
echo "Netboot.xyz:"
echo "  http://${SERVER_IP}:3000"
echo
echo "PXE HTTP:"
echo "  http://${SERVER_IP}/"
echo
echo "Cockpit:"
echo "  https://${SERVER_IP}:9090"
echo
echo "UFW:"
echo "  UDP 67"
echo "  UDP 69"
echo "  TCP 80"
echo "  TCP 3000"
echo "  TCP 9090"
echo
echo "============================================================"
echo " BELANGRIJK"
echo "============================================================"
echo
echo "Dit script heeft de IP-stack NIET gewijzigd."
echo
echo "Nu:"
echo
echo "  1. Server uitschakelen"
echo "  2. Kabel naar deploymentnetwerk"
echo "  3. Server starten"
echo "  4. Controleren op 10.90.90.10"
echo
echo "Deploymentnetwerk:"
echo "  10.90.90.0/24"
echo
echo "Server:"
echo "  10.90.90.10"
echo
echo "============================================================"