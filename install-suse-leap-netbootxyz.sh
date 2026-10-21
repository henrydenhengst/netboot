#!/usr/bin/env bash
# =============================================================================
#  NETBOOT STACK INSTALLER VOOR OPENSUSE LEAP — DEFINITIEVE VERSIE
# =============================================================================
#  Deze versie is gebaseerd op de live-geteste configuratie en bevat:
#    - Automatische download van netboot.xyz bootbestanden
#    - Automatische deploy naar /srv/netboot-config/menus (TFTP-root container)
#    - 0xFF-workaround voor Dell E7440 (en vergelijkbare hardware)
#    - DNS_SERVER=1.1.1.1 in de netbootxyz Quadlet-unit
#    - Robuuste foutafhandeling met getypeerde rollback
#    - Uitgebreide eindcontrole per component (PASS/FAIL)
#    - Retry-logica voor containerstarts
#    - Pre-flight check van python3 en skopeo
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/netboot-stack-install.log"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly DNSMASQ_CONF_DIR="/etc/dnsmasq.d"
readonly DNSMASQ_CONF="${DNSMASQ_CONF_DIR}/netboot.conf"

readonly NETBOOT_TFTP_PORT=69
readonly NETBOOT_HTTP_PORT=80
readonly NETBOOT_WEB_PORT=12080
readonly DOKUWIKI_PORT=12081
readonly FORGEJO_HTTP_PORT=12082
readonly FORGEJO_SSH_PORT=2222
readonly COCKPIT_PORT=9090

readonly NETBOOT_IMAGE="ghcr.io/netbootxyz/netbootxyz:latest"
readonly DOKUWIKI_IMAGE="docker.io/dokuwiki/dokuwiki:2024-02-06b"
readonly FORGEJO_IMAGE="codeberg.org/forgejo/forgejo:16.0"

readonly TFTP_DIR="/srv/tftp"
readonly NETBOOT_CONFIG_DIR="/srv/netboot-config"
readonly NETBOOT_MENUS_DIR="${NETBOOT_CONFIG_DIR}/menus"
readonly DOKUWIKI_DATA_DIR="/srv/dokuwiki/data"
readonly FORGEJO_DATA_DIR="/srv/forgejo/data"

readonly NETBOOT_DOWNLOADS_EFI="https://boot.netboot.xyz/ipxe/netboot.xyz.efi"
readonly NETBOOT_DOWNLOADS_KPXE="https://boot.netboot.xyz/ipxe/netboot.xyz.kpxe"

readonly CONTAINER_START_TIMEOUT=90
readonly CONTAINER_MAX_ATTEMPTS=3

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
#  ROLLBACK
# =============================================================================

register_rollback_file()          { RB_TYPE+=("restore_file");    RB_ARG1+=("${1:-}"); RB_ARG2+=("${2:-}"); }
register_rollback_remove()        { RB_TYPE+=("remove_path");     RB_ARG1+=("${1:-}"); RB_ARG2+=("");       }
register_rollback_service()       { RB_TYPE+=("restore_service"); RB_ARG1+=("${1:-}"); RB_ARG2+=("");       }
register_rollback_owner()         { RB_TYPE+=("restore_owner");   RB_ARG1+=("${1:-}"); RB_ARG2+=("${2:-}"); }
register_rollback_reload_fw()     { RB_TYPE+=("reload_firewall"); RB_ARG1+=("");       RB_ARG2+=("");       }
register_rollback_daemon_reload() { RB_TYPE+=("daemon_reload");   RB_ARG1+=("");       RB_ARG2+=("");       }
register_rollback_podman_rm()     { RB_TYPE+=("podman_rm");       RB_ARG1+=("${1:-}"); RB_ARG2+=("");       }

