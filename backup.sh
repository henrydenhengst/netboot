#!/bin/bash
#
# server-toolkit.sh
# Doel: documentatie, back-up en container-inventarisatie voor SUSE Leap + Podman
# Gebruik: ./server-toolkit.sh [documentatie|backup|containers|alles]
# Let op: uitvoeren als root (of met sudo) voor volledige functionaliteit.
#

set -uo pipefail

# ---------- Configuratie ----------
BACKUP_BASE="/var/backups/server-toolkit"
DATUM=$(date +%Y%m%d-%H%M)
HOSTNAME=$(hostname -s)
DOC_DIR="${BACKUP_BASE}/documentatie-${DATUM}"
CONTAINER_DIR="${BACKUP_BASE}/containers-${DATUM}"

# ---------- Hulpfuncties ----------
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Dit script moet als root draaien (gebruik sudo)."
    fi
}

check_podman() {
    command -v podman >/dev/null 2>&1 || die "Podman niet gevonden. Installeer podman eerst."
}

# ==========================================================
# DEEL 1: DOCUMENTATIE (alles in tekstbestanden)
# ==========================================================
do_documentatie() {
    log "Start documentatie naar ${DOC_DIR}"
    mkdir -p "${DOC_DIR}" || die "Kan ${DOC_DIR} niet aanmaken"

    # 1a. Supportconfig (de officiële SUSE-manier voor "alles")
    if command -v supportconfig >/dev/null 2>&1; then
        log "Draai supportconfig (dit kan enkele minuten duren)..."
        supportconfig -t "${DOC_DIR}/supportconfig" >/dev/null 2>&1 \
            && log "supportconfig archief aangemaakt" \
            || log "WAARSCHUWING: supportconfig gaf een fout"
    else
        log "WAARSCHUWING: supportconfig niet gevonden, sla over"
    fi

    # 1b. Eigen snelle inventarisatie in leesbare tekst
    log "Verzamel eigen inventarisatie..."
    {
        echo "===== SYSTEEM INFO ====="
        hostnamectl 2>/dev/null
        echo
        echo "===== SUSE VERSIE ====="
        cat /etc/os-release
        echo
        echo "===== KERNEL ====="
        uname -a
        echo
        echo "===== CPU ====="
        lscpu 2>/dev/null | head -20
        echo
        echo "===== GEHEUGEN ====="
        free -h
        echo
        echo "===== SCHIJVEN / FS ====="
        df -hT
        echo
        echo "===== BLOCK DEVICES ====="
        lsblk -f 2>/dev/null
    } > "${DOC_DIR}/systeem-info.txt" 2>&1

    {
        echo "===== NETWERK INTERFACES ====="
        ip -brief address 2>/dev/null
        echo
        echo "===== ROUTES ====="
        ip route 2>/dev/null
        echo
        echo "===== DNS ====="
        cat /etc/resolv.conf 2>/dev/null
    } > "${DOC_DIR}/netwerk.txt" 2>&1

    {
        echo "===== DRAaiENDE SERVICES ====="
        systemctl list-units --type=service --state=running --no-pager 2>/dev/null
        echo
        echo "===== ALLE ENABLED SERVICES ====="
        systemctl list-unit-files --state=enabled --no-pager 2>/dev/null
    } > "${DOC_DIR}/services.txt" 2>&1

    {
        echo "===== GEINSTALLEERDE PAKKETTEN ====="
        zypper se -i 2>/dev/null
    } > "${DOC_DIR}/pakketten.txt" 2>&1

    # 1c. Configuratiebestanden kopiëren (let op: kan gevoelige data bevatten!)
    log "Kopieer /etc configuratiebestanden..."
    mkdir -p "${DOC_DIR}/etc"
    rsync -a --include='*/' --include='*.conf' --include='*.cfg' \
          --include='*.service' --include='*.yml' --include='*.yaml' \
          --exclude='*' /etc/ "${DOC_DIR}/etc/" 2>/dev/null \
        || cp -a /etc "${DOC_DIR}/etc_full" 2>/dev/null
    log "LET OP: ${DOC_DIR}/etc kan gevoelige info bevatten (wachtwoorden, sleutels)."

    log "Documentatie klaar in ${DOC_DIR}"
}

