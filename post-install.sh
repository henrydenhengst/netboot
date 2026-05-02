#!/bin/bash
# post-install.sh
# Volledig autonome Netboot-server installatie voor Devuan
# Detecteert NICs automatisch zonder gebruikersinteractie

set -euo pipefail

# ============================================
# LOGGING NAAR BESTAND
# ============================================

LOGFILE="/var/log/netboot.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=========================================="
echo "Netboot installatie gestart op: $(date)"
echo "=========================================="

# ============================================
# KLEUREN EN FUNCTIES
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================
# INIT SYSTEEM DETECTIE
# ============================================

detect_init() {
    if pidof systemd >/dev/null 2>&1; then
        echo "systemd"
    elif [ -f /sbin/openrc-run ] || [ -f /usr/sbin/openrc-run ]; then
        echo "openrc"
    else
        echo "sysvinit"
    fi
}

# Service management (werkt op alle init systemen)
service_control() {
    local action=$1
    local service=$2
    
    INIT_SYS=$(detect_init)
    
    case $INIT_SYS in
        systemd)
            systemctl $action $service
            ;;
        openrc)
            rc-service $service $action
            ;;
        sysvinit)
            service $service $action
            ;;
    esac
}

# Service inschakelen bij boot
service_enable() {
    local service=$1
    
    INIT_SYS=$(detect_init)
    
    case $INIT_SYS in
        systemd)
            systemctl enable $service
            ;;
        openrc)
            rc-update add $service default
            ;;
        sysvinit)
            update-rc.d $service defaults
            ;;
    esac
}

# Controleer of interface fysiek is
is_physical_interface() {
    local iface=$1
    [ -e "/sys/class/net/$iface/device" ] && return 0
    return 1
}

# Backup maken van bestand (enkele timestamp)
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$file" "${file}.backup.${timestamp}"
        log_info "Backup gemaakt: ${file}.backup.${timestamp}"
    fi
}

# ============================================
# CHECK OF HET SYSTEEM DEVUAN IS
# ============================================

log_info "Controleren of systeem Devuan is..."

if [ -f /etc/devuan_version ]; then
    log_info "Devuan versie: $(cat /etc/devuan_version)"
elif [ -f /etc/os-release ] && grep -qi "devuan" /etc/os-release; then
    log_info "Devuan gedetecteerd via os-release"
else
    echo ""
    echo "=========================================="
    echo "INSTALLATIE GESTOPT"
    echo "=========================================="
    echo "Dit script is alleen voor Devuan Linux."
    echo ""
    echo "Gedetecteerd besturingssysteem:"
    if [ -f /etc/os-release ]; then
        grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"'
    elif [ -f /etc/debian_version ]; then
        echo "Debian (niet Devuan)"
    else
        echo "Onbekend (geen Devuan)"
    fi
    echo "Log: $LOGFILE"
    echo "=========================================="
    exit 1
fi

# Controleer root
if [ "$EUID" -ne 0 ]; then 
    log_error "Dit script moet als root worden uitgevoerd (sudo)"
    exit 1
fi

# ============================================
# INIT SYSTEEM DETECTIE
# ============================================

INIT_SYS=$(detect_init)
log_info "Gedetecteerd init systeem: $INIT_SYS"

# ============================================
# NETWERK INTERFACES OVERZICHT (debug)
# ============================================

log_info "Huidige netwerk interfaces:"
ip -brief addr | grep -v lo | while read line; do
    echo "  $line"
done
echo ""

# ============================================
# DHCP CONFLICT DETECTIE
# ============================================

log_info "Controleren op bestaande DHCP servers..."
if ss -lupn 2>/dev/null | grep -q ":67 "; then
    log_warn "⚠️ Er draait AL een DHCP server op dit systeem!"
    log_warn "    Dit kan conflicten geven. Overweeg deze te stoppen."
    ss -lupn 2>/dev/null | grep ":67 " | while read line; do
        log_warn "    $line"
    done
    echo ""
