#!/usr/bin/env bash
#
# Deployment / PXE-boot server setup voor Fedora / RHEL / AlmaLinux
# Versie: 2.5
# Wijzigingen t.o.v. 2.4:
#   - Digest-tag verwijderd (niet onafhankelijk geverifieerd)
#   - netboot.xyz image op leesbare tag 0.7.6-nbxyz24
#   - TFTP-test ruimt tijdelijke map op via trap
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

# Vastgezette netboot.xyz container versie (geen :latest).
# Wil je maximale reproduceerbaarheid, verifieer dan de digest lokaal met:
#   skopeo inspect docker://ghcr.io/netbootxyz/netbootxyz:0.7.6-nbxyz24 | grep -i digest
# en gebruik daarna:
#   NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:0.7.6-nbxyz24@sha256:<digest>"
NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:0.7.6-nbxyz24"

FORGEJO_DIR="/opt/forgejo"
FORGEJO_DATA="${FORGEJO_DIR}/data"
FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:15"
FORGEJO_WEB_PORT="3001"
FORGEJO_SSH_PORT="2222"

echo "=== [1/9] Hostnaam en Netwerk instellen ==="
hostnamectl set-hostname "${HOSTNAME_SET}"

CONN_NAME="$(nmcli -t -f NAME,DEVICE connection show | grep ":${INTERFACE}$" | head -n1 | cut -d: -f1 || true)"

if [[ -n "${CONN_NAME}" ]]; then
    echo "  -> Bestaand connectieprofiel gevonden: ${CONN_NAME}"
    nmcli connection modify "${CONN_NAME}" \
        ipv4.addresses "${IP_ADDR}" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS_SERVERS}" \
        ipv4.method manual \
        connection.autoconnect yes
else
    echo "  -> Geen profiel voor ${INTERFACE}, nieuwe aanmaken..."
    nmcli connection add type ethernet con-name "${INTERFACE}" ifname "${INTERFACE}" \
        ip4 "${IP_ADDR}" gw4 "${GATEWAY}"
    nmcli connection modify "${INTERFACE}" \
        ipv4.dns "${DNS_SERVERS}" \
        ipv4.method manual \
        connection.autoconnect yes
    CONN_NAME="${INTERFACE}"
fi

nmcli connection up "${CONN_NAME}" || true

echo "=== [2/9] Systeempakketten Installeren ==="
dnf install -y \
    curl wget tar \
    firewalld \
    dnsmasq \
    podman \
    openssh-server \
    cockpit \
    cockpit-podman \
    tftp

dnf update -y

echo "=== [3/9] SSH Server Activeren ==="
systemctl enable --now sshd

echo "=== [4/9] Cockpit Web UI Activeren ==="
systemctl enable --now cockpit.socket

echo "=== [5/9] Netboot.xyz Container Starten (PXE) ==="
mkdir -p "${NETBOOT_CONFIG}" "${NETBOOT_ASSETS}"
chown -R 1000:1000 "${NETBOOT_DIR}"
chmod -R 755 "${NETBOOT_DIR}"

for i in {1..3}; do
    podman pull "${NETBOOT_IMAGE}" && break
    echo "  -> Pull poging ${i} mislukt, opnieuw over 5s..."
    sleep 5
    [[ ${i} -eq 3 ]] && { echo "FOUT: kon netboot image niet pullen." >&2; exit 1; }
done

podman rm -f netbootxyz &>/dev/null || true

cat <<EOF > /etc/systemd/system/netbootxyz.service
[Unit]
Description=netboot.xyz container (TFTP + Web + Assets)
Wants=network-online.target
After=network-online.target

[Service]
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/podman rm -f netbootxyz
ExecStart=/usr/bin/podman run \\
    --name=netbootxyz \\
    --net=host \\
    -e TFTPD_OPTS="--tftp-single-port" \\
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