record_service_state() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && return 0
    local was_enabled=0 was_active=0
    systemctl is-enabled --quiet "$svc" 2>/dev/null && was_enabled=1 || true
    systemctl is-active  --quiet "$svc" 2>/dev/null && was_active=1  || true
    SERVICE_STATE["$svc"]="$was_enabled:$was_active"
    info "  State ${svc}: enabled=${was_enabled} active=${was_active}"
}

restore_service_state() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && return 0
    local state="${SERVICE_STATE[$svc]:-}"
    [[ -z "$state" ]] && return 0
    local was_enabled="${state%:*}"
    local was_active="${state#*:}"
    (( was_enabled == 0 )) && systemctl disable "$svc" 2>/dev/null || true
    (( was_active == 0 ))  && systemctl stop "$svc" 2>/dev/null || true
}

perform_rollback() {
    (( ROLLBACK_DONE == 1 )) && return 0
    ROLLBACK_DONE=1
    (( ${#RB_TYPE[@]} == 0 )) && { info "Geen rollback-acties."; return 0; }
    info "Rollback gestart (${#RB_TYPE[@]} acties)..."
    local idx
    for (( idx=${#RB_TYPE[@]}-1; idx>=0; idx-- )); do
        local t="${RB_TYPE[$idx]:-}" a1="${RB_ARG1[$idx]:-}" a2="${RB_ARG2[$idx]:-}"
        set +e
        case "$t" in
            restore_file)    [[ -n "$a1" && -n "$a2" && -f "$a2" ]] && cp -a "$a2" "$a1" && info "  Hersteld: $a1" ;;
            remove_path)     if [[ -d "$a1" ]]; then rmdir "$a1" 2>/dev/null && info "  Map weg: $a1"; elif [[ -e "$a1" ]]; then rm -f "$a1" && info "  Bestand weg: $a1"; fi ;;
            restore_service) info "  Service-state: ${a1:-?}"; restore_service_state "$a1" ;;
            restore_owner)   [[ -n "$a1" && -n "$a2" && -e "$a1" ]] && chown "$a2" "$a1" 2>/dev/null && info "  Eigenaar: $a1 → $a2" ;;
            reload_firewall) firewall-cmd --reload >/dev/null 2>&1 && info "  firewall herladen" ;;
            daemon_reload)   systemctl daemon-reload && info "  daemon-reload" ;;
            podman_rm)       [[ -n "$a1" ]] && command -v podman >/dev/null && podman rm -f "$a1" >/dev/null 2>&1 && info "  Container weg: $a1" ;;
            *)               warn "  Onbekende actie: $t" ;;
        esac
        set -e
    done
    RB_TYPE=(); RB_ARG1=(); RB_ARG2=()
    ok "Rollback voltooid."
}

die() { error "$@"; perform_rollback; exit 1; }

_on_error() {
    local ec=$?; local ln=${1:-?}
    error "Fout op regel ${ln} (exit ${ec})."
    perform_rollback
    exit 1
}

_on_interrupt() { error "Onderbroken."; perform_rollback; exit 130; }

trap '_on_error $LINENO' ERR
trap '_on_interrupt' INT TERM

# =============================================================================
#  HULPFUNCTIES
# =============================================================================

command_exists() { command -v "$1" >/dev/null 2>&1; }

backup_or_register_new() {
    local file="${1:-}"
    [[ -z "$file" ]] && return 0
    if [[ -e "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        register_rollback_file "$file" "$backup"
        info "  Back-up: $backup"
    else
        register_rollback_remove "$file"
    fi
}

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
    [[ $EUID -eq 0 ]] || { error "Voer als root uit (sudo $0)."; exit 1; }
}

require_opensuse_leap() {
    [[ -f /etc/os-release ]] || { error "/etc/os-release ontbreekt."; exit 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "opensuse-leap" ]] || { error "Alleen openSUSE Leap (gevonden: ${ID:-?})."; exit 1; }
    ok "Distro: ${PRETTY_NAME:-openSUSE Leap}"
}

