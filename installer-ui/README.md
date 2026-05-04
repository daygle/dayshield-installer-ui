# DayShield Installer UI

A minimal, offline, deterministic installer UI for DayShield Firewall OS.

Runs on tty1 (physical console) and is served by busybox httpd on 0.0.0.0:8080 inside the live environment.

Default ISO behavior is to auto-start the web service. The tty1 launcher can be
started manually if desired.

## Stack

| Layer | Technology |
|-------|-----------|
| Markup | HTML5 |
| Styles | Tailwind CSS v3 runtime (bundled script) |
| Reactivity | Alpine.js |
| Backend | POSIX sh scripts (busybox ash compatible) |
| HTTP server | busybox httpd |
| Init | systemd |

---

## Repository Structure

```text
installer-ui/
|-- index.html               # Main installer UI (Alpine + Tailwind runtime)
|-- styles.css               # Plain browser CSS only (no build step)
|-- app.js                   # Alpine application state and logic
|-- alpine.min.js            # Alpine bundle (committed for offline use)
|-- tailwind.min.js          # Tailwind runtime bundle (committed for offline use)
|-- httpd.conf               # busybox httpd CGI configuration
|-- api/
|   |-- detect-disks.sh      # List block disks -> JSON
|   |-- detect-ifaces.sh     # List network interfaces -> JSON
|   |-- partition.sh         # GPT + EFI + root partition creation
|   |-- format.sh            # FAT32 EFI + ext4 root formatting
|   |-- install-rootfs.sh    # Mount + extract rootfs.tar.zst from ISO
|   |-- install-bootloader.sh# GRUB BIOS + UEFI install
|   |-- configure-system.sh  # Hostname, password, network, fstab, services
|   |-- finalize.sh          # Unmount, sync, clean temp files
|   `-- reboot.sh            # systemctl reboot
`-- systemd/
    |-- installer-ui.service     # Console launcher
    `-- installer-ui-web.service # busybox httpd service
```

---

## Offline Operation

No external resources are fetched at install time.

Required files before ISO build:

| File | Description |
|------|-------------|
| installer-ui/alpine.min.js | Alpine reactive framework bundle |
| installer-ui/tailwind.min.js | Tailwind runtime bundle |

Fetch/update both bundles (run on build host when refreshing versions):

```bash
curl -Lo installer-ui/alpine.min.js \
  "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js"

curl -Lo installer-ui/tailwind.min.js \
  "https://cdn.tailwindcss.com"
```

---

## CSS Architecture

styles.css contains only plain browser-native CSS (focus rings, scroll behavior, font smoothing).

Tailwind utility classes and component classes that use @apply are processed at runtime by tailwind.min.js via inline blocks in index.html:

- script block: tailwind.config = { ... }
- style block: <style type="text/tailwindcss"> ... </style>

No Tailwind compile step is required for ISO builds.

---

## Integrating With ISO Build

From the dayshield-iso repository:

```bash
make iso \
  ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
  INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

The ISO pipeline validates installer assets and fails fast if any required file is missing.