echo "  -> Wachten tot netboot.xyz TFTP klaar is..."
TFTP_READY=0
for i in {1..30}; do
    if ss -lunp 2>/dev/null | grep -q ':69 '; then
        if command -v tftp &>/dev/null; then
            TFTP_TEST_DIR="$(mktemp -d)"
            trap 'rm -rf "${TFTP_TEST_DIR:-}"' EXIT

            EFI_OK=0
            BIOS_OK=0

            # Test UEFI boot bestand
            if (
                cd "${TFTP_TEST_DIR}"
                printf 'get netboot.xyz.efi\nquit\n' | tftp 127.0.0.1
            ) &>/dev/null; then
                EFI_OK=1
            fi

            # Test BIOS boot bestand
            if (
                cd "${TFTP_TEST_DIR}"
                printf 'get netboot.xyz.kpxe\nquit\n' | tftp 127.0.0.1
            ) &>/dev/null; then
                BIOS_OK=1
            fi

            rm -rf "${TFTP_TEST_DIR}"
            trap - EXIT

            if [[ ${EFI_OK} -eq 1 && ${BIOS_OK} -eq 1 ]]; then
                TFTP_READY=1
                break
            fi
        else
            TFTP_READY=2
            break
        fi
    fi
    sleep 2
done

case "${TFTP_READY}" in
    1) echo "  -> TFTP werkt: zowel netboot.xyz.efi als netboot.xyz.kpxe kunnen worden opgehaald." ;;
    2) echo "  -> TFTP luistert op poort 69 (bestandstest overgeslagen — tftp-client ontbreekt)." ;;
    0) echo "  WAARSCHUWING: TFTP-test niet volledig geslaagd binnen 60s." >&2
       echo "  Controleer: podman logs netbootxyz" >&2 ;;
esac

if ! systemctl is-active --quiet netbootxyz.service; then
    echo "FOUT: netbootxyz.service draait niet." >&2
    echo "  journalctl -u netbootxyz -n 50 --no-pager" >&2
    exit 1
fi

echo "=== [6/9] Forgejo Container Starten (Git) ==="
mkdir -p "${FORGEJO_DATA}"
chown -R 1000:1000 "${FORGEJO_DATA}"
chmod -R 750 "${FORGEJO_DATA}"

for i in {1..3}; do
    podman pull "${FORGEJO_IMAGE}" && break
    echo "  -> Pull poging ${i} mislukt, opnieuw over 5s..."
    sleep 5
    [[ ${i} -eq 3 ]] && { echo "FOUT: kon Forgejo image niet pullen." >&2; exit 1; }
done

podman rm -f forgejo &>/dev/null || true

cat <<EOF > /etc/systemd/system/forgejo.service
[Unit]
Description=Forgejo container (Git forge)
Wants=network-online.target
After=network-online.target

[Service]
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/usr/bin/podman rm -f forgejo
ExecStart=/usr/bin/podman run \\
    --name=forgejo \\
    -p ${FORGEJO_WEB_PORT}:3000 \\
    -p ${FORGEJO_SSH_PORT}:22 \\
    -e USER_UID=1000 \\
    -e USER_GID=1000 \\
    -v ${FORGEJO_DATA}:/data:Z \\
    ${FORGEJO_IMAGE}
ExecStop=/usr/bin/podman stop -t 10 forgejo
ExecStopPost=-/usr/bin/podman rm -f forgejo

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now forgejo.service
sleep 5

if ! systemctl is-active --quiet forgejo.service; then
    echo "FOUT: forgejo.service draait niet." >&2
    echo "  journalctl -u forgejo -n 50 --no-pager" >&2
    exit 1
fi

echo "  -> Forgejo draait."

echo "=== [7/9] Dnsmasq als DHCP-server configureren (PXE) ==="
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

# GEEN enable-tftp — de netboot.xyz container draait tftp-hpa op poort 69/udp.
# Met TFTPD_OPTS="--tftp-single-port" loopt ALLE TFTP-data via poort 69.

# --- Architectuur-detectie via DHCP optie 93 (RFC 4578) ---

# BIOS (x86)
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,netboot.xyz.kpxe,,${IP_ONLY}

# UEFI x86_64 (standaard)
dhcp-match=set:efi64,option:client-arch,7
dhcp-boot=tag:efi64,netboot.xyz.efi,,${IP_ONLY}