fi

# ============================================
# AUTOMATISCHE NIC DETECTIE
# ============================================

log_info "Automatisch detecteren van netwerkinterfaces..."

# Detecteer WAN interface (heeft IP in 192.168.178.x)
WAN_IF=""
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
    if is_physical_interface $iface; then
        if ip addr show $iface 2>/dev/null | grep -q "inet 192.168.178."; then
            WAN_IF="$iface"
            log_info "WAN interface: $iface"
            break
        fi
    fi
done

# WAN fallback via default route
if [ -z "$WAN_IF" ]; then
    WAN_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$WAN_IF" ]; then
        log_warn "WAN fallback via default route: $WAN_IF"
    else
        log_error "Geen WAN interface gevonden!"
        exit 1
    fi
fi

# Detecteer LAN interface (fysiek, geen IP, niet de WAN)
LAN_IF=""
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
    if is_physical_interface $iface && [ "$iface" != "$WAN_IF" ]; then
        if ! ip addr show $iface 2>/dev/null | grep -q "inet "; then
            LAN_IF="$iface"
            log_info "LAN interface: $iface"
            break
        fi
    fi
done

# LAN fallback (elke andere fysieke NIC die niet WAN is)
if [ -z "$LAN_IF" ]; then
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if is_physical_interface $iface && [ "$iface" != "$WAN_IF" ]; then
            LAN_IF="$iface"
            log_warn "LAN fallback: $iface (heeft mogelijk al een IP)"
            break
        fi
    done
fi

if [ -z "$LAN_IF" ]; then
    log_error "Geen LAN interface gevonden!"
    exit 1
fi

# Vaste netboot configuratie
LAN_IP="10.0.0.1"
LAN_MASK="24"
LAN_NETWORK="10.0.0.0"
DHCP_START="10.0.0.50"
DHCP_END="10.0.0.200"

log_info "Configuratie:"
log_info "  Init systeem:   $INIT_SYS"
log_info "  WAN:            ${WAN_IF} -> router (192.168.178.1)"
log_info "  LAN:            ${LAN_IF} -> ${LAN_IP}/${LAN_MASK}"
log_info "  DHCP range:     ${DHCP_START} - ${DHCP_END}"
log_info "  DNS:            9.9.9.9, 1.1.1.1"
echo ""

# ============================================
# SYSTEEM UPDATE
# ============================================

log_info "Systeem updaten..."
apt update
apt upgrade -y

# ============================================
# PACKAGES INSTALLEREN
# ============================================

log_info "Netboot packages installeren..."
apt install -y \
    dnsmasq \
    tftpd-hpa \
    nfs-kernel-server \
    nginx \
    wget \
    curl \
    unzip \
    vim \
    net-tools \
    htop \
    iptables \
    iptables-persistent

# Stop services voor configuratie
service_control stop dnsmasq 2>/dev/null || true
service_control stop tftpd-hpa 2>/dev/null || true
service_control stop nginx 2>/dev/null || true

# ============================================
# DIRECTORY STRUCTUUR
# ============================================

log_info "Directory structuur aanmaken..."
mkdir -p /srv/tftp /srv/nfs /var/www/netboot

# ============================================
# DOWNLOAD BOOTLOADERS (met error handling)
# ============================================

log_info "Netboot.xyz bootloaders downloaden..."
cd /srv/tftp

log_info "  Downloading netboot.xyz.kpxe..."
wget -q --show-progress https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe || {
    log_error "Download mislukt: netboot.xyz.kpxe"
    exit 1
}

log_info "  Downloading netboot.xyz.efi..."
wget -q --show-progress https://boot.netboot.xyz/ipxe/netboot.xyz.efi || {
    log_error "Download mislukt: netboot.xyz.efi"
    exit 1
}

