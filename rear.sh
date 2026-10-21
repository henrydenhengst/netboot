#!/bin/bash
#
# setup-rear-usb.sh
# Doel: ReaR configureren voor back-up naar USB-stick (/dev/sdd) en eerste back-up maken
# Gebruik: sudo ./setup-rear-usb.sh
#

set -uo pipefail

USB_DEV="/dev/sdd"
REAR_CONF="/etc/rear/local.conf"
USB_LABEL="REAR-000"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }
ok()  { echo "  [OK]        $*"; }
fail(){ echo "  [MISLUKT]   $*"; }

# ---------- Controles vooraf ----------
[[ $EUID -eq 0 ]] || die "Dit script moet als root draaien (gebruik sudo)."

command -v rear >/dev/null 2>&1 \
    || die "ReaR niet gevonden. Installeer eerst met: sudo zypper install rear"

[[ -b "${USB_DEV}" ]] || die "${USB_DEV} is geen block-device. Controleer met lsblk of de stick aangesloten is."

# Veiligheidscheck: is dit echt een USB-apparaat?
USB_CHECK=$(lsblk -no TRAN "${USB_DEV}" 2>/dev/null | head -1)
if [[ "${USB_CHECK}" != "usb" ]]; then
    log "WAARSCHUWING: ${USB_DEV} lijkt geen USB-apparaat (TRAN=${USB_CHECK:-onbekend})."
    read -rp "Toch doorgaan? Dit WIST alle data op ${USB_DEV}. Typ 'JA': " bevestig
    [[ "${bevestig}" == "JA" ]] || die "Afgebroken door gebruiker."
else
    log "Bevestigd: ${USB_DEV} is een USB-apparaat."
    read -rp "${USB_DEV} wordt GEHEEL GEWIST. Typ 'JA' om door te gaan: " bevestig
    [[ "${bevestig}" == "JA" ]] || die "Afgebroken door gebruiker."
fi

# ---------- Stap 1: Formatteren ----------
log "Stap 1: formatteren van ${USB_DEV} met ReaR (label ${USB_LABEL})..."
if rear format "${USB_DEV}" </dev/null; then
    ok "rear format voltooid"
else
    die "rear format mislukt. Controleer of ${USB_DEV} niet gemount is en probeer opnieuw."
fi

# ---------- Stap 2: Label verifiëren ----------
log "Stap 2: controleren van het volumelabel..."
sleep 1
LABEL=$(lsblk -no LABEL "${USB_DEV}" 2>/dev/null | head -1)
if [[ "${LABEL}" == "${USB_LABEL}" ]]; then
    ok "label ${USB_LABEL} aanwezig op ${USB_DEV}"
else
    fail "label is '${LABEL}', verwacht '${USB_LABEL}'. Back-up-URL zal niet werken."
    die "Stop. Controleer handmatig met: lsblk -o NAME,LABEL ${USB_DEV}"
fi

# ---------- Stap 3: Configuratie schrijven ----------
log "Stap 3: schrijven van ${REAR_CONF}..."
if [[ -f "${REAR_CONF}" ]]; then
    cp "${REAR_CONF}" "${REAR_CONF}.bak.$(date +%Y%m%d-%H%M)"
    ok "bestaande configuratie geback-upt"
fi

cat > "${REAR_CONF}" <<EOF
# ReaR configuratie - automatisch aangemaakt op $(date +%Y-%m-%d\ %H:%M)
OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/${USB_LABEL}
EOF
ok "${REAR_CONF} geschreven"

# ---------- Stap 4: Eerste back-up ----------
log "Stap 4: eerste back-up maken (kan enkele minuten duren)..."
START=$(date +%s)
if rear mkbackup; then
    DUUR=$(( $(date +%s) - START ))
    ok "rear mkbackup voltooid in ${DUUR}s"
else
    fail "rear mkbackup mislukt. Zie /var/log/rear/ voor details."
    die "Stop na mislukte back-up."
fi

# ---------- Stap 5: Resultaat controleren ----------
log "Stap 5: controleren van de back-up op de USB-stick..."

# Mount-punt achterhalen (ReaR mount de stick doorgaans onder /tmp/rear.* of /mnt)
MOUNTPOINT=$(findmnt -n -o TARGET -S "/dev/disk/by-label/${USB_LABEL}" 2>/dev/null || true)

if [[ -n "${MOUNTPOINT}" && -d "${MOUNTPOINT}" ]]; then
    ok "USB-stick gemount op ${MOUNTPOINT}"
    log "Inhoud:"
    ls -lh "${MOUNTPOINT}" | sed 's/^/      /'

    ISO_COUNT=$(find "${MOUNTPOINT}" -maxdepth 2 -name '*.iso' 2>/dev/null | wc -l)
    TAR_COUNT=$(find "${MOUNTPOINT}" -maxdepth 2 -name 'backup.tar.gz' 2>/dev/null | wc -l)

    [[ "${ISO_COUNT}" -ge 1 ]] && ok "ISO gevonden (${ISO_COUNT})" || fail "geen ISO gevonden"
    [[ "${TAR_COUNT}" -ge 1 ]] && ok "backup.tar.gz gevonden" || fail "geen backup.tar.gz gevonden"
else
    log "USB-stick is niet (meer) gemount. Controleer handmatig:"
    log "  mount ${USB_DEV} /mnt && ls -lh /mnt"
fi

# ---------- Stap 6: ReaR-log controleren ----------
log "Stap 6: laatste ReaR-logregels..."
LAATSTE_LOG=$(ls -t /var/log/rear/rear-*.log 2>/dev/null | head -1)
if [[ -n "${LAATSTE_LOG}" ]]; then
    ok "logbestand: ${LAATSTE_LOG}"
    grep -iE 'error|failed|mislukt' "${LAATSTE_LOG}" 2>/dev/null | tail -5 | sed 's/^/      /' \
        || ok "geen fouten gevonden in ReaR-log"
else
    log "Geen ReaR-log gevonden in /var/log/rear/"
fi

# ---------- Samenvatting ----------
echo
log "===== SAMENVATTING ====="
echo "  Configuratie:  ${REAR_CONF}"
echo "  USB-apparaat:  ${USB_DEV} (label ${USB_LABEL})"
echo "  Back-up-URL:   usb:///dev/disk/by-label/${USB_LABEL}"
echo
log "Klaar. Het wekelijkse systemd-script zal ReaR nu automatisch meenemen."
log "Herstelmedium maken (indien nodig):  sudo rear mkrescue"