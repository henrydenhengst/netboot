#!/usr/bin/env bash
# =============================================================================
#  NETBOOT STACK — DIAGNOSE SCRIPT
# =============================================================================
#
#  Verzamelt informatie over de netboot-stack containers en services, zodat
#  zichtbaar wordt waarom een container niet start. Schrijft alles naar
#  /tmp/netboot-diagnose.txt en toont het ook op het scherm.
#
#  Gebruik:
#      sudo ./netboot-diagnose.sh
#
#  Daarna:
#      cat /tmp/netboot-diagnose.txt
#
# =============================================================================

set -uo pipefail

OUT="/tmp/netboot-diagnose.txt"

# Kleuren (alleen als we op een terminal draaien)
if [[ -t 1 ]]; then
    C_BLUE=$'\033[0;34m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[0;31m'
    C_RESET=$'\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

# Schrijft zowel naar het scherm als naar het outputbestand
say()  { echo -e "$*" | tee -a "$OUT"; }
head1() {
    say ""
    say "${C_BLUE}============================================================${C_RESET}"
    say "${C_BLUE}  $*${C_RESET}"
    say "${C_BLUE}============================================================${C_RESET}"
}
head2() {
    say ""
    say "${C_GREEN}--- $* ---${C_RESET}"
}
note() { say "${C_YELLOW}[info]${C_RESET} $*"; }
err()  { say "${C_RED}[err] ${C_RESET} $*"; }

# Voer een commando uit, toon output, en markeer als het faalt
run() {
    local label="$1"; shift
    say "\$ $*"
    if output="$("$@" 2>&1)"; then
        if [[ -z "$output" ]]; then
            say "  (geen output)"
        else
            say "$output" | sed 's/^/  /'
        fi
    else
        local rc=$?
        err "commando faalde (exit ${rc}): $*"
        [[ -n "$output" ]] && say "$output" | sed 's/^/  /'
    fi
}

# =============================================================================
#  Controle: root
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "Dit script moet als root worden uitgevoerd (sudo $0)." >&2
    exit 1
fi

# Start met een schoon bestand
: > "$OUT"

say "Netboot-stack diagnose — $(date '+%Y-%m-%d %H:%M:%S')"
say "Hostname: $(hostname)"
say "Kernel:   $(uname -r)"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    say "Distro:   ${PRETTY_NAME:-onbekend}"
fi

# =============================================================================
#  1. Systemd-services
# =============================================================================
head1 "1. SYSTEMD-SERVICES"

for svc in netbootxyz.service dokuwiki.service forgejo.service dnsmasq.service firewalld.service; do
    head2 "$svc"
    run "status" systemctl status "$svc" --no-pager -l
done

# =============================================================================
#  2. Journalctl-logs (laatste 60 regels per container)
# =============================================================================
head1 "2. JOURNALCTL-LOGS"

for svc in netbootxyz.service dokuwiki.service forgejo.service; do
    head2 "$svc"
    say "\$ journalctl -u $svc -n 60 --no-pager"
    journalctl -u "$svc" -n 60 --no-pager 2>&1 | sed 's/^/  /' | tee -a "$OUT" >/dev/null
    # Toon ook op scherm
    journalctl -u "$svc" -n 60 --no-pager 2>&1 | sed 's/^/  /'
done

# =============================================================================
#  3. Podman-containers
# =============================================================================
head1 "3. PODMAN-CONTAINERS"

head2 "podman ps -a"
if command -v podman >/dev/null 2>&1; then
    podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>&1 | tee -a "$OUT"
else
    err "podman is niet geïnstalleerd"
fi

head2 "podman images"
if command -v podman >/dev/null 2>&1; then
    podman images 2>&1 | tee -a "$OUT"
fi

# =============================================================================
#  4. Podman logs (laatste 40 regels per container)
# =============================================================================
head1 "4. PODMAN-LOGS"

