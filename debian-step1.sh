#!/bin/bash

# ============================================================
# Debian 13 NETBOOT SERVER
# ============================================================
#
# Doel:
#   Debian 13 voorbereiden als PXE/netboot-server.
#
# HUIDIGE SITUATIE:
#   Server hangt nog aan het productienetwerk.
#
# DHCP:
#   NIET op deze server.
#   DHCP wordt later door OPNsense verzorgd.
#
# Deze versie installeert:
#   - dnsmasq : uitsluitend TFTP
#   - nginx   : HTTP
#   - Debian 13 PXE bestanden
#
# Ondersteuning:
#   - UEFI
#   - BIOS/Legacy
#
# ============================================================

set -euo pipefail

TFTP_DIR="/srv/tftp"
HTTP_DIR="/var/www/html/debian"

DEBIAN_URL="https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz"

TMP_FILE="/tmp/debian-netboot.tar.gz"

# ------------------------------------------------------------
# Kleuren
# ------------------------------------------------------------

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[FOUT]${NC} $1"
}

# ------------------------------------------------------------
# Root controleren
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    error "Start dit script met sudo:"
    echo
    echo "sudo $0"
    exit 1
fi

# ------------------------------------------------------------
# Debian controleren
# ------------------------------------------------------------

if [ ! -f /etc/debian_version ]; then
    error "Dit systeem lijkt geen Debian te zijn."
    exit 1
fi

. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    error "Dit systeem is geen Debian."
    exit 1
fi

echo
echo "============================================================"
echo " Debian 13 Netboot Server"
echo "============================================================"
echo
echo "DHCP wordt NIET geconfigureerd."
echo "De server kan dus op het productienetwerk blijven."
echo

# ------------------------------------------------------------
# Netwerk tonen
# ------------------------------------------------------------

info "Huidige netwerkconfiguratie:"
ip -br addr
echo

# ------------------------------------------------------------
# Pakketten
# ------------------------------------------------------------

echo "============================================================"
echo "1. Pakketten installeren"
echo "============================================================"

apt-get update

apt-get install -y \
    dnsmasq \
    nginx \
    curl \
    ca-certificates \
    tar

ok "Benodigde pakketten geïnstalleerd."

# ------------------------------------------------------------
# dnsmasq configuratie
# ------------------------------------------------------------

echo
echo "============================================================"
echo "2. dnsmasq configureren"
echo "============================================================"

mkdir -p /etc/dnsmasq.d
mkdir -p "$TFTP_DIR"

# Oude FreeBoot/netboot configuratie verwijderen
rm -f /etc/dnsmasq.d/netboot.conf

cat > /etc/dnsmasq.d/netboot.conf <<'EOF'
# ============================================================
# FreeBoot Debian Netboot
# ============================================================
#
# DHCP staat UIT.
# OPNsense verzorgt later DHCP.
#
# dnsmasq doet hier alleen TFTP.
# ============================================================

port=0

enable-tftp
tftp-root=/srv/tftp
EOF

ok "dnsmasq configuratie geschreven."

# ------------------------------------------------------------
# dnsmasq configuratie testen
# ------------------------------------------------------------

echo
info "dnsmasq configuratie controleren..."

if dnsmasq --test; then
    ok "dnsmasq configuratie is geldig."
else
    error "dnsmasq configuratie bevat een fout."
    exit 1
fi

# ------------------------------------------------------------
# dnsmasq starten
# ------------------------------------------------------------

echo
info "dnsmasq starten..."

if systemctl restart dnsmasq; then
    ok "dnsmasq draait."
else
    error "dnsmasq kon niet starten."
    echo
    echo "Controleer met:"
    echo
    echo "sudo systemctl status dnsmasq --no-pager -l"
    echo
    echo "Het script stopt hier."
    exit 1
fi

systemctl enable dnsmasq >/dev/null

# ------------------------------------------------------------
# Debian PXE bestanden
# ------------------------------------------------------------

