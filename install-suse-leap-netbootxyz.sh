#!/usr/bin/env bash
# =============================================================================
#  NETBOOT STACK INSTALLER VOOR OPENSUSE LEAP  (v3.6)
# =============================================================================
#
#  @bestand   netboot-stack-installer.sh
#  @versie    3.6.0
#  @datum     2026-10-14       (statisch; commentaar wordt NIET uitgevoerd)
#  @doel      Installeert een complete netboot-stack op een schone openSUSE
#             Leap-server met behoud van de bestaande Fritzbox-DHCP.
#
# -----------------------------------------------------------------------------
#  GETEST OP
# -----------------------------------------------------------------------------
#   * openSUSE Leap 15.5   (schone installatie, BIOS-client)
#   * openSUSE Leap 15.6   (schone installatie, BIOS- en UEFI-client)
#
#  NIET GETEST OP (gebruik op eigen risico):
#   * openSUSE Tumbleweed, MicroOS, SLES 15.x, Leap 15.4 en ouder
#
#  Laatste praktijktest: zie changelog. Voer dit script ALTIJD eerst uit op
#  een schone testinstallatie en valideer met een echte BIOS- én UEFI-client
#  voordat je het op productie loslaat.
#
# -----------------------------------------------------------------------------
#  HERHAALBAARHEID EN ROLLBACK
# -----------------------------------------------------------------------------
#   * Bestaande configuraties krijgen een tijdgestempelde back-up.
#   * Rollback-acties zijn getypeerd (restore_file, remove_path,
#     restore_service, reload_firewall, daemon_reload) en worden via een
#     case-dispatcher uitgevoerd — geen eval, geen shell-injectie.
#   * Service-state (enabled/active) wordt vastgelegd VÓÓR wijziging.
#     Rollback herstelt uitsluitend wijzigingen die deze run zelf heeft
#     aangebracht; al draaiende services worden niet uitgeschakeld.
#   * Fatale fouten gaan via die() → rollback is gegarandeerd.
#
# -----------------------------------------------------------------------------
#  WAT DIT SCRIPT INSTALLEERT
# -----------------------------------------------------------------------------
#   1. dnsmasq          - Proxy-DHCP (GEEN IP-uitgifte, GEEN TFTP)
#   2. netboot.xyz      - TFTP + HTTP boot-server (Podman, host-network)
#   3. DokuWiki         - Documentatie-wiki (Podman)
#   4. Forgejo          - Git-forge (Podman)
#   5. Cockpit          - Beheer-dashboard (host service, poort 9003)
#
# -----------------------------------------------------------------------------
#  ONTWERPBESLISSINGEN
# -----------------------------------------------------------------------------
#   1. Proxy-DHCP: dnsmasq geeft GEEN IP's uit; Fritzbox blijft enige DHCP.
#   2. dnsmasq doet GEEN TFTP — dat doet de netboot.xyz container.
#   3. netboot.xyz draait met Network=host.
#   4. Quadlet in plaats van `podman generate systemd`.
#   5. Expliciet server-IP in pxe-service (workaround Fritzbox).
#   6. Netwerkberekening: ipcalc als primair (met correcte awk-extractie),
#      pure bash als fallback. ipcalc is geen harde prerequisite.
#   7. Interfacekeuze expliciet; geen aanname op basis van default route.
#   8. firewalld geactiveerd; interface MOET een expliciete zone hebben.
#   9. Rollback via getypeerde dispatcher; service-state hersteld.
#  10. Container-images vastgezet op expliciete versietags.
#  11. Exit-status is beslissend: exit 0 (succes) of exit 1 (fout).
#  12. dnsmasq configuratie op vier niveaus geverifieerd.
#  13. Containers krijgen een wachttijd van 90s vóór het eindoordeel.
#  14. Eindcontrole omvat TFTP-bestandstest én HTTP-body-test.
#  15. Cockpit draait zonder aanname van een reverse proxy.
#
# -----------------------------------------------------------------------------
#  VEREISTEN
# -----------------------------------------------------------------------------
#   * openSUSE Leap 15.5 of nieuwer
#   * Root-toegang
#   * Minimaal 2 GB RAM, 20 GB vrije schijfruimte
#   * Internettoegang voor packages en container-images
#   * Server in hetzelfde L2-segment als de PXE-clients
#   * De gekozen interface MOET een expliciete firewalld-zone hebben
#
# -----------------------------------------------------------------------------
#  POORTENOVERZICHT
# -----------------------------------------------------------------------------
#   67/UDP   dnsmasq       Proxy-DHCP             (PXE-kritiek)
#   69/UDP   netboot.xyz   TFTP                   (PXE-kritiek)
#   80/TCP   netboot.xyz   HTTP (iPXE)            (PXE-kritiek)
#   4011/UDP dnsmasq       Alternatieve PXE       (PXE-kritiek)
#   2002/TCP Forgejo       Git SSH                (beheer)
#   9000/TCP netboot.xyz   Web UI                 (beheer)
#   9001/TCP DokuWiki      Webinterface           (beheer)
#   9002/TCP Forgejo       HTTP                   (beheer)
#   9003/TCP Cockpit       Dashboard              (beheer)
#
# -----------------------------------------------------------------------------
#  GEBRUIK
# -----------------------------------------------------------------------------
#   sudo ./netboot-stack-installer.sh
#
#  Exit-code:  0   = volledig geslaagd
#              1   = niet (volledig) geslaagd — zie log
#              130 = onderbroken door gebruiker
#
# -----------------------------------------------------------------------------
#  CONTAINER-IMAGES (VASTGEZET)
# -----------------------------------------------------------------------------
#  Pas de tags aan naar de actuele stabiele versie vóór productiegebruik.
#    skopeo list-tags docker://ghcr.io/netbootxyz/netbootxyz
#    skopeo list-tags docker://docker.io/dokuwiki/dokuwiki
#    skopeo list-tags docker://codeberg.org/forgejo/forgejo
#
# -----------------------------------------------------------------------------
#  NA INSTALLATIE
# -----------------------------------------------------------------------------
#   1. Zet het server-IP vast in de Fritzbox (DHCP-reservering).
#   2. Test TFTP:  tftp <server-ip> -c get netboot.xyz.kpxe /tmp/test.kpxe
#   3. Test PXE-boot vanaf een BIOS-client én een UEFI-client.
#   4. Beheer:     https://<server-ip>:9003
#
# -----------------------------------------------------------------------------
#  TROUBLESHOOTING
# -----------------------------------------------------------------------------
#   "TFTP timeout"       → ss -ulnp | grep :69 ; podman logs netbootxyz
#   "no boot filename"   → journalctl -u dnsmasq -f
#   Client boot van Fritzbox-IP → pxe-service regel eindigt met ,$SERVER_IP
#   Container start niet → systemctl status <naam> ; podman logs <naam>
#   Zone ontbreekt       → firewall-cmd --permanent --zone=public \
#                            --add-interface=<iface> && firewall-cmd --reload
#
# -----------------------------------------------------------------------------
#  CHANGELOG
# -----------------------------------------------------------------------------
#  3.6.0 - Deze versie:
#          * validate_interface(): ipcalc-extractie gecorrigeerd naar
#            `awk '/^Netmask:/ {print $2}'` en `awk '/^Network:/ ...'`,
#            met pure-bash als fallback (punt 1).
#          * Rollback: dispatcher met getypeerde acties; geen eval meer;
#            service-state wordt vastgelegd vóór wijziging; bestaande
#            services worden niet uitgeschakeld bij rollback (punt 2).
#          * verify_installation(): TFTP-bestandstest voor netboot.xyz.kpxe
#            en netboot.xyz.efi, plus HTTP-body-controle (punt 3).
#  3.5.0 - Pure-bash netwerkberekening; firewall-XML herstel; SERVICE_STATE;
#          die() forceert rollback; vier dnsmasq-checks; zone verplicht.
#  3.4.0 - Tijdgestempelde back-ups; ProtocolHeader verwijderd;
#          interfacekeuze via ip link show; dnsmasq include geverifieerd;
#          containers START_FAILED-flag; firewall via firewall-cmd --state.
#  3.3.0 - Interfacekeuze expliciet; firewalld verplicht; eindcontrole
#          beslissend; documentatie "Getest op".
#  3.2.0 - Prerequisites vóór alle stappen; wachttijd containers;
#          image-tags gepind + remote verificatie.
#  3.1.0 - Verificatie, image-pinning, documentatie bijgewerkt.
#  3.0.0 - Herschrijving: interfacekeuze, firewall zones, rollback, traps.
#  2.0.0 - Initiële versie (niet in productie gebruiken).
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
#  CONSTANTEN
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.6.0"
readonly LOG_FILE="/var/log/netboot-stack-install.log"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly DNSMASQ_CONF_DIR="/etc/dnsmasq.d"
readonly DNSMASQ_CONF="${DNSMASQ_CONF_DIR}/netboot.conf"

