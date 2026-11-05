# 🚀 FreeBoot Core Infrastructure

<p align="center">
  <img src="https://via.placeholder.com/900x200/1e293b/38bdf8?text=FreeBoot+Core+Infrastructure" alt="FreeBoot Banner">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/openSUSE-Leap-73ba25?style=for-the-badge&logo=opensuse&logoColor=white" alt="openSUSE Leap">
  <img src="https://img.shields.io/badge/Ansible-Automation-EE0000?style=for-the-badge&logo=ansible&logoColor=white" alt="Ansible">
  <img src="https://img.shields.io/badge/Podman-Rootless-892CA0?style=for-the-badge&logo=podman&logoColor=white" alt="Podman">
  <img src="https://img.shields.io/badge/Forgejo-Git%20Forge-FB8C00?style=for-the-badge&logo=forgejo&logoColor=white" alt="Forgejo">
  <img src="https://img.shields.io/badge/DokuWiki-FlatFile-000000?style=for-the-badge&logo=dokuwiki&logoColor=white" alt="DokuWiki">
  <img src="https://img.shields.io/badge/KVM%2FQEMU-Virtualization-CC0000?style=for-the-badge&logo=linux&logoColor=white" alt="KVM">
  <img src="https://img.shields.io/badge/netboot.xyz-PXE%20Boot-1f2937?style=for-the-badge&logo=ipxe&logoColor=white" alt="netboot.xyz">
</p>

---

Een robuuste, self-hosted infrastructuurstack ontworpen op basis van de **KISS-filosofie** (Keep It Simple, Stupid). Geen zware enterprise bloat, maar snelle, voorspelbare open-source componenten voor automatisering, containerbeheer en documentatie binnen het `192.168.192.0/18` netwerk.

---

## 🛠️ Stack Overzicht

| Component | Logo / Badge | Rol in de Architectuur |
| :--- | :--- | :--- |
| **openSUSE Leap** | ![openSUSE](https://img.shields.io/badge/-openSUSE%20Leap-73ba25?style=flat-square&logo=opensuse&logoColor=white) | Rotsvaste Enterprise Linux-hostbasis |
| **Ansible** | ![Ansible](https://img.shields.io/badge/-Ansible-EE0000?style=flat-square&logo=ansible&logoColor=white) | Volledige configuratieautomatisering en deployment |
| **Podman** | ![Podman](https://img.shields.io/badge/-Podman-892CA0?style=flat-square&logo=podman&logoColor=white) | Rootless container-runtime voor services (geen Docker daemon) |
| **Forgejo** | ![Forgejo](https://img.shields.io/badge/-Forgejo-FB8C00?style=flat-square&logo=forgejo&logoColor=white) | Lokale, snelle Git-forge voor code- en playbookbeheer |
| **DokuWiki** | ![DokuWiki](https://img.shields.io/badge/-DokuWiki-000000?style=flat-square&logo=dokuwiki&logoColor=white) | Snelle flat-file wiki voor operationele documentatie |
| **KVM / QEMU** | ![KVM](https://img.shields.io/badge/-KVM%2FQEMU-CC0000?style=flat-square&logo=linux&logoColor=white) | Hypervisor-laag voor virtuele machines en testnodes |
| **netboot.xyz** | ![netboot](https://img.shields.io/badge/-netboot.xyz-1f2937?style=flat-square&logo=ipxe&logoColor=white) | Lokale iPXE-bootomgeving voor bare-metal provisioning |

---

---
# 📋 Server Toolkit — Functioneel Overzicht

Het script ondersteunt **zes modi**: `check`, `documentatie`, `backup`, `containers`, `opruimen`, of **alles** als standaard.

---

## 1. Systeem- en Toolcontrole (`check`)

- **Dependency-check**: controleert of onmisbare tools aanwezig zijn (`supportconfig`, `rear`, `podman`, `rsync`).
- **Bestandssysteem-inspectie**: detecteert automatisch of het root-bestandssysteem op **Btrfs** draait. Zo ja, dan wordt gecontroleerd of **Snapper** geïnstalleerd is voor snapshot-beheer.

## 2. Systeemdocumentatie (`documentatie`)

Maakt een timestamped map aan onder `/var/backups/server-toolkit/documentatie-<DATUM>` en legt de volledige staat van de server vast:

- Draait SUSE's officiële **supportconfig**-tool voor diepgaande diagnostische logs.
- Legt **hardware-, kernel- en geheugenstatistieken** vast (`hostnamectl`, `lscpu`, `free`, `lsblk`, `findmnt`).
- Slaat **netwerkconfiguraties** op (IP, routes, DNS) en actieve/ingeschakelde **systemd-services**.
- Maakt een volledige lijst van alle **geïnstalleerde pakketten** via `zypper se -i`.
- Maakt een veilige kopie van configuratiebestanden uit `/etc` (`.conf`, `.cfg`, `.service`, `.yml`, `.yaml`).

## 3. Systeemback-up (`backup`)

- **Btrfs Snappers**: maakt automatisch een Snapper-snapshot aan van het root-bestandssysteem (`snapper create`) als Btrfs wordt gebruikt.
- **Disaster Recovery (ReaR)**: triggert Relax-and-Recover (`rear mkbackup`) als het configuratiebestand `/etc/rear/local.conf` aanwezig is, om een bare-metal herstel-image te genereren.

## 4. Podman Container Back-up (`containers`)

Exporteert de complete staat van de containeromgeving naar `/var/backups/server-toolkit/containers-<DATUM>`:

- **Inventaris**: slaat lijsten op van draaiende containers, images en volumes.
- **Volume Export**: exporteert elk Podman-volume (`podman volume export`) en comprimeert dit direct via Gzip (`.tar.gz`).
- **Image Saven**: slaat alle lokale container-images op als `.tar`-archieven (`podman save`).
- **Configuratie**: slaat de volledige JSON-inspectiedata van actieve containers op en zoekt naar eventuele `docker-compose.yml` of `compose.yml`-bestanden in de werkmap.

## 5. Automatisch Opruimen / Retentie (`opruimen`)

- **Veiligheidsmechanisme**: voordat oude back-ups worden gewist, controleert het script of er een **recente back-up** bestaat en of de nieuwste back-up **niet ouder is dan 2 dagen**. Dit voorkomt dat het script per ongeluk álle back-ups wist als er iets misgaat.
- **Retentie**: verwijdert back-upmappen die ouder zijn dan de ingestelde retentieperiode van **30 dagen** (`BEWAAR_DAGEN=30`).

---

## 🛡️ Veiligheid en Robuustheid

Het script is geschreven volgens strikte shell-scriptingstandaarden:

| Mechanisme | Werking |
|---|---|
| `set -uo pipefail` | Stopt direct bij niet-gedefinieerde variabelen of fouten in pipes |
| Root-controle | Dwingt af dat het script met rootrechten (`sudo`) wordt uitgevoerd, voor toegang tot alle logbestanden en volumes |


```bash
# Wekelijks: documentatie + containers
0 3 * * 0 /usr/sbin/server-toolkit.sh documentatie >> /var/log/server-toolkit.log 2>&1
30 3 * * 0 /usr/sbin/server-toolkit.sh containers >> /var/log/server-toolkit.log 2>&1

# Maandelijks: ReaR back-up + opruimen (eerste zondag)
0 4 1-7 * 0 /usr/sbin/server-toolkit.sh backup >> /var/log/server-toolkit.log 2>&1
30 5 1-7 * 0 /usr/sbin/server-toolkit.sh opruimen >> /var/log/server-toolkit.log 2>&1
```

