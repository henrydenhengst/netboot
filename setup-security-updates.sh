#!/usr/bin/env bash
# Richt automatische security patches in voor openSUSE Leap 16.
# Draait elke vrijdag om 03:00 via een systemd-timer.
# Herstart de machine direct als dat nodig is na de patches.
# Gebruik: sudo bash setup-security-updates.sh

set -euo pipefail

RUNNER=/usr/local/sbin/security-patch.sh
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

# Eventuele eerdere versie uit het eerste voorbeeld opruimen
if systemctl list-unit-files auto-update.timer >/dev/null 2>&1; then
    systemctl disable --now auto-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/auto-update.timer /etc/systemd/system/auto-update.service
fi

# Het script dat de timer uitvoert
cat > "$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

ZYPPER="/usr/bin/zypper --non-interactive --quiet"

$ZYPPER refresh

# Exitcode 103 = zypper heeft zichzelf bijgewerkt; dan nogmaals draaien.
# Exitcode 102 = patches geinstalleerd, reboot nodig (hier geen fout).
for attempt in 1 2 3; do
    $ZYPPER patch --category security --auto-agree-with-licenses
    rc=$?
    [[ $rc -eq 103 ]] && continue
    break
done

if [[ $rc -ne 0 && $rc -ne 102 ]]; then
    echo "zypper patch faalde met exitcode $rc" >&2
    exit "$rc"
fi

# Controleer of een herstart nodig is (exitcode 102 = ja)
/usr/bin/zypper needs-rebooting >/dev/null 2>&1
if [[ $? -eq 102 || $rc -eq 102 ]]; then
    echo "Herstart nodig na security patches; systeem herstart over 1 minuut."
    /usr/sbin/shutdown -r +1 "Herstart na security patches"
else
    echo "Geen herstart nodig."
fi
EOF
chmod 755 "$RUNNER"

cat > "$SERVICE" <<EOF
[Unit]
Description=Automatische security patches (zypper)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER
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
echo "  sudo systemctl start security-patch.service   # nu handmatig draaien (herstart indien nodig!)"
echo "  journalctl -u security-patch.service         # log bekijken"
echo "  sudo shutdown -c                             # geplande herstart annuleren"