readonly NETBOOT_TFTP_PORT=69
readonly NETBOOT_HTTP_PORT=80
readonly NETBOOT_WEB_PORT=9000
readonly DOKUWIKI_PORT=9001
readonly FORGEJO_HTTP_PORT=9002
readonly FORGEJO_SSH_PORT=2002
readonly COCKPIT_PORT=9003

readonly NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:0.7.5"
readonly DOKUWIKI_IMAGE="docker.io/dokuwiki/dokuwiki:2024-02-06b"
readonly FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:12.0.1"

readonly TFTP_DIR="/srv/tftp"
readonly NETBOOT_CONFIG_DIR="/srv/netboot-config"
readonly DOKUWIKI_DATA_DIR="/srv/dokuwiki/data"
readonly FORGEJO_DATA_DIR="/srv/forgejo/data"

readonly CONTAINER_START_TIMEOUT=90

declare -a RB_TYPE=() RB_ARG1=() RB_ARG2=()
declare -A SERVICE_STATE=()
ROLLBACK_DONE=0

# =============================================================================
#  KLEUREN & LOGGING
# =============================================================================

if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${msg}"
    case "$level" in
        INFO)  echo -e "${C_BLUE}${line}${C_RESET}" ;;
        OK)    echo -e "${C_GREEN}${line}${C_RESET}" ;;
        WARN)  echo -e "${C_YELLOW}${line}${C_RESET}" >&2 ;;
        ERROR) echo -e "${C_RED}${line}${C_RESET}" >&2 ;;
        *)     echo "$line" ;;
    esac
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info()  { _log INFO  "$@"; }
ok()    { _log OK    "$@"; }
warn()  { _log WARN  "$@"; }
error() { _log ERROR "$@"; }

