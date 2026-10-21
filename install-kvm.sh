#!/usr/bin/env bash
# install-kvm-leap16.sh
# KVM/QEMU + libvirt + NAT voor openSUSE Leap 16

set -Eeuo pipefail

#------------------------------------------------------------------------------
# Controles
#------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Gebruik: sudo bash $0"
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "opensuse-leap" || "${VERSION_ID:-}" != 16* ]]; then
    echo "FOUT: dit script is bedoeld voor openSUSE Leap 16."
    exit 1
fi

if [[ ! -c /dev/kvm ]]; then
    echo "FOUT: /dev/kvm ontbreekt of is geen character device."
    exit 1
fi

for cmd in zypper systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FOUT: vereist commando '$cmd' niet gevonden."
        exit 1
    fi
done

#------------------------------------------------------------------------------
# Pakketten
#------------------------------------------------------------------------------

echo "==> Pakketbronnen vernieuwen"
zypper --non-interactive --gpg-auto-import-keys refresh

echo "==> KVM/QEMU en libvirt installeren"
zypper --non-interactive install \
    qemu-x86 \
    libvirt-client \
    libvirt-daemon-driver-qemu \
    libvirt-daemon-driver-network \
    libvirt-daemon-driver-storage \
    libvirt-daemon-config-network

#------------------------------------------------------------------------------
# Services
#------------------------------------------------------------------------------

echo "==> Controleren van libvirt-services"
for svc in virtqemud.socket virtnetworkd.socket; do
    if ! systemctl cat "$svc" >/dev/null 2>&1; then
        echo "FOUT: systemd-unit $svc ontbreekt."
        echo "Geen verdere netwerkconfiguratie uitgevoerd."
        exit 1
    fi
done

echo "==> QEMU-daemon activeren"
systemctl enable --now virtqemud.socket

echo "==> Netwerkdaemon activeren"
systemctl enable --now virtnetworkd.socket

#------------------------------------------------------------------------------
# NAT-netwerk
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

echo "==> NAT-netwerk starten"
net_active="$(virsh -c qemu:///system net-info default \
              | awk '/^Active:/ {print $2}')"
if [[ "$net_active" != "yes" ]]; then
    virsh -c qemu:///system net-start default
fi

#------------------------------------------------------------------------------
# Overzicht
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