# DayShield Firewall Installer UI

Web and console installer interface for **DayShield Firewall**, used by the live ISO.

## What this repo contains

- `installer-ui/`: the static web installer frontend, console launcher, CGI API scripts, and live systemd service units.
- `installer-ui/README.md`: the installer runtime and integration reference.

## What this installer does

The installer UI provides an offline setup experience for DayShield live images. It supports:

- **Install DayShield Firewall** for new systems on a blank or prepared disk.
- **Reinstall DayShield Firewall** to overwrite an existing target system with a fresh immutable layout.
- **Local web-based configuration** and console wizard on the live image.

The installer prepares an immutable disk layout:

- immutable system root (`DAYSHIELD_SYSROOT`)
- persistent state partition mounted at `/var` (`DAYSHIELD_STATE`)
- dedicated `/boot` and EFI partitions for boot assets

## Security note

> The installer UI is intentionally unauthenticated. It is designed for one-time local setup on a trusted network or direct console. Do not expose it to untrusted networks.

## Quick integration

Build an installer-enabled ISO from `dayshield-iso`:

```sh
# Either pass ROOTFS_SHA256 explicitly, or place a sibling
# ../dayshield-rootfs/rootfs.tar.zst.sha256 sidecar file.
make iso \
  ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
  ROOTFS_SHA256=<sha256-of-rootfs.tar.zst> \
  INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

## Full docs

See [installer-ui/README.md](installer-ui/README.md) for detailed installer runtime behavior, API endpoints, and service startup information.
