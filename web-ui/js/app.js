/**
 * DStack Web UI - Main Application
 * Vanilla JS, no framework dependencies
 */

(function() {
  'use strict';

  // ==========================================================================
  // Configuration & Constants
  // ==========================================================================
  const CONFIG = {
    apiBase: '/api',
    refreshIntervals: {
      services: 5000,
      logs: 3000,
      health: 30000
    },
    toastDuration: 5000,
    maxLogLines: 100
  };

  const SERVICES = ['nginx', 'php', 'mysql', 'redis', 'phpmyadmin'];
  const SERVICE_LABELS = {
    nginx: 'Nginx',
    php: 'PHP-FPM',
    mysql: 'MySQL',
    redis: 'Redis',
    phpmyadmin: 'phpMyAdmin'
  };

  const FRAMEWORKS = [
    { value: 'php', label: 'PHP (Generic)' },
    { value: 'laravel', label: 'Laravel' },
    { value: 'symfony', label: 'Symfony' },
    { value: 'wordpress', label: 'WordPress' },
    { value: 'static', label: 'Static HTML' }
  ];

  // ==========================================================================
  // State
  // ==========================================================================
  const state = {
    theme: 'light',
    services: {},
    vhosts: [],
    certs: [],
    rdsStatus: {},
    backups: [],
    logs: {
      currentService: 'all',
      autoRefresh: true,
      polling: false
    },
    modals: {
      vhost: null,
      backup: null,
      restore: null
    },
    timers: {},
    toasts: []
  };

  // ==========================================================================
  // DOM Element Cache
  // ==========================================================================
  const els = {};

  function cacheElements() {
    // Header
    els.themeToggle = document.getElementById('theme-toggle');
    els.startAllBtn = document.getElementById('start-all-btn');
    els.stopAllBtn = document.getElementById('stop-all-btn');
    els.healthStatus = document.getElementById('health-status');
    els.banner = document.getElementById('api-banner');
    els.bannerMessage = document.getElementById('banner-message');
    els.dismissBanner = document.getElementById('dismiss-banner');

    // Services
    els.servicesGrid = document.getElementById('services-grid');
    els.servicesLastUpdated = document.getElementById('services-last-updated');

    // Vhosts
    els.vhostsTableBody = document.getElementById('vhosts-tbody');
    els.addVhostBtn = document.getElementById('add-vhost-btn');
    els.vhostModal = document.getElementById('vhost-modal');
    els.vhostForm = document.getElementById('vhost-form');
    els.vhostDomain = document.getElementById('vhost-domain');
    els.vhostFramework = document.getElementById('vhost-framework');
    els.vhostRoot = document.getElementById('vhost-root');

    // SSL
    els.certsTableBody = document.getElementById('certs-tbody');
    els.localSslForm = document.getElementById('local-ssl-form');
    els.localSslDomain = document.getElementById('local-ssl-domain');
    els.letsencryptForm = document.getElementById('letsencrypt-form');
    els.letsencryptDomain = document.getElementById('letsencrypt-domain');
    els.letsencryptEmail = document.getElementById('letsencrypt-email');

    // RDS
    els.rdsForm = document.getElementById('rds-form');
    els.rdsStartBtn = document.getElementById('rds-start-btn');
    els.rdsStopBtn = document.getElementById('rds-stop-btn');
    els.rdsStatusCard = document.querySelector('.rds-status-card');

    // Logs
    els.logsServiceSelect = document.getElementById('logs-service-select');
    els.logsAutoRefresh = document.getElementById('logs-auto-refresh');
    els.logsClearBtn = document.getElementById('logs-clear-btn');
    els.logsViewer = document.getElementById('logs-viewer');

    // Backups
    els.createBackupBtn = document.getElementById('create-backup-btn');
    els.backupsTableBody = document.getElementById('backups-tbody');
    els.backupModal = document.getElementById('backup-modal');
    els.backupForm = document.getElementById('backup-form');
    els.backupDatabase = document.getElementById('backup-database');
    els.backupDescription = document.getElementById('backup-description');
    els.restoreModal = document.getElementById('restore-modal');
    els.restoreBackupId = document.getElementById('restore-backup-id');
    els.restoreDatabase = document.getElementById('restore-database');
    els.restoreConfirmBtn = document.getElementById('restore-confirm-btn');

    // Toast container
    els.toastContainer = document.getElementById('toast-container');

    // Modal close buttons
    document.querySelectorAll('.modal-close, .modal-cancel').forEach(btn => {
      btn.addEventListener('click', (e) => {
        const modal = e.target.closest('.modal');
        if (modal) closeModal(modal.id);
      });
    });

    // Modal overlays
    document.querySelectorAll('.modal-overlay').forEach(overlay => {
      overlay.addEventListener('click', (e) => {
        const modal = e.target.closest('.modal');
        if (modal) closeModal(modal.id);
      });
    });
  }

  // ==========================================================================
  // API Helper
  // ==========================================================================
  async function api(path, options = {}) {
    const url = `${CONFIG.apiBase}${path}`;
    const defaultOptions = {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    };

    const mergedOptions = {
      ...defaultOptions,
      ...options,
      headers: {
        ...defaultOptions.headers,
        ...(options.headers || {})
      }
    };

    if (mergedOptions.body && typeof mergedOptions.body === 'object') {
      mergedOptions.body = JSON.stringify(mergedOptions.body);
    }

    try {
      const response = await fetch(url, mergedOptions);

      if (!response.ok) {
        let errorData = { message: `HTTP ${response.status}: ${response.statusText}` };
        try {
          errorData = await response.json();
        } catch (e) {
          // Use default error
        }
        throw new Error(errorData.error || errorData.message || errorData);
      }

      if (response.status === 204) {
        return null;
      }

      return await response.json();
    } catch (error) {
      // Don't show toast for network errors during polling
      if (!options.silent) {
        showToast('error', 'API Error', error.message);
      }
      throw error;
    }
  }

  // ==========================================================================
  // Theme Management
  // ==========================================================================
  function initTheme() {
    const savedTheme = localStorage.getItem('theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    state.theme = savedTheme || (prefersDark ? 'dark' : 'light');
    applyTheme(state.theme);
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    state.theme = theme;
    localStorage.setItem('theme', theme);
  }

  function toggleTheme() {
    applyTheme(state.theme === 'dark' ? 'light' : 'dark');
  }

  // ==========================================================================
  // Toast Notifications
  // ==========================================================================
  function showToast(type, title, message) {
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.innerHTML = `
      <svg class="toast-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        ${getToastIcon(type)}
      </svg>
      <div class="toast-content">
        <div class="toast-title">${escapeHtml(title)}</div>
        <div class="toast-message">${escapeHtml(message)}</div>
      </div>
      <button class="toast-close" aria-label="Dismiss">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"></line>
          <line x1="6" y1="6" x2="18" y2="18"></line>
        </svg>
      </button>
    `;

    const closeBtn = toast.querySelector('.toast-close');
    closeBtn.addEventListener('click', () => removeToast(toast));

    els.toastContainer.appendChild(toast);
    state.toasts.push(toast);

    // Auto-remove
    setTimeout(() => removeToast(toast), CONFIG.toastDuration);

    return toast;
  }

  function getToastIcon(type) {
    switch (type) {
      case 'success':
        return '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline>';
      case 'error':
        return '<circle cx="12" cy="12" r="10"></circle><line x1="15" y1="9" x2="9" y2="15"></line><line x1="9" y1="9" x2="15" y2="15"></line>';
      case 'warning':
        return '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line>';
      default:
        return '<circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line>';
    }
  }

  function removeToast(toast) {
    if (!toast.classList.contains('removing')) {
      toast.classList.add('removing');
      toast.addEventListener('animationend', () => toast.remove());
      state.toasts = state.toasts.filter(t => t !== toast);
    }
  }

  // ==========================================================================
  // Modal Management
  // ==========================================================================
  function openModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
      modal.classList.remove('hidden');
      document.body.style.overflow = 'hidden';
      // Focus first input
      const firstInput = modal.querySelector('input, select, textarea');
      if (firstInput) {
        setTimeout(() => firstInput.focus(), 100);
      }
    }
  }

  function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
      modal.classList.add('hidden');
      document.body.style.overflow = '';
      // Reset forms
      const form = modal.querySelector('form');
      if (form) form.reset();
    }
  }

  // ==========================================================================
  // Utility Functions
  // ==========================================================================
  function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function formatDate(isoString) {
    const date = new Date(isoString);
    return date.toLocaleString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  }

  function formatRelativeTime(isoString) {
    const date = new Date(isoString);
    const now = new Date();
    const diff = now - date;

    if (diff < 1000) return 'just now';
    if (diff < 60000) return `${Math.floor(diff / 1000)}s ago`;
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
    return formatDate(isoString);
  }

  function getStatusClass(status, state) {
    if (status === 'running' || state === 'running') return 'running';
    if (status === 'stopped' || state === 'stopped') return 'stopped';
    if (status === 'starting' || status === 'stopping') return status;
    return 'unknown';
  }

  function getStatusLabel(status, state) {
    const s = status || state || 'unknown';
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function debounce(fn, delay) {
    let timeoutId;
    return (...args) => {
      clearTimeout(timeoutId);
      timeoutId = setTimeout(() => fn(...args), delay);
    };
  }

  // ==========================================================================
  // Health Check
  // ==========================================================================
  async function checkHealth() {
    try {
      const data = await api('/health', { silent: true });
      if (data && data.status === 'ok') {
        els.healthStatus.classList.remove('unhealthy');
        els.healthStatus.querySelector('.status-dot').className = 'status-dot status-healthy';
        els.healthStatus.querySelector('span:last-child').textContent = 'API Healthy';
      } else {
        throw new Error('Unhealthy');
      }
    } catch (error) {
      els.healthStatus.classList.add('unhealthy');
      els.healthStatus.querySelector('.status-dot').className = 'status-dot';
      els.healthStatus.querySelector('.status-dot').style.backgroundColor = 'var(--color-danger)';
      els.healthStatus.querySelector('span:last-child').textContent = 'API Unreachable';
    }
  }

  // ==========================================================================
  // Services
  // ==========================================================================
  async function loadServices() {
    try {
      const data = await api('/services', { silent: true });
      if (data && !data.error) {
        state.services = data;
        renderServices();
        updateGlobalControls();
      } else if (data && data.error) {
        showBanner('Daemon error: ' + data.error);
      }
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderServices() {
    const fragment = document.createDocumentFragment();

    SERVICES.forEach(service => {
      const svc = state.services[service] || {};
      const status = svc.status || svc.state || 'unknown';
      const health = svc.health || 'unknown';
      const statusClass = getStatusClass(status, svc.state);

      const card = document.createElement('div');
      card.className = 'card service-card';
      card.dataset.service = service;

      card.innerHTML = `
        <div class="service-header">
          <h3 class="service-name">${escapeHtml(SERVICE_LABELS[service])}</h3>
          <span class="service-status ${statusClass}">
            <span class="status-dot"></span>
            ${escapeHtml(getStatusLabel(status, svc.state))}
          </span>
        </div>
        <div class="service-details">
          <div class="service-detail">
            <span class="service-detail-label">Status</span>
            <span class="service-detail-value">${escapeHtml(status)}</span>
          </div>
          <div class="service-detail">
            <span class="service-detail-label">Health</span>
            <span class="service-detail-value">${escapeHtml(health)}</span>
          </div>
          ${svc.pid ? `
          <div class="service-detail">
            <span class="service-detail-label">PID</span>
            <span class="service-detail-value">${escapeHtml(String(svc.pid))}</span>
          </div>
          ` : ''}
          ${svc.uptime ? `
          <div class="service-detail">
            <span class="service-detail-label">Uptime</span>
            <span class="service-detail-value">${escapeHtml(svc.uptime)}</span>
          </div>
          ` : ''}
        </div>
        <div class="service-actions">
          <button class="btn btn-sm btn-success" data-action="start" data-service="${service}" ${status === 'running' ? 'disabled' : ''}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>
            Start
          </button>
          <button class="btn btn-sm btn-danger" data-action="stop" data-service="${service}" ${status === 'stopped' ? 'disabled' : ''}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="6" y="4" width="4" height="16"></rect><rect x="14" y="4" width="4" height="16"></rect></svg>
            Stop
          </button>
          <button class="btn btn-sm btn-secondary" data-action="restart" data-service="${service}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"></polyline><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"></path></svg>
            Restart
          </button>
        </div>
      `;

      fragment.appendChild(card);
    });

    els.servicesGrid.innerHTML = '';
    els.servicesGrid.appendChild(fragment);

    // Update last updated
    els.servicesLastUpdated.textContent = `Last updated: ${formatRelativeTime(new Date().toISOString())}`;

    // Attach event listeners
    attachServiceListeners();
  }

  function attachServiceListeners() {
    document.querySelectorAll('.service-actions .btn').forEach(btn => {
      btn.addEventListener('click', handleServiceAction);
    });
  }

  async function handleServiceAction(e) {
    const btn = e.currentTarget;
    const service = btn.dataset.service;
    const action = btn.dataset.action;

    btn.disabled = true;
    const originalHtml = btn.innerHTML;
    btn.innerHTML = '<svg class="spinner" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10" stroke-opacity="0.25"></circle><path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round"></path></svg>';

    try {
      const endpoint = service === 'all' ? `/services/all/${action}` : `/services/${service}/${action}`;
      const result = await api(endpoint, { method: 'POST' });

      if (result && result.success) {
        showToast('success', 'Success', result.message || `${action.charAt(0).toUpperCase() + action.slice(1)} ${SERVICE_LABELS[service] || service} successfully`);
        await loadServices();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      btn.disabled = false;
      btn.innerHTML = originalHtml;
    }
  }

  function updateGlobalControls() {
    const allRunning = SERVICES.every(s => (state.services[s]?.status || state.services[s]?.state) === 'running');
    const allStopped = SERVICES.every(s => (state.services[s]?.status || state.services[s]?.state) === 'stopped');

    els.startAllBtn.disabled = allRunning;
    els.stopAllBtn.disabled = allStopped;
  }

  async function handleGlobalAction(action) {
    const btn = action === 'start' ? els.startAllBtn : els.stopAllBtn;
    btn.disabled = true;
    const originalHtml = btn.innerHTML;
    btn.innerHTML = '<svg class="spinner" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10" stroke-opacity="0.25"></circle><path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round"></path></svg>';

    try {
      const result = await api(`/services/all/${action}`, { method: 'POST' });
      if (result && result.success) {
        showToast('success', 'Success', result.message || `All services ${action}ed`);
        await loadServices();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      btn.disabled = false;
      btn.innerHTML = originalHtml;
    }
  }

  // ==========================================================================
  // Virtual Hosts
  // ==========================================================================
  async function loadVhosts() {
    try {
      const data = await api('/vhosts', { silent: true });
      state.vhosts = Array.isArray(data) ? data : [];
      renderVhosts();
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderVhosts() {
    if (state.vhosts.length === 0) {
      els.vhostsTableBody.innerHTML = `
        <tr>
          <td colspan="5" class="table-empty">No virtual hosts configured. Click "Add Vhost" to create one.</td>
        </tr>
      `;
      return;
    }

    els.vhostsTableBody.innerHTML = state.vhosts.map(vhost => `
      <tr>
        <td><code>${escapeHtml(vhost.domain)}</code></td>
        <td><span class="status-badge ${vhost.framework || 'unknown'}">${escapeHtml(vhost.framework || 'php')}</span></td>
        <td><code class="text-xs">${escapeHtml(vhost.root || '-')}</code></td>
        <td><code class="text-xs">${escapeHtml(vhost.config_path || '-')}</code></td>
        <td>
          <div class="table-actions">
            <button class="btn btn-sm btn-danger" data-action="delete" data-domain="${escapeHtml(vhost.domain)}" title="Delete">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
            </button>
          </div>
        </td>
      </tr>
    `).join('');

    // Attach delete listeners
    els.vhostsTableBody.querySelectorAll('[data-action="delete"]').forEach(btn => {
      btn.addEventListener('click', handleDeleteVhost);
    });
  }

  async function handleDeleteVhost(e) {
    const domain = e.currentTarget.dataset.domain;
    if (!confirm(`Delete virtual host "${domain}"? This will remove the Nginx config.`)) return;

    try {
      const result = await api(`/vhosts/${encodeURIComponent(domain)}`, { method: 'DELETE' });
      if (result && result.success) {
        showToast('success', 'Deleted', result.message || `Virtual host ${domain} deleted`);
        await loadVhosts();
      }
    } catch (error) {
      // Error shown by api()
    }
  }

  function handleVhostFormSubmit(e) {
    e.preventDefault();
    const formData = new FormData(els.vhostForm);
    const data = {
      domain: formData.get('domain').trim(),
      framework: formData.get('framework') || 'php',
      root: formData.get('root').trim() || undefined
    };

    if (!data.domain) {
      showToast('error', 'Validation Error', 'Domain is required');
      return;
    }

    createVhost(data);
  }

  async function createVhost(data) {
    const submitBtn = els.vhostForm.querySelector('button[type="submit"]');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Creating...';

    try {
      const result = await api('/vhosts', { method: 'POST', body: data });
      if (result && result.success) {
        showToast('success', 'Created', result.message || `Virtual host ${data.domain} created`);
        closeModal('vhost-modal');
        await loadVhosts();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Create';
    }
  }

  // ==========================================================================
  // SSL Certificates
  // ==========================================================================
  async function loadCerts() {
    try {
      const data = await api('/ssl', { silent: true });
      state.certs = Array.isArray(data) ? data : [];
      renderCerts();
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderCerts() {
    if (state.certs.length === 0) {
      els.certsTableBody.innerHTML = `
        <tr>
          <td colspan="5" class="table-empty">No SSL certificates found. Create one using the forms below.</td>
        </tr>
      `;
      return;
    }

    els.certsTableBody.innerHTML = state.certs.map(cert => `
      <tr>
        <td><code>${escapeHtml(cert.domain)}</code></td>
        <td><code class="text-xs">${escapeHtml(cert.cert_path || '-')}</code></td>
        <td><code class="text-xs">${escapeHtml(cert.key_path || '-')}</code></td>
        <td>
          <span class="status-badge ${cert.exists ? 'valid' : 'invalid'}">
            ${cert.exists ? 'Valid' : 'Missing'}
          </span>
        </td>
        <td>
          <div class="table-actions">
            <button class="btn btn-sm btn-danger" data-action="delete" data-domain="${escapeHtml(cert.domain)}" title="Delete">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
            </button>
          </div>
        </td>
      </tr>
    `).join('');

    // Attach delete listeners
    els.certsTableBody.querySelectorAll('[data-action="delete"]').forEach(btn => {
      btn.addEventListener('click', handleDeleteCert);
    });
  }

  async function handleDeleteCert(e) {
    const domain = e.currentTarget.dataset.domain;
    if (!confirm(`Delete SSL certificate for "${domain}"?`)) return;

    try {
      const result = await api(`/ssl/${encodeURIComponent(domain)}`, { method: 'DELETE' });
      if (result && result.success) {
        showToast('success', 'Deleted', result.message || `Certificate for ${domain} deleted`);
        await loadCerts();
      }
    } catch (error) {
      // Error shown by api()
    }
  }

  async function handleLocalSslSubmit(e) {
    e.preventDefault();
    const domain = els.localSslDomain.value.trim();
    if (!domain) {
      showToast('error', 'Validation Error', 'Domain is required');
      return;
    }

    const btn = els.localSslForm.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = 'Generating...';

    try {
      const result = await api('/ssl/local', { method: 'POST', body: { domain } });
      if (result && result.success) {
        showToast('success', 'Success', result.message || `Local certificate for ${domain} created`);
        els.localSslForm.reset();
        await loadCerts();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      btn.disabled = false;
      btn.textContent = 'Generate';
    }
  }

  async function handleLetsEncryptSubmit(e) {
    e.preventDefault();
    const domain = els.letsencryptDomain.value.trim();
    const email = els.letsencryptEmail.value.trim();

    if (!domain || !email) {
      showToast('error', 'Validation Error', 'Domain and email are required');
      return;
    }

    const btn = els.letsencryptForm.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = 'Requesting...';

    try {
      const result = await api('/ssl/letsencrypt', { method: 'POST', body: { domain, email } });
      if (result && result.success) {
        showToast('success', 'Success', result.message || `Let's Encrypt certificate for ${domain} obtained`);
        els.letsencryptForm.reset();
        await loadCerts();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      btn.disabled = false;
      btn.textContent = 'Request Certificate';
    }
  }

  // ==========================================================================
  // RDS Tunnel
  // ==========================================================================
  async function loadRdsStatus() {
    try {
      const data = await api('/rds/tunnel/status', { silent: true });
      state.rdsStatus = data || {};
      renderRdsStatus();
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderRdsStatus() {
    const status = state.rdsStatus;
    const connected = status.connected === true;
    const statusClass = connected ? 'status-connected' : (status.connecting ? 'status-connecting' : 'status-disconnected');
    const statusText = connected ? 'Connected' : (status.connecting ? 'Connecting...' : 'Disconnected');

    els.rdsStatusCard.innerHTML = `
      <div class="rds-status-header">
        <h3>RDS SSH Tunnel</h3>
        <span class="status-indicator ${statusClass}">
          <span class="status-dot"></span>
          ${statusText}
        </span>
      </div>
      ${connected ? `
        <div class="rds-status-details">
          <div class="detail-row">
            <span class="detail-label">Local Port</span>
            <span class="detail-value">${escapeHtml(String(status.local_port || '-'))}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">RDS Host</span>
            <span class="detail-value">${escapeHtml(status.rds_host || '-')}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">RDS Port</span>
            <span class="detail-value">${escapeHtml(String(status.rds_port || '-'))}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">EC2 Host</span>
            <span class="detail-value">${escapeHtml(status.ec2_host || '-')}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">EC2 User</span>
            <span class="detail-value">${escapeHtml(status.ec2_user || '-')}</span>
          </div>
        </div>
      ` : ''}
    `;
  }

  async function handleRdsStart(e) {
    e.preventDefault();
    const formData = new FormData(els.rdsForm);
    const data = {
      ec2_host: formData.get('ec2_host').trim(),
      ec2_user: formData.get('ec2_user').trim(),
      ec2_key_path: formData.get('ec2_key_path').trim(),
      rds_host: formData.get('rds_host').trim(),
      rds_port: parseInt(formData.get('rds_port')) || 3306,
      local_port: parseInt(formData.get('local_port')) || 3307
    };

    if (!data.ec2_host || !data.ec2_user || !data.ec2_key_path || !data.rds_host) {
      showToast('error', 'Validation Error', 'All fields are required');
      return;
    }

    els.rdsStartBtn.disabled = true;
    els.rdsStartBtn.innerHTML = '<svg class="spinner" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10" stroke-opacity="0.25"></circle><path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round"></path></svg> Starting...';

    try {
      const result = await api('/rds/tunnel/start', { method: 'POST', body: data });
      if (result && result.success) {
        showToast('success', 'Success', result.message || 'RDS tunnel started');
        await loadRdsStatus();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      els.rdsStartBtn.disabled = false;
      els.rdsStartBtn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg> Start Tunnel';
    }
  }

  async function handleRdsStop() {
    els.rdsStopBtn.disabled = true;
    els.rdsStopBtn.innerHTML = '<svg class="spinner" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10" stroke-opacity="0.25"></circle><path d="M12 2a10 10 0 0 1 10 10" stroke-linecap="round"></path></svg> Stopping...';

    try {
      const result = await api('/rds/tunnel/stop', { method: 'POST' });
      if (result && result.success) {
        showToast('success', 'Success', result.message || 'RDS tunnel stopped');
        await loadRdsStatus();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      els.rdsStopBtn.disabled = false;
      els.rdsStopBtn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="6" y="4" width="4" height="16"></rect><rect x="14" y="4" width="4" height="16"></rect></svg> Stop Tunnel';
    }
  }

  // ==========================================================================
  // Logs
  // ==========================================================================
  function handleLogsServiceChange() {
    state.logs.currentService = els.logsServiceSelect.value;
    loadLogs();
  }

  function handleLogsAutoRefreshChange() {
    state.logs.autoRefresh = els.logsAutoRefresh.checked;
    if (state.logs.autoRefresh) {
      startLogsPolling();
    } else {
      stopLogsPolling();
    }
  }

  function startLogsPolling() {
    stopLogsPolling();
    state.logs.polling = true;
    pollLogs();
  }

  function stopLogsPolling() {
    state.logs.polling = false;
    if (state.timers.logs) {
      clearTimeout(state.timers.logs);
      state.timers.logs = null;
    }
  }

  async function pollLogs() {
    if (!state.logs.polling) return;
    await loadLogs();
    state.timers.logs = setTimeout(pollLogs, CONFIG.refreshIntervals.logs);
  }

  async function loadLogs() {
    const service = state.logs.currentService;
    try {
      const data = await api(`/logs/${service}?lines=${CONFIG.maxLogLines}`, { silent: true });
      if (data && data.success !== false) {
        renderLogs(data.lines || [], data.raw || '');
      }
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderLogs(lines, raw) {
    if (lines.length === 0 && !raw) {
      els.logsViewer.textContent = 'No logs available';
      return;
    }

    const content = lines.length > 0
      ? lines.map(line => formatLogLine(line)).join('\n')
      : raw;

    els.logsViewer.textContent = content;
    // Auto-scroll to bottom
    els.logsViewer.scrollTop = els.logsViewer.scrollHeight;
  }

  function formatLogLine(line) {
    // Try to parse common log formats
    // Format: [timestamp] [level] message
    const match = line.match(/^\[(.*?)\]\s*\[(.*?)\]\s*(.*)$/);
    if (match) {
      const [, time, level, message] = match;
      return `<span class="log-time">[${escapeHtml(time)}]</span> <span class="log-level ${escapeHtml(level.toLowerCase())}">[${escapeHtml(level)}]</span> ${escapeHtml(message)}`;
    }
    return escapeHtml(line);
  }

  function handleLogsClear() {
    els.logsViewer.textContent = 'Logs cleared. Waiting for new entries...';
  }

  // ==========================================================================
  // Backups
  // ==========================================================================
  async function loadBackups() {
    try {
      const data = await api('/backups', { silent: true });
      state.backups = Array.isArray(data) ? data : [];
      renderBackups();
    } catch (error) {
      // Error handled by api()
    }
  }

  function renderBackups() {
    if (state.backups.length === 0) {
      els.backupsTableBody.innerHTML = `
        <tr>
          <td colspan="7" class="table-empty">No backups found. Click "Create Backup" to make your first backup.</td>
        </tr>
      `;
      return;
    }

    els.backupsTableBody.innerHTML = state.backups.map(backup => `
      <tr>
        <td><code class="text-xs">${escapeHtml(backup.id)}</code></td>
        <td>${formatDate(backup.timestamp)}</td>
        <td>${escapeHtml(backup.description || '-')}</td>
        <td>${escapeHtml(backup.database || 'all')}</td>
        <td>${formatBytes(backup.size_bytes || 0)}</td>
        <td>${Array.isArray(backup.files) ? backup.files.length : 0} file(s)</td>
        <td>
          <div class="table-actions">
            <button class="btn btn-sm btn-danger" data-action="restore" data-backup-id="${escapeHtml(backup.id)}" title="Restore">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7v10a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-6l-2-2H5a2 2 0 0 0-2 2z"></path><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg>
            </button>
          </div>
        </td>
      </tr>
    `).join('');

    // Attach restore listeners
    els.backupsTableBody.querySelectorAll('[data-action="restore"]').forEach(btn => {
      btn.addEventListener('click', handleRestoreClick);
    });
  }

  function handleRestoreClick(e) {
    const backupId = e.currentTarget.dataset.backupId;
    els.restoreBackupId.textContent = backupId;
    els.restoreDatabase.value = '';
    openModal('restore-modal');
  }

  async function handleRestoreConfirm() {
    const backupId = els.restoreBackupId.textContent;
    const database = els.restoreDatabase.value.trim() || undefined;

    els.restoreConfirmBtn.disabled = true;
    els.restoreConfirmBtn.textContent = 'Restoring...';

    try {
      const result = await api('/restore', { method: 'POST', body: { backup_id: backupId, database } });
      if (result && result.success) {
        showToast('success', 'Success', result.message || 'Database restored successfully');
        closeModal('restore-modal');
        await loadBackups();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      els.restoreConfirmBtn.disabled = false;
      els.restoreConfirmBtn.textContent = 'Restore';
    }
  }

  function handleCreateBackupClick() {
    els.backupForm.reset();
    openModal('backup-modal');
  }

  async function handleBackupSubmit(e) {
    e.preventDefault();
    const formData = new FormData(els.backupForm);
    const data = {
      database: formData.get('database').trim() || undefined,
      description: formData.get('description').trim()
    };

    if (!data.description) {
      showToast('error', 'Validation Error', 'Description is required');
      return;
    }

    const btn = els.backupForm.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = 'Creating...';

    try {
      const result = await api('/backup', { method: 'POST', body: data });
      if (result && result.success) {
        showToast('success', 'Success', result.message || 'Backup created successfully');
        closeModal('backup-modal');
        await loadBackups();
      }
    } catch (error) {
      // Error shown by api()
    } finally {
      btn.disabled = false;
      btn.textContent = 'Create Backup';
    }
  }

  // ==========================================================================
  // Banner
  // ==========================================================================
  function showBanner(message) {
    els.bannerMessage.textContent = message;
    els.banner.classList.remove('hidden');
  }

  function hideBanner() {
    els.banner.classList.add('hidden');
  }

  // ==========================================================================
  // Event Listeners Setup
  // ==========================================================================
  function setupEventListeners() {
    // Theme toggle
    els.themeToggle.addEventListener('click', toggleTheme);

    // Global controls
    els.startAllBtn.addEventListener('click', () => handleGlobalAction('start'));
    els.stopAllBtn.addEventListener('click', () => handleGlobalAction('stop'));

    // Banner dismiss
    els.dismissBanner.addEventListener('click', hideBanner);

    // Vhosts
    els.addVhostBtn.addEventListener('click', () => openModal('vhost-modal'));
    els.vhostForm.addEventListener('submit', handleVhostFormSubmit);

    // SSL
    els.localSslForm.addEventListener('submit', handleLocalSslSubmit);
    els.letsencryptForm.addEventListener('submit', handleLetsEncryptSubmit);

    // RDS
    els.rdsForm.addEventListener('submit', handleRdsStart);
    els.rdsStopBtn.addEventListener('click', handleRdsStop);

    // Logs
    els.logsServiceSelect.addEventListener('change', handleLogsServiceChange);
    els.logsAutoRefresh.addEventListener('change', handleLogsAutoRefreshChange);
    els.logsClearBtn.addEventListener('click', handleLogsClear);

    // Backups
    els.createBackupBtn.addEventListener('click', handleCreateBackupClick);
    els.backupForm.addEventListener('submit', handleBackupSubmit);
    els.restoreConfirmBtn.addEventListener('click', handleRestoreConfirm);

    // Keyboard: Escape to close modals
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        document.querySelectorAll('.modal:not(.hidden)').forEach(modal => {
          closeModal(modal.id);
        });
      }
    });
  }

  // ==========================================================================
  // Initialization
  // ==========================================================================
  async function init() {
    cacheElements();
    initTheme();
    setupEventListeners();

    // Initial loads
    await Promise.all([
      checkHealth(),
      loadServices(),
      loadVhosts(),
      loadCerts(),
      loadRdsStatus(),
      loadBackups(),
      loadLogs()
    ]);

    // Start auto-refresh timers
    startAutoRefresh();

    // Start logs polling if enabled
    if (state.logs.autoRefresh) {
      startLogsPolling();
    }

    console.log('DStack Web UI initialized');
  }

  function startAutoRefresh() {
    // Services
    state.timers.services = setInterval(loadServices, CONFIG.refreshIntervals.services);

    // Health
    state.timers.health = setInterval(checkHealth, CONFIG.refreshIntervals.health);

    // Vhosts, certs, rds, backups - less frequent
    state.timers.vhosts = setInterval(loadVhosts, 30000);
    state.timers.certs = setInterval(loadCerts, 30000);
    state.timers.rds = setInterval(loadRdsStatus, 10000);
    state.timers.backups = setInterval(loadBackups, 30000);
  }

  function stopAutoRefresh() {
    Object.values(state.timers).forEach(timer => {
      if (timer) clearInterval(timer);
    });
    state.timers = {};
    stopLogsPolling();
  }

  // Cleanup on page unload
  window.addEventListener('beforeunload', stopAutoRefresh);

  // Start the app
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Expose for debugging
  window.DStack = {
    api,
    state,
    loadServices,
    loadVhosts,
    loadCerts,
    loadRdsStatus,
    loadBackups,
    loadLogs,
    showToast
  };
})();