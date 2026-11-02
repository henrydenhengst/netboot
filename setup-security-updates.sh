#!/usr/bin/env bash
# Richt automatische security patches in voor openSUSE Leap 16.
# Draait elke vrijdag om 03:00 via een systemd-timer.
# Gebruik: sudo bash setup-security-updates.sh

set -euo pipefail

SERVICE=/etc/systemd/system/security-patch.service
TIMER=/etc/systemd/system/security-patch.timer

if [[ $EUID -ne 0 ]]; then
    echo "Voer dit script uit als root: sudo bash $0" >&2
    exit 1
fi

if ! command -v zypper >/dev/null 2>&1; then
    echo "zypper niet gevonden; dit script is bedoeld voor openSUSE." >&2
    exit 1
fi

# Eventuele eerdere versie uit het vorige voorbeeld opruimen
if systemctl list-unit-files auto-update.timer >/dev/null 2>&1; then
    systemctl disable --now auto-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/auto-update.timer /etc/systemd/system/auto-update.service
fi

cat > "$SERVICE" <<'EOF'
[Unit]
Description=Automatische security patches (zypper)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/zypper --non-interactive --quiet refresh
ExecStart=/usr/bin/zypper --non-interactive --quiet patch --category security --auto-agree-with-licenses
Nice=10
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Security patches elke vrijdag om 03:00

[Timer]
OnCalendar=Fri *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now security-patch.timer

echo
echo "Klaar. Volgende run:"
systemctl list-timers security-patch.timer --no-pager
echo
echo "Handige commando's:"
echo "  sudo systemctl start security-patch.service   # nu handmatig draaien"
echo "  journalctl -u security-patch.service         # log bekijken"
echo "  sudo zypper ps -s                            # herstart nodig?"
