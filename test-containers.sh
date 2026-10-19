#!/usr/bin/env bash
# =============================================================================
#  CONTAINER TEST — minimale versie
# =============================================================================
#  Test alleen of de drie containers willen starten.
#  Detecteert automatisch volumes en poorten uit de image.
#  Stopt bij de eerste fout en toont de exacte oorzaak.
#
#  Gebruik:  sudo ./test-containers.sh
# =============================================================================

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Root vereist: sudo $0" >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "podman niet gevonden. Installeer eerst: zypper install podman" >&2
    exit 1
fi

PASS=0
FAIL=0

log()  { echo -e "\n[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
nok()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# -----------------------------------------------------------------------------
# Fase 1: images pullen
# -----------------------------------------------------------------------------
log "FASE 1: images pullen"

for img in \
    "ghcr.io/netbootxyz/netbootxyz:latest" \
    "docker.io/dokuwiki/dokuwiki:2024-02-06b" \
    "codeberg.org/forgejo/forgejo:16.0"
do
    echo "  pull: $img"
    if podman pull "$img" >/dev/null 2>&1; then
        ok "gepulld: $img"
    else
        nok "pull mislukt: $img"
        echo "  → Probeer handmatig: podman pull $img"
    fi
done

if (( FAIL > 0 )); then
    log "STOP: minstens één image kon niet worden gepulld."
    log "Los dit eerst op voordat we verder gaan."
    exit 1
fi

# -----------------------------------------------------------------------------
# Fase 2: inspecteer images (watch: volumes, poorten, user)
# -----------------------------------------------------------------------------
log "FASE 2: image-inspectie (dit is wat de image verwacht)"

for img in \
    "ghcr.io/netbootxyz/netbootxyz:latest" \
    "docker.io/dokuwiki/dokuwiki:2024-02-06b" \
    "codeberg.org/forgejo/forgejo:16.0"
do
    echo ""
    echo "  === $img ==="
    echo "  Volumes:"
    podman inspect "$img" --format '{{json .Config.Volumes}}' 2>/dev/null | \
        tr ',' '\n' | tr -d '{}"' | grep -v '^$' | sed 's/^/    /' || echo "    (geen)"
    echo "  Exposed poorten:"
    podman inspect "$img" --format '{{json .Config.ExposedPorts}}' 2>/dev/null | \
        tr ',' '\n' | tr -d '{}"' | grep -v '^$' | sed 's/^/    /' || echo "    (geen)"
    echo "  User:"
    podman inspect "$img" --format '{{.Config.User}}' 2>/dev/null | sed 's/^/    /' || echo "    (root)"
    echo "  Entrypoint:"
    podman inspect "$img" --format '{{json .Config.Entrypoint}}' 2>/dev/null | sed 's/^/    /'
done

echo ""
read -rp "Druk op Enter om verder te gaan met het starten van de containers..."

# -----------------------------------------------------------------------------
# Fase 3: containers één voor één starten
# -----------------------------------------------------------------------------
log "FASE 3: containers starten"

mkdir -p /srv/tftp /srv/netboot-config /srv/dokuwiki/data /srv/forgejo/data

# --- netboot.xyz ---
log "3a. netboot.xyz starten"
podman rm -f netbootxyz >/dev/null 2>&1 || true

if podman run -d --name netbootxyz \
    --network host \
    -v /srv/tftp:/assets:Z \
    -v /srv/netboot-config:/config:Z \
    -e TFTPD_OPTS=--tftp-single-port \
    -e WEB_APP_PORT=12080 \
    -e NGINX_PORT=80 \
    ghcr.io/netbootxyz/netbootxyz:latest >/dev/null 2>&1
then
    sleep 5
    if podman ps --format '{{.Names}}' | grep -q '^netbootxyz$'; then
        ok "netbootxyz draait"
    else
        nok "netbootxyz start maar stopt direct — logs:"
        podman logs netbootxyz 2>&1 | tail -30 | sed 's/^/    /'
    fi
else
    nok "netbootxyz kon niet starten — logs:"
    podman logs netbootxyz 2>&1 | tail -30 | sed 's/^/    /'
fi

# --- DokuWiki ---
log "3b. dokuwiki starten"
podman rm -f dokuwiki >/dev/null 2>&1 || true

if podman run -d --name dokuwiki \
    -p 12081:80 \
    -v /srv/dokuwiki/data:/storage:Z \
    docker.io/dokuwiki/dokuwiki:2024-02-06b >/dev/null 2>&1
then
    sleep 5
    if podman ps --format '{{.Names}}' | grep -q '^dokuwiki$'; then
        ok "dokuwiki draait"
    else
        nok "dokuwiki start maar stopt direct — logs:"
        podman logs dokuwiki 2>&1 | tail -30 | sed 's/^/    /'
    fi
else
    nok "dokuwiki kon niet starten — logs:"
    podman logs dokuwiki 2>&1 | tail -30 | sed 's/^/    /'
fi

# --- Forgejo ---
log "3c. forgejo starten"
podman rm -f forgejo >/dev/null 2>&1 || true

if podman run -d --name forgejo \
    -p 12082:3000 \
    -p 2222:22 \
    -v /srv/forgejo/data:/data:Z \
    -e USER_UID=1000 \
    -e USER_GID=1000 \
    codeberg.org/forgejo/forgejo:16.0 >/dev/null 2>&1
then
    sleep 5
    if podman ps --format '{{.Names}}' | grep -q '^forgejo$'; then
        ok "forgejo draait"
    else
        nok "forgejo start maar stopt direct — logs:"
        podman logs forgejo 2>&1 | tail -30 | sed 's/^/    /'
    fi
else
    nok "forgejo kon niet starten — logs:"
    podman logs forgejo 2>&1 | tail -30 | sed 's/^/    /'
fi

# -----------------------------------------------------------------------------
# Fase 4: controle
# -----------------------------------------------------------------------------
log "FASE 4: controle"

echo ""
echo "  Draaiende containers:"
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 | sed 's/^/    /'

echo ""
echo "  Luisterende poorten:"
ss -tlnp 2>/dev/null | grep -E ':(69|80|12080|12081|12082|2222) ' | sed 's/^/    /' || echo "    (geen van de verwachte poorten luistert)"

echo ""
log "RESULTAAT: $PASS geslaagd, $FAIL mislukt"

if (( FAIL == 0 )); then
    echo ""
    echo "  Alle drie de containers draaien."
    echo "  Test nu handmatig:"
    echo "    curl -I http://127.0.0.1:12080/    (netboot.xyz UI)"
    echo "    curl -I http://127.0.0.1:12081/    (DokuWiki)"
    echo "    curl -I http://127.0.0.1:12082/    (Forgejo)"
    echo ""
    echo "  Als dat werkt, zijn de images en poorten goed en kunnen we"
    echo "  het volledige script hierop aanpassen."
    echo ""
    echo "  Opruimen:"
    echo "    podman rm -f netbootxyz dokuwiki forgejo"
else
    echo ""
    echo "  Plak de output hierboven. Daaruit blijkt:"
    echo "    - welke container faalt"
    echo "    - met welke foutmelding"
    echo "    - welke volumes/poorten de image echt verwacht (Fase 2)"
    echo ""
    echo "  Opruimen:"
    echo "    podman rm -f netbootxyz dokuwiki forgejo"
fi