
#!/usr/bin/env bash
set -e

echo "Tailscale installeren op SUSE Leap 16..."

sudo zypper --non-interactive ar -g \
  https://pkgs.tailscale.com/stable/opensuse/leap/16.0/tailscale.repo \
  tailscale

sudo zypper --non-interactive refresh tailscale
sudo zypper --non-interactive install tailscale

sudo systemctl enable --now tailscaled

echo
echo "Controle:"
systemctl is-active tailscaled

echo
echo "Installatie klaar. Koppel de server met:"
echo "sudo tailscale up"