chmod 644 /srv/tftp/*

log_info "Devuan netboot image downloaden..."
cd /tmp

log_info "  Downloading netboot.tar.gz..."
wget -q --show-progress https://deb.devuan.org/devuan/dists/excalibur/main/installer-amd64/current/images/netboot/netboot.tar.gz 2>/dev/null || \
wget -q --show-progress https://mirror.dogado.de/devuan/devuan/dists/excalibur/main/installer-amd64/current/images/netboot/netboot.tar.gz || {
    log_error "Download mislukt: Devuan netboot image"
    exit 1
}

log_info "  Uitpakken..."
tar -xzf netboot.tar.gz -C /srv/tftp/
rm -f netboot.tar.gz

# ============================================
# STATISCH IP VOOR LAN INTERFACE
# ============================================

log_info "Statisch IP configureren voor ${LAN_IF}..."

INTERFACES_DIR="/etc/network/interfaces.d"
mkdir -p $INTERFACES_DIR

backup_file "${INTERFACES_DIR}/${LAN_IF}"

cat > "${INTERFACES_DIR}/${LAN_IF}" << EOF
auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}
    netmask 255.255.255.0
EOF

# ============================================
# IP FORWARDING EN NAT (met -w voor race condition)
# ============================================

log_info "IP forwarding en NAT inschakelen..."

# Schakel IP forwarding in
echo 1 > /proc/sys/net/ipv4/ip_forward

# Maak persistent
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# NAT iptables regel (met -w)
iptables -w -t nat -C POSTROUTING -o $WAN_IF -j MASQUERADE 2>/dev/null || {
    iptables -w -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
    log_info "NAT regel toegevoegd"
}

# Maak iptables persistent
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-save > /etc/iptables/rules.v4
elif command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
fi

# ============================================
# DNSMASQ CONFIGURATIE (met lokale DNS forwarding)
# ============================================

log_info "Dnsmasq configureren..."
backup_file /etc/dnsmasq.conf

cat > /etc/dnsmasq.conf << EOF
interface=${LAN_IF}
bind-interfaces
dhcp-range=${DHCP_START},${DHCP_END},12h
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}

# DNS forwarding naar externe servers
server=9.9.9.9
server=1.1.1.1

enable-tftp
tftp-root=/srv/tftp

# PXE boot
dhcp-match=set:bios,60,PXEClient:Arch:00000
dhcp-boot=tag:bios,netboot.xyz.kpxe

dhcp-match=set:efi64,60,PXEClient:Arch:00007
dhcp-boot=tag:efi64,netboot.xyz.efi

dhcp-boot=netboot.xyz.kpxe

log-dhcp
EOF

# ============================================
# TFTPD-HPA CONFIGURATIE
# ============================================

log_info "Tftpd-hpa configureren..."
backup_file /etc/default/tftpd-hpa

cat > /etc/default/tftpd-hpa << EOF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
EOF

# ============================================
# NFS CONFIGURATIE
# ============================================

log_info "NFS configureren..."
backup_file /etc/exports

cat > /etc/exports << EOF
/srv/nfs ${LAN_NETWORK}/${LAN_MASK}(rw,sync,no_subtree_check,no_root_squash)
/srv/tftp ${LAN_NETWORK}/${LAN_MASK}(ro,sync,no_subtree_check)
EOF

# ============================================
# NGINX CONFIGURATIE
# ============================================

log_info "Nginx configureren..."
cat > /etc/nginx/sites-available/netboot << EOF
server {
    listen 80;
    server_name _;
    root /var/www/netboot;
    autoindex on;
    location /tftp { alias /srv/tftp; autoindex on; }
    location /nfs { alias /srv/nfs; autoindex on; }
}
EOF

ln -sf /etc/nginx/sites-available/netboot /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# ============================================
# STATUS WEBPAGINA
# ============================================

cat > /var/www/netboot/index.html << EOF
<!DOCTYPE html>
<html>
<head><title>Netboot Server - Devuan</title></head>
<body>
<h1>Netboot Server - Devuan ($INIT_SYS)</h1>
<p>Netboot netwerk: ${LAN_NETWORK}/${LAN_MASK}</p>
<p>DHCP range: ${DHCP_START} - ${DHCP_END}</p>
<p>DNS server: ${LAN_IP} (forwarding naar 9.9.9.9, 1.1.1.1)</p>
<p>NAT: Actief (internet via ${WAN_IF})</p>
<ul>
    <li><a href="/tftp/">TFTP Bestanden</a></li>
    <li><a href="/nfs/">NFS Shares</a></li>
</ul>
</body>
</html>
EOF

# ============================================
# SERVICES STARTEN
# ============================================

log_info "Services inschakelen en starten..."

for service in dnsmasq tftpd-hpa nfs-kernel-server nginx; do
    service_enable $service 2>/dev/null || true
    service_control restart $service
done

# Herstart networking voor de LAN interface (geen ifconfig)
log_info "LAN interface configureren..."
ip addr add $LAN_IP/24 dev $LAN_IF 2>/dev/null || true
ip link set $LAN_IF up

# ============================================
# SERVICE STATUS CHECK (met pipefail veilig)
# ============================================

echo ""
log_info "Service status:"
for svc in dnsmasq tftpd-hpa nfs-kernel-server nginx; do
    set +e
    STATUS=$(service_control status $svc 2>/dev/null)
    set -e
    if echo "$STATUS" | grep -q "running\|active"; then
        echo "  ✓ $svc"
    else
        echo "  ✗ $svc"
    fi
done

# Check NAT
echo ""
if iptables -w -t nat -C POSTROUTING -o $WAN_IF -j MASQUERADE 2>/dev/null; then
    echo "  ✓ NAT actief op $WAN_IF"
else
    echo "  ✗ NAT niet actief"
fi

# ============================================
# DHCP WAARSCHUWING (opnieuw checken)
# ============================================

echo ""
if ss -lupn 2>/dev/null | grep -q ":67 "; then
    log_warn "⚠️ DHCP server is actief op poort 67"
    log_warn "   Dit is WAARSCHIJNLIJK jouw eigen dnsmasq (goed)"
    log_warn "   Maar check of er geen andere DHCP loopt!"
fi

# ============================================
# EINDBERICHT
# ============================================

echo ""
echo "=========================================="
log_info "INSTALLATIE VOLTOOID"
echo "=========================================="
echo "Init systeem:   $INIT_SYS"
echo "WAN:            ${WAN_IF} -> router (192.168.178.1)"
echo "LAN:            ${LAN_IF} -> switch -> PXE-clients"
echo "Server IP:      ${LAN_IP}"
echo "DNS:            ${LAN_IP} (forwarding naar 9.9.9.9, 1.1.1.1)"
echo "NAT:            Actief (clients hebben internet)"
echo "Web interface:  http://${LAN_IP}"
echo "Log bestand:    $LOGFILE"
echo ""
echo "⚠️  KRITISCHE WAARSCHUWING:"
echo "   ╔══════════════════════════════════════════════════════╗"
echo "   ║  De switch met PXE-clients mag NIET verbonden zijn  ║"
echo "   ║  met jouw bestaande router!                         ║"
echo "   ║                                                      ║"
echo "   ║  JUIST:   server[LAN] --- switch --- PXE-clients    ║"
echo "   ║  FOUT:    server[LAN] --- switch --- router         ║"
echo "   ╚══════════════════════════════════════════════════════╝"
echo ""
echo "📋 Testen:"
echo "   1. Sluit een client aan op de LAN switch"
echo "   2. Zet PXE boot aan in BIOS/UEFI"
echo "   3. Client krijgt IP 10.0.0.x"
echo "   4. Netboot.xyz menu verschijnt"
echo ""
echo "🐛 Debug bij problemen:"
echo "   sudo tail -f $LOGFILE"
echo "   sudo tail -f /var/log/daemon.log | grep dnsmasq"
echo "   ip -brief addr"
echo "=========================================="

echo ""
log_info "Einde installatie. Tijd: $(date)"