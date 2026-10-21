#!/bin/bash
#
# setup-logrotate-server-toolkit.sh
# Doel: logrotate-config voor /var/log/server-toolkit.log aanmaken en testen
# Gebruik: sudo ./setup-logrotate-server-toolkit.sh
#

set -uo pipefail

LOGROTATE_CONF="/etc/logrotate.d/server-toolkit"
LOGFILE="/var/log/server-toolkit.log"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }
ok()  { echo "  [OK]        $*"; }
fail(){ echo "  [MISLUKT]   $*"; }

# ---------- Controles ----------
[[ $EUID -eq 0 ]] || die "Dit script moet als root draaien (gebruik sudo)."
command -v logrotate >/dev/null 2>&1 || die "logrotate niet gevonden. Installeer met: sudo zypper install logrotate"

# ---------- Bestaande config back-uppen ----------
if [[ -f "${LOGROTATE_CONF}" ]]; then
    cp "${LOGROTATE_CONF}" "${LOGROTATE_CONF}.bak.$(date +%Y%m%d-%H%M)"
    ok "bestaande config geback-upt"
fi

# ---------- Config schrijven ----------
log "Schrijf ${LOGROTATE_CONF}..."
cat > "${LOGROTATE_CONF}" <<'EOF'
/var/log/server-toolkit.log {
    size 50M
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

if [[ -f "${LOGROTATE_CONF}" ]]; then
    ok "${LOGROTATE_CONF} aangemaakt"
else
    die "kon ${LOGROTATE_CONF} niet aanmaken"
fi

# ---------- Rechten ----------
chmod 644 "${LOGROTATE_CONF}"
ok "rechten ingesteld op 644"

# ---------- Logbestand aanmaken indien nodig ----------
if [[ ! -f "${LOGFILE}" ]]; then
    touch "${LOGFILE}"
    chmod 640 "${LOGFILE}"
    ok "${LOGFILE} aangemaakt"
else
    ok "${LOGFILE} bestaat al"
fi

# ---------- Syntaxis testen ----------
log "Test de configuratie (dry-run)..."
if logrotate -d "${LOGROTATE_CONF}" 2>&1 | grep -qiE 'error|invalid'; then
    fail "logrotate -d meldde een probleem:"
    logrotate -d "${LOGROTATE_CONF}" 2>&1 | sed 's/^/      /'
    die "Stop na configuratiefout."
else
    ok "dry-run zonder fouten"
fi

# ---------- Echte rotatie forceren (alleen als log niet leeg is) ----------
log "Forceer een rotatie om te testen..."
if [[ -s "${LOGFILE}" ]]; then
    if logrotate -f "${LOGROTATE_CONF}"; then
        ok "rotatie uitgevoerd"
    else
        fail "logrotate -f gaf een fout"
    fi
else
    log "  ${LOGFILE} is leeg, rotatie overgeslagen (notifempty)"
fi

# ---------- Resultaat tonen ----------
log "Controleer resultaat..."
ls -lh "${LOGFILE}"* 2>/dev/null | sed 's/^/      /' \
    || fail "geen logbestanden gevonden"

# ---------- Samenvatting ----------
echo
log "===== SAMENVATTING ====="
echo "  Configuratie:  ${LOGROTATE_CONF}"
echo "  Rotatie bij:   50 MB"
echo "  Bewaren:       8 versies (gecomprimeerd)"
echo "  Methode:       copytruncate (systemd-compatibel)"
echo
log "Klaar. logrotate draait dit automatisch mee met de dagelijkse systeemrotatie."
log "Handmatig testen:  sudo logrotate -f ${LOGROTATE_CONF}"
log "Status bekijken:   cat /var/lib/logrotate.status | grep server-toolkit"