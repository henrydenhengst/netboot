
#!/usr/bin/env bash
#
# podman-update-check.sh
# Controleert rootful en rootless Podman.
# Voert updates uitsluitend uit na expliciete toestemming.

set -uo pipefail

command -v podman >/dev/null 2>&1 || {
    echo "FOUT: Podman is niet geïnstalleerd."
    exit 1
}

if [[ $EUID -eq 0 ]]; then
    echo "Start dit script als gewone gebruiker, zonder sudo."
    exit 1
fi

echo "=========================================="
echo " FreeBoot - Podman updatecontrole"
echo "=========================================="
echo

# Bepaal welke Podman-contexten containers bevatten.
ROOTLESS_CONTAINERS=$(podman ps -q 2>/dev/null || true)

ROOTFUL_CONTAINERS=""
if command -v sudo >/dev/null 2>&1; then
    echo "Rootful Podman controleren..."
    if sudo -v; then
        ROOTFUL_CONTAINERS=$(sudo podman ps -q 2>/dev/null || true)
    else
        echo "WAARSCHUWING: sudo-toegang niet beschikbaar."
    fi
fi

contexts=()

if [[ -n "$ROOTLESS_CONTAINERS" ]]; then
    contexts+=("rootless")
fi

if [[ -n "$ROOTFUL_CONTAINERS" ]]; then
    contexts+=("rootful")
fi

if [[ ${#contexts[@]} -eq 0 ]]; then
    echo "Geen draaiende containers gevonden."
    echo "Controleer ook of containers eventueel gestopt zijn."
    exit 0
fi

# Controleer iedere gevonden context afzonderlijk.
for context in "${contexts[@]}"; do
    echo
    echo "------------------------------------------"
    echo "Context: $context"
    echo "------------------------------------------"

    if [[ "$context" == "rootful" ]]; then
        CMD=(sudo podman)
    else
        CMD=(podman)
    fi

    echo "Draaiende containers:"
    "${CMD[@]}" ps --format 'table {{.Names}}\t{{.Image}}'

    echo
    echo "Auto-update dry-run uitvoeren..."

    # Bewaar zowel uitvoer als exitcode.
    if output=$("${CMD[@]}" auto-update --dry-run \
        --format '{{.ContainerName}} | {{.Image}} | {{.Updated}}' 2>&1); then
        rc=0
    else
        rc=$?
    fi

    printf '%s\n' "$output"
    echo

    if [[ $rc -ne 0 ]]; then
        echo "ADVIES: NIET UPDATEN."
        echo "De dry-run is mislukt (exitcode $rc)."
        echo "Los eerst de gemelde fout op."
        continue
    fi

    if grep -Eiq '(^|[|[:space:]])(failed|error)([|[:space:]]|$)' <<< "$output"; then
        echo "ADVIES: NIET UPDATEN."
        echo "De uitvoer bevat een foutstatus."
        continue
    fi

    if grep -Eiq '(^|[|[:space:]])pending([|[:space:]]|$)' <<< "$output"; then
        echo "ADVIES: er zijn image-updates beschikbaar."
        echo "Let op: een nieuwe image is niet automatisch een veilige update."
        echo "Controleer compatibiliteit, changelog en eventuele"
        echo "configuratie- of databasewijzigingen."

        echo
        read -r -p "Wil je de updates voor $context NU uitvoeren? [j/N] " answer

        case "$answer" in
            j|J|ja|JA|Ja)
                echo
                echo "Updates uitvoeren..."

                if "${CMD[@]}" auto-update; then
                    echo
                    echo "Updatecommando succesvol afgerond."
                    echo "Status van containers:"
                    "${CMD[@]}" ps
                else
                    echo "WAARSCHUWING: updatecommando is mislukt."
                    echo "Controleer de containers en systemd-services."
                fi
                ;;
            *)
                echo "Updates overgeslagen."
                ;;
        esac
    else
        echo "Geen beschikbare updates gemeld."
        echo "Er is geen update uitgevoerd."
        echo "Controleer of containers voor auto-update zijn ingesteld."
    fi
done

echo
echo "=========================================="
echo " Controle afgerond."
echo "=========================================="