for ctr in netbootxyz dokuwiki forgejo; do
    head2 "$ctr"
    if command -v podman >/dev/null 2>&1; then
        say "\$ podman logs --tail 40 $ctr"
        podman logs --tail 40 "$ctr" 2>&1 | sed 's/^/  /' | tee -a "$OUT"
    fi
done

# =============================================================================
#  5. Image-inspectie: volumes, poorten, user
# =============================================================================
head1 "5. IMAGE-INSPECTIE"

inspect_image() {
    local image="$1"
    head2 "$image"
    if ! command -v podman >/dev/null 2>&1; then
        return
    fi

    say "\$ podman inspect $image --format '{{json .Config.Volumes}}'"
    podman inspect "$image" --format '{{json .Config.Volumes}}' 2>&1 | sed 's/^/  /' | tee -a "$OUT"

    say "\$ podman inspect $image --format '{{json .Config.ExposedPorts}}'"
    podman inspect "$image" --format '{{json .Config.ExposedPorts}}' 2>&1 | sed 's/^/  /' | tee -a "$OUT"

    say "\$ podman inspect $image --format '{{.Config.User}}'"
    podman inspect "$image" --format '{{.Config.User}}' 2>&1 | sed 's/^/  /' | tee -a "$OUT"

    say "\$ podman inspect $image --format '{{.Config.Entrypoint}}'"
    podman inspect "$image" --format '{{json .Config.Entrypoint}}' 2>&1 | sed 's/^/  /' | tee -a "$OUT"
}

inspect_image "ghcr.io/netbootxyz/netbootxyz:latest"
inspect_image "docker.io/dokuwiki/dokuwiki:2024-02-06b"
inspect_image "codeberg.org/forgejo/forgejo:16.0"

# =============================================================================
#  6. Quadlet-bestanden
# =============================================================================
head1 "6. QUADLET-BESTANDEN"

for f in /etc/containers/systemd/*.container; do
    if [[ -f "$f" ]]; then
        head2 "$f"
        sed 's/^/  /' "$f" | tee -a "$OUT"
    fi
done

# =============================================================================
#  7. Poorten en listeners
# =============================================================================
head1 "7. POORTEN"

head2 "ss -tlnp (TCP)"
ss -tlnp 2>&1 | tee -a "$OUT"

head2 "ss -ulnp (UDP)"
ss -ulnp 2>&1 | tee -a "$OUT"

# =============================================================================
#  8. Firewalld-zone
# =============================================================================
head1 "8. FIREWALLD"

if command -v firewall-cmd >/dev/null 2>&1; then
    head2 "firewall-cmd --state"
    firewall-cmd --state 2>&1 | tee -a "$OUT"

    head2 "firewall-cmd --get-active-zones"
    firewall-cmd --get-active-zones 2>&1 | tee -a "$OUT"

    head2 "firewall-cmd --get-default-zone"
    firewall-cmd --get-default-zone 2>&1 | tee -a "$OUT"
else
    err "firewall-cmd niet gevonden"
fi

# =============================================================================
#  9. Netwerk
# =============================================================================
head1 "9. NETWERK"

head2 "ip -br -4 addr"
ip -br -4 addr 2>&1 | tee -a "$OUT"

head2 "ip route"
ip route 2>&1 | tee -a "$OUT"

# =============================================================================
#  10. Recente installatie-log (laatste 80 regels)
# =============================================================================
head1 "10. INSTALLATIE-LOG (laatste 80 regels)"

if [[ -f /var/log/netboot-stack-install.log ]]; then
    tail -80 /var/log/netboot-stack-install.log | sed 's/^/  /' | tee -a "$OUT"
else
    err "/var/log/netboot-stack-install.log niet gevonden"
fi

# =============================================================================
#  Klaar
# =============================================================================
head1 "KLAAR"
say "Volledige output staat in: $OUT"
say ""
say "Plak de inhoud hiervan in je antwoord:"
say "  cat $OUT"
say ""