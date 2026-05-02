# DayShield Installer UI

A minimal, offline, deterministic installer UI for **DayShield Firewall OS**.

Runs on `tty1` (physical console) and optionally as a local web UI at `http://127.0.0.1:8080`.

## Stack

| Layer | Technology |
|-------|-----------|
| Markup | HTML5 |
| Styles | Tailwind CSS v3 |
| Reactivity | Alpine.js |
| Backend | POSIX sh scripts (busybox ash compatible) |
| HTTP server | busybox httpd |
| Init | systemd |

---

## Repository Structure

```
installer-ui/
├── index.html               # Main installer UI (Alpine.js + Tailwind)
├── styles.css               # Tailwind CSS (build input + custom components)
├── app.js                   # Alpine.js application state & logic
├── alpine.min.js            # Alpine.js bundle (copy from releases — offline)
├── httpd.conf               # busybox httpd CGI configuration
├── api/
│   ├── detect-disks.sh      # List block disks → JSON
│   ├── detect-ifaces.sh     # List network interfaces → JSON
│   ├── partition.sh         # GPT + EFI + root partition creation
│   ├── format.sh            # FAT32 EFI + ext4 root formatting
│   ├── install-rootfs.sh    # Mount + extract /run/installer/rootfs.tar.zst
│   ├── install-bootloader.sh# GRUB BIOS + UEFI install
│   ├── configure-system.sh  # Hostname, password, network, fstab, services
│   ├── finalize.sh          # Unmount, sync, clean temp files
│   └── reboot.sh            # systemctl reboot
└── systemd/
    ├── installer-ui.service     # tty1 launcher (browser or text fallback)
    └── installer-ui-web.service # busybox httpd on 127.0.0.1:8080
```

---

## How It Works

### Installation Flow

```
Welcome → Disk Selection → Partition Summary
       → [auto] Partition → Format → Install rootfs → Install bootloader
       → Configuration (hostname / password / iface)
       → Summary → [auto] Configure system → Finalize
       → Complete → Reboot
```

### API Layer

The web UI communicates exclusively with local shell scripts via `fetch()` calls
to `/api/<script>.sh?param=value`.  Scripts are executed as CGI by busybox httpd.

Every script:
- Prints a `Content-Type: application/json` CGI header
- Reads parameters from `$QUERY_STRING`
- Returns `{"ok":true}` on success
- Returns `{"error":"<message>"}` and exits non-zero on failure
- Is POSIX-compliant (tested with busybox ash)

### Offline Operation

No external resources are fetched at install time.  The only file that must be
present on the ISO but is not committed here is:

| File | Description |
|------|-------------|
| `/installer-ui/alpine.min.js` | Alpine.js bundle (copy from CDN before ISO build) |
| `/run/installer/rootfs.tar.zst` | DayShield root filesystem archive |
| `/run/installer/defaults/` | Optional `/etc/dayshield` overlay files |

---

## Building Tailwind CSS

The committed `styles.css` contains Tailwind directives and custom component
classes.  To compile for production:

```bash
# Install Tailwind CLI (build machine only — not needed on target)
npm install -D tailwindcss

# Generate compiled stylesheet
npx tailwindcss -i installer-ui/styles.css \
                -o installer-ui/dist/styles.css \
                --content "installer-ui/index.html,installer-ui/app.js" \
                --minify

# Then update index.html to reference dist/styles.css
```

For the ISO build, replace the `<link>` in `index.html` with the compiled output.

---

## Testing in QEMU

### Prerequisites

```bash
# Host packages (Debian/Ubuntu)
sudo apt-get install qemu-system-x86 ovmf busybox-static
```

### Quick Start

