#!/bin/bash
# ============================================
# Debian 13 Deployment Server - VERBETERD
# Alle fixes: gateway, logging, error handling, UEFI, encrypted passwords
# ============================================

set -e
trap 'log_error "Script gefaald op regel $LINENO"; exit 1' ERR

# ============================================
# LOGGING
# ============================================

LOG_FILE="/var/log/deploy-server.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Kleuren
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# ============================================
# CLEANUP
# ============================================

cleanup() {
    log_info "Cleanup..."
    apt clean 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true
    rm -f /tmp/netboot.tar.gz 2>/dev/null || true
    rm -f /tmp/debian-*.iso 2>/dev/null || true
    log_success "Cleanup voltooid"
}

trap cleanup EXIT

# ============================================
# VARIABELEN
# ============================================

# Netwerk
SERVER_IP="10.0.0.1"
SERVER_NETMASK="255.255.255.0"
SERVER_GATEWAY="10.0.0.254"  # Verbeterd: niet zichzelf
DHCP_START="10.0.0.100"
DHCP_END="10.0.0.200"
DOMAIN="lan"

# Debian 13
DEBIAN_VERSION="trixie"
DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/"

# Wachtwoorden (worden gehashed)
XFCE_PASS="xfce123"
GNOME_PASS="gnome123"
KDE_PASS="kde123"
ADMIN_PASS="admin123"

# ============================================
# FUNCTIES
# ============================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dit script moet als root worden uitgevoerd!"
        exit 1
    fi
}

check_internet() {
    log_info "Controleer internet verbinding..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_error "Geen internet verbinding!"
        exit 1
    fi
    log_success "Internet OK"
}

detect_interface() {
    log_info "Netwerk interface detecteren..."
    
    # Zoek interface met default route
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    
    # Of zoek interface met IP
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip -o addr show | grep -v lo | grep -v virbr | grep -v docker | grep "inet " | head -1 | awk '{print $2}')
    fi
    
    # Of zoek UP interface
    if [ -z "$INTERFACE" ]; then
        INTERFACE=$(ip link show | grep -v lo | grep "state UP" | head -1 | cut -d: -f2 | xargs)
    fi
    
    # Fallback
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
        log_warning "Geen interface gevonden, gebruik eth0"
    fi
    
    log_info "Interface: $INTERFACE"
    export INTERFACE
}

setup_ip_forwarding() {
    log_info "IP forwarding inschakelen..."
    
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    sysctl -p
    
    log_success "IP forwarding ingeschakeld"
}

setup_dns() {
    log_info "DNS configureren..."
    
    cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
search $DOMAIN
EOF
    
    log_success "DNS geconfigureerd"
}

install_packages() {
    log_info "Packages installeren..."
    
    apt update
    apt install -y \
        dnsmasq \
        nfs-kernel-server \
        syslinux \
        syslinux-efi \
        wget \
        curl \
        rsync \
        xorriso \
        rsyslog \
        isc-dhcp-server \
        tftpd-hpa \
        memtest86+ \
        whois \
        net-tools \
        iproute2
    
    log_success "Packages geïnstalleerd"
}

setup_static_ip() {
    log_info "Statisch IP configureren..."
    
    # Backup
    cp /etc/network/interfaces /etc/network/interfaces.backup
    
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $SERVER_IP
    netmask $SERVER_NETMASK
    gateway $SERVER_GATEWAY
EOF
    
    # Hostname
    echo "deploymentserver" > /etc/hostname
    hostname deploymentserver
    
    cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       deploymentserver.$DOMAIN deploymentserver
$SERVER_IP      deploymentserver.$DOMAIN deploymentserver
EOF
    
    log_success "Statisch IP: $SERVER_IP"
}

