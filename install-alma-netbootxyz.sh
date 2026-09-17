#!/usr/bin/env bash
#
# Deployment / PXE-boot server setup voor Fedora / RHEL / AlmaLinux
# Optie A: netboot.xyz container doet TFTP + web, dnsmasq doet alleen DHCP
#
# Architectuur:
#   - Podman container (ghcr.io/netbootxyz/netbootxyz) draait met --net=host
#     en serveert TFTP (poort 69/udp), Web UI (poort 3000), Assets (poort 80)
#   - Container wordt beheerd door systemd unit 'netbootxyz.service'
#   - dnsmasq draait ALLEEN als DHCP-server (geen TFTP, geen DNS)
#   - Cockpit Web UI + Cockpit Podman module op poort 9090
#

set -euo pipefail

# --- ROOT CHECK ---
if [[ $EUID -ne 0 ]]; then
    echo "Dit script moet als root draaien." >&2
    exit 1
fi

# --- VARIABELEN ---
INTERFACE="eno1"
IP_ADDR="10.90.90.10/24"
IP_ONLY="10.90.90.10"
NETMASK="255.255.255.0"
GATEWAY="10.90.90.1"
DNS_SERVERS="9.9.9.9 1.1.1.1 8.8.8.8"
HOSTNAME_SET="deployment-server"

DHCP_RANGE_START="10.90.90.100"
DHCP_RANGE_END="10.90.90.200"
DHCP_LEASE="12h"

NETBOOT_DIR="/opt/netbootxyz"
NETBOOT_CONFIG="${NETBOOT_DIR}/config"
NETBOOT_ASSETS="${NETBOOT_DIR}/assets"
NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:latest"

echo "=== [1/8] Hostnaam en Netwerk instellen ==="
hostnamectl set-hostname "${HOSTNAME_SET}"

if nmcli connection show "${INTERFACE}" &>/dev/null; then
    nmcli connection modify "${INTERFACE}" \
        ipv4.addresses "${IP_ADDR}" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS_SERVERS}" \
        ipv4.method manual \
        connection.autoconnect yes
else
    nmcli connection add type ethernet con-name "${INTERFACE}" ifname "${INTERFACE}" \
        ip4 "${IP_ADDR}" gw4 "${GATEWAY}"
    nmcli connection modify "${INTERFACE}" \
        ipv4.dns "${DNS_SERVERS}" \
        ipv4.method manual \
        connection.autoconnect yes
fi

nmcli connection up "${INTERFACE}" || true

echo "=== [2/8] Systeempakketten, Cockpit & Podman Installeren ==="
dnf update -y
dnf install -y \
    curl wget tar \
    firewalld \
    dnsmasq \
    podman \
    openssh-server \
    cockpit \
    cockpit-podman \
    dnf-utils

echo "=== [3/8] SSH Server Activeren ==="
systemctl enable --now sshd

echo "=== [4/8] Cockpit Web UI Activeren ==="
systemctl enable --now cockpit.socket

echo "=== [5/8] Netboot.xyz Container Voorbereiden ==="
mkdir -p "${NETBOOT_CONFIG}" "${NETBOOT_ASSETS}"

# Permissies voor PUID/PGID 1000 (default in image)
chown -R 1000:1000 "${NETBOOT_DIR}"
chmod -R 755 "${NETBOOT_DIR}"

# SELinux: sta container toe om cgroup/systemd te beheren (soms nodig voor Podman)
setsebool -P container_manage_cgroup on 2>/dev/null || true

# Image pull met retry (DNS kan net na netwerk-config nog niet klaar zijn)
echo "  -> Image pullen: ${NETBOOT_IMAGE}"
for i in {1..3}; do
    if podman pull "${NETBOOT_IMAGE}"; then
        break
    fi
    echo "  -> Pull poging ${i} mislukt, opnieuw over 5s..."
    sleep 5
    if [[ ${i} -eq 3 ]]; then
        echo "FOUT: kon image niet pullen na 3 pogingen." >&2
        exit 1
    fi
done

# Oude container opruimen (indien aanwezig)
podman rm -f netbootxyz &>/dev/null || true

# Systemd unit voor de container (dependency-aware)
echo "=== [6/8] Systemd unit voor netboot.xyz aanmaken ==="
cat <<EOF > /etc/systemd/system/netbootxyz.service
[Unit]
Description=netboot.xyz container (TFTP + Web + Assets)
Wants=network-online.target
After=network-online.target
Documentation=https://netboot.xyz

[Service]
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/podman rm -f netbootxyz
ExecStart=/usr/bin/podman run \\
    --name=netbootxyz \\
    --net=host \\
    -v ${NETBOOT_CONFIG}:/config:z \\
    -v ${NETBOOT_ASSETS}:/assets:z \\
    ${NETBOOT_IMAGE}
ExecStop=/usr/bin/podman stop -t 10 netbootxyz
ExecStopPost=-/usr/bin/podman rm -f netbootxyz

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now netbootxyz.service

# Wacht kort en controleer of de container draait
sleep 5
if ! systemctl is-active --quiet netbootxyz.service; then
    echo "FOUT: netbootxyz.service draait niet. Bekijk logs met:" >&2
    echo "  journalctl -u netbootxyz -n 50 --no-pager" >&2
    echo "  podman logs netbootxyz" >&2
    exit 1
fi

echo "  -> Container actief. TFTP/web beschikbaar."

