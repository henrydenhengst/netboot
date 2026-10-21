#!/usr/bin/env bash
# install-kvm-leap16.sh
# KVM/QEMU + libvirt + NAT voor openSUSE Leap 16
#
# Doel:
#   - KVM/QEMU en libvirt installeren
#   - Modulaire libvirt-daemons (virtqemud, virtnetworkd) activeren
#   - Standaard NAT-netwerk 'default' definiëren, autostarten en starten
#
# Niet gewijzigd:
#   - Fysieke netwerkconfiguratie
#   - Podman
#
set -Eeuo pipefail

#------------------------------------------------------------------------------
# 0. Voorwaarden
#------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Gebruik: sudo bash $0"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "opensuse-leap" || "${VERSION_ID:-}" != 16* ]]; then
    echo "FOUT: dit script is bedoeld voor openSUSE Leap 16."
    exit 1
fi

if [[ ! -c /dev/kvm ]]; then
    echo "FOUT: /dev/kvm ontbreekt of is geen character device."
    echo "Controleer of virtualisatie in de BIOS/UEFI is ingeschakeld"
    echo "en of de kvm-module geladen is (lsmod | grep kvm)."
    exit 1
fi

for cmd in zypper systemctl virsh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FOUT: vereist commando '$cmd' niet gevonden."
        exit 1
    fi
done

#------------------------------------------------------------------------------
# 1. Pakketten installeren
#------------------------------------------------------------------------------

echo "==> Pakketbronnen vernieuwen"
zypper --non-interactive --gpg-auto-import-keys refresh

echo "==> KVM/QEMU en libvirt installeren"
zypper --non-interactive install \
    qemu-x86 \
    qemu-x86_64 \
    libvirt-client \
    libvirt-daemon-driver-qemu \
    libvirt-daemon-driver-network \
    libvirt-daemon-driver-storage \
    libvirt-daemon-config-network

#------------------------------------------------------------------------------
# 2. Controleren of de modulaire libvirt-units bestaan
#------------------------------------------------------------------------------

echo "==> Controleren van libvirt-services"
for svc in virtqemud.socket virtnetworkd.socket; do
    if ! systemctl cat "$svc" >/dev/null 2>&1; then
        echo "FOUT: systemd-unit $svc ontbreekt."
        echo "Geen verdere netwerkconfiguratie uitgevoerd."
        exit 1
    fi
done

#------------------------------------------------------------------------------
# 3. Daemons activeren
#------------------------------------------------------------------------------

echo "==> QEMU-daemon activeren"
systemctl enable --now virtqemud.socket

echo "==> Netwerkdaemon activeren"
systemctl enable --now virtnetworkd.socket

#------------------------------------------------------------------------------
# 4. Standaard NAT-netwerk definiëren (indien nodig)
#------------------------------------------------------------------------------

echo "==> Standaard NAT-netwerk controleren"
if ! virsh -c qemu:///system net-info default >/dev/null 2>&1; then
    if [[ -f /usr/share/libvirt/networks/default.xml ]]; then
        virsh -c qemu:///system net-define \
            /usr/share/libvirt/networks/default.xml
    else
        echo "FOUT: standaard NAT-configuratie niet gevonden."
        echo "Controleer de bestanden van libvirt-daemon-config-network."
        exit 1
    fi
fi

echo "==> NAT-netwerk automatisch laten starten"
virsh -c qemu:///system net-autostart default

#------------------------------------------------------------------------------
# 5. NAT-netwerk starten (robuust, zonder pipefail-valkuil)
#------------------------------------------------------------------------------

echo "==> NAT-netwerk starten"
net_active="$(virsh -c qemu:///system net-info default \
              | awk '/^Active:/ {print $2}')"
if [[ "$net_active" != "yes" ]]; then
    virsh -c qemu:///system net-start default
fi

# Wacht kort tot virbr0 daadwerkelijk bestaat (dnsmasq is asynchroon).
for _ in {1..10}; do
    if ip -br link show virbr0 >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

#------------------------------------------------------------------------------
# 6. Firewalld-sanity (openSUSE-specifiek)
#------------------------------------------------------------------------------

if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --zone=libvirt --list-all >/dev/null 2>&1; then
        echo "WAARSCHUWING: firewalld-zone 'libvirt' niet gevonden."
        echo "NAT-forwarding werkt mogelijk niet zoals verwacht."
    fi
fi

#------------------------------------------------------------------------------
# 7. Overzicht
#------------------------------------------------------------------------------

echo
echo "==> Virtuele machines"
virsh -c qemu:///system list --all

echo
echo "==> Virtuele netwerken"
virsh -c qemu:///system net-list --all

echo
echo "KVM/libvirt-configuratie afgerond."
echo "Fysieke netwerkconfiguratie is niet bewust gewijzigd."
echo "Podman is niet bewust gewijzigd."