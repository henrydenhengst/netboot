#!/bin/bash
#
# setup-rear-usb.sh (handmatige formatteer-methode)
# Doel: USB-stick handmatig partitioneren/formatteren en ReaR configureren
# Gebruik: sudo ./setup-rear-usb.sh
#

set -uo pipefail

USB_DEV="/dev/sdd"
USB_PART="${USB_DEV}1"
REAR_CONF="/etc/rear/local.conf"
USB_LABEL="REAR-000"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }
ok()  { echo "  [OK]        $*"; }
fail(){ echo "  [MISLUKT]   $*"; }

# ---------- Controles vooraf ----------
[[ $EUID -eq 0 ]] || die "Dit script moet als root draaien (gebruik sudo)."

command -v rear  >/dev/null 2>&1 || die "ReaR niet gevonden. Installeer met: sudo zypper install rear"
command -v parted >/dev/null 2>&1 || die "parted niet gevonden. Installeer met: sudo zypper install parted"

[[ -b "${USB_DEV}" ]] || die "${USB_DEV} is geen block-device. Controleer met lsblk."

USB_TRAN=$(lsblk -no TRAN "${USB_DEV}" 2>/dev/null | head -1)
if [[ "${USB_TRAN}" != "usb" ]]; then
    log "WAARSCHUWING: ${USB_DEV} lijkt geen USB-apparaat (TRAN=${USB_TRAN:-onbekend})."
fi
read -rp "${USB_DEV} wordt GEHEEL GEWIST. Typ 'JA' om door te gaan: " bevestig
[[ "${bevestig}" == "JA" ]] || die "Afgebroken door gebruiker."

# ---------- Stap 1: Ontkoppelen ----------
log "Stap 1: bestaande mounts op ${USB_DEV} ontkoppelen..."
for part in "${USB_DEV}"*; do
    [[ -b "${part}" ]] || continue
    if mountpoint -q "$(findmnt -n -o TARGET "${part}" 2>/dev/null)" 2>/dev/null; then
        umount "${part}" 2>/dev/null && ok "ontkoppeld: ${part}" || fail "kon ${part} niet ontkoppelen"
    fi
done
swapoff "${USB_DEV}"* 2>/dev/null || true

# ---------- Stap 2: Partitioneren ----------
log "Stap 2: GPT-label en partitie aanmaken op ${USB_DEV}..."
parted -s "${USB_DEV}" mklabel gpt        || die "mklabel mislukt"
parted -s "${USB_DEV}" mkpart primary ext3 1MiB 100% || die "mkpart mislukt"

# Wacht tot kernel de partitie ziet
sleep 2
[[ -b "${USB_PART}" ]] || die "${USB_PART} bestaat niet na partitioneren."
ok "partitie ${USB_PART} aangemaakt"

# ---------- Stap 3: Formatteren met label ----------
log "Stap 3: formatteren van ${USB_PART} als ext3 met label ${USB_LABEL}..."
mkfs.ext3 -F -L "${USB_LABEL}" "${USB_PART}" || die "mkfs.ext3 mislukt"
ok "ext3 geformatteerd met label ${USB_LABEL}"

# ---------- Stap 4: Label verifiëren ----------
log "Stap 4: label verifiëren..."
sleep 1
LABEL=$(lsblk -no LABEL "${USB_PART}" 2>/dev/null | head -1)
if [[ "${LABEL}" == "${USB_LABEL}" ]]; then
    ok "label ${USB_LABEL} bevestigd op ${USB_PART}"
else
    fail "label is '${LABEL}', verwacht '${USB_LABEL}'"
    die "Stop. Controleer handmatig met: lsblk -o NAME,LABEL ${USB_DEV}"
fi

# ---------- Stap 5: ReaR-configuratie ----------
log "Stap 5: schrijven van ${REAR_CONF}..."
if [[ -f "${REAR_CONF}" ]]; then
    cp "${REAR_CONF}" "${REAR_CONF}.bak.$(date +%Y%m%d-%H%M)"
    ok "bestaande configuratie geback-upt"
fi

cat > "${REAR_CONF}" <<EOF
# ReaR configuratie - automatisch aangemaakt op $(date +%Y-%m-%d\ %H:%M)
OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/${USB_LABEL}
USB_UEFI_PART_SIZE="1024"
EOF
ok "${REAR_CONF} geschreven"

# ---------- Stap 6: Eerste back-up ----------
log "Stap 6: eerste back-up maken (kan enkele minuten duren)..."
START=$(date +%s)
if rear mkbackup; then
    DUUR=$(( $(date +%s) - START ))
    ok "rear mkbackup voltooid in ${DUUR}s"
else
    fail "rear mkbackup mislukt. Zie /var/log/rear/ voor details."
    die "Stop na mislukte back-up."
fi

# ---------- Stap 7: Resultaat controleren ----------
log "Stap 7: controleren van de back-up..."
MOUNTPOINT=$(findmnt -n -o TARGET -S "/dev/disk/by-label/${USB_LABEL}" 2>/dev/null || true)

if [[ -n "${MOUNTPOINT}" && -d "${MOUNTPOINT}" ]]; then
    ok "USB gemount op ${MOUNTPOINT}"
    ls -lh "${MOUNTPOINT}" | sed 's/^/      /'
    ISO_COUNT=$(find "${MOUNTPOINT}" -maxdepth 2 -name '*.iso' 2>/dev/null | wc -l)
    TAR_COUNT=$(find "${MOUNTPOINT}" -maxdepth 2 -name 'backup.tar.gz' 2>/dev/null | wc -l)
    [[ "${ISO_COUNT}" -ge 1 ]] && ok "ISO gevonden (${ISO_COUNT})" || fail "geen ISO gevonden"
    [[ "${TAR_COUNT}" -ge 1 ]] && ok "backup.tar.gz gevonden"       || fail "geen backup.tar.gz gevonden"
else
    log "USB niet gemount; controleer handmatig: mount ${USB_PART} /mnt && ls -lh /mnt"
fi

# ---------- Stap 8: Log controleren ----------
log "Stap 8: laatste ReaR-logregels..."
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
echo "  USB-apparaat:  ${USB_DEV} -> ${USB_PART} (label ${USB_LABEL})"
echo "  Back-up-URL:   usb:///dev/disk/by-label/${USB_LABEL}"
echo
log "Klaar. Het wekelijkse systemd-script neemt ReaR nu automatisch mee."
log "Herstelmedium opnieuw maken:  sudo rear mkrescue"