require_systemd() { command_exists systemctl || { error "systemd vereist."; exit 1; }; }
require_zypper()  { command_exists zypper    || { error "zypper vereist.";  exit 1; }; }

# =============================================================================
#  STAP 0 — PREREQUISITES
# =============================================================================

install_prerequisites() {
    info "[0/9] Prerequisites controleren..."
    if ! command_exists skopeo; then
        info "  skopeo installeren..."
        zypper --non-interactive install --no-recommends skopeo || die "skopeo mislukt."
    fi
    ok "  skopeo aanwezig."

    if ! command_exists python3; then
        info "  python3 installeren (nodig voor 0xFF-workaround)..."
        zypper --non-interactive install --no-recommends python3 || die "python3 mislukt."
    fi
    ok "  python3 aanwezig."

    if ! command_exists ipcalc; then
        zypper --non-interactive install --no-recommends ipcalc >/dev/null 2>&1 \
            || warn "  ipcalc niet geïnstalleerd — pure-bash fallback."
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
    warn "  Let op: netboot.xyz gebruikt 'latest' — niet reproduceerbaar."
}

# =============================================================================
#  STAP 1 — NETWERKDETECTIE
# =============================================================================

choose_interface() {
    info "Beschikbare netwerkinterfaces:"
    echo
    ip -br -4 addr
    echo
    read -rp "Welke interface is aangesloten op het PXE-netwerk? " SELECTED_IFACE
    if [[ -z "$SELECTED_IFACE" ]] || ! ip link show "$SELECTED_IFACE" &>/dev/null; then
        die "Ongeldige interface: '${SELECTED_IFACE}'"
    fi
    ok "Gekozen interface: ${SELECTED_IFACE}"
}