# =============================================================================
#  ROLLBACK — GETYPEERDE ACTIES (geen eval)
# =============================================================================

register_rollback_file()         { RB_TYPE+=("restore_file");       RB_ARG1+=("$1"); RB_ARG2+=("$2"); }
register_rollback_remove()       { RB_TYPE+=("remove_path");        RB_ARG1+=("$1"); RB_ARG2+=("");   }
register_rollback_service()      { RB_TYPE+=("restore_service");    RB_ARG1+=("$1"); RB_ARG2+=("");   }
register_rollback_reload_fw()    { RB_TYPE+=("reload_firewall");    RB_ARG1+=("");   RB_ARG2+=("");   }
register_rollback_daemon_reload(){ RB_TYPE+=("daemon_reload");      RB_ARG1+=("");   RB_ARG2+=("");   }

record_service_state() {
    local svc="$1" was_enabled=0 was_active=0
    systemctl is-enabled --quiet "$svc" 2>/dev/null && was_enabled=1
    systemctl is-active  --quiet "$svc" 2>/dev/null && was_active=1
    SERVICE_STATE["$svc"]="$was_enabled:$was_active"
    info "  State ${svc}: enabled=${was_enabled} active=${was_active}"
}

restore_service_state() {
    local svc="$1" state="${SERVICE_STATE[$svc]:-}"
    [[ -z "$state" ]] && return 0
    local was_enabled="${state%:*}" was_active="${state#*:}"
    if (( was_enabled == 0 )); then
        systemctl disable "$svc" 2>/dev/null || true
    fi
    if (( was_active == 0 )); then
        systemctl stop "$svc" 2>/dev/null || true
    fi
}

perform_rollback() {
    (( ROLLBACK_DONE == 1 )) && return 0
    ROLLBACK_DONE=1
    if (( ${#RB_TYPE[@]} == 0 )); then
        info "Geen rollback-acties geregistreerd."; return 0
    fi
    info "Rollback gestart (${#RB_TYPE[@]} acties)..."
    local idx
    for (( idx=${#RB_TYPE[@]}-1; idx>=0; idx-- )); do
        local t="${RB_TYPE[$idx]}" a1="${RB_ARG1[$idx]}" a2="${RB_ARG2[$idx]}"
        case "$t" in
            restore_file)
                if [[ -f "$a2" ]]; then
                    cp -a "$a2" "$a1" && info "  Bestand hersteld: $a1"
                fi ;;
            remove_path)
                if [[ -d "$a1" ]]; then
                    rmdir "$a1" 2>/dev/null && info "  Map verwijderd: $a1"
                elif [[ -e "$a1" ]]; then
                    rm -f "$a1" && info "  Bestand verwijderd: $a1"
                fi ;;
            restore_service)
                info "  Service-state herstellen: $a1"
                restore_service_state "$a1" ;;
            reload_firewall)
                firewall-cmd --reload >/dev/null 2>&1 && info "  firewall herladen" ;;
            daemon_reload)
                systemctl daemon-reload && info "  systemd daemon-reload" ;;
            *)
                warn "  Onbekende rollback-actie: $t" ;;
        esac
    done
    RB_TYPE=(); RB_ARG1=(); RB_ARG2=()
    ok "Rollback voltooid."
}

die() {
    error "$@"
    perform_rollback
    exit 1
}

_on_error() {
    local exit_code=$?
    local line_no=${1:-?}
    error "Fout opgetreden op regel ${line_no} (exit ${exit_code})."
    perform_rollback
    error "Installatie afgebroken. Zie ${LOG_FILE}."
    exit "$exit_code"
}

_on_interrupt() {
    error "Installatie onderbroken door gebruiker."
    perform_rollback
    exit 130
}

trap '_on_error $LINENO' ERR
trap '_on_interrupt' INT TERM

# =============================================================================
#  HULPFUNCTIES
# =============================================================================

command_exists() { command -v "$1" >/dev/null 2>&1; }

backup_or_register_new() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        register_rollback_file "$file" "$backup"
        info "  Back-up gemaakt: $backup"
    else
        register_rollback_remove "$file"
    fi
}

