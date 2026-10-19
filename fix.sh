#!/usr/bin/env bash
# Fix DokuWiki poortmapping: 12081:80 → 12081:8080
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Root vereist: sudo $0" >&2; exit 1; }

FILE="/etc/containers/systemd/dokuwiki.container"

sed -i 's|^PublishPort=12081:80$|PublishPort=12081:8080|' "$FILE"

systemctl stop dokuwiki.service
podman rm -f dokuwiki
systemctl daemon-reload
systemctl start dokuwiki.service

sleep 20
curl -I http://127.0.0.1:12081/