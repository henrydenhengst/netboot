#!/bin/bash
#
# fix-server-toolkit-logging.sh
# Doel: StandardOutput/StandardError toevoegen aan server-toolkit.service
#       zodat uitvoer ook in /var/log/server-toolkit.log terechtkomt.
# Gebruik: sudo ./fix-server-toolkit-logging.sh
#

set -uo pipefail

SERVICE="/etc/systemd/system/server-toolkit.service"
LOGFILE="/var/log/server-toolkit.log"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }
ok()  { echo "  [OK]        $*"; }
fail(){ echo "  [MISLUKT]   $*"; }

# ---------- Controles ----------
[[ $EUID -eq 0 ]] || die "Dit script moet als root draaien (gebruik sudo)."
[[ -f "${SERVICE}" ]] || die "${SERVICE} bestaat niet. Draai eerst het installatiescript."

# ---------- Backup van het originele bestand ----------
cp "${SERVICE}" "${SERVICE}.bak.$(date +%Y%m%d-%H%M)" \
    && log "Back-up gemaakt van ${SERVICE}" \
    || die "Kon geen back-up maken van ${SERVICE}"

# ---------- Controleren of de regels al aanwezig zijn ----------
if grep -q '^StandardOutput=' "${SERVICE}" && grep -q '^StandardError=' "${SERVICE}"; then
    log "StandardOutput/StandardError staan al in ${SERVICE}, niets te doen."
else
    log "Voeg StandardOutput/StandardError toe aan ${SERVICE}"

    # Verwijder eventueel bestaande (maar onvolledige) regels
    sed -i '/^StandardOutput=/d; /^StandardError=/d' "${SERVICE}"

    # Voeg de regels toe direct na de ExecStart-regel
    if grep -q '^ExecStart=' "${SERVICE}"; then
        sed -i '/^ExecStart=/a StandardOutput=append:'"${LOGFILE}"'\nStandardError=append:'"${LOGFILE}" "${SERVICE}"
        ok "regels toegevoegd na ExecStart"
    else
        die "Geen ExecStart-regel gevonden in ${SERVICE}"
    fi
fi

# ---------- Logbestand aanmaken indien nodig ----------
if [[ ! -f "${LOGFILE}" ]]; then
    touch "${LOGFILE}" && chmod 640 "${LOGFILE}" \
        && ok "${LOGFILE} aangemaakt" \
        || fail "kon ${LOGFILE} niet aanmaken"
else
    ok "${LOGFILE} bestaat al"
fi

# ---------- Herladen ----------
log "Herlaad systemd..."
systemctl daemon-reload || die "daemon-reload mislukt"

# ---------- Verifiëren ----------
log "Controleer syntaxis..."
if systemd-analyze verify "${SERVICE}" 2>&1; then
    ok "syntaxis in orde"
else
    fail "systemd-analyze meldde een probleem"
fi

# ---------- Testrun ----------
log "Start een testrun van server-toolkit.service..."
START=$(date +%s)
if systemctl start server-toolkit.service; then
    DUUR=$(( $(date +%s) - START ))
    ok "service klaar in ${DUUR}s"
else
    fail "systemctl start gaf een fout"
fi

# ---------- Controleren of het logbestand gevuld is ----------
log "Controleer of ${LOGFILE} gevuld is..."
if [[ -s "${LOGFILE}" ]]; then
    ok "${LOGFILE} bevat output (laatste 5 regels):"
    tail -5 "${LOGFILE}" | sed 's/^/      /'
else
    fail "${LOGFILE} is nog leeg"
    log "Laatste journalregels ter diagnose:"
    journalctl -u server-toolkit.service -n 20 --no-pager | sed 's/^/      /'
fi

# ---------- Eindstatus ----------
echo
log "===== RESULTAAT ====="
systemctl show -p Result --value server-toolkit.service \
    | sed 's/^/  service Result = /'
echo
log "Klaar. Bekijk het volledige logboek met: tail -50 ${LOGFILE}"