```bash
# 1. Create a virtual disk
qemu-img create -f qcow2 /tmp/dayshield-test.qcow2 20G

# 2. Prepare a fake rootfs archive (for UI testing without a real rootfs)
mkdir -p /tmp/fake-rootfs/etc/dayshield /tmp/fake-rootfs/boot
tar -C /tmp/fake-rootfs -cJf /tmp/rootfs.tar.zst .

# 3. Copy installer UI files
mkdir -p /tmp/installer-iso/installer-ui/api
cp -r installer-ui/* /tmp/installer-iso/installer-ui/
chmod +x /tmp/installer-iso/installer-ui/api/*.sh
mkdir -p /tmp/installer-iso/run/installer
cp /tmp/rootfs.tar.zst /tmp/installer-iso/run/installer/

# 4. Start busybox httpd manually for local testing
cd /tmp/installer-iso/installer-ui
busybox httpd -f -p 127.0.0.1:8080 -h . &
xdg-open http://127.0.0.1:8080/

# 5. Run QEMU with the live environment (when full ISO is available)
qemu-system-x86_64 \
  -m 2G \
  -enable-kvm \
  -drive file=/tmp/dayshield-test.qcow2,format=qcow2 \
  -cdrom dayshield-installer.iso \
  -boot d \
  -bios /usr/share/ovmf/OVMF.fd \
  -nographic
```

### Smoke-testing the API Scripts

```bash
# Test disk detection
QUERY_STRING="" sh installer-ui/api/detect-disks.sh

# Test partitioning (WARNING: this will modify the disk!)
QUERY_STRING="disk=sdb" sh installer-ui/api/partition.sh

# Test formatting
QUERY_STRING="disk=sdb" sh installer-ui/api/format.sh
```

---

## Integrating with the ISO Builder

Add the following to your ISO build script after rootfs extraction:

```bash
# Copy installer UI
cp -r installer-ui/         "${ISO_ROOT}/installer-ui/"
chmod +x "${ISO_ROOT}/installer-ui/api/"*.sh

# Copy rootfs archive
cp rootfs.tar.zst           "${ISO_ROOT}/run/installer/rootfs.tar.zst"

# Copy /etc/dayshield defaults (optional)
cp -r defaults/             "${ISO_ROOT}/run/installer/defaults/"

# Install Alpine.js bundle (download once during ISO build)
curl -Lo "${ISO_ROOT}/installer-ui/alpine.min.js" \
  "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js"

# Install systemd units
cp installer-ui/systemd/installer-ui.service \
   installer-ui/systemd/installer-ui-web.service \
   "${ISO_ROOT}/etc/systemd/system/"

# Enable services
ln -sf /etc/systemd/system/installer-ui.service \
       "${ISO_ROOT}/etc/systemd/system/multi-user.target.wants/"
ln -sf /etc/systemd/system/installer-ui-web.service \
       "${ISO_ROOT}/etc/systemd/system/multi-user.target.wants/"
```

---

## Customizing Installer Steps

### Adding a New Step

1. Add an entry to the `steps` array in `app.js`:
   ```js
   { label: 'Time Zone' },
   ```

2. Add corresponding HTML in `index.html`:
   ```html
   <div x-show="step === N" x-transition class="...">
     <!-- step content -->
   </div>
   ```

3. Update `canProceed()` in `app.js` for the new step index.

4. Update `next()` to handle navigation to/from the new step.

### Adding a New API Script

1. Create `installer-ui/api/my-script.sh`:
   ```sh
   #!/bin/sh
   set -eu
   printf 'Content-Type: application/json\r\n'
   printf '\r\n'
   # ... your logic ...
   printf '{"ok":true}\n'
   ```

2. Make it executable:
   ```bash
   chmod +x installer-ui/api/my-script.sh
   ```

3. Call it from `app.js`:
   ```js
   await this.callApi('my-script', { param: value });
   ```

---

## Security Notes

- The web UI listens on `127.0.0.1:8080` **only** (loopback).
- Scripts run as root on the live ISO — this is required for disk operations.
- Passwords are hashed with SHA-512 (openssl passwd -6) before writing to `/etc/shadow`.
- No external network connections are made during installation.
- The installer service is intended to be disabled or removed from the installed system; it only runs on the live ISO.

---

## License

Part of the DayShield Firewall OS project.