setup_tftp() {
    log_info "TFTP & PXE setup..."
    
    # Directories
    mkdir -p /srv/tftp/{bios,efi64,preseed,scripts,pxelinux.cfg,debian-installer/amd64}
    
    # Netboot downloaden
    cd /tmp
    if [ ! -f "netboot.tar.gz" ]; then
        wget -O netboot.tar.gz "http://deb.debian.org/debian/dists/${DEBIAN_VERSION}/main/installer-amd64/current/images/netboot/netboot.tar.gz"
    fi
    tar -xvf netboot.tar.gz -C /srv/tftp
    
    # BIOS bootloader
    if [ -f /usr/lib/syslinux/modules/bios/ldlinux.c32 ]; then
        cp /usr/lib/syslinux/modules/bios/*.c32 /srv/tftp/bios/ 2>/dev/null || true
    fi
    if [ -f /usr/lib/PXELINUX/pxelinux.0 ]; then
        cp /usr/lib/PXELINUX/pxelinux.0 /srv/tftp/bios/ 2>/dev/null || true
    fi
    
    # UEFI bootloader
    if [ -d /usr/lib/syslinux/modules/efi64 ]; then
        cp /usr/lib/syslinux/modules/efi64/*.c32 /srv/tftp/efi64/ 2>/dev/null || true
    fi
    if [ -f /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi ]; then
        cp /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi /srv/tftp/efi64/ 2>/dev/null || true
    else
        log_warning "UEFI bootloader niet gevonden, probeer alternatief..."
        if [ -f /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi ]; then
            cp /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi /srv/tftp/efi64/
        fi
    fi
    
    # Symlinks
    ln -sf /srv/tftp/pxelinux.cfg /srv/tftp/bios/pxelinux.cfg 2>/dev/null || true
    ln -sf /srv/tftp/pxelinux.cfg /srv/tftp/efi64/pxelinux.cfg 2>/dev/null || true
    
    # Memtest
    if [ -f /usr/lib/memtest86+/memtest86+.bin ]; then
        cp /usr/lib/memtest86+/memtest86+.bin /srv/tftp/ 2>/dev/null || true
    fi
    
    log_success "TFTP & PXE setup voltooid"
}

configure_dnsmasq() {
    log_info "Dnsmasq configureren..."
    
    cat > /etc/dnsmasq.conf << EOF
# ============================================
# DNSMASQ - Debian 13 Deployment Server (VERBETERD)
# BIOS + UEFI + IPv6
# ============================================

# Interface
interface=$INTERFACE
bind-interfaces

# DHCP (IPv4)
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,12h
dhcp-option=3,$SERVER_IP
dhcp-option=6,$SERVER_IP
dhcp-option=15,$DOMAIN

# DHCP (IPv6) - Optioneel
dhcp-range=fc00::100,fc00::200,64,12h
dhcp-option=option6:dns-server,fc00::1
enable-ra

# Domein
domain=$DOMAIN
expand-hosts

# BIOS PXE
dhcp-boot=bios/pxelinux.0

# UEFI PXE
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:efi-x86_64,efi64/syslinux.efi

# TFTP
enable-tftp
tftp-root=/srv/tftp

# DNS (vooruitsturend)
resolv-file=/etc/resolv.conf
domain-needed
bogus-priv

# Logging
log-facility=/var/log/dnsmasq.log
log-dhcp
log-queries

# Extra boot opties
dhcp-option-force=208,f1:00:74:7e
dhcp-option-force=210,$SERVER_IP/
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    # Check status
    if systemctl is-active --quiet dnsmasq; then
        log_success "Dnsmasq actief"
    else
        log_error "Dnsmasq start niet!"
        systemctl status dnsmasq --no-pager
        exit 1
    fi
}

setup_nfs_repo() {
    log_info "NFS repository opzetten..."
    
    mkdir -p /srv/debian-repo
    
    # Download Debian 13 DVD (dynamisch)
    cd /tmp
    DEBIAN_ISO=$(curl -s $DEBIAN_ISO_URL | grep -o 'debian-13.*-amd64-DVD-1.iso' | head -1)
    
    if [ -z "$DEBIAN_ISO" ]; then
        log_warning "Geen Debian 13 DVD gevonden, gebruik vaste versie..."
        DEBIAN_ISO="debian-13.5.0-amd64-DVD-1.iso"
    fi
    
    if [ ! -f "$DEBIAN_ISO" ]; then
        log_info "Downloaden: $DEBIAN_ISO (kan even duren)..."
        wget -O "$DEBIAN_ISO" "${DEBIAN_ISO_URL}${DEBIAN_ISO}" || {
            log_warning "Download mislukt, probeer fallback..."
            wget -O "$DEBIAN_ISO" "https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/$DEBIAN_ISO"
        }
    fi
    
    # Mount ISO
    if mount | grep -q "/srv/debian-repo"; then
        umount /srv/debian-repo 2>/dev/null || true
    fi
    
    mount -o loop "/tmp/$DEBIAN_ISO" /srv/debian-repo || {
        log_error "Mounten mislukt!"
        exit 1
    }
    
    # NFS exporteren
    if ! grep -q "/srv/debian-repo" /etc/exports; then
        echo "/srv/debian-repo 10.0.0.0/24(ro,sync,no_subtree_check)" >> /etc/exports
    fi
    exportfs -a
    
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    
    # Check status
    if systemctl is-active --quiet nfs-kernel-server; then
        log_success "NFS actief"
    else
        log_error "NFS start niet!"
        exit 1
    fi
}

create_pxe_menu() {
    log_info "PXE menu aanmaken..."
    
    cat > /srv/tftp/pxelinux.cfg/default << 'EOF'
UI menu.c32
MENU TITLE Debian 13 Deployment Server - Kies een optie

TIMEOUT 300
ONTIMEOUT xfce

LABEL xfce
  MENU LABEL ^1) Debian 13 XFCE (Lichtgewicht)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/xfce.cfg log_host=10.0.0.1 DEBCONF_DEBUG=5 ---

LABEL gnome
  MENU LABEL ^2) Debian 13 GNOME (Volledig)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/gnome.cfg log_host=10.0.0.1 DEBCONF_DEBUG=5 ---

LABEL kde
  MENU LABEL ^3) Debian 13 KDE Plasma
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/kde.cfg log_host=10.0.0.1 DEBCONF_DEBUG=5 ---

LABEL server
  MENU LABEL ^4) Debian 13 Server (Geen GUI)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/server.cfg log_host=10.0.0.1 DEBCONF_DEBUG=5 ---

LABEL manual
  MENU LABEL ^5) Handmatige installatie
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz log_host=10.0.0.1 ---

LABEL memtest
  MENU LABEL ^6) Geheugentest (Memtest86+)
  KERNEL memtest86+.bin

LABEL local
  MENU LABEL ^7) Boot vanaf lokale schijf
  LOCALBOOT 0

LABEL reboot
  MENU LABEL ^8) Reboot systeem
  COM32 reboot.c32
EOF

    log_success "PXE menu aangemaakt"
}

generate_password_hash() {
    local password=$1
    if command -v mkpasswd &> /dev/null; then
        mkpasswd -m sha-512 "$password" 2>/dev/null || echo "$password"
    else
        echo "$password"
    fi
}

create_preseed_files() {
    log_info "Preseed bestanden aanmaken (met encrypted wachtwoorden)..."
    
    # Genereer hashes
    XFCE_HASH=$(generate_password_hash "$XFCE_PASS")
    GNOME_HASH=$(generate_password_hash "$GNOME_PASS")
    KDE_HASH=$(generate_password_hash "$KDE_PASS")
    ADMIN_HASH=$(generate_password_hash "$ADMIN_PASS")
    
    # XFCE preseed
    cat > /srv/tftp/preseed/xfce.cfg << EOF
# ============================================
# Debian 13 XFCE - Automatische installatie
# ============================================

# Locale
d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-xfce
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60

# Tijd
d-i time/zone string Europe/Amsterdam
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean false

# Partitionering
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/disk string /dev/sda
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Gebruiker (encrypted wachtwoord)
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string XFCE Gebruiker
d-i passwd/username string xfce
d-i passwd/user-password-crypted password $XFCE_HASH

# Software
tasksel tasksel/first multiselect standard, xfce-desktop

# APT offline
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true

# Grub
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

# Late command: NFS mount + post-install script
d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog wget ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "$SERVER_IP:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo || true ; \
    in-target echo "deb file:/mnt/debian-repo $DEBIAN_VERSION main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target wget -O /tmp/post-install.sh tftp://$SERVER_IP/scripts/post-install.sh ; \
    in-target chmod +x /tmp/post-install.sh ; \
    in-target bash /tmp/post-install.sh

# Reboot
d-i finish-install/reboot_in_progress note
EOF

    # GNOME preseed
    cat > /srv/tftp/preseed/gnome.cfg << EOF
# ============================================
# Debian 13 GNOME - Automatische installatie
# ============================================

d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-gnome
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60

d-i time/zone string Europe/Amsterdam
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean false

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/disk string /dev/sda
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string GNOME Gebruiker
d-i passwd/username string gnome
d-i passwd/user-password-crypted password $GNOME_HASH

tasksel tasksel/first multiselect standard, gnome-desktop

d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog wget ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "$SERVER_IP:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo || true ; \
    in-target echo "deb file:/mnt/debian-repo $DEBIAN_VERSION main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target wget -O /tmp/post-install.sh tftp://$SERVER_IP/scripts/post-install.sh ; \
    in-target chmod +x /tmp/post-install.sh ; \
    in-target bash /tmp/post-install.sh

d-i finish-install/reboot_in_progress note
EOF

    # KDE preseed
    cat > /srv/tftp/preseed/kde.cfg << EOF
# ============================================
# Debian 13 KDE Plasma - Automatische installatie
# ============================================

d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-kde
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60

d-i time/zone string Europe/Amsterdam
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean false

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/disk string /dev/sda
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string KDE Gebruiker
d-i passwd/username string kde
d-i passwd/user-password-crypted password $KDE_HASH

tasksel tasksel/first multiselect standard, kde-desktop

d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog wget ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "$SERVER_IP:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo || true ; \
    in-target echo "deb file:/mnt/debian-repo $DEBIAN_VERSION main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target wget -O /tmp/post-install.sh tftp://$SERVER_IP/scripts/post-install.sh ; \
    in-target chmod +x /tmp/post-install.sh ; \
    in-target bash /tmp/post-install.sh

d-i finish-install/reboot_in_progress note
EOF

    # Server preseed
    cat > /srv/tftp/preseed/server.cfg << EOF
# ============================================
# Debian 13 Server - Minimale installatie
# ============================================

d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-server
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60

d-i time/zone string Europe/Amsterdam
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean false

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/disk string /dev/sda
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i passwd/root-login boolean true
d-i passwd/make-user boolean true
d-i passwd/user-fullname string Server Admin
d-i passwd/username string admin
d-i passwd/user-password-crypted password $ADMIN_HASH

tasksel tasksel/first multiselect standard

d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog wget htop net-tools git curl vim ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "$SERVER_IP:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo || true ; \
    in-target echo "deb file:/mnt/debian-repo $DEBIAN_VERSION main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target wget -O /tmp/post-install.sh tftp://$SERVER_IP/scripts/post-install.sh ; \
    in-target chmod +x /tmp/post-install.sh ; \
    in-target bash /tmp/post-install.sh ; \
    in-target systemctl enable ssh ; \
    in-target systemctl start ssh

d-i finish-install/reboot_in_progress note
EOF

    log_success "Preseed bestanden aangemaakt (met encrypted wachtwoorden)"
}

create_client_script() {
    log_info "Client post-installatie script aanmaken..."
    
    mkdir -p /srv/tftp/scripts
    
    cat > /srv/tftp/scripts/post-install.sh << 'EOF'
#!/bin/bash
# ============================================
# Debian 13 Client Post-Installatie Script
# ULTRA-LICHTGEWICHT - 64-bit 2006-2026
# ============================================

set -e

# Kleuren
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/deployment.log"
HOSTNAME="debian-client"
DOMAIN="lan"
SERVER_IP="10.0.0.1"
TIMEZONE="Europe/Amsterdam"
KEYBOARD="us"
LOCALE="nl_NL.UTF-8"

exec > >(tee -a "$LOG_FILE") 2>&1

log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dit script moet als root worden uitgevoerd!"
        exit 1
    fi
}

detect_hardware() {
    log_info "Hardware detectie..."
    
    CPU_MODEL=$(lscpu | grep "Model name" | head -1 | cut -d: -f2 | xargs)
    CPU_CORES=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    log_info "CPU: $CPU_MODEL ($CPU_CORES cores)"
    
    RAM_TOTAL_MB=$(free -m | grep Mem | awk '{print $2}')
    RAM_TOTAL_GB=$(echo "scale=1; $RAM_TOTAL_MB/1024" | bc)
    log_info "RAM: ${RAM_TOTAL_GB}GB"
    
    if [[ $RAM_TOTAL_MB -lt 2048 ]]; then
        LOW_RAM=true
        ZRAM_PERCENT=50
    elif [[ $RAM_TOTAL_MB -lt 4096 ]]; then
        LOW_RAM=false
        ZRAM_PERCENT=40
    else
        LOW_RAM=false
        ZRAM_PERCENT=30
    fi
    
    if lsblk -d -o name,rota 2>/dev/null | grep -v "loop" | grep -q "0$"; then
        IS_SSD=true
        log_info "SSD gedetecteerd"
    else
        IS_SSD=false
        log_info "HDD gedetecteerd"
    fi
    
    if [[ -d /proc/acpi/battery ]] || ls /sys/class/power_supply/BAT* 2>/dev/null | grep -q .; then
        IS_LAPTOP=true
        log_info "Laptop gedetecteerd"
    else
        IS_LAPTOP=false
    fi
    
    GPU_INFO=$(lspci | grep -E "VGA|3D|Display" | head -1)
    log_info "GPU: $GPU_INFO"
}

set_hostname() {
    log_info "Hostname instellen..."
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME"
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "127.0.1.1 $HOSTNAME.$DOMAIN $HOSTNAME" >> /etc/hosts
    fi
}

set_locale() {
    log_info "Locale instellen..."
    sed -i "s/^# *$LOCALE/$LOCALE/" /etc/locale.gen
    locale-gen
    update-locale LANG=$LOCALE
    cat > /etc/default/keyboard << EOF
XKBMODEL="pc105"
XKBLAYOUT="$KEYBOARD"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    timedatectl set-timezone $TIMEZONE
    timedatectl set-ntp true
}

setup_repositories() {
    log_info "Repositories configureren..."
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
    apt update
}

install_firmware() {
    log_info "Firmware installeren..."
    apt install -y \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        firmware-iwlwifi \
        firmware-atheros \
        firmware-b43-installer \
        firmware-realtek \
        firmware-zd1211 \
        firmware-ralink \
        firmware-brcm80211 \
        firmware-ti-connectivity \
        bluez-firmware
    
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        apt install -y intel-microcode
    elif grep -q "AMD" /proc/cpuinfo; then
        apt install -y amd64-microcode
    fi
}

install_gpu() {
    log_info "GPU drivers installeren..."
    apt install -y pciutils usbutils mesa-utils mesa-vulkan-drivers
    
    if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
        if echo "$GPU_INFO" | grep -qi "GeForce 8\|GeForce 9\|GeForce 2\|GeForce 3\|GeForce 4\|GeForce 5\|GeForce 6\|GeForce 7"; then
            apt install -y nvidia-legacy-340xx-driver nvidia-legacy-340xx-settings 2>/dev/null || \
            apt install -y nvidia-legacy-390xx-driver nvidia-legacy-390xx-settings 2>/dev/null || \
            apt install -y nvidia-driver nvidia-settings
        else
            apt install -y nvidia-driver nvidia-settings nvidia-utils nvidia-kernel-dkms
        fi
    elif echo "$GPU_INFO" | grep -qi "AMD\|ATI"; then
        if echo "$GPU_INFO" | grep -qi "HD 2\|HD 3\|HD 4\|Radeon X"; then
            apt install -y firmware-amd-graphics xserver-xorg-video-radeon
        else
            apt install -y firmware-amd-graphics xserver-xorg-video-amdgpu
        fi
    else
        apt install -y firmware-intel-graphics intel-media-va-driver xserver-xorg-video-intel
    fi
}

install_desktop() {
    log_info "Desktop installeren..."
    if [[ "$LOW_RAM" == true ]]; then
        apt install -y xfce4 xfce4-terminal thunar lightdm lightdm-gtk-greeter xorg xinit
    else
        apt install -y xfce4 xfce4-goodies lightdm lightdm-gtk-greeter papirus-icon-theme arc-theme
    fi
    systemctl enable lightdm
    systemctl set-default graphical.target
}

install_apps() {
    log_info "Apps installeren..."
    if [[ "$LOW_RAM" == true ]]; then
        apt install -y firefox-esr vlc gimp libreoffice keepassxc
    else
        apt install -y firefox-esr thunderbird vlc mpv gimp libreoffice libreoffice-l10n-nl keepassxc filezilla synaptic gparted
    fi
}

install_communication() {
    log_info "Communicatie tools installeren..."
    apt install -y remmina remmina-plugin-rdp remmina-plugin-vnc openssh-client openssh-server samba-client cifs-utils nfs-common cups cups-client cups-filters system-config-printer printer-driver-all
    systemctl enable cups
    systemctl start cups
    systemctl enable ssh
    systemctl start ssh
}

install_audio() {
    log_info "Audio installeren..."
    apt install -y alsa-utils pulseaudio pulseaudio-utils firmware-intel-sound firmware-sof-signed sof-firmware v4l-utils firmware-uvc guvcview gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad gstreamer1.0-libav ffmpeg
}

install_filesystems() {
    log_info "Filesystems installeren..."
    apt install -y ntfs-3g exfatprogs exfat-fuse fuse fuse3 dosfstools e2fsprogs
}

optimize_system() {
    log_info "Systeem optimaliseren..."
    apt install -y zram-tools
    echo "PERCENT=$ZRAM_PERCENT" > /etc/default/zramswap
    systemctl restart zramswap
    systemctl enable zramswap
    
    if [[ "$LOW_RAM" == true ]]; then
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    cat > /etc/sysctl.d/99-optimize.conf << EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
kernel.dmesg_restrict=1
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.inotify.max_user_watches=524288
fs.file-max=2097152
EOF
    
    sysctl -p /etc/sysctl.d/99-optimize.conf
    
    if [[ "$IS_SSD" == true ]]; then
        systemctl enable fstrim.timer
        systemctl start fstrim.timer
    fi
    
    if [[ -n "$SUDO_USER" ]]; then
        for group in sudo audio video dialout plugdev netdev input; do
            usermod -aG "$group" "$SUDO_USER" 2>/dev/null || true
        done
    fi
}

configure_security() {
    log_info "Beveiliging configureren..."
    apt install -y ufw unattended-upgrades fail2ban
    echo "y" | ufw enable
    ufw allow ssh
    ufw allow from $SERVER_IP to any
    
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades
    systemctl enable fail2ban
    systemctl start fail2ban
}

configure_power() {
    if [[ "$IS_LAPTOP" == true ]]; then
        log_info "Power management configureren..."
        apt install -y tlp tlp-rdw acpi acpid
        systemctl enable tlp
        systemctl start tlp
        systemctl enable acpid
        systemctl start acpid
    fi
}

configure_remote_logging() {
    log_info "Remote logging configureren..."
    echo "*.* @@$SERVER_IP:514" >> /etc/rsyslog.conf
    systemctl restart rsyslog
}

final_cleanup() {
    apt clean
    apt autoremove -y
    journalctl --vacuum-size=50M
}

main() {
    echo ""
    echo "========================================="
    echo "  Debian 13 Client Post-Installatie"
    echo "  ULTRA-LICHTGEWICHT - 64-bit 2006-2026"
    echo "========================================="
    echo ""
    
    check_root
    detect_hardware
    set_hostname
    set_locale
    setup_repositories
    install_firmware
    install_gpu
    install_desktop
    install_apps
    install_communication
    install_audio
    install_filesystems
    optimize_system
    configure_security
    configure_power
    configure_remote_logging
    final_cleanup
    
    echo ""
    echo "========================================="
    echo -e "${GREEN}  DEPLOYMENT COMPLEET!${NC}"
    echo "========================================="
    echo ""
    echo -e "${BLUE}Systeem:${NC}"
    echo "  - Hostname: $HOSTNAME.$DOMAIN"
    echo "  - OS: $(lsb_release -ds)"
    echo "  - Kernel: $(uname -r)"
    echo ""
    echo -e "${BLUE}Hardware:${NC}"
    echo "  - CPU: $CPU_MODEL"
    echo "  - RAM: ${RAM_TOTAL_GB}GB"
    echo "  - GPU: $GPU_INFO"
    echo "  - SSD: $IS_SSD"
    echo "  - Laptop: $IS_LAPTOP"
    echo ""
    echo -e "${YELLOW}Herstart aanbevolen:${NC} sudo reboot"
    echo "========================================="
}

main "$@"
EOF

    chmod +x /srv/tftp/scripts/post-install.sh
    
    log_success "Client post-installatie script aangemaakt"
}

configure_rsyslog() {
    log_info "RSyslog configureren..."
    
    # UDP module aanzetten
    if ! grep -q "module(load=\"imudp\")" /etc/rsyslog.conf; then
        sed -i 's/#module(load="imudp")/module(load="imudp")/' /etc/rsyslog.conf
    fi
    if ! grep -q "input(type=\"imudp\" port=\"514\")" /etc/rsyslog.conf; then
        sed -i 's/#input(type="imudp" port="514")/input(type="imudp" port="514")/' /etc/rsyslog.conf
    fi
    
    cat > /etc/rsyslog.d/20-client-logs.conf << 'EOF'
if $fromhost-ip != '127.0.0.1' then /var/log/client-logs.log
& stop
EOF
    
    touch /var/log/client-logs.log
    chown syslog:adm /var/log/client-logs.log
    systemctl restart rsyslog
    
    log_success "RSyslog geconfigureerd"
}

verify_services() {
    log_info "Services verifiëren..."
    
    local failed=false
    
    for service in dnsmasq nfs-kernel-server rsyslog; do
        if systemctl is-active --quiet "$service"; then
            log_success "$service: actief"
        else
            log_error "$service: NIET actief!"
            failed=true
        fi
    done
    
    if [ "$failed" = true ]; then
        log_error "Sommige services zijn niet actief!"
        return 1
    fi
    
    log_success "Alle services actief"
}

show_summary() {
    echo ""
    echo "========================================="
    echo -e "${GREEN}  DEPLOYMENT SERVER VOLTOOID!${NC}"
    echo "========================================="
    echo ""
    echo -e "${BLUE}Server:${NC}"
    echo "  - IP: $SERVER_IP"
    echo "  - Domain: $DOMAIN"
    echo "  - Interface: $INTERFACE"
    echo ""
    echo -e "${BLUE}Directories:${NC}"
    echo "  - TFTP Root: /srv/tftp"
    echo "  - NFS Repo: /srv/debian-repo"
    echo ""
    echo -e "${BLUE}Wachtwoorden (gehashed):${NC}"
    echo "  - XFCE:  $XFCE_PASS"
    echo "  - GNOME: $GNOME_PASS"
    echo "  - KDE:   $KDE_PASS"
    echo "  - Admin: $ADMIN_PASS"
    echo ""
    echo -e "${BLUE}Logbestanden:${NC}"
    echo "  - Dnsmasq: /var/log/dnsmasq.log"
    echo "  - Client: /var/log/client-logs.log"
    echo "  - Setup: $LOG_FILE"
    echo ""
    echo -e "${YELLOW}Volgende stap:${NC}"
    echo "1. Herstart de server: sudo reboot"
    echo "2. Sluit een client aan op de switch"
    echo "3. Zet client op PXE boot (Network boot)"
    echo "4. Kies een optie uit het menu!"
    echo ""
    echo -e "${YELLOW}Handige commando's:${NC}"
    echo "  - Logs:     sudo tail -f /var/log/dnsmasq.log"
    echo "  - Client:   sudo tail -f /var/log/client-logs.log"
    echo "  - NFS:      showmount -e $SERVER_IP"
    echo "  - TFTP:     tftp $SERVER_IP -c get pxelinux.0"
    echo "========================================="
}

# ============================================
# HOOFDPROGRAMMA
# ============================================

main() {
    echo ""
    echo "========================================="
    echo "  Debian 13 Deployment Server Setup"
    echo "  VERBETERD - Alle fixes toegepast"
    echo "========================================="
    echo ""
    
    check_root
    check_internet
    
    read -p "Doorgaan? (j/N): " confirm
    if [[ ! "$confirm" =~ ^[Jj] ]]; then
        log_warning "Installatie geannuleerd."
        exit 0
    fi
    
    detect_interface
    setup_ip_forwarding
    setup_dns
    install_packages
    setup_static_ip
    setup_tftp
    configure_dnsmasq
    setup_nfs_repo
    create_pxe_menu
    create_preseed_files
    create_client_script
    configure_rsyslog
    verify_services
    
    show_summary
    
    log_success "Deployment Server voltooid!"
}

main "$@"