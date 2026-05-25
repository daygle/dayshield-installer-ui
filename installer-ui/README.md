# DayShield Installer UI

The installer UI provides an offline web-based setup experience for DayShield live images and ISOs. It runs in the live environment on `tty1` and is served by `busybox httpd` on port `8443`.

## Purpose

This repository contains the static installer frontend and shell-backed API scripts used during installation and initial system configuration.

- `index.html`, `app.js`, `styles.css` — browser UI
- `api/*.sh` — installer actions exposed as CGI endpoints
- `httpd.conf` — busybox httpd configuration
- `systemd/` — live service units for console and web installer startup
- `alpine.min.js`, `tailwind.min.js` — offline runtime bundles committed for air-gapped installs

## Offline operation

No external CDN resources are fetched during install. The runtime bundles are included in the repo so the installer UI works in offline and air-gapped environments.

## Integration

The ISO build uses this folder as the installer UI source. In `dayshield-iso`, point `INSTALLER_UI` at this directory when building the image.

Example:

```bash
make iso \
  ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
  ROOTFS_SHA256=<sha256-of-rootfs.tar.zst> \
  INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

## Notes

- The installer UI is intentionally unauthenticated. It is designed for one-time local setup on a trusted network or directly from the installation console.
- The live installer exposes a temporary web UI on `http://<live-ip>:8443/`.
- There is no separate build step for this repo; the UI is shipped as static assets.
- The installer writes an OSTree-ready immutable layout: `DAYSHIELD_SYSROOT` for system content and `DAYSHIELD_STATE` mounted at `/var` for persistent state.