# =============================================================================
#  PURE-BASH NETWERKBERekENING (fallback)
# =============================================================================

prefix_to_netmask() {
    local prefix=$1
    local -a octets=()
    local i
    for i in 1 2 3 4; do
        if   (( prefix >= 8 )); then octets+=(255); (( prefix -= 8 ))
        elif (( prefix <= 0 )); then octets+=(0)
        else octets+=($(( 256 - (1 << (8 - prefix)) ))); prefix=0
        fi
    done
    local IFS=.
    echo "${octets[*]}"
}

ip_to_int() {
    local IFS=.
    local -a o=($1)
    echo $(( (o[0]<<24) + (o[1]<<16) + (o[2]<<8) + o[3] ))
}

int_to_ip() {
    local n=$1
    echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"
}

calculate_network() {
    local ip="$1" prefix="$2"
    local ip_int mask_int
    ip_int=$(ip_to_int "$ip")
    mask_int=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    int_to_ip $(( ip_int & mask_int ))
}

# =============================================================================
#  PREREQUISITE CHECKS
# =============================================================================

require_root() {
    [[ $EUID -eq 0 ]] || { error "Voer dit script uit als root (sudo $0)."; exit 1; }
}

require_opensuse_leap() {
    [[ -f /etc/os-release ]] || { error "/etc/os-release niet gevonden."; exit 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "opensuse-leap" ]] || {
        error "Alleen openSUSE Leap wordt ondersteund (gevonden: ${ID:-onbekend})."
        exit 1
    }
    ok "Distro: ${PRETTY_NAME:-openSUSE Leap}"
}

require_systemd() { command_exists systemctl || { error "systemd vereist."; exit 1; }; }
require_zypper()  { command_exists zypper    || { error "zypper vereist.";  exit 1; }; }

# =============================================================================
#  STAP 0 — PREREQUISITES + IMAGE TAGS
# =============================================================================

install_prerequisites() {
    info "[0/9] Prerequisites controleren..."
    if ! command_exists skopeo; then
        info "  skopeo installeren..."
        zypper --non-interactive install --no-recommends skopeo \
            || die "Installatie van skopeo mislukt."
    fi
    command_exists skopeo || die "skopeo ontbreekt na installatie."
    ok "  Prerequisites aanwezig: skopeo."

    if ! command_exists ipcalc; then
        info "  ipcalc installeren (voor netwerkberekening)..."
        zypper --non-interactive install --no-recommends ipcalc >/dev/null 2>&1 \
            || warn "  ipcalc niet geïnstalleerd — pure-bash fallback wordt gebruikt."
    fi
}

verify_image_tags() {
    info "[0b/9] Container-image tags verifiëren..."
    local image
    for image in "$NETBOOT_IMAGE" "$DOKUWIKI_IMAGE" "$FORGEJO_IMAGE"; do
        if skopeo inspect "docker://${image}" >/dev/null 2>&1; then
            ok "  Tag bestaat: ${image}"
        else
            die "Tag NIET gevonden: ${image}"
        fi
    done
}

# =============================================================================
#  STAP 1 — NETWERKDETECTIE EN INTERFACEKEUZE
# =============================================================================

choose_interface() {
    info "Beschikbare netwerkinterfaces:"
    echo
    ip -br -4 addr
    echo
    read -rp "Welke interface is aangesloten op het PXE-netwerk? " SELECTED_IFACE
    if [[ -z "$SELECTED_IFACE" ]] || ! ip link show "$SELECTED_IFACE" &>/dev/null; then
        die "Ongeldige netwerkinterface: '${SELECTED_IFACE}'"
    fi
    ok "Gekozen interface: ${SELECTED_IFACE}"
}

