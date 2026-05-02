/**
 * DayShield Installer — Alpine.js application
 *
 * Registers the global `installer()` Alpine component.
 * All backend calls hit local shell scripts served by busybox httpd
 * on http://127.0.0.1:8080  (same origin when loaded from the web UI)
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
    ifaces: [],
    loadingIfaces: false,

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
      // Load disks eagerly so step 1 is ready when user arrives
      this.loadDisks();
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

    canProceed() {
      switch (this.step) {
        case 0: return true;
        case 1: return !!this.selectedDisk;
        case 2: return !!this.selectedDisk;
        case 3: return false; // automated — driven by runInstallPipeline()
        case 4: return (
          this.hostname.length > 0 &&
          this.password.length >= 8 &&
          this.password === this.passwordConfirm &&
          !!this.iface
        );
        case 5: return true;
        case 6: return false; // automated
        case 7: return true;
        default: return false;
      }
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
    async callApi(script, params = {}) {
      const qs = new URLSearchParams(params).toString();
      const url = `/api/${script}.sh${qs ? '?' + qs : ''}`;
      let res;
      try {
        res = await fetch(url);
      } catch (e) {
        throw new Error(`Network error calling ${script}: ${e.message}`);
      }

      let data;
      try {
        data = await res.json();
      } catch (_) {
        const text = await res.text().catch(() => '');
        throw new Error(`Script ${script} returned non-JSON response: ${text.slice(0, 200)}`);
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
        this.ifaces = data.ifaces || [];
        if (!this.iface && this.ifaces.length > 0) {
          this.iface = this.ifaces[0];
        }
      } catch (_) {
        // Non-fatal: user can type manually
        this.ifaces = [];
      } finally {
        this.loadingIfaces = false;
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
        disk:     this.selectedDisk,
        hostname: this.hostname,
        password: this.password,
        iface:    this.iface,
      });
    },

    async runFinalize() {
      return this.callApi('finalize', { disk: this.selectedDisk });
    },

    async reboot() {
      try {
        await this.callApi('reboot');
      } catch (_) {
        // Reboot kills the server; network error is expected
      }
    },
  };
}
