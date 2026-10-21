#!/bin/bash
#
# server-toolkit.sh
# Doel: documentatie, back-up en container-inventarisatie voor SUSE Leap + Podman
# Gebruik: ./server-toolkit.sh [check|documentatie|backup|containers|opruimen|alles]
#

set -uo pipefail

# ---------- Configuratie ----------
BACKUP_BASE="/var/backups/server-toolkit"
DATUM=$(date +%Y%m%d-%H%M)
DOC_DIR="${BACKUP_BASE}/documentatie-${DATUM}"
CONTAINER_DIR="${BACKUP_BASE}/containers-${DATUM}"
BEWAAR_DAGEN=30   # retentie: back-ups ouder dan 30 dagen worden opgeruimd

# ---------- Hulpfuncties ----------
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FOUT: $*" >&2; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Dit script moet als root draaien (gebruik sudo)."
    fi
}

detect_root_fs() {
    findmnt -n -o FSTYPE / 2>/dev/null || echo "onbekend"
}

check_tools() {
    local missing=0
    for tool in supportconfig rear podman rsync; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "  [OK]          $tool"
        else
            echo "  [ONTBREEKT]   $tool"
            missing=1
        fi
    done

    local rootfs
    rootfs=$(detect_root_fs)
    if [[ "$rootfs" == "btrfs" ]]; then
        if command -v snapper >/dev/null 2>&1; then
            echo "  [OK]          snapper (root is Btrfs)"
        else
            echo "  [ONTBREEKT]   snapper (root is Btrfs, dus aanbevolen)"
            missing=1
        fi
    else
        echo "  [OVERgeslagen] snapper (root is ${rootfs}, geen Btrfs)"
    fi

    if [[ $missing -eq 1 ]]; then
        echo
        echo "Installeer ontbrekende tools met:"
        echo "  sudo zypper install supportutils rear podman rsync"
        return 1
    fi
    return 0
}

check_podman() {
    command -v podman >/dev/null 2>&1 || die "Podman niet gevonden."
}

# ==========================================================
# DEEL 1: DOCUMENTATIE
# ==========================================================
do_documentatie() {
    log "Start documentatie naar ${DOC_DIR}"
    mkdir -p "${DOC_DIR}" || die "Kan ${DOC_DIR} niet aanmaken"

    if command -v supportconfig >/dev/null 2>&1; then
        log "Draai supportconfig (kan enkele minuten duren)..."
        supportconfig -t "${DOC_DIR}/supportconfig" >/dev/null 2>&1 \
            && log "supportconfig archief aangemaakt" \
            || log "WAARSCHUWING: supportconfig gaf een fout"
    else
        log "WAARSCHUWING: supportconfig niet gevonden, sla over"
    fi

    log "Verzamel eigen inventarisatie..."
    {
        echo "===== SYSTEEM INFO ====="
        hostnamectl 2>/dev/null
        echo; echo "===== SUSE VERSIE ====="
        cat /etc/os-release
        echo; echo "===== KERNEL ====="
        uname -a
        echo; echo "===== ROOT BESTANDSSYSTEEM ====="
        findmnt / 2>/dev/null
        echo; echo "===== CPU ====="
        lscpu 2>/dev/null | head -20
        echo; echo "===== GEHEUGEN ====="
        free -h
        echo; echo "===== SCHIJVEN / FS ====="
        df -hT
        echo; echo "===== BLOCK DEVICES ====="
        lsblk -f 2>/dev/null
    } > "${DOC_DIR}/systeem-info.txt" 2>&1

    {
        echo "===== NETWERK INTERFACES ====="
        ip -brief address 2>/dev/null
        echo; echo "===== ROUTES ====="
        ip route 2>/dev/null
        echo; echo "===== DNS ====="
        cat /etc/resolv.conf 2>/dev/null
    } > "${DOC_DIR}/netwerk.txt" 2>&1

    {
        echo "===== DRAAIENDE SERVICES ====="
        systemctl list-units --type=service --state=running --no-pager 2>/dev/null
        echo; echo "===== ENABLED SERVICES ====="
        systemctl list-unit-files --state=enabled --no-pager 2>/dev/null
    } > "${DOC_DIR}/services.txt" 2>&1

    {
        echo "===== GEINSTALLEERDE PAKKETTEN ====="
        zypper se -i 2>/dev/null
    } > "${DOC_DIR}/pakketten.txt" 2>&1

    log "Kopieer /etc configuratiebestanden..."
    mkdir -p "${DOC_DIR}/etc"
    rsync -a --include='*/' --include='*.conf' --include='*.cfg' \
          --include='*.service' --include='*.yml' --include='*.yaml' \
          --exclude='*' /etc/ "${DOC_DIR}/etc/" 2>/dev/null \
        || cp -a /etc "${DOC_DIR}/etc_full" 2>/dev/null
    log "LET OP: ${DOC_DIR}/etc kan gevoelige info bevatten."

    log "Documentatie klaar in ${DOC_DIR}"
}

