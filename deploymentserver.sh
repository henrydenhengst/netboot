#!/bin/bash
# ============================================
# Debian 13 Deployment Server Setup Script
# PXE + DHCP + TFTP + NFS + Preseed + Scripts
# ============================================

set -e

# Kleuren
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

# ============================================
# 1. BASIS INSTALLATIE
# ============================================

install_server_packages() {
    log_info "Server packages installeren..."
    
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
        wget
    
    log_success "Packages geïnstalleerd"
}

set_static_ip() {
    log_info "Statisch IP configureren..."
    
    # Interface naam detecteren
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address 10.0.0.1
    netmask 255.255.255.0
    gateway 10.0.0.1
EOF
    
    # Hostname
    echo "deploymentserver" > /etc/hostname
    hostname deploymentserver
    
    cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       deploymentserver.lan deploymentserver
10.0.0.1        deploymentserver.lan deploymentserver
EOF
    
    log_success "Statisch IP: 10.0.0.1"
}

# ============================================
# 2. TFTP & PXE SETUP
# ============================================

setup_tftp() {
    log_info "TFTP & PXE setup..."
    
    # Directories
    mkdir -p /srv/tftp/{bios,efi64,preseed,scripts,pxelinux.cfg,debian-installer/amd64}
    
    # Netboot downloaden (Debian 13 Trixie)
    cd /tmp
    wget -O netboot.tar.gz http://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz
    tar -xvf netboot.tar.gz -C /srv/tftp
    
    # BIOS bootloader
    cp /usr/lib/syslinux/modules/bios/*.c32 /srv/tftp/bios/
    cp /usr/lib/PXELINUX/pxelinux.0 /srv/tftp/bios/
    
    # UEFI bootloader
    cp /usr/lib/syslinux/modules/efi64/*.c32 /srv/tftp/efi64/
    cp /usr/lib/SYSLINUX.EFI/efi64/syslinux.efi /srv/tftp/efi64/
    
    # Symlinks
    ln -sf /srv/tftp/pxelinux.cfg /srv/tftp/bios/pxelinux.cfg
    ln -sf /srv/tftp/pxelinux.cfg /srv/tftp/efi64/pxelinux.cfg
    
    # Memtest
    cp /usr/lib/memtest86+/memtest86+.bin /srv/tftp/ 2>/dev/null || true
    
    log_success "TFTP & PXE setup voltooid"
}

# ============================================
# 3. DNSMASQ CONFIGURATIE
# ============================================

configure_dnsmasq() {
    log_info "Dnsmasq configureren..."
    
    cat > /etc/dnsmasq.conf << 'EOF'
# ============================================
# DNSMASQ - Debian 13 Deployment Server
# BIOS + UEFI ondersteuning
# ============================================

interface=eth0
bind-interfaces

# DHCP
dhcp-range=10.0.0.100,10.0.0.200,255.255.255.0,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
dhcp-option=15,lan

# Domein
domain=lan
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

# DNS (offline)
no-resolv
domain-needed
bogus-priv

# Logging
log-facility=/var/log/dnsmasq.log
log-dhcp
log-queries

# Extra boot opties
dhcp-option-force=208,f1:00:74:7e
dhcp-option-force=210,10.0.0.1/
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    log_success "Dnsmasq geconfigureerd"
}

# ============================================
# 4. NFS REPOSITORY
# ============================================

setup_nfs_repo() {
    log_info "NFS repository opzetten..."
    
    mkdir -p /srv/debian-repo
    
    # Download Debian 13 DVD 1
    cd /tmp
    if [ ! -f "debian-13.5.0-amd64-DVD-1.iso" ]; then
        wget -O debian-13.5.0-amd64-DVD-1.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/debian-13.5.0-amd64-DVD-1.iso
    fi
    
    # Mount ISO
    mount -o loop /tmp/debian-13.5.0-amd64-DVD-1.iso /srv/debian-repo || {
        log_warning "Mounten mislukt, probeer opnieuw..."
        mount -o loop /tmp/debian-13.5.0-amd64-DVD-1.iso /srv/debian-repo
    }
    
    # NFS exporteren
    echo "/srv/debian-repo 10.0.0.0/24(ro,sync,no_subtree_check)" >> /etc/exports
    exportfs -a
    
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server
    
    log_success "NFS repository klaar"
}

# ============================================
# 5. PXE MENU
# ============================================

create_pxe_menu() {
    log_info "PXE menu aanmaken..."
    
    cat > /srv/tftp/pxelinux.cfg/default << 'EOF'
UI menu.c32
MENU TITLE Debian 13 Deployment Server

TIMEOUT 300
ONTIMEOUT xfce

LABEL xfce
  MENU LABEL ^1) Debian 13 XFCE (Lichtgewicht)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/xfce.cfg log_host=10.0.0.1 ---

LABEL gnome
  MENU LABEL ^2) Debian 13 GNOME (Volledig)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/gnome.cfg log_host=10.0.0.1 ---

LABEL kde
  MENU LABEL ^3) Debian 13 KDE Plasma
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/kde.cfg log_host=10.0.0.1 ---

LABEL server
  MENU LABEL ^4) Debian 13 Server (Geen GUI)
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz auto url=tftp://10.0.0.1/preseed/server.cfg log_host=10.0.0.1 ---

LABEL manual
  MENU LABEL ^5) Handmatige installatie
  KERNEL debian-installer/amd64/linux
  APPEND initrd=debian-installer/amd64/initrd.gz log_host=10.0.0.1 ---

LABEL memtest
  MENU LABEL ^6) Geheugentest
  KERNEL memtest86+.bin

LABEL local
  MENU LABEL ^7) Boot vanaf lokale schijf
  LOCALBOOT 0
EOF

    log_success "PXE menu aangemaakt"
}

# ============================================
# 6. PRESEED BESTANDEN
# ============================================

create_preseed_files() {
    log_info "Preseed bestanden aanmaken..."
    
    # XFCE preseed
    cat > /srv/tftp/preseed/xfce.cfg << 'EOF'
# Debian 13 XFCE
d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-xfce
d-i netcfg/get_domain string lan
d-i time/zone string Europe/Amsterdam
d-i clock-setup/ntp boolean false
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string XFCE Gebruiker
d-i passwd/username string xfce
d-i passwd/user-password password xfce123
d-i passwd/user-password-again password xfce123
tasksel tasksel/first multiselect standard, xfce-desktop
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true
d-i grub-installer/only_debian boolean true
d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "10.0.0.1:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo ; \
    in-target echo "deb file:/mnt/debian-repo trixie main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target apt-get install -y firefox-esr vlc gimp libreoffice htop neofetch git curl wget ; \
    in-target hostnamectl set-hostname debian-xfce ; \
    in-target echo "nameserver 10.0.0.1" >> /etc/resolv.conf ; \
    in-target echo "*.* @@10.0.0.1:514" >> /etc/rsyslog.conf ; \
    in-target systemctl restart rsyslog
d-i finish-install/reboot_in_progress note
EOF

    # GNOME preseed
    cat > /srv/tftp/preseed/gnome.cfg << 'EOF'
# Debian 13 GNOME
d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-gnome
d-i netcfg/get_domain string lan
d-i time/zone string Europe/Amsterdam
d-i clock-setup/ntp boolean false
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string GNOME Gebruiker
d-i passwd/username string gnome
d-i passwd/user-password password gnome123
d-i passwd/user-password-again password gnome123
tasksel tasksel/first multiselect standard, gnome-desktop
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true
d-i grub-installer/only_debian boolean true
d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "10.0.0.1:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo ; \
    in-target echo "deb file:/mnt/debian-repo trixie main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target apt-get install -y firefox-esr vlc gimp libreoffice htop neofetch git curl wget gnome-tweaks ; \
    in-target hostnamectl set-hostname debian-gnome ; \
    in-target echo "nameserver 10.0.0.1" >> /etc/resolv.conf ; \
    in-target echo "*.* @@10.0.0.1:514" >> /etc/rsyslog.conf ; \
    in-target systemctl restart rsyslog
d-i finish-install/reboot_in_progress note
EOF

    # KDE preseed
    cat > /srv/tftp/preseed/kde.cfg << 'EOF'
# Debian 13 KDE Plasma
d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-kde
d-i netcfg/get_domain string lan
d-i time/zone string Europe/Amsterdam
d-i clock-setup/ntp boolean false
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string KDE Gebruiker
d-i passwd/username string kde
d-i passwd/user-password password kde123
d-i passwd/user-password-again password kde123
tasksel tasksel/first multiselect standard, kde-desktop
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true
d-i grub-installer/only_debian boolean true
d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "10.0.0.1:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo ; \
    in-target echo "deb file:/mnt/debian-repo trixie main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target apt-get install -y firefox-esr vlc gimp libreoffice htop neofetch git curl wget ; \
    in-target hostnamectl set-hostname debian-kde ; \
    in-target echo "nameserver 10.0.0.1" >> /etc/resolv.conf ; \
    in-target echo "*.* @@10.0.0.1:514" >> /etc/rsyslog.conf ; \
    in-target systemctl restart rsyslog
d-i finish-install/reboot_in_progress note
EOF

    # Server preseed
    cat > /srv/tftp/preseed/server.cfg << 'EOF'
# Debian 13 Server
d-i debian-installer/locale string nl_NL
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian-server
d-i netcfg/get_domain string lan
d-i time/zone string Europe/Amsterdam
d-i clock-setup/ntp boolean false
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i passwd/root-login boolean true
d-i passwd/make-user boolean true
d-i passwd/user-fullname string Server Admin
d-i passwd/username string admin
d-i passwd/user-password password admin123
d-i passwd/user-password-again password admin123
tasksel tasksel/first multiselect standard
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect none
d-i apt-setup/cdrom/set-first boolean true
d-i grub-installer/only_debian boolean true
d-i preseed/late_command string \
    in-target apt-get install -y nfs-common openssh-server rsyslog htop net-tools git curl wget vim ; \
    in-target mkdir -p /mnt/debian-repo ; \
    in-target echo "10.0.0.1:/srv/debian-repo /mnt/debian-repo nfs ro,noauto 0 0" >> /etc/fstab ; \
    in-target mount /mnt/debian-repo ; \
    in-target echo "deb file:/mnt/debian-repo trixie main contrib non-free" > /etc/apt/sources.list ; \
    in-target apt-get update ; \
    in-target hostnamectl set-hostname debian-server ; \
    in-target echo "nameserver 10.0.0.1" >> /etc/resolv.conf ; \
    in-target echo "*.* @@10.0.0.1:514" >> /etc/rsyslog.conf ; \
    in-target systemctl restart rsyslog ; \
    in-target systemctl enable ssh ; \
    in-target systemctl start ssh
d-i finish-install/reboot_in_progress note
EOF

    log_success "Preseed bestanden aangemaakt"
}

# ============================================
# 7. CLIENT POST-INSTALLATIE SCRIPT
# ============================================

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

# Hardware detectie
detect_hardware() {
    log_info "Hardware detectie..."
    
    # CPU
    CPU_MODEL=$(lscpu | grep "Model name" | head -1 | cut -d: -f2 | xargs)
    CPU_CORES=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    log_info "CPU: $CPU_MODEL ($CPU_CORES cores)"
    
    # RAM
    RAM_TOTAL_MB=$(free -m | grep Mem | awk '{print $2}')
    RAM_TOTAL_GB=$(echo "scale=1; $RAM_TOTAL_MB/1024" | bc)
    log_info "RAM: ${RAM_TOTAL_GB}GB"
    
    # RAM aanpassingen
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
    
    # SSD detectie
    if lsblk -d -o name,rota 2>/dev/null | grep -v "loop" | grep -q "0$"; then
        IS_SSD=true
        log_info "SSD gedetecteerd"
    else
        IS_SSD=false
        log_info "HDD gedetecteerd"
    fi
    
    # Laptop detectie
    if [[ -d /proc/acpi/battery ]] || ls /sys/class/power_supply/BAT* 2>/dev/null | grep -q .; then
        IS_LAPTOP=true
        log_info "Laptop gedetecteerd"
    else
        IS_LAPTOP=false
    fi
    
    # GPU detectie
    GPU_INFO=$(lspci | grep -E "VGA|3D|Display" | head -1)
    log_info "GPU: $GPU_INFO"
}

# Hostname
set_hostname() {
    log_info "Hostname instellen..."
    echo "$HOSTNAME" > /etc/hostname
    hostname "$HOSTNAME"
    echo "127.0.1.1 $HOSTNAME.$DOMAIN $HOSTNAME" >> /etc/hosts
}

# Locale
set_locale() {
    log_info "Locale instellen..."
    sed -i "s/^# *$LOCALE/$LOCALE/" /etc/locale.gen
    locale-gen
    update-locale LANG=$LOCALE
    cat > /etc/default/keyboard << EOF
XKBMODEL="pc105"
XKBLAYOUT="us"
EOF
    timedatectl set-timezone $TIMEZONE
}

# Repositories
setup_repositories() {
    log_info "Repositories configureren..."
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
    apt update
}

# Firmware
install_firmware() {
    log_info "Firmware installeren..."
    apt install -y \
        firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
        firmware-iwlwifi firmware-atheros firmware-b43-installer \
        firmware-realtek firmware-zd1211 firmware-ralink firmware-brcm80211 \
        bluez-firmware
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        apt install -y intel-microcode
    elif grep -q "AMD" /proc/cpuinfo; then
        apt install -y amd64-microcode
    fi
}

# GPU drivers
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

# Desktop
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

# Apps
install_apps() {
    log_info "Apps installeren..."
    if [[ "$LOW_RAM" == true ]]; then
        apt install -y firefox-esr vlc gimp libreoffice keepassxc
    else
        apt install -y firefox-esr thunderbird vlc mpv gimp libreoffice libreoffice-l10n-nl keepassxc filezilla synaptic gparted
    fi
}

# Communicatie
install_communication() {
    log_info "Communicatie tools installeren..."
    apt install -y remmina remmina-plugin-rdp remmina-plugin-vnc openssh-client openssh-server samba-client cifs-utils nfs-common cups cups-client cups-filters system-config-printer printer-driver-all
    systemctl enable cups ssh
    systemctl start cups ssh
}

# Audio
install_audio() {
    log_info "Audio installeren..."
    apt install -y alsa-utils pulseaudio pulseaudio-utils firmware-intel-sound firmware-sof-signed sof-firmware v4l-utils firmware-uvc guvcview gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad gstreamer1.0-libav ffmpeg
}

# Filesystems
install_filesystems() {
    log_info "Filesystems installeren..."
    apt install -y ntfs-3g exfatprogs exfat-fuse fuse fuse3 dosfstools e2fsprogs
}

# Optimalisatie
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

# Beveiliging
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
    
    systemctl enable unattended-upgrades fail2ban
    systemctl start unattended-upgrades fail2ban
}

# Power (laptop)
configure_power() {
    if [[ "$IS_LAPTOP" == true ]]; then
        log_info "Power management configureren..."
        apt install -y tlp tlp-rdw acpi acpid
        systemctl enable tlp acpid
        systemctl start tlp acpid
    fi
}

# Cleanup
final_cleanup() {
    apt clean
    apt autoremove -y
}

# Main
main() {
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
    final_cleanup
    
    echo ""
    echo "========================================="
    echo -e "\033[0;32m  DEPLOYMENT COMPLEET!${NC}"
    echo "========================================="
    echo ""
    echo -e "\033[0;34mHerstart aanbevolen:${NC} sudo reboot"
    echo "========================================="
}

main "$@"
EOF

    chmod +x /srv/tftp/scripts/post-install.sh
    
    log_success "Client post-installatie script aangemaakt"
}

# ============================================
# 8. RSYSLOG (Client logs ontvangen)
# ============================================

configure_rsyslog() {
    log_info "RSyslog configureren..."
    
    sed -i 's/#module(load="imudp")/module(load="imudp")/' /etc/rsyslog.conf
    sed -i 's/#input(type="imudp" port="514")/input(type="imudp" port="514")/' /etc/rsyslog.conf
    
    cat > /etc/rsyslog.d/20-client-logs.conf << 'EOF'
if $fromhost-ip != '127.0.0.1' then /var/log/client-logs.log
& stop
EOF
    
    touch /var/log/client-logs.log
    chown syslog:adm /var/log/client-logs.log
    systemctl restart rsyslog
    
    log_success "RSyslog geconfigureerd"
}

# ============================================
# 9. SUMMARY
# ============================================

show_summary() {
    echo ""
    echo "========================================="
    echo -e "${GREEN}  DEPLOYMENT SERVER VOLTOOID!${NC}"
    echo "========================================="
    echo ""
    echo -e "${BLUE}Server IP:${NC} 10.0.0.1"
    echo -e "${BLUE}Domain:${NC} lan"
    echo -e "${BLUE}TFTP Root:${NC} /srv/tftp"
    echo -e "${BLUE}NFS Repo:${NC} /srv/debian-repo"
    echo ""
    echo -e "${BLUE}Services:${NC}"
    systemctl status dnsmasq --no-pager | grep -E "Active:" || true
    systemctl status nfs-kernel-server --no-pager | grep -E "Active:" || true
    systemctl status rsyslog --no-pager | grep -E "Active:" || true
    echo ""
    echo -e "${BLUE}Logbestanden:${NC}"
    echo "  - Dnsmasq:    /var/log/dnsmasq.log"
    echo "  - Client logs: /var/log/client-logs.log"
    echo "  - Syslog:     /var/log/syslog"
    echo ""
    echo -e "${YELLOW}Volgende stap:${NC}"
    echo "1. Herstart de server: sudo reboot"
    echo "2. Sluit een client aan op de switch"
    echo "3. Zet client op PXE boot (Network boot)"
    echo "4. Kies een optie uit het menu!"
    echo ""
    echo -e "${YELLOW}Handige commando's:${NC}"
    echo "  - Logs bekijken:         sudo tail -f /var/log/dnsmasq.log"
    echo "  - Client logs bekijken:  sudo tail -f /var/log/client-logs.log"
    echo "  - NFS testen:            showmount -e 10.0.0.1"
    echo "  - TFTP testen:           tftp 10.0.0.1 -c get pxelinux.0"
    echo "========================================="
}

# ============================================
# HOOFDPROGRAMMA
# ============================================

main() {
    echo ""
    echo "========================================="
    echo "  Debian 13 Deployment Server Setup"
    echo "  PXE + DHCP + TFTP + NFS + Preseed"
    echo "========================================="
    echo ""
    
    check_root
    check_internet
    
    read -p "Doorgaan? (j/N): " confirm
    if [[ ! "$confirm" =~ ^[Jj] ]]; then
        log_warning "Installatie geannuleerd."
        exit 0
    fi
    
    install_server_packages
    set_static_ip
    setup_tftp
    configure_dnsmasq
    setup_nfs_repo
    create_pxe_menu
    create_preseed_files
    create_client_script
    configure_rsyslog
    
    show_summary
    
    log_success "Deployment Server voltooid!"
}

main "$@"