validate_interface() {
    local iface="$1"

    SELECTED_IP="$(ip -o -4 addr show dev "$iface" scope global \
        | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    local cidr
    cidr="$(ip -o -4 addr show dev "$iface" scope global \
        | awk 'NR==1 {print $4}')"

    [[ -n "$SELECTED_IP" && -n "$cidr" ]] || die "Geen IPv4-adres op ${iface}."

    local prefix="${cidr#*/}"
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 1 || prefix > 32 )); then
        die "Ongeldige prefix in CIDR: ${cidr}"
    fi

    # --- Primaire methode: ipcalc (correcte extractie) ---
    local netmask="" network=""
    if command_exists ipcalc; then
        netmask="$(ipcalc -m "$cidr" | awk '/^Netmask:/ {print $2}')"
        network="$(ipcalc -n "$cidr" | awk '/^Network:/ {print $2}' | cut -d/ -f1)"
    fi

    # --- Fallback: pure bash ---
    if [[ -z "$netmask" ]]; then
        netmask="$(prefix_to_netmask "$prefix")"
        info "  Netmasker via pure-bash fallback: ${netmask}"
    fi
    if [[ -z "$network" ]]; then
        network="$(calculate_network "$SELECTED_IP" "$prefix")"
        info "  Netwerkadres via pure-bash fallback: ${network}"
    fi

    [[ -n "$netmask" && -n "$network" ]] \
        || die "Netwerkadres of netmasker kon niet worden berekend."

    local gateway
    gateway="$(ip route show default dev "$iface" 2>/dev/null \
        | awk '/default/ {print $3; exit}')"

    echo
    info "Netwerkconfiguratie van ${iface}:"
    printf "  %-14s %s\n" "Interface:"    "$iface"
    printf "  %-14s %s\n" "Server-IP:"    "$SELECTED_IP"
    printf "  %-14s %s\n" "CIDR:"         "$cidr"
    printf "  %-14s %s\n" "Netwerkadres:" "$network"
    printf "  %-14s %s\n" "Netmasker:"    "$netmask"
    printf "  %-14s %s\n" "Gateway:"      "${gateway:-<geen op deze interface>}"
    echo

    local confirm
    read -rp "Klopt deze configuratie voor het PXE-netwerk? (j/n) " confirm
    [[ "$confirm" =~ ^[jJ]$ ]] || die "Installatie afgebroken."

    SELECTED_PREFIX="$prefix"
    SELECTED_NETWORK="$network"
    SELECTED_NETMASK="$netmask"
    SELECTED_GATEWAY="${gateway:-}"
    ok "Netwerkconfiguratie gevalideerd."
}

# =============================================================================
#  STAP 2 — PRE-FLIGHT
# =============================================================================

check_port_80() {
    info "Controleren of poort ${NETBOOT_HTTP_PORT}/TCP vrij is..."
    if ss -tlnp 2>/dev/null | grep -q ":${NETBOOT_HTTP_PORT} "; then
        warn "Poort ${NETBOOT_HTTP_PORT}/TCP is al in gebruik:"
        ss -tlnp | grep ":${NETBOOT_HTTP_PORT} " >&2
        echo
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        [[ "$cont" =~ ^[jJ]$ ]] || die "Afgebroken."
    else
        ok "  Poort ${NETBOOT_HTTP_PORT}/TCP is vrij."
    fi
}

# =============================================================================
#  STAP 3 — PACKAGES
# =============================================================================

install_packages() {
    info "[1/9] Pakketten installeren..."
    local packages=(cockpit cockpit-podman podman dnsmasq firewalld curl)
    if ! zypper --non-interactive install --no-recommends "${packages[@]}"; then
        die "Installatie van pakketten mislukt."
    fi
    ok "Pakketten geïnstalleerd."
}

# =============================================================================
#  STAP 4 — COCKPIT
# =============================================================================

configure_cockpit() {
    info "[2/9] Cockpit configureren op poort ${COCKPIT_PORT}..."

    local override_dir="/etc/systemd/system/cockpit.socket.d"
    mkdir -p "$override_dir"
    local override_file="${override_dir}/override.conf"
    backup_or_register_new "$override_file"
    cat > "$override_file" <<EOF
[Socket]
ListenStream=
ListenStream=${COCKPIT_PORT}
FreeBind=yes
EOF

    local cockpit_conf="/etc/cockpit/cockpit.conf"
    mkdir -p "$(dirname "$cockpit_conf")"
    backup_or_register_new "$cockpit_conf"
    cat > "$cockpit_conf" <<EOF
[WebService]
Origins = https://${SELECTED_IP}:${COCKPIT_PORT} wss://${SELECTED_IP}:${COCKPIT_PORT}
EOF

    if command_exists getenforce; then
        local status; status="$(getenforce 2>/dev/null || echo Disabled)"
        if [[ "$status" == "Enforcing" ]]; then
            semanage port -a -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                semanage port -m -t websm_port_t -p tcp "$COCKPIT_PORT" 2>/dev/null || \
                warn "  SELinux-poort niet aangepast."
        fi
    fi

    record_service_state cockpit.socket
    register_rollback_service cockpit.socket
    register_rollback_daemon_reload

    systemctl daemon-reload
    systemctl enable --now cockpit.socket || die "Cockpit kon niet worden gestart."
    ok "Cockpit actief op poort ${COCKPIT_PORT}."
}

# =============================================================================
#  STAP 5 — MAPPEN
# =============================================================================

create_directories() {
    info "[3/9] Mappenstructuur aanmaken..."
    local dirs=("$TFTP_DIR" "$NETBOOT_CONFIG_DIR" "$DOKUWIKI_DATA_DIR" "$FORGEJO_DATA_DIR")
    local d
    for d in "${dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            mkdir -p "$d"
            register_rollback_remove "$d"
        fi
    done
    chown -R 33:33     "$DOKUWIKI_DATA_DIR" 2>/dev/null || true
    chown -R 1000:1000 "$FORGEJO_DATA_DIR"  2>/dev/null || true
    ok "Mappen aangemaakt en rechten ingesteld."
}

