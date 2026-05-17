# DayShield Firewall Installer UI

Web and console installer interface for **DayShield Firewall**, used by the live ISO.

## What this repo contains

- `installer-ui/`: web UI assets, console wizard, CGI API scripts, and systemd units.
- Root README: integration quick reference for ISO builds.

> Note: the web installer is intended as a one-time local setup interface on a trusted network or direct console. It is not protected by authentication, so it should not be exposed to untrusted networks.

The live installer supports both **Upgrade from ISO** for existing A/B
appliances and **Reinstall from ISO** for fresh destructive installs.

## Quick integration

Build the installer-enabled ISO from `dayshield-iso`:

```sh
# Either pass ROOTFS_SHA256 explicitly, or place a sibling
# ../dayshield-rootfs/rootfs.tar.zst.sha256 sidecar file.
make iso \
  ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
  ROOTFS_SHA256=<sha256-of-rootfs.tar.zst> \
  INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

## Full docs

See [installer-ui/README.md](installer-ui/README.md) for API, service, and runtime details.