validate_interface() {
    local iface="$1"
    SELECTED_IP="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    local cidr
    cidr="$(ip -o -4 addr show dev "$iface" scope global | awk 'NR==1 {print $4}')"
    [[ -n "$SELECTED_IP" && -n "$cidr" ]] || die "Geen IPv4-adres op ${iface}."

    local prefix="${cidr#*/}"
    if ! [[ "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 1 || prefix > 32 )); then
        die "Ongeldige prefix: ${cidr}"
    fi

    local netmask="" network=""
    if command_exists ipcalc; then
        netmask="$(ipcalc -m "$cidr" | awk '/^Netmask:/ {print $2}')"
        network="$(ipcalc -n "$cidr" | awk '/^Network:/ {print $2}' | cut -d/ -f1)"
    fi
    [[ -z "$netmask" ]] && { netmask="$(prefix_to_netmask "$prefix")"; info "  Netmasker fallback: ${netmask}"; }
    [[ -z "$network" ]] && { network="$(calculate_network "$SELECTED_IP" "$prefix")"; info "  Netwerk fallback: ${network}"; }
    [[ -n "$netmask" && -n "$network" ]] || die "Netwerk/netmasker onbekend."

    local gateway=""
    gateway="$(ip route show default dev "$iface" 2>/dev/null | awk '/default/ {print $3; exit}')"

    echo
    info "Netwerkconfiguratie van ${iface}:"
    printf "  %-14s %s\n" "Interface:"    "$iface"
    printf "  %-14s %s\n" "Server-IP:"    "$SELECTED_IP"
    printf "  %-14s %s\n" "CIDR:"         "$cidr"
    printf "  %-14s %s\n" "Netwerkadres:" "$network"
    printf "  %-14s %s\n" "Netmasker:"    "$netmask"
    printf "  %-14s %s\n" "Gateway:"      "${gateway:-<geen>}"
    echo
    local confirm
    read -rp "Klopt dit? (j/n) " confirm
    [[ "$confirm" =~ ^[jJ]$ ]] || die "Afgebroken."

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
        warn "Poort ${NETBOOT_HTTP_PORT}/TCP in gebruik:"
        ss -tlnp | grep ":${NETBOOT_HTTP_PORT} " >&2
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        [[ "$cont" =~ ^[jJ]$ ]] || die "Afgebroken."
    else
        ok "  Poort ${NETBOOT_HTTP_PORT}/TCP vrij."
    fi
}

# =============================================================================
#  STAP 3 — PACKAGES
# =============================================================================

install_packages() {
    info "[1/9] Pakketten installeren..."
    local packages=(cockpit cockpit-podman podman dnsmasq firewalld curl python3)
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
    systemctl enable --now cockpit.socket || die "Cockpit start mislukt."
    ok "Cockpit actief op poort ${COCKPIT_PORT}."
}

# =============================================================================
#  STAP 5 — MAPPEN
# =============================================================================

ensure_ownership() {
    local path="$1" uid="$2" gid="$3"
    local target="${uid}:${gid}"
    if [[ ! -d "$path" ]]; then
        mkdir -p "$path"
        chown "$target" "$path"
        register_rollback_remove "$path"
        ok "  $path aangemaakt ($target)."
        return 0
    fi
    local current_owner; current_owner="$(stat -c '%u:%g' "$path")"
    [[ "$current_owner" == "$target" ]] && { ok "  $path heeft al $target."; return 0; }
    local content_count; content_count=$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if (( content_count == 0 )); then
        info "  $path leeg; recursief chown → $target."
        chown -R "$target" "$path"
    else
        warn "  $path bevat ${content_count} item(s); alleen top-level chown."
        chown "$target" "$path"
    fi
    register_rollback_owner "$path" "$current_owner"
}

create_directories() {
    info "[3/9] Mappenstructuur aanmaken..."
    ensure_ownership "$TFTP_DIR"             root root
    ensure_ownership "$NETBOOT_CONFIG_DIR"   root root
    ensure_ownership "$NETBOOT_MENUS_DIR"    root root
    ensure_ownership "$DOKUWIKI_DATA_DIR"    33   33
    ensure_ownership "$FORGEJO_DATA_DIR"     1000 1000
    ok "Mappenstructuur gereed."
}

# =============================================================================
#  STAP 5b — NETBOOT.XYZ BOOTBESTANDEN
# =============================================================================

download_netboot_files() {
    info "[3b/9] netboot.xyz bootbestanden downloaden..."
    local f url pair
    for pair in "netboot.xyz.efi:${NETBOOT_DOWNLOADS_EFI}" "netboot.xyz.kpxe:${NETBOOT_DOWNLOADS_KPXE}"; do
        f="${pair%%:*}"; url="${pair#*:}"
        if [[ -s "${TFTP_DIR}/${f}" ]]; then
            ok "  ${f} bestaat al ($(stat -c%s "${TFTP_DIR}/${f}") bytes)."
            continue
        fi
        info "  Downloaden: ${f}..."
        if curl -fL --retry 3 --connect-timeout 15 -o "${TFTP_DIR}/${f}" "$url"; then
            ok "  ${f} gedownload ($(stat -c%s "${TFTP_DIR}/${f}") bytes)."
        else
            die "  Downloaden van ${f} mislukt."
        fi
    done
}

deploy_netboot_files() {
    info "[3c/9] Bootbestanden naar TFTP-root van container kopiëren..."
    local f
    for f in netboot.xyz.efi netboot.xyz.kpxe; do
        [[ -s "${TFTP_DIR}/${f}" ]] || die "Bronbestand ontbreekt: ${TFTP_DIR}/${f}"
        cp -f "${TFTP_DIR}/${f}" "${NETBOOT_MENUS_DIR}/${f}" \
            && ok "  Gekopieerd: ${f}" \
            || die "  Kopiëren mislukt: ${f}"
    done

    info "  0xFF-workaround aanmaken voor Dell E7440..."
    if python3 - "${NETBOOT_MENUS_DIR}/netboot.xyz.efi" <<'PYEOF'
import sys, shutil
src = sys.argv[1]
dst = src + '\xff'
shutil.copyfile(src, dst)
PYEOF
    then
        ok "  Workaround aangemaakt."
    else
        die "  0xFF-workaround mislukt (python3 ontbreekt of fout)."
    fi
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
    dnsmasq --test >/dev/null 2>&1 || { dnsmasq --test 2>&1 >&2; die "hoofdconfig ongeldig."; }
    ok "  dnsmasq hoofdconfiguratie geldig."
    dnsmasq --test -C "$DNSMASQ_CONF" >/dev/null 2>&1 || { dnsmasq --test -C "$DNSMASQ_CONF" 2>&1 >&2; die "$DNSMASQ_CONF ongeldig."; }
    ok "  $DNSMASQ_CONF syntactisch geldig."
}

configure_dnsmasq() {
    info "[4/9] dnsmasq configureren als proxy-DHCP..."
    mkdir -p "$DNSMASQ_CONF_DIR"
    backup_or_register_new "$DNSMASQ_CONF"
    cat > "$DNSMASQ_CONF" <<EOF
# Proxy-DHCP voor netboot.xyz (gegenereerd door ${SCRIPT_NAME})
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
        journalctl -u dnsmasq -n 50 --no-pager
        die "dnsmasq start mislukt."
    fi
    systemctl is-active --quiet dnsmasq || die "dnsmasq niet actief."
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
        journalctl -u firewalld -n 30 --no-pager
        die "firewalld start mislukt."
    fi
    firewall-cmd --state >/dev/null 2>&1 || die "firewalld niet actief."
    ok "  firewalld actief en enabled."
}

configure_firewall() {
    info "[5/9] Firewall configureren..."
    local zone=""
    zone="$(firewall-cmd --get-zone-of-interface="$SELECTED_IFACE" 2>/dev/null || true)"
    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
        error "Interface ${SELECTED_IFACE} heeft geen firewalld-zone."
        error "  firewall-cmd --permanent --zone=public --add-interface=${SELECTED_IFACE}"
        error "  firewall-cmd --reload"
        die "Geen zone voor ${SELECTED_IFACE}."
    fi
    ok "Zone voor ${SELECTED_IFACE}: ${zone}"
    if [[ "$zone" == "trusted" ]]; then
        warn "Zone 'trusted' opent ALLE poorten."
        local cont
        read -rp "Toch doorgaan? (j/n): " cont
        [[ "$cont" =~ ^[jJ]$ ]] || die "Afgebroken."
    fi

    local zone_file="/etc/firewalld/zones/${zone}.xml"
    if [[ -f "$zone_file" ]]; then
        local backup="${zone_file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$zone_file" "$backup"
        register_rollback_file "$zone_file" "$backup"
        register_rollback_reload_fw
        info "  Back-up zone-XML: $backup"
    fi

    firewall-cmd --permanent --zone="$zone" --add-service=dhcp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-service=tftp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port=4011/udp >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${NETBOOT_WEB_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${DOKUWIKI_PORT}/tcp"     >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_HTTP_PORT}/tcp" >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${FORGEJO_SSH_PORT}/tcp"  >/dev/null
    firewall-cmd --permanent --zone="$zone" --add-port="${COCKPIT_PORT}/tcp"      >/dev/null
    firewall-cmd --reload || die "Firewall herladen mislukt."
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
PublishPort=${NETBOOT_TFTP_PORT}:69/udp
PublishPort=${NETBOOT_HTTP_PORT}:80
PublishPort=${NETBOOT_WEB_PORT}:3000
Volume=${TFTP_DIR}:/assets:Z
Volume=${NETBOOT_CONFIG_DIR}:/config:Z
Environment=TFTPD_OPTS=--tftp-single-port
Environment=DNS_SERVER=1.1.1.1

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
PublishPort=${DOKUWIKI_PORT}:8080
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
    local svc="${1:-}" timeout="${2:-$CONTAINER_START_TIMEOUT}" waited=0
    [[ -z "$svc" ]] && return 1
    while (( waited < timeout )); do
        systemctl is-active --quiet "$svc" && return 0
        sleep 3; (( waited += 3 ))
    done
    return 1
}

start_one_container() {
    local ctr="$1"
    local attempt=1
    while (( attempt <= CONTAINER_MAX_ATTEMPTS )); do
        info "  ${ctr}: poging ${attempt}/${CONTAINER_MAX_ATTEMPTS}..."
        if systemctl start "${ctr}.service" 2>/dev/null; then
            if wait_for_service "${ctr}.service" "$CONTAINER_START_TIMEOUT"; then
                ok "  ${ctr}: actief."
                return 0
            fi
            warn "  ${ctr}: gestart maar niet actief binnen ${CONTAINER_START_TIMEOUT}s."
        else
            warn "  ${ctr}: systemctl start faalde."
        fi
        if (( attempt < CONTAINER_MAX_ATTEMPTS )); then
            info "  ${ctr}: 10s wachten voor volgende poging..."
            sleep 10
        fi
        (( attempt++ ))
    done
    error "  ${ctr}: na ${CONTAINER_MAX_ATTEMPTS} pogingen niet actief."
    journalctl -u "${ctr}.service" -n 30 --no-pager || true
    podman logs "$ctr" 2>&1 | tail -30 || true
    return 1
}

start_containers() {
    info "[7/9] Containers starten (max ${CONTAINER_START_TIMEOUT}s elk)..."
    systemctl daemon-reload
    register_rollback_daemon_reload

    local START_FAILED=0 ctr=""
    for ctr in netbootxyz dokuwiki forgejo; do
        register_rollback_podman_rm "$ctr"
        if ! start_one_container "$ctr"; then
            START_FAILED=1
        fi
    done
    (( START_FAILED != 0 )) && die "Een of meer containers faalden na retries."
}

# =============================================================================
#  STAP 10 — EINDCONTROLES
# =============================================================================

verify_installation() {
    info "[8/9] Eindcontroles uitvoeren..."
    local FAILED=0

    info "  Host-services:"
    local svc=""
    for svc in dnsmasq cockpit.socket firewalld; do
        systemctl is-active --quiet "$svc" && ok "    $svc: actief" || { error "    $svc: NIET actief"; FAILED=1; }
    done

    info "  Containers draaien:"
    local ctr=""
    for ctr in netbootxyz dokuwiki forgejo; do
        podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ctr}$" && ok "    ${ctr}: draait" || { error "    ${ctr}: draait NIET"; FAILED=1; }
    done

    info "  dnsmasq configuratie:"
    dnsmasq --test >/dev/null 2>&1 && ok "    syntactisch geldig" || { error "    ongeldig"; FAILED=1; }

    info "  Poorten:"
    ss -ulnp 2>/dev/null | grep -qE '(:|\])69[[:space:]]' && ok "    TFTP UDP 69 luistert" || { error "    TFTP UDP 69 luistert NIET"; FAILED=1; }
    ss -tlnp 2>/dev/null | grep -qE '(:|\])80[[:space:]]' && ok "    HTTP TCP 80 luistert" || { error "    HTTP TCP 80 luistert NIET"; FAILED=1; }

    info "  HTTP-responsiviteit:"
    local body=""
    if body="$(curl -fsS --max-time 5 "http://127.0.0.1/" 2>/dev/null)" && [[ -n "$body" ]]; then
        ok "    netboot.xyz HTTP root geeft ${#body} bytes."
    else
        error "    netboot.xyz HTTP root geeft leeg antwoord."
        FAILED=1
    fi

    info "  TFTP lokaal (127.0.0.1):"
    local f="" tmp=""
    tmp="$(mktemp)"
    for f in netboot.xyz.kpxe netboot.xyz.efi; do
        if curl -fsS --max-time 10 "tftp://127.0.0.1/${f}" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            ok "    ${f}: $(stat -c%s "$tmp") bytes."
        else
            error "    ${f}: NIET opgehaald."
            FAILED=1
        fi
    done
    rm -f "$tmp"

    info "  TFTP via fysiek IP (${SELECTED_IP}):"
    tmp="$(mktemp)"
    if curl -fsS --max-time 10 "tftp://${SELECTED_IP}/netboot.xyz.efi" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        ok "    netboot.xyz.efi: $(stat -c%s "$tmp") bytes."
    else
        warn "    niet bereikbaar via ${SELECTED_IP} — controleer firewall."
        FAILED=1
    fi
    rm -f "$tmp"

    info "  0xFF-workaround aanwezig:"
    if [[ -f "${NETBOOT_MENUS_DIR}/netboot.xyz.efi"* ]]; then
        local count; count=$(find "${NETBOOT_MENUS_DIR}" -maxdepth 1 -name 'netboot.xyz.efi*' | wc -l)
        (( count >= 2 )) && ok "    ${count} varianten gevonden." || { error "    workaround ontbreekt."; FAILED=1; }
    fi

    info "  DokuWiki HTTP:"
    if curl -fsS --max-time 5 "http://127.0.0.1:${DOKUWIKI_PORT}/" >/dev/null 2>&1; then
        ok "    DokuWiki antwoordt op poort ${DOKUWIKI_PORT}."
    else
        error "    DokuWiki antwoordt NIET op poort ${DOKUWIKI_PORT}."
        FAILED=1
    fi

    info "  Forgejo HTTP:"
    if curl -fsS --max-time 5 "http://127.0.0.1:${FORGEJO_HTTP_PORT}/" >/dev/null 2>&1; then
        ok "    Forgejo antwoordt op poort ${FORGEJO_HTTP_PORT}."
    else
        error "    Forgejo antwoordt NIET op poort ${FORGEJO_HTTP_PORT}."
        FAILED=1
    fi

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
    echo "  Bootbestanden:"
    echo "    ${TFTP_DIR}/netboot.xyz.efi"
    echo "    ${TFTP_DIR}/netboot.xyz.kpxe"
    echo "    ${NETBOOT_MENUS_DIR}/netboot.xyz.efi"
    echo "    ${NETBOOT_MENUS_DIR}/netboot.xyz.kpxe"
    echo "    ${NETBOOT_MENUS_DIR}/netboot.xyz.efi<0xFF>  (Dell workaround)"
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
    echo "    2. Test PXE-boot vanaf een BIOS-client."
    echo "    3. Test PXE-boot vanaf een UEFI-client (bv. Dell E7440)."
    echo "    4. Live logs: sudo podman logs -f netbootxyz"
    echo "============================================================"
    echo
}

print_summary_failure() {
    echo
    echo "============================================================"
    echo "  Installatie VOLTOOID, eindcontrole MISLUKT"
    echo "============================================================"
    echo "  GEEN rollback uitgevoerd. Onderzoek de situatie handmatig."
    echo
    echo "  Logbestand     : ${LOG_FILE}"
    echo
    echo "  Onderzoek:"
    echo "    systemctl status <service>"
    echo "    journalctl -u <service> -n 50 --no-pager"
    echo "    podman ps -a"
    echo "    podman logs <container>"
    echo "    ss -ulnp | grep :69"
    echo "    ss -tlnp | grep :80"
    echo "    curl -I http://127.0.0.1/"
    echo "    curl -I http://127.0.0.1:12081/"
    echo "    curl -I http://127.0.0.1:12082/"
    echo "============================================================"
    echo
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    echo "============================================================"
    echo "  netboot-stack installer voor openSUSE Leap"
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
    download_netboot_files
    deploy_netboot_files
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
        exit 2
    fi
}

main "$@"