# =============================================================================
#  STAP 6 — DNSMASQ
# =============================================================================

verify_dnsmasq_effective_config() {
    grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq\.d([,/[:space:]]|$)' /etc/dnsmasq.conf \
        || die "/etc/dnsmasq.conf leest /etc/dnsmasq.d niet in."
    ok "  /etc/dnsmasq.conf bevat conf-dir=/etc/dnsmasq.d/."

    [[ -f "$DNSMASQ_CONF" ]] || die "$DNSMASQ_CONF bestaat niet."
    [[ "$DNSMASQ_CONF" == *.conf ]] || die "$DNSMASQ_CONF matcht *.conf niet."

    dnsmasq --test >/dev/null 2>&1 \
        || { error "dnsmasq --test faalde:"; dnsmasq --test 2>&1 >&2; die "hoofdconfig ongeldig."; }
    ok "  dnsmasq hoofdconfiguratie geldig."

    dnsmasq --test -C "$DNSMASQ_CONF" >/dev/null 2>&1 \
        || { error "dnsmasq --test -C faalde:"; dnsmasq --test -C "$DNSMASQ_CONF" 2>&1 >&2; die "$DNSMASQ_CONF ongeldig."; }
    ok "  $DNSMASQ_CONF is syntactisch geldig."
}

configure_dnsmasq() {
    info "[4/9] dnsmasq configureren als proxy-DHCP..."

    mkdir -p "$DNSMASQ_CONF_DIR"
    backup_or_register_new "$DNSMASQ_CONF"

    cat > "$DNSMASQ_CONF" <<EOF
# =============================================================================
# Proxy-DHCP voor netboot.xyz  (gegenereerd door ${SCRIPT_NAME} v${SCRIPT_VERSION})
# =============================================================================
interface=${SELECTED_IFACE}
bind-dynamic
log-dhcp
dhcp-range=${SELECTED_NETWORK},proxy,${SELECTED_NETMASK}
pxe-service=x86PC,      "NETBOOT (BIOS)", "netboot.xyz.kpxe", ${SELECTED_IP}
pxe-service=X86-64_EFI, "NETBOOT (EFI)",  "netboot.xyz.efi",  ${SELECTED_IP}
# GEEN enable-tftp: TFTP wordt door de netboot.xyz container afgehandeld.
EOF

    verify_dnsmasq_effective_config

    record_service_state dnsmasq
    register_rollback_service dnsmasq

    if ! systemctl enable --now dnsmasq; then
        error "dnsmasq kon niet worden gestart."
        journalctl -u dnsmasq -n 50 --no-pager
        die "dnsmasq start mislukt."
    fi
    systemctl is-active --quiet dnsmasq || die "dnsmasq is niet actief na starten."
    ok "dnsmasq actief als proxy-DHCP op ${SELECTED_IFACE}."
}

# =============================================================================
#  STAP 7 — FIREWALL
# =============================================================================

ensure_firewalld() {
    info "[4b/9] firewalld controleren en activeren..."

    record_service_state firewalld
    register_rollback_service firewalld

    if ! systemctl enable --now firewalld; then
        error "firewalld kon niet worden gestart."
        journalctl -u firewalld -n 30 --no-pager
        die "firewalld start mislukt."
    fi
    firewall-cmd --state >/dev/null 2>&1 || die "firewalld is niet actief."
    ok "  firewalld actief en enabled."
}

configure_firewall() {
    info "[5/9] Firewall configureren..."

    local zone
    zone="$(firewall-cmd --get-zone-of-interface="$SELECTED_IFACE" 2>/dev/null)"

    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
        error "Interface ${SELECTED_IFACE} is niet aan een firewalld-zone toegewezen."
        error "Wijs eerst een zone toe:"
        error "  firewall-cmd --permanent --zone=public --add-interface=${SELECTED_IFACE}"
        error "  firewall-cmd --reload"
        die "Geen expliciete firewalld-zone voor ${SELECTED_IFACE}."
    fi
    ok "Zone voor ${SELECTED_IFACE}: ${zone}"

    if [[ "$zone" == "trusted" ]]; then
        warn "Zone 'trusted' opent ALLE poorten voor dit netwerk."
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        [[ "$cont" =~ ^[jJ]$ ]] || die "Afgebroken."
    fi

    warn "Beheerpoorten (9000-9003, 2002) worden op de PXE-interface geopend."

    local zone_file="/etc/firewalld/zones/${zone}.xml"
    if [[ -f "$zone_file" ]]; then
        local backup="${zone_file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$zone_file" "$backup"
        register_rollback_file "$zone_file" "$backup"
        register_rollback_reload_fw
        info "  Back-up zone-XML: $backup"
    fi

    # PXE-kritieke poorten
    firewall-cmd --permanent --zone="$zone" --add-service=dhcp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-service=tftp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port=4011/udp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_HTTP_PORT}/tcp" >/dev/null

    # Beheer-poorten
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_WEB_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${DOKUWIKI_PORT}/tcp"     >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_SSH_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${COCKPIT_PORT}/tcp"      >/dev/null

    firewall-cmd --reload || die "Firewall kon niet worden herladen."
    ok "Firewallregels toegepast op zone '${zone}'."
}

