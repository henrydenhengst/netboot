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

## 📂 Project Structuur

```text
freeboot-infra-core/
├── .github/
│   └── workflows/              # CI/CD linting voor Ansible playbooks
├── ansible/
│   ├── inventory.yml           # Host definities (192.168.192.0/18 subnet)
│   ├── site.yml                # Hoofdplaybook
│   └── roles/
│       ├── host_base/          # openSUSE Leap, KVM, br0 bridge, packages
│       ├── podman_services/    # Podman systemd units voor Forgejo & DokuWiki
│       └── netboot_pxe/        # Lokale iPXE / netboot.xyz menu configuratie
├── containers/
│   ├── docker-compose.yml      # Podman-compatible compose voor Forgejo & DokuWiki
│   ├── forgejo/
│   │   └── app.ini.template    # Configuratie template
│   └── dokuwiki/
│       └── local.php           # Flat-file instellingen
└── tftp/
    └── custom.ipxe             # Lokale netboot.xyz custom menu override
