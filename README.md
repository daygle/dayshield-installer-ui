# DayShield Installer UI

Offline installer interface for **DayShield Firewall OS**, used by the live ISO.

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