echo
echo "============================================================"
echo "3. Debian 13 PXE-bestanden downloaden"
echo "============================================================"

rm -f "$TMP_FILE"

curl \
    --fail \
    --location \
    --show-error \
    --progress-bar \
    "$DEBIAN_URL" \
    --output "$TMP_FILE"

ok "Debian netboot.tar.gz gedownload."

# ------------------------------------------------------------
# Oude bestanden opruimen
# ------------------------------------------------------------

rm -rf "$TFTP_DIR"/*
mkdir -p "$TFTP_DIR"

# ------------------------------------------------------------
# Uitpakken
# ------------------------------------------------------------

echo
info "PXE-bestanden uitpakken..."

tar -xzf "$TMP_FILE" -C "$TFTP_DIR"

rm -f "$TMP_FILE"

ok "PXE-bestanden uitgepakt."

# ------------------------------------------------------------
# Bestanden controleren
# ------------------------------------------------------------

echo
echo "Belangrijke PXE-bestanden:"
echo

find "$TFTP_DIR" \
    -type f \
    \( \
        -name "bootnetx64.efi" \
        -o -name "grubx64.efi" \
        -o -name "pxelinux.0" \
        -o -name "linux" \
        -o -name "initrd.gz" \
    \) \
    -print | sort

# ------------------------------------------------------------
# nginx
# ------------------------------------------------------------

echo
echo "============================================================"
echo "4. HTTP-server configureren"
echo "============================================================"

mkdir -p "$HTTP_DIR"

cat > "$HTTP_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <title>FreeBoot Debian Netboot</title>
</head>
<body>
    <h1>FreeBoot Debian 13 Netboot</h1>
    <p>Netboot-server actief.</p>
</body>
</html>
EOF

systemctl enable nginx >/dev/null
systemctl restart nginx

ok "nginx draait."

# ------------------------------------------------------------
# HTTP controleren
# ------------------------------------------------------------

echo
info "HTTP-server testen..."

if curl --fail --silent http://127.0.0.1/debian/ >/dev/null; then
    ok "HTTP werkt."
else
    error "HTTP-test mislukt."
    exit 1
fi

# ------------------------------------------------------------
# TFTP controleren
# ------------------------------------------------------------

echo
echo "============================================================"
echo "5. TFTP controleren"
echo "============================================================"

if [ -d "$TFTP_DIR/debian-installer" ]; then
    ok "Debian installer aanwezig."
else
    error "Debian installer ontbreekt."
    exit 1
fi

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

echo
echo "============================================================"
echo "6. Services"
echo "============================================================"

systemctl --no-pager --full status dnsmasq | sed -n '1,8p'
echo
systemctl --no-pager --full status nginx | sed -n '1,8p'

# ------------------------------------------------------------
# Eindcontrole
# ------------------------------------------------------------

echo
echo "============================================================"
echo " NETBOOT SERVER KLAAR"
echo "============================================================"
echo

echo "TFTP:"
echo "  $TFTP_DIR"
echo

echo "HTTP:"
echo "  http://<server-ip>/debian/"
echo

echo "DHCP:"
echo "  NIET actief op deze server"
echo

echo "PXE:"
echo "  UEFI : Debian netboot UEFI bestanden aanwezig"
echo "  BIOS : Debian netboot BIOS bestanden aanwezig"
echo

echo "Huidige netwerk:"
ip -br addr

echo
echo "============================================================"
echo "VOLGENDE STAP"
echo "============================================================"
echo
echo "1. Deze server blijft voorlopig op het productienetwerk."
echo "2. PXE/DHCP wordt nog NIET gebruikt."
echo "3. Configureer later een apart netboot-netwerk op OPNsense."
echo "4. Laat OPNsense DHCP verzorgen."
echo "5. Verplaats daarna deze server naar het netboot-netwerk."
echo "6. Test vervolgens met één PXE-client."
echo
echo "Installatie succesvol afgerond."
echo