echo "=== [7/8] Dnsmasq als DHCP-server configureren ==="
# dnsmasq draait ALLEEN DHCP. Container verzorgt TFTP op 69/udp.
cat <<EOF > /etc/dnsmasq.d/pxe.conf
# Interface & binding
interface=${INTERFACE}
bind-interfaces

# Alleen DHCP, geen DNS-resolving
port=0

# DHCP scope voor PXE clients
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${NETMASK},${DHCP_LEASE}
dhcp-option=option:router,${GATEWAY}
dhcp-option=option:dns-server,9.9.9.9,1.1.1.1

# GEEN enable-tftp — container draait tftp-hpa op poort 69/udp

# --- Architectuur-detectie ---
# Boot binaries zitten ingebakken in de container image.

# Legacy BIOS (x86)
dhcp-match=set:bios,60,PXEClient:Arch:00000
dhcp-boot=tag:bios,netboot.xyz.kpxe,,${IP_ONLY}

# UEFI x86_64
dhcp-match=set:efi64,60,PXEClient:Arch:00007
dhcp-boot=tag:efi64,netboot.xyz.efi,,${IP_ONLY}

# UEFI x86_64 (obsolete)
dhcp-match=set:efi64-2,60,PXEClient:Arch:00009
dhcp-boot=tag:efi64-2,netboot.xyz.efi,,${IP_ONLY}

# UEFI ARM64
dhcp-match=set:efi-arm64,60,PXEClient:Arch:0000B
dhcp-boot=tag:efi-arm64,netboot.xyz-arm64.efi,,${IP_ONLY}

# --- Optioneel: Secure Boot clients ---
# Haal de commentaar weg als je moderne hardware met Secure Boot gebruikt.
# De container downloadt de signed shim automatisch naar /config/menus/.
#dhcp-match=set:efi64-sb,60,PXEClient:Arch:00007,uefi
#dhcp-boot=tag:efi64-sb,secureboot-x86_64/shimx64.efi,,${IP_ONLY}
EOF

# dnsmasq pas starten nadat netbootxyz container draait
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat <<'EOF' > /etc/systemd/system/dnsmasq.service.d/after-netbootxyz.conf
[Unit]
After=netbootxyz.service
Wants=netbootxyz.service
EOF

systemctl daemon-reload
systemctl enable dnsmasq
systemctl restart dnsmasq

if ! systemctl is-active --quiet dnsmasq; then
    echo "FOUT: dnsmasq start niet. Bekijk logs met:" >&2
    echo "  journalctl -u dnsmasq -n 50 --no-pager" >&2
    exit 1
fi

echo "=== [8/8] Firewall Poorten Openzetten ==="
systemctl enable --now firewalld

# DHCP (dnsmasq)
firewall-cmd --permanent --add-service=dhcp

# SSH (beheer)
firewall-cmd --permanent --add-service=ssh

# Cockpit (beheer, poort 9090)
firewall-cmd --permanent --add-service=cockpit

# TFTP (container tftp-hpa op poort 69/udp)
firewall-cmd --permanent --add-port=69/udp

# Netboot Web UI (container, poort 3000)
firewall-cmd --permanent --add-port=3000/tcp

# Netboot Assets HTTP (container NGINX, poort 80)
firewall-cmd --permanent --add-port=80/tcp

firewall-cmd --reload

# --- SAMENVATTING ---
echo "===================================================="
echo " Deployment Server is VOLLEDIG OPERATIONEEL!"
echo "===================================================="
echo " Hostname:       ${HOSTNAME_SET}"
echo " Interface:      ${INTERFACE}"
echo " IP-adres:       ${IP_ONLY}"
echo " Gateway:        ${GATEWAY}"
echo " DHCP-bereik:    ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "----------------------------------------------------"
echo " Cockpit UI:     https://${IP_ONLY}:9090 (incl. Podman tab)"
echo " Netboot WebUI:  http://${IP_ONLY}:3000"
echo " Assets HTTP:    http://${IP_ONLY}:80"
echo "----------------------------------------------------"
echo " TFTP:           container (poort 69/udp)"
echo " DHCP:           dnsmasq (/etc/dnsmasq.d/pxe.conf)"
echo " Image:          ${NETBOOT_IMAGE}"
echo " Config volume:  ${NETBOOT_CONFIG}"
echo " Assets volume:  ${NETBOOT_ASSETS}"
echo " Systemd unit:   netbootxyz.service"
echo "===================================================="
echo ""
echo " Volgende stappen:"
echo "  1. Log in op Cockpit:  https://${IP_ONLY}:9090 -> 'Podman Containers'"
echo "  2. Start een PXE-client in het 10.90.90.0/24 netwerk"
echo "  3. Bekijk TFTP-logs:   podman logs -f netbootxyz"
echo "  4. Bekijk DHCP-logs:   journalctl -u dnsmasq -f"
echo "  5. Test web UI:        curl -I http://${IP_ONLY}:3000"
echo "  6. Test assets:        curl -I http://${IP_ONLY}/"
echo
echo ". 7. Hier eventuele iso's plaatsen: /opt/netbootxyz/assets"
"===================================================="

# --- REBOOT CHECK ---
if needs-restarting -r &>/dev/null; then
    echo ""
    echo "⚠️  LET OP: Een reboot is vereist (kernel of core libraries geüpdatet)."
    echo "   Voer uit:  reboot"
fi