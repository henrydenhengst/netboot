#!/usr/bin/env bash
#
# Netboot.xyz 3.0.3 / Podman diagnose voor FreeBoot Debian-menu
# Alleen-lezen: wijzigt niets en herstart niets.
# Gebruik: sudo bash netbootxyz-diagnose.sh
#
set -uo pipefail
umask 077

section() { printf '\n\n========== %s ==========\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "Systeem"
date -Is 2>/dev/null || date
uname -a
printf 'UID: '; id
printf 'Podman: '; podman --version 2>/dev/null || echo "niet beschikbaar"
printf 'Docker: '; docker --version 2>/dev/null || echo "niet beschikbaar"

section "Containers (Podman)"
if have podman; then
    podman ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
else
    echo "podman niet gevonden"
fi

section "Containers (Docker, indien aanwezig)"
if have docker; then
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
else
    echo "docker niet gevonden"
fi

# Bepaal netboot.xyz containers op basis van naam of image.
declare -a CONTAINERS=()
if have podman; then
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        info="$(podman inspect --format '{{.Name}} {{.Config.Image}}' "$c" 2>/dev/null || true)"
        if [[ "${info,,}" == *netboot* ]]; then CONTAINERS+=("$c"); fi
    done < <(podman ps -a --format '{{.Names}}' 2>/dev/null)
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo
    echo "Geen container met 'netboot' in naam/image automatisch gevonden."
    echo "Controleer de containerlijst hierboven. Mogelijk draait Podman rootless;"
    echo "voer het script dan uit als de gebruiker die de container beheert, zonder sudo."
fi

for c in "${CONTAINERS[@]}"; do
    section "Podman inspect: $c"
    # Alleen niet-geheime basisgegevens en mount-informatie tonen.
    podman inspect --format \
'Naam={{.Name}}
Image={{.Config.Image}}
Status={{.State.Status}}
Image-ID={{.Image}}
Mounts:
{{range .Mounts}}  {{.Source}} -> {{.Destination}} (rw={{.RW}}, type={{.Type}})
{{end}}
Poorten:
{{range $p, $conf := .NetworkSettings.Ports}}  {{$p}} => {{range $conf}}{{.HostIp}}:{{.HostPort}} {{end}}
{{end}}' "$c" 2>&1

    section "Versie-/omgeving-indicaties in container: $c"
    podman exec "$c" sh -lc '
      echo "-- relevante environment keys (waarden gefilterd) --"
      env | cut -d= -f1 | grep -Ei "NETBOOT|TFTP|WEB|PORT|ARCH|VERSION|MENU|CUSTOM" | sort -u || true
      echo "-- mogelijke versiebestanden --"
      for f in /etc/os-release /version /app/version /config/version; do
        if [ -r "$f" ]; then echo "### $f"; sed -n "1,30p" "$f"; fi
      done
      echo "-- directories --"
      for d in /srv/tftp /config /assets /www /var/www /boot; do
        if [ -d "$d" ]; then
          echo "### $d"
          ls -la "$d" 2>/dev/null | head -60
        fi
      done
    ' 2>&1

    section "Relevante bestanden in container: $c"
    podman exec "$c" sh -lc '
      for root in /srv/tftp /config /assets /www /var/www /boot; do
        [ -d "$root" ] || continue
        echo "### bestanden onder $root (max diepte 5)"
        find "$root" -maxdepth 5 -type f \
          \( -iname "*.ipxe" -o -iname "*.cfg" -o -iname "*.menu" \
             -o -iname "*.inc" -o -iname "*.conf" -o -iname "*custom*" \) \
          -print 2>/dev/null | head -250
      done
    ' 2>&1

    section "Zoektermen in menu/config-bestanden: $c"
    # Toon alleen regels met relevante termen; secrets worden gemaskeerd.
    podman exec "$c" sh -lc '
      for root in /srv/tftp /config /assets /www /var/www /boot; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth 5 -type f \
          \( -iname "*.ipxe" -o -iname "*.cfg" -o -iname "*.menu" \
             -o -iname "*.inc" -o -iname "*.conf" \) -print 2>/dev/null
      done | sort -u | while IFS= read -r f; do
        grep -niE "FreeBoot|freeboot|custom|menuentry|preseed|netboot\.xyz|include|chain|goto" "$f" 2>/dev/null |
          head -30 | sed -E \
          -e "s/(password|passwd|token|secret|api[_-]?key)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\\1\\2[REDACTED]/Ig" |
          sed "s|^|$f:|"
      done
    ' 2>&1 | head -500

    section "Recente containerlogs: $c"
    podman logs --tail 120 "$c" 2>&1 |
      sed -E \
        -e 's/(password|passwd|token|secret|api[_-]?key)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/Ig' |
      tail -120
done

section "Host: /srv/tftp"
if [[ -d /srv/tftp ]]; then
    ls -ld /srv/tftp
    find /srv/tftp -maxdepth 4 -type f \
      \( -iname "*.ipxe" -o -iname "*.cfg" -o -iname "*.menu" \
         -o -iname "*.inc" -o -iname "*custom*" \) -print 2>/dev/null | head -300
    echo "-- relevante regels op host --"
    find /srv/tftp -maxdepth 4 -type f \
      \( -iname "*.ipxe" -o -iname "*.cfg" -o -iname "*.menu" -o -iname "*.inc" \) \
      -print 2>/dev/null | sort -u | while IFS= read -r f; do
        grep -niE "FreeBoot|freeboot|custom|menuentry|preseed|include|chain|goto" "$f" 2>/dev/null |
          head -20 | sed -E \
          -e 's/(password|passwd|token|secret|api[_-]?key)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/Ig' |
          sed "s|^|$f:|"
      done | head -400
else
    echo "/srv/tftp bestaat niet op deze host."
fi

section "Mounts host"
if have findmnt; then
    findmnt -T /srv/tftp 2>&1 || true
fi
if have podman; then
    podman volume ls 2>&1 | head -100
fi

section "Afgerond"
echo "Dit script heeft geen configuratie gewijzigd en geen services herstart."
echo "Controleer de uitvoer vóór delen en verwijder eventueel IP-adressen of interne namen."
