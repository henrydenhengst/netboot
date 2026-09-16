#!/bin/bash

# ============================================================
# Debian 13 Netboot Server
#
# Voorbereiding op apart netboot-netwerk
#
# Deze versie:
# - installeert nginx
# - installeert dnsmasq voor TFTP
# - downloadt Debian 13 PXE-bestanden
# - ondersteunt UEFI en BIOS
#
# LET OP:
# DHCP staat bewust UIT.
# OPNsense gaat later DHCP verzorgen.
# ============================================================

set -e

# ------------------------------------------------------------
# Instellingen
# ------------------------------------------------------------

TFTP_DIR="/srv/tftp"
HTTP_DIR="/var/www/html/debian"

DEBIAN_URL="https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz"

echo
echo "=========================================="
echo " Debian 13 Netboot Server"
echo "=========================================="
echo

# ------------------------------------------------------------
# Controle root
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Start dit script als root:"
    echo
    echo "sudo $0"
    exit 1
fi

# ------------------------------------------------------------
# Controle Debian
# ------------------------------------------------------------

if [ ! -f /etc/debian_version ]; then
    echo "Dit lijkt geen Debian-systeem."
    exit 1
fi

echo "[1/7] Pakketten installeren..."

apt-get update

apt-get install -y \
    dnsmasq \
    nginx \
    curl \
    ca-certificates \
    tar

# ------------------------------------------------------------
# dnsmasq DHCP uitschakelen
# ------------------------------------------------------------

echo "[2/7] dnsmasq voorbereiden..."

mkdir -p /etc/dnsmasq.d

cat > /etc/dnsmasq.d/netboot.conf <<'EOF'
# Debian Netboot
#
# DHCP staat bewust uit.
# OPNsense verzorgt later DHCP.

port=0

enable-tftp
tftp-root=/srv/tftp
EOF

# dnsmasq mag nu nog geen DHCP leveren.
# Port 53 wordt eveneens niet gebruikt.

systemctl enable dnsmasq
systemctl restart dnsmasq

# ------------------------------------------------------------
# TFTP directory
# ------------------------------------------------------------

echo "[3/7] TFTP-directory maken..."

mkdir -p "$TFTP_DIR"

# ------------------------------------------------------------
# Debian netboot downloaden
# ------------------------------------------------------------

echo "[4/7] Debian 13 netboot downloaden..."

TMP_FILE="/tmp/debian-netboot.tar.gz"

curl -fL "$DEBIAN_URL" -o "$TMP_FILE"

echo "Uitpakken..."

tar -xzf "$TMP_FILE" -C "$TFTP_DIR"

rm -f "$TMP_FILE"

# ------------------------------------------------------------
# Controle bestanden
# ------------------------------------------------------------

echo
echo "PXE-bestanden:"

find "$TFTP_DIR/debian-installer/amd64" \
    -maxdepth 2 \
    -type f \
    | sort

# ------------------------------------------------------------
# Handige UEFI symlinks
# ------------------------------------------------------------

echo
echo "[5/7] UEFI PXE-links maken..."

ln -sfn \
    debian-installer/amd64/grubx64.efi \
    "$TFTP_DIR/grubx64.efi"

ln -sfn \
    debian-installer/amd64/grub \
    "$TFTP_DIR/grub"

# ------------------------------------------------------------
# HTTP directory
# ------------------------------------------------------------

echo "[6/7] HTTP-directory maken..."

mkdir -p "$HTTP_DIR"

cat > "$HTTP_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="nl">
<head>
<meta charset="UTF-8">
<title>FreeBoot Debian Netboot</title>
</head>
<body>
<h1>Debian 13 Netboot Server</h1>
<p>FreeBoot PXE server</p>
</body>
</html>
EOF

systemctl enable nginx
systemctl restart nginx

# ------------------------------------------------------------
# dnsmasq status
# ------------------------------------------------------------

echo "[7/7] Controle..."

systemctl --no-pager --full status dnsmasq || true

echo
echo "=========================================="
echo " KLAAR"
echo "=========================================="
echo
echo "TFTP:"
echo "  $TFTP_DIR"
echo
echo "HTTP:"
echo "  $HTTP_DIR"
echo
echo "Debian PXE:"
echo "  UEFI : grubx64.efi"
echo "  BIOS : pxelinux.0"
echo
echo "DHCP:"
echo "  UIT"
echo
echo "De server kan nu veilig op het"
echo "productienetwerk blijven."
echo
echo "Volgende stap:"
echo "  1. Netboot-netwerk maken op OPNsense"
echo "  2. DHCP op OPNsense configureren"
echo "  3. Deze server naar het netboot-netwerk verplaatsen"
echo "  4. Eén test-PC PXE laten booten"
echo