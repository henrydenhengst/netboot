#!/bin/bash
#
# install-server-toolkit-systemd.sh
# Doel: systemd service + timer installeren EN verifiëren voor /usr/sbin/server-toolkit.sh
# Gebruik: sudo ./install-server-toolkit-systemd.sh
#

set -uo pipefail

SCRIPT="/usr/sbin/server-toolkit.sh"
SERVICE="/etc/systemd/system/server-toolkit.service"
TIMER="/etc/systemd/system/server-toolkit.timer"
LOG_FILE="/var/log/server-toolkit.log"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }
ok()  { echo "  [OK]        $*"; }
fail(){ echo "  [MISLUKT]   $*"; }

# ---------- Controles vooraf ----------
[[ $EUID -eq 0 ]] || die "Dit script moet als root draaien (gebruik sudo)."

if [[ ! -x "${SCRIPT}" ]]; then
    die "${SCRIPT} niet gevonden of niet uitvoerbaar. Kopieer het eerst naar /usr/sbin en chmod +x."
fi

if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl niet gevonden. Is dit wel een systemd-systeem?"
fi

# ---------- Service-bestand ----------
log "Schrijf ${SERVICE}"
cat > "${SERVICE}" <<'EOF'
[Unit]
Description=Server toolkit - wekelijkse documentatie en container back-up

[Service]
Type=oneshot
ExecStart=/usr/sbin/server-toolkit.sh alles
EOF

# ---------- Timer-bestand ----------
log "Schrijf ${TIMER}"
cat > "${TIMER}" <<'EOF'
[Unit]
Description=Wekelijkse uitvoering van server-toolkit

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
Unit=server-toolkit.service

[Install]
WantedBy=timers.target
EOF

# ---------- Verifiëren ----------
log "Controleer syntaxis met systemd-analyze verify..."
if ! systemd-analyze verify "${SERVICE}" "${TIMER}" 2>&1; then
    log "WAARSCHUWING: systemd-analyze meldde iets. Controleer de output hierboven."
fi

# ---------- Herladen en inschakelen ----------
log "Herlaad systemd..."
systemctl daemon-reload || die "daemon-reload mislukt"

log "Schakel timer in..."
systemctl enable --now server-toolkit.timer || die "Inschakelen timer mislukt"

# ==========================================================
# TESTFASE
# ==========================================================
echo
log "===== TESTFASE ====="

# 1. Bestaat het service-bestand?
echo "Test 1: service-bestand aanwezig"
[[ -f "${SERVICE}" ]] && ok "${SERVICE}" || fail "${SERVICE} ontbreekt"

# 2. Bestaat het timer-bestand?
echo "Test 2: timer-bestand aanwezig"
[[ -f "${TIMER}" ]] && ok "${TIMER}" || fail "${TIMER} ontbreekt"

# 3. Is de timer actief?
echo "Test 3: timer actief"
if systemctl is-active --quiet server-toolkit.timer; then
    ok "server-toolkit.timer is actief"
else
    fail "server-toolkit.timer is niet actief"
fi

# 4. Is de timer enabled (start na reboot)?
echo "Test 4: timer enabled (overleeft reboot)"
if systemctl is-enabled --quiet server-toolkit.timer; then
    ok "server-toolkit.timer is enabled"
else
    fail "server-toolkit.timer is niet enabled"
fi

# 5. Toon de volgende geplande run
echo "Test 5: volgende geplande run"
systemctl list-timers server-toolkit.timer --no-pager 2>/dev/null | head -3 \
    || fail "kon list-timers niet uitvoeren"

# 6. Testrun van de service (dit is de echte functionele test)
echo "Test 6: eenmalige testrun van de service"
log "Start server-toolkit.service (dit kan even duren)..."
START_TIJD=$(date +%s)

if systemctl start server-toolkit.service; then
    EIND_TIJD=$(date +%s)
    DUUR=$((EIND_TIJD - START_TIJD))
    ok "service gestart en gestopt in ${DUUR}s"
else
    fail "systemctl start gaf een fout"
fi

# 7. Is de service zonder fouten afgerond?
echo "Test 7: service status na de run"
SERVICE_STATUS=$(systemctl show -p Result --value server-toolkit.service 2>/dev/null)
if [[ "${SERVICE_STATUS}" == "success" ]]; then
    ok "service Result = success"
else
    fail "service Result = ${SERVICE_STATUS} (verwacht: success)"
fi

# 8. Zijn er fouten in het journal?
echo "Test 8: fouten in het journal"
FOUTEN=$(journalctl -u server-toolkit.service --since "5 minutes ago" --no-pager 2>/dev/null \
    | grep -iE 'error|failed|mislukt|command not found|not found' || true)
if [[ -z "${FOUTEN}" ]]; then
    ok "geen fouten gevonden in het journal"
else
    fail "mogelijke fouten gevonden:"
    echo "${FOUTEN}" | sed 's/^/      /'
fi

# 9. Is er output in het logbestand?
echo "Test 9: logbestand"
if [[ -f "${LOG_FILE}" ]]; then
    LAATSTE=$(tail -3 "${LOG_FILE}" 2>/dev/null)
    ok "${LOG_FILE} bestaat (laatste regels:)"
    echo "${LAATSTE}" | sed 's/^/      /'
else
    fail "${LOG_FILE} bestaat niet (nog geen output weggeschreven)"
fi

# 10. Laatste 20 journalregels zien
echo "Test 10: laatste 20 journalregels van de service"
journalctl -u server-toolkit.service -n 20 --no-pager 2>/dev/null | sed 's/^/      /' \
    || fail "kon journal niet lezen"

# ==========================================================
# SAMENVATTING
# ==========================================================
echo
log "===== SAMENVATTING ====="
systemctl list-timers server-toolkit.timer --no-pager 2>/dev/null || true
echo
log "Installatie en test afgerond."
log "Bekijk het volledige journal met:  journalctl -u server-toolkit.service -n 100"
log "Bekijk het logbestand met:        tail -50 ${LOG_FILE}"