# ==========================================================
# DEEL 2: SYSTEEM BACK-UP (Snapper + ReaR)
# ==========================================================
do_backup() {
    log "Start systeem-back-up"

    # 2a. Snapper momentopname (snel, zelfde schijf)
    if command -v snapper >/dev/null 2>&1; then
        log "Maak Snapper momentopname..."
        snapper create --description "backup-${DATUM}" --cleanup-algorithm number \
            && log "Snapper momentopname gemaakt" \
            || log "WAARSCHUWING: Snapper momentopname mislukt"
    else
        log "Snapper niet gevonden, sla over"
    fi

    # 2b. ReaR bare-metal back-up (als geconfigureerd)
    if command -v rear >/dev/null 2>&1; then
        if [[ -f /etc/rear/local.conf ]]; then
            log "Start ReaR mkbackup (kan lang duren)..."
            rear mkbackup >> "${BACKUP_BASE}/rear-${DATUM}.log" 2>&1 \
                && log "ReaR back-up klaar" \
                || log "WAARSCHUWING: ReaR back-up mislukt, zie log"
        else
            log "WAARSCHUWING: /etc/rear/local.conf ontbreekt, ReaR overgeslagen"
        fi
    else
        log "ReaR niet geïnstalleerd (zypper install rear), overgeslagen"
    fi
}

# ==========================================================
# DEEL 3: PODMAN CONTAINER BACK-UP
# ==========================================================
do_containers() {
    check_podman
    log "Start container back-up naar ${CONTAINER_DIR}"
    mkdir -p "${CONTAINER_DIR}" || die "Kan ${CONTAINER_DIR} niet aanmaken"

    # 3a. Inventarisatie van containers
    log "Inventariseer containers en images..."
    podman ps -a --format "{{.Names}}\t{{.Image}}\t{{.Status}}" \
        > "${CONTAINER_DIR}/containers-lijst.txt" 2>&1
    podman images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" \
        > "${CONTAINER_DIR}/images-lijst.txt" 2>&1
    podman volume ls --format "{{.Name}}\t{{.Driver}}" \
        > "${CONTAINER_DIR}/volumes-lijst.txt" 2>&1

    # 3b. Back-up van alle named volumes (native podman export)
    log "Back-up van Podman volumes..."
    while IFS= read -r vol; do
        [[ -z "${vol}" ]] && continue
        log "  -> volume: ${vol}"
        podman volume export "${vol}" 2>/dev/null \
            | gzip > "${CONTAINER_DIR}/volume-${vol}.tar.gz" \
            && log "     OK" || log "     MISLUKT"
    done < <(podman volume ls --format "{{.Name}}" 2>/dev/null)

    # 3c. Back-up van alle images (voor het geval je ze niet opnieuw kunt pullen)
    log "Back-up van Podman images..."
    while IFS= read -r img; do
        [[ -z "${img}" ]] && continue
        safe_name=$(echo "${img}" | tr '/:' '__')
        log "  -> image: ${img}"
        podman save -o "${CONTAINER_DIR}/image-${safe_name}.tar" "${img}" 2>/dev/null \
            && log "     OK" || log "     MISLUKT"
    done < <(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v '<none>')

    # 3d. Back-up van container-configuratie (inspect JSON)
    log "Back-up van container inspect data..."
    while IFS= read -r ctr; do
        [[ -z "${ctr}" ]] && continue
        podman inspect "${ctr}" > "${CONTAINER_DIR}/inspect-${ctr}.json" 2>/dev/null
    done < <(podman ps -a --format "{{.Names}}" 2>/dev/null)

    # 3e. Kopieer compose-bestanden indien aanwezig
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "${f}" ]] && cp "${f}" "${CONTAINER_DIR}/" 2>/dev/null
    done

    log "Container back-up klaar in ${CONTAINER_DIR}"
}

# ==========================================================
# MAIN
# ==========================================================
main() {
    check_root
    mkdir -p "${BACKUP_BASE}" || die "Kan ${BACKUP_BASE} niet aanmaken"

    case "${1:-alles}" in
        documentatie) do_documentatie ;;
        backup)       do_backup ;;
        containers)   do_containers ;;
        alles)
            do_documentatie
            do_backup
            do_containers
            ;;
        *)
            echo "Gebruik: $0 [documentatie|backup|containers|alles]"
            exit 1
            ;;
    esac
    log "Klaar. Resultaten staan in ${BACKUP_BASE}"
}

main "$@"