# ==========================================================
# DEEL 2: SYSTEEM BACK-UP
# ==========================================================
do_backup() {
    log "Start systeem-back-up"

    local rootfs
    rootfs=$(detect_root_fs)
    log "Root-bestandssysteem: ${rootfs}"

    if [[ "$rootfs" == "btrfs" ]]; then
        if command -v snapper >/dev/null 2>&1; then
            log "Maak Snapper momentopname..."
            snapper create --description "backup-${DATUM}" --cleanup-algorithm number \
                && log "Snapper momentopname gemaakt" \
                || log "WAARSCHUWING: Snapper momentopname mislukt"
        else
            log "WAARSCHUWING: Btrfs gedetecteerd maar snapper ontbreekt, sla over"
        fi
    else
        log "Root is ${rootfs}, geen Btrfs -> Snapper overgeslagen"
    fi

    if command -v rear >/dev/null 2>&1; then
        if [[ -f /etc/rear/local.conf ]]; then
            log "Start ReaR mkbackup (kan lang duren)..."
            rear mkbackup >> "${BACKUP_BASE}/rear-${DATUM}.log" 2>&1 \
                && log "ReaR back-up klaar" \
                || log "WAARSCHUWING: ReaR back-up mislukt, zie ${BACKUP_BASE}/rear-${DATUM}.log"
        else
            log "WAARSCHUWING: /etc/rear/local.conf ontbreekt, ReaR overgeslagen"
        fi
    else
        log "ReaR niet geïnstalleerd, overgeslagen"
    fi
}

# ==========================================================
# DEEL 3: PODMAN CONTAINER BACK-UP
# ==========================================================
do_containers() {
    check_podman
    log "Start container back-up naar ${CONTAINER_DIR}"
    mkdir -p "${CONTAINER_DIR}" || die "Kan ${CONTAINER_DIR} niet aanmaken"

    log "Inventariseer containers en images..."
    podman ps -a --format "{{.Names}}\t{{.Image}}\t{{.Status}}" \
        > "${CONTAINER_DIR}/containers-lijst.txt" 2>&1
    podman images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" \
        > "${CONTAINER_DIR}/images-lijst.txt" 2>&1
    podman volume ls --format "{{.Name}}\t{{.Driver}}" \
        > "${CONTAINER_DIR}/volumes-lijst.txt" 2>&1

    log "Back-up van Podman volumes..."
    while IFS= read -r vol; do
        [[ -z "${vol}" ]] && continue
        log "  -> volume: ${vol}"
        podman volume export "${vol}" 2>/dev/null \
            | gzip > "${CONTAINER_DIR}/volume-${vol}.tar.gz" \
            && log "     OK" || log "     MISLUKT"
    done < <(podman volume ls --format "{{.Name}}" 2>/dev/null)

    log "Back-up van Podman images..."
    while IFS= read -r img; do
        [[ -z "${img}" ]] && continue
        safe_name=$(echo "${img}" | tr '/:' '__')
        log "  -> image: ${img}"
        podman save -o "${CONTAINER_DIR}/image-${safe_name}.tar" "${img}" 2>/dev/null \
            && log "     OK" || log "     MISLUKT"
    done < <(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v '<none>')

    log "Back-up van container inspect data..."
    while IFS= read -r ctr; do
        [[ -z "${ctr}" ]] && continue
        podman inspect "${ctr}" > "${CONTAINER_DIR}/inspect-${ctr}.json" 2>/dev/null
    done < <(podman ps -a --format "{{.Names}}" 2>/dev/null)

    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "${f}" ]] && cp "${f}" "${CONTAINER_DIR}/" 2>/dev/null
    done

    log "Container back-up klaar in ${CONTAINER_DIR}"
}

# ==========================================================
# DEEL 4: OPRUIMEN (retentie 30 dagen)
# ==========================================================
do_opruimen() {
    log "Opruimen: back-ups ouder dan ${BEWAAR_DAGEN} dagen verwijderen"

    # Veiligheidscheck: alleen opruimen als er een recente back-up bestaat
    local nieuwste
    nieuwste=$(find "${BACKUP_BASE}" -maxdepth 1 -mindepth 1 -type d \
        -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]*' \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)

    if [[ -z "${nieuwste}" ]]; then
        log "Geen back-ups gevonden, niets op te ruimen"
        return
    fi

    # Controleer of de nieuwste back-up niet ouder is dan 2 dagen
    if [[ $(find "${nieuwste}" -maxdepth 0 -mtime +2 2>/dev/null) ]]; then
        log "WAARSCHUWING: nieuwste back-up is ouder dan 2 dagen (${nieuwste})"
        log "Opruimen overgeslagen om geen goede back-up te verliezen"
        return
    fi

    # Verzamel kandidaten (dry-run eerst)
    local kandidaten
    kandidaten=$(find "${BACKUP_BASE}" -maxdepth 1 -mindepth 1 \
        -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]*' \
        -mtime +"${BEWAAR_DAGEN}" 2>/dev/null)

    if [[ -z "${kandidaten}" ]]; then
        log "Geen back-ups ouder dan ${BEWAAR_DAGEN} dagen, niets te doen"
        return
    fi

    log "De volgende items worden verwijderd:"
    echo "${kandidaten}" | while read -r item; do
        log "  - ${item}"
    done

    # Daadwerkelijk verwijderen
    echo "${kandidaten}" | while read -r item; do
        rm -rf "${item}" && log "  verwijderd: ${item}" \
            || log "  MISLUKT: ${item}"
    done

    log "Opruimen klaar"
}

# ==========================================================
# MAIN
# ==========================================================
main() {
    check_root
    mkdir -p "${BACKUP_BASE}" || die "Kan ${BACKUP_BASE} niet aanmaken"

    case "${1:-alles}" in
        check)
            log "Controleren van benodigde tools (root-fs: $(detect_root_fs)):"
            check_tools
            ;;
        documentatie) do_documentatie ;;
        backup)       do_backup ;;
        containers)   do_containers ;;
        opruimen)     do_opruimen ;;
        alles)
            check_tools || die "Installeer eerst de ontbrekende tools."
            do_documentatie
            do_backup
            do_containers
            do_opruimen
            ;;
        *)
            echo "Gebruik: $0 [check|documentatie|backup|containers|opruimen|alles]"
            exit 1
            ;;
    esac
    log "Klaar. Resultaten staan in ${BACKUP_BASE}"
}

main "$@"