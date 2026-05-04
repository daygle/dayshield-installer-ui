# DayShield Installer UI

Web installer interface for **DayShield Firewall OS**, used by the live ISO.

## What this repo contains

- `installer-ui/`: web UI assets, CGI API scripts, and systemd units.
- Root README: integration quick reference for ISO builds.

## Quick integration

Build the installer-enabled ISO from `dayshield-iso`:

```sh
make iso \
  ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
  INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

## Full docs

See [installer-ui/README.md](installer-ui/README.md) for API, service, and runtime details.

## Offline prerequisites

Before ISO build, ensure these files exist in installer-ui/:

- alpine.min.js
- tailwind.min.js

If missing, fetch them once:

```sh
curl -Lo installer-ui/alpine.min.js "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js"
curl -Lo installer-ui/tailwind.min.js "https://cdn.tailwindcss.com"
```