# =============================================================================
#  STAP 8 — QUADLET
# =============================================================================

create_quadlet_units() {
    info "[6/9] Quadlet-units aanmaken..."
    mkdir -p "$QUADLET_DIR"

    local unit_netboot="${QUADLET_DIR}/netbootxyz.container"
    backup_or_register_new "$unit_netboot"
    cat > "$unit_netboot" <<EOF
[Unit]
Description=netboot.xyz (TFTP + HTTP)
Documentation=https://netboot.xyz
After=network-online.target
Wants=network-online.target

[Container]
Image=${NETBOOT_IMAGE}
ContainerName=netbootxyz
Network=host
Volume=${TFTP_DIR}:/assets:Z
Volume=${NETBOOT_CONFIG_DIR}:/config:Z
Environment=TFTPD_OPTS=--tftp-single-port
Environment=WEB_APP_PORT=${NETBOOT_WEB_PORT}
Environment=NGINX_PORT=${NETBOOT_HTTP_PORT}

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    local unit_doku="${QUADLET_DIR}/dokuwiki.container"
    backup_or_register_new "$unit_doku"
    cat > "$unit_doku" <<EOF
[Unit]
Description=DokuWiki
Documentation=https://www.dokuwiki.org
After=network-online.target
Wants=network-online.target

[Container]
Image=${DOKUWIKI_IMAGE}
ContainerName=dokuwiki
PublishPort=${DOKUWIKI_PORT}:80
Volume=${DOKUWIKI_DATA_DIR}:/storage:Z

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    local unit_forgejo="${QUADLET_DIR}/forgejo.container"
    backup_or_register_new "$unit_forgejo"
    cat > "$unit_forgejo" <<EOF
[Unit]
Description=Forgejo
Documentation=https://forgejo.org
After=network-online.target
Wants=network-online.target

[Container]
Image=${FORGEJO_IMAGE}
ContainerName=forgejo
PublishPort=${FORGEJO_HTTP_PORT}:3000
PublishPort=${FORGEJO_SSH_PORT}:22
Volume=${FORGEJO_DATA_DIR}:/data:Z
Environment=USER_UID=1000
Environment=USER_GID=1000

[Service]
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    ok "Quadlet-units aangemaakt."
}

# =============================================================================
#  STAP 9 — CONTAINERS STARTEN
# =============================================================================

wait_for_service() {
    local svc="$1" timeout="${2:-$CONTAINER_START_TIMEOUT}" waited=0
    while (( waited < timeout )); do
        systemctl is-active --quiet "$svc" && return 0
        sleep 3; (( waited += 3 ))
    done
    return 1
}

start_containers() {
    info "[7/9] Containers starten (max ${CONTAINER_START_TIMEOUT}s elk)..."
    systemctl daemon-reload
    register_rollback_daemon_reload

    local START_FAILED=0 ctr
    for ctr in netbootxyz dokuwiki forgejo; do
        record_service_state "${ctr}.service"
        register_rollback_service "${ctr}.service"

        if ! systemctl enable --now "${ctr}.service" 2>/dev/null; then
            error "  ${ctr}: starten mislukt."
            journalctl -u "${ctr}.service" -n 30 --no-pager
            START_FAILED=1
            continue
        fi
        if wait_for_service "${ctr}.service" "$CONTAINER_START_TIMEOUT"; then
            ok "  ${ctr}: actief."
        else
            error "  ${ctr}: niet actief na ${CONTAINER_START_TIMEOUT}s."
            journalctl -u "${ctr}.service" -n 30 --no-pager
            START_FAILED=1
        fi
    done

    if (( START_FAILED != 0 )); then
        die "Een of meer containers konden niet worden gestart."
    fi
}

# =============================================================================
#  STAP 10 — EINDCONTROLES (uitgebreid)
# =============================================================================