# UEFI x86_64 (obsolete)
dhcp-match=set:efi64-2,option:client-arch,9
dhcp-boot=tag:efi64-2,netboot.xyz.efi,,${IP_ONLY}

# UEFI ARM64
dhcp-match=set:efi-arm64,option:client-arch,11
dhcp-boot=tag:efi-arm64,netboot.xyz-arm64.efi,,${IP_ONLY}
EOF

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
    echo "FOUT: dnsmasq start niet." >&2
    echo "  journalctl -u dnsmasq -n 50 --no-pager" >&2
    exit 1
fi

echo "=== [8/9] Firewall Poorten Openzetten ==="
systemctl enable --now firewalld

firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=cockpit
firewall-cmd --permanent --add-port=69/udp
firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=${FORGEJO_WEB_PORT}/tcp
firewall-cmd --permanent --add-port=${FORGEJO_SSH_PORT}/tcp

firewall-cmd --reload

echo "=== [9/9] Eindcontrole & Samenvatting ==="
echo ""
echo "--- PXE-keten validatie ---"

if systemctl is-active --quiet netbootxyz.service; then
    echo "  [OK] netbootxyz container draait"
else
    echo "  [FOUT] netbootxyz container draait NIET" >&2
fi

if ss -lunp 2>/dev/null | grep -q ':69 '; then
    echo "  [OK] TFTP luistert op poort 69/udp (single-port mode)"
else
    echo "  [FOUT] TFTP luistert NIET op poort 69/udp" >&2
fi

for f in netboot.xyz.efi netboot.xyz.kpxe netboot.xyz-arm64.efi; do
    if [[ -f "${NETBOOT_CONFIG}/menus/${f}" ]]; then
        echo "  [OK] ${f} aanwezig"
    else
        echo "  [INFO] ${f} niet gevonden (kan ontbreken als container nog initialiseert)"
    fi
done

if systemctl is-active --quiet dnsmasq; then
    echo "  [OK] dnsmasq draait"
else
    echo "  [FOUT] dnsmasq draait NIET" >&2
fi

echo ""
echo "===================================================="
echo " Deployment Server Samenvatting"
echo "===================================================="
echo " Hostname:       ${HOSTNAME_SET}"
echo " Interface:      ${INTERFACE}"
echo " IP-adres:       ${IP_ONLY}"
echo " Gateway:        ${GATEWAY}"
echo " DHCP-bereik:    ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "----------------------------------------------------"
echo " Cockpit UI:     https://${IP_ONLY}:9090"
echo " Netboot WebUI:  http://${IP_ONLY}:3000"
echo " Assets HTTP:    http://${IP_ONLY}:80"
echo "----------------------------------------------------"
echo " Forgejo WebUI:  http://${IP_ONLY}:${FORGEJO_WEB_PORT}"
echo " Forgejo SSH:    ssh://git@${IP_ONLY}:${FORGEJO_SSH_PORT}"
echo "----------------------------------------------------"
echo " Netboot image:  ${NETBOOT_IMAGE}"
echo " TFTP:           container:/config/menus (single-port, 69/udp)"
echo " DHCP:           dnsmasq (/etc/dnsmasq.d/pxe.conf)"
echo " Architectuur:   option:client-arch (DHCP optie 93, RFC 4578)"
echo " Systemd units:  netbootxyz.service, forgejo.service"
echo "===================================================="
echo ""
echo " Volgende stappen:"
echo "  1. Test TFTP vanaf een andere machine:"
echo "       tftp ${IP_ONLY} -c get netboot.xyz.efi"
echo "       tftp ${IP_ONLY} -c get netboot.xyz.kpxe"
echo "  2. Start een PXE-client in het 10.90.90.0/24 netwerk"
echo "  3. Bekijk TFTP-logs:   podman logs -f netbootxyz"
echo "  4. Bekijk DHCP-logs:   journalctl -u dnsmasq -f"
echo "  5. Forgejo:            http://${IP_ONLY}:${FORGEJO_WEB_PORT}"
echo "===================================================="

if command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r &>/dev/null; then
        echo ""
        echo "⚠️  LET OP: Een reboot is vereist."
        echo "   Voer uit:  reboot"
    fi
fi