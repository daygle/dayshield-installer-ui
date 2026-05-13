/**
 * DayShield Installer - Alpine.js application
 *
 * Registers the global `installer()` Alpine component.
 * All backend calls hit local shell scripts served by busybox httpd
 * on http://127.0.0.1:8443  (same origin when loaded from the web UI)
 * or via a CGI-like path /api/<script>.sh when using the web service.
 *
 * POSIX scripts return either:
 *   { "ok": true, ... }   on success
 *   { "error": "message" } on failure
 */

function installer() {
  return {
    /* ── State ─────────────────────────────────────────────── */
    step: 0,

    // Disk selection
    disks: [],
    selectedDisk: '',
    loadingDisks: false,

    // Configuration
    hostname: 'dayshield',
    password: '',
    passwordConfirm: '',
    iface: '',
    wanIface: '',
    lanIp: '192.168.1.1',
    lanPrefix: '24',
    lanDhcpEnabled: true,
    dhcpStart: '192.168.1.100',
    dhcpEnd: '192.168.1.199',
    wanType: 'dhcp',
    wanPppoeUser: '',
    wanPppoePass: '',

    // Reboot countdown state
    rebootPending: false,
    rebootCountdown: 10,
    rebootTimer: null,
    ifaces: [],
    loadingIfaces: false,

    // Access details for remote clients (e.g. Windows browser)
    accessIps: [],
    accessUrls: [],
    fallbackIface: '',
    fallbackAssigned: false,
    loadingAccess: false,
    showConnectHelp: false,

    // Progress
    progress: 0,
    configProgress: 0,
    installing: false,
    error: null,

    // Step definitions
    steps: [
      { label: 'Welcome' },
      { label: 'Disk Selection' },
      { label: 'Partitioning' },
      { label: 'Installation' },
      { label: 'Configuration' },
      { label: 'Summary' },
      { label: 'Configuring' },
      { label: 'Complete' },
    ],

    // Installation task list (step 3)
    installTasks: [
      { id: 'partition',  label: 'Creating partitions',         status: 'pending' },
      { id: 'format',     label: 'Formatting partitions',       status: 'pending' },
      { id: 'rootfs',     label: 'Installing root filesystem',  status: 'pending' },
      { id: 'bootloader', label: 'Installing bootloader',       status: 'pending' },
    ],

    // Configuration task list (step 6)
    configTasks: [
      { id: 'configure', label: 'Applying system settings',     status: 'pending' },
      { id: 'finalize',  label: 'Finalizing and unmounting',    status: 'pending' },
    ],

    /* ── Lifecycle ──────────────────────────────────────────── */
    init() {
      // Only show remote-access instructions when the installer UI is opened locally.
      this.showConnectHelp = ['127.0.0.1', 'localhost'].includes(window.location.hostname);
      // Load disks eagerly so step 1 is ready when user arrives
      this.loadDisks();
      this.loadAccessInfo();
    },

    /* ── Navigation helpers ─────────────────────────────────── */
    stepClass(i) {
      if (i === this.step) return 'bg-blue-900/40 text-white';
      if (i < this.step)  return 'text-green-400';
      return 'text-gray-600';
    },

    stepBadgeClass(i) {
      if (i === this.step) return 'bg-blue-600 text-white';
      if (i < this.step)  return 'bg-green-700 text-white';
      return 'bg-gray-800 text-gray-600';
    },

    selectedDiskInfo() {
      return this.disks.find(d => d.name === this.selectedDisk) || null;
    },

    isValidIpv4(value) {
      const text = (value || '').trim();
      if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(text)) return false;
      const octets = text.split('.');
      return octets.length === 4 && octets.every(o => {
        const n = Number(o);
        return Number.isInteger(n) && n >= 0 && n <= 255;
      });
    },

    partitionPath(number) {
      const disk = (this.selectedDisk || '').trim();
      if (!disk) return '';
      return `/dev/${disk}${/^(nvme|mmcblk)/.test(disk) ? 'p' : ''}${number}`;
    },

    canProceed() {
      const lan = (this.iface || '').trim();
      const wan = (this.wanIface || '').trim();
      switch (this.step) {
        case 0: return true;
        case 1: return !!this.selectedDisk;
        case 2: return !!this.selectedDisk;
        case 3: return false; // automated - driven by runInstallPipeline()
        case 4: {
          const ipValid = this.isValidIpv4(this.lanIp);
          const prefix = Number((this.lanPrefix || '').trim());
          const prefixValid = Number.isInteger(prefix) && prefix >= 1 && prefix <= 32;
          const dhcpStartValid = this.isValidIpv4(this.dhcpStart);
          const dhcpEndValid = this.isValidIpv4(this.dhcpEnd);
          return (
            this.hostname.length > 0 &&
            this.password.length >= 8 &&
            !this.passwordError() &&
            this.password === this.passwordConfirm &&
            !!lan &&
            !!wan &&
            ipValid &&
            prefixValid &&
            wan !== lan &&
            (this.wanType !== 'pppoe' || (!!this.wanPppoeUser && !!this.wanPppoePass)) &&
            (!this.lanDhcpEnabled || (dhcpStartValid && dhcpEndValid))
          );
        }
        case 5: return true;
        case 6: return false; // automated
        case 7: return true;
        default: return false;
      }
    },

    passwordError() {
      const p = this.password;
      if (p.length < 8) return '';
      if (!/[A-Z]/.test(p)) return 'Password must contain at least one uppercase letter.';
      if (!/[a-z]/.test(p)) return 'Password must contain at least one lowercase letter.';
      if (!/[^a-zA-Z]/.test(p)) return 'Password must contain at least one digit or special character.';
      return '';
    },

    nextLabel() {
      switch (this.step) {
        case 0: return 'Start';
        case 2: return 'Partition & Install';
        case 5: return 'Install';
        default: return 'Next';
      }
    },

    async next() {
      this.error = null;
      switch (this.step) {
        case 0:
          this.step = 1;
          break;
        case 1:
          this.step = 2;
          break;
        case 2:
          // Move to installation step and kick off pipeline
          this.step = 3;
          await this.runInstallPipeline();
          break;
        case 3:
          // Should not be reachable while installing; handled by pipeline completion
          break;
        case 4:
          await this.loadIfaces(); // refresh if needed
          this.iface = (this.iface || '').trim();
          this.wanIface = (this.wanIface || '').trim();
          this.step = 5;
          break;
        case 5:
          this.step = 6;
          await this.runConfigPipeline();
          break;
        default:
          if (this.step < this.steps.length - 1) this.step++;
      }
    },

    back() {
      if (this.step > 0 && !this.installing) {
        this.error = null;
        this.step--;
      }
    },

    /* ── API helpers ────────────────────────────────────────── */

    /**
     * Call a local shell script and return parsed JSON.
     * Scripts are served via busybox httpd CGI at /api/<name>.sh
     * Query parameters are passed as a URL query string.
     *
     * @param {string} script   - e.g. "detect-disks"
     * @param {object} params   - key/value pairs appended as ?key=value
     * @returns {object}        - parsed response JSON
     * @throws  {Error}         - if network or script error
     */
    async callApi(script, params = {}, method = 'GET') {
      const qs = new URLSearchParams(params).toString();
      const url = `/api/${script}.sh${method === 'GET' && qs ? '?' + qs : ''}`;
      const fetchOptions = {
        method,
      };

      if (method === 'POST') {
        fetchOptions.headers = {
          'Content-Type': 'application/x-www-form-urlencoded',
        };
        fetchOptions.body = qs;
      }

      let res;
      try {
        res = await fetch(url, fetchOptions);
      } catch (e) {
        throw new Error(`Network error calling ${script}: ${e.message}`);
      }

      const text = await res.text().catch(() => '');
      const normalizedText = text.replace(/\r\n/g, '\n');
      const bodyText = normalizedText.replace(/^Content-Type:[^\n]*\n(?:[^\n]*\n)*\n/, '');

      let data;
      try {
        data = bodyText ? JSON.parse(bodyText) : null;
      } catch (_) {
        throw new Error(`Script ${script} returned non-JSON response: ${bodyText.slice(0, 200)}`);
      }

      if (!data) {
        throw new Error(`Script ${script} returned empty response`);
      }

      if (data.error) throw new Error(data.error);
      if (!res.ok && !data.ok) throw new Error(`Script ${script} failed with HTTP ${res.status}`);
      return data;
    },

    /* ── Disk detection ─────────────────────────────────────── */
    async loadDisks() {
      this.loadingDisks = true;
      this.error = null;
      try {
        const data = await this.callApi('detect-disks');
        this.disks = data.disks || [];
        if (this.disks.length === 1) {
          this.selectedDisk = this.disks[0].name;
        }
      } catch (e) {
        this.error = e.message;
        this.disks = [];
      } finally {
        this.loadingDisks = false;
      }
    },

    /* ── Network interface detection ────────────────────────── */
    async loadIfaces() {
      this.loadingIfaces = true;
      try {
        const data = await this.callApi('detect-ifaces');
        const normalizedIfaces = (data.ifaces || [])
          .map(i => (i || '').trim())
          .filter(Boolean);
        this.ifaces = [...new Set(normalizedIfaces)];

        this.iface = (this.iface || '').trim();
        this.wanIface = (this.wanIface || '').trim();

        if (!this.wanIface && this.ifaces.length > 0) {
          this.wanIface = this.ifaces[0];
        }

        if (!this.iface && this.ifaces.length > 0) {
          const lanCandidate = this.ifaces.find(i => i !== this.wanIface);
          this.iface = lanCandidate || this.ifaces[0];
        }

        if (this.wanIface && !this.ifaces.includes(this.wanIface)) {
          this.wanIface = this.ifaces[0] || '';
        }
        if (this.iface && !this.ifaces.includes(this.iface)) {
          const lanCandidate = this.ifaces.find(i => i !== this.wanIface);
          this.iface = lanCandidate || this.ifaces[0] || '';
        }
      } catch (_) {
        // Non-fatal: user can type manually
        this.ifaces = [];
      } finally {
        this.loadingIfaces = false;
      }
    },

    async loadAccessInfo() {
      this.loadingAccess = true;
      try {
        const data = await this.callApi('detect-access');
        this.accessIps = data.ips || [];
        this.accessUrls = (data.urls || []).filter(u => !u.includes('127.0.0.1'));
        this.fallbackIface = data.fallback_iface || '';
        this.fallbackAssigned = !!data.fallback_assigned;
      } catch (_) {
        // Non-fatal: keep installer usable even if access detection fails.
        this.accessIps = [];
        this.accessUrls = [];
        this.fallbackIface = '';
        this.fallbackAssigned = false;
      } finally {
        this.loadingAccess = false;
      }
    },

    /* ── Task state helpers ─────────────────────────────────── */
    setTaskStatus(list, id, status) {
      const t = list.find(t => t.id === id);
      if (t) t.status = status;
    },

    /* ── Installation pipeline ──────────────────────────────── */
    async runInstallPipeline() {
      this.installing = true;
      this.progress = 0;
      // Reset task statuses
      this.installTasks.forEach(t => t.status = 'pending');

      const steps = [
        {
          id: 'partition',
          fn: () => this.runPartition(),
          weight: 10,
        },
        {
          id: 'format',
          fn: () => this.runFormat(),
          weight: 10,
        },
        {
          id: 'rootfs',
          fn: () => this.runInstallRootfs(),
          weight: 60,
        },
        {
          id: 'bootloader',
          fn: () => this.runInstallBootloader(),
          weight: 20,
        },
      ];

      let accumulated = 0;
      for (const s of steps) {
        this.setTaskStatus(this.installTasks, s.id, 'running');
        try {
          await s.fn();
          this.setTaskStatus(this.installTasks, s.id, 'done');
          accumulated += s.weight;
          this.progress = accumulated;
        } catch (e) {
          this.setTaskStatus(this.installTasks, s.id, 'error');
          this.error = e.message;
          this.installing = false;
          return;
        }
      }

      this.progress = 100;
      this.installing = false;
      // Move to configuration step
      await this.$nextTick();
      this.step = 4;
      this.loadIfaces();
    },

    /* ── Configuration pipeline ─────────────────────────────── */
    async runConfigPipeline() {
      this.installing = true;
      this.configProgress = 0;
      this.configTasks.forEach(t => t.status = 'pending');

      const steps = [
        {
          id: 'configure',
          fn: () => this.runConfigureSystem(),
          weight: 70,
        },
        {
          id: 'finalize',
          fn: () => this.runFinalize(),
          weight: 30,
        },
      ];

      let accumulated = 0;
      for (const s of steps) {
        this.setTaskStatus(this.configTasks, s.id, 'running');
        try {
          await s.fn();
          this.setTaskStatus(this.configTasks, s.id, 'done');
          accumulated += s.weight;
          this.configProgress = accumulated;
        } catch (e) {
          this.setTaskStatus(this.configTasks, s.id, 'error');
          this.error = e.message;
          this.installing = false;
          return;
        }
      }

      this.configProgress = 100;
      this.installing = false;
      await this.$nextTick();
      this.step = 7;
    },

    /* ── Individual API calls ───────────────────────────────── */
    async runPartition() {
      return this.callApi('partition', { disk: this.selectedDisk });
    },

    async runFormat() {
      return this.callApi('format', { disk: this.selectedDisk });
    },

    async runInstallRootfs() {
      return this.callApi('install-rootfs', { disk: this.selectedDisk });
    },

    async runInstallBootloader() {
      return this.callApi('install-bootloader', { disk: this.selectedDisk });
    },

    async runConfigureSystem() {
      return this.callApi('configure-system', {
        disk:            this.selectedDisk,
        hostname:        this.hostname,
        password:        this.password,
        iface:           (this.iface || '').trim(),
        wan_iface:       (this.wanIface || '').trim(),
        lan_ip:          (this.lanIp || '').trim(),
        lan_prefix:      (this.lanPrefix || '').trim(),
        lan_dhcp_enable: this.lanDhcpEnabled ? 'yes' : 'no',
        wan_type:        this.wanType,
        wan_pppoe_user:  this.wanPppoeUser,
        wan_pppoe_pass:  this.wanPppoePass,
        dhcp_start:      (this.dhcpStart || '').trim(),
        dhcp_end:        (this.dhcpEnd || '').trim(),
      }, 'POST');
    },

    async runFinalize() {
      return this.callApi('finalize', { disk: this.selectedDisk });
    },

    async reboot() {
      if (this.rebootPending) return;

      this.rebootPending = true;
      this.rebootCountdown = 10;

      this.rebootTimer = setInterval(async () => {
        if (this.rebootCountdown <= 1) {
          clearInterval(this.rebootTimer);
          this.rebootTimer = null;
          this.rebootCountdown = 0;
          try {
            await this.callApi('reboot');
          } catch (e) {
            // Reboot kills the server; network error is expected.
            // If the request fails before reboot starts, show the error.
            if (!/network error/i.test(e.message)) {
              this.error = e.message;
            }
          }
          return;
        }

        this.rebootCountdown -= 1;
      }, 1000);
    },
  };
}