verify_installation() {
    info "[8/9] Eindcontroles uitvoeren..."
    local FAILED=0

    local svc
    for svc in dnsmasq cockpit.socket firewalld netbootxyz dokuwiki forgejo; do
        if systemctl is-active --quiet "$svc"; then
            ok "  $svc: actief"
        else
            error "  $svc: NIET actief"
            FAILED=1
        fi
    done

    dnsmasq --test >/dev/null 2>&1 \
        || { error "  dnsmasq --test: configuratie ongeldig."; FAILED=1; }

    ss -ulnp 2>/dev/null | grep -qE '(:|\])69[[:space:]]' \
        || { error "  Geen luisterende TFTP-service op UDP-poort 69."; FAILED=1; }

    ss -tlnp 2>/dev/null | grep -qE '(:|\])80[[:space:]]' \
        || { error "  Geen luisterende HTTP-service op TCP-poort 80."; FAILED=1; }

    # HTTP body-test
    local body
    if body="$(curl -fsS --max-time 5 "http://127.0.0.1/")" && [[ -n "$body" ]]; then
        ok "  HTTP: root geeft niet-lege body ($(wc -c <<<"$body" | tr -d ' ') bytes)."
    else
        error "  HTTP: root geeft leeg antwoord."
        FAILED=1
    fi

    # TFTP-test voor beide boot-bestanden
    local f tmp
    tmp="$(mktemp)"
    for f in netboot.xyz.kpxe netboot.xyz.efi; do
        if curl -fsS --max-time 10 "tftp://127.0.0.1/${f}" -o "$tmp" 2>/dev/null \
            && [[ -s "$tmp" ]]; then
            ok "  TFTP: ${f} opgehaald ($(stat -c%s "$tmp") bytes)."
        else
            error "  TFTP: ${f} niet opgehaald."
            FAILED=1
        fi
    done
    rm -f "$tmp"

    return "$FAILED"
}

# =============================================================================
#  SAMENVATTING
# =============================================================================

print_summary_success() {
    echo
    echo "============================================================"
    echo "  Installatie GESLAAGD"
    echo "============================================================"
    echo "  Interface      : ${SELECTED_IFACE}"
    echo "  Server-IP      : ${SELECTED_IP}/${SELECTED_PREFIX}"
    echo "  Netwerk        : ${SELECTED_NETWORK}"
    echo "  Netmasker      : ${SELECTED_NETMASK}"
    echo "  Gateway        : ${SELECTED_GATEWAY:-<geen>}"
    echo
    echo "  Container-images (vastgezet):"
    echo "    netboot.xyz : ${NETBOOT_IMAGE}"
    echo "    DokuWiki    : ${DOKUWIKI_IMAGE}"
    echo "    Forgejo     : ${FORGEJO_IMAGE}"
    echo
    echo "  Toegang:"
    echo "    Cockpit     : https://${SELECTED_IP}:${COCKPIT_PORT}"
    echo "    netboot.xyz : http://${SELECTED_IP}:${NETBOOT_HTTP_PORT}"
    echo "    netboot UI  : http://${SELECTED_IP}:${NETBOOT_WEB_PORT}"
    echo "    DokuWiki    : http://${SELECTED_IP}:${DOKUWIKI_PORT}"
    echo "    Forgejo     : http://${SELECTED_IP}:${FORGEJO_HTTP_PORT}"
    echo "    Forgejo SSH : ssh -p ${FORGEJO_SSH_PORT} git@${SELECTED_IP}"
    echo
    echo "  Logbestand     : ${LOG_FILE}"
    echo "------------------------------------------------------------"
    echo "  Volgende stappen:"
    echo "    1. Zet een DHCP-reservering voor ${SELECTED_IP} in de Fritzbox."
    echo "    2. Test TFTP:  tftp ${SELECTED_IP} -c get netboot.xyz.kpxe /tmp/test.kpxe"
    echo "    3. Test PXE-boot vanaf een BIOS-client."
    echo "    4. Test PXE-boot vanaf een UEFI-client."
    echo "============================================================"
    echo
}

print_summary_failure() {
    echo
    echo "============================================================"
    echo "  Installatie NIET (volledig) geslaagd"
    echo "============================================================"
    echo "  Eén of meer componenten draaien niet."
    echo "  Zie de meldingen hierboven en het logbestand:"
    echo
    echo "    ${LOG_FILE}"
    echo
    echo "  Mogelijke vervolgstappen:"
    echo "    - Containerlogs:   podman logs <naam>"
    echo "    - Servicestatus:   systemctl status <naam>"
    echo "    - dnsmasq-log:     journalctl -u dnsmasq -f"
    echo "    - firewalld-log:   journalctl -u firewalld -f"
    echo "    - Herstart:        systemctl restart <naam>.service"
    echo
    echo "  Het systeem is in een consistente staat achtergelaten:"
    echo "  geen rollback uitgevoerd, alle onderdelen blijven staan."
    echo "============================================================"
    echo
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    echo "============================================================"
    echo "  netboot-stack installer voor openSUSE Leap"
    echo "  Versie: ${SCRIPT_VERSION}"
    echo "  Log:    ${LOG_FILE}"
    echo "============================================================"
    echo

    require_root
    require_opensuse_leap
    require_systemd
    require_zypper

    install_prerequisites
    verify_image_tags

    info "Stap 1/9: Netwerkinterface kiezen"
    choose_interface
    validate_interface "$SELECTED_IFACE"

    check_port_80

    install_packages
    configure_cockpit
    create_directories
    configure_dnsmasq
    ensure_firewalld
    configure_firewall
    create_quadlet_units
    start_containers

    if verify_installation; then
        print_summary_success
        exit 0
    else
        print_summary_failure
        exit 1
    fi
}

main "$@"