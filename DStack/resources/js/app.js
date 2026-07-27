const API = {
    async request(method, url, payload) {
        const options = { method, headers: { 'Content-Type': 'application/json' } };
        if (payload && method !== 'GET') {
            options.body = JSON.stringify(payload);
        }
        const res = await fetch(url, options);
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
            throw new Error(data.message || (data.errors ? Object.values(data.errors).flat().join(', ') : `HTTP ${res.status}`));
        }
        return data;
    },
    get(url) { return this.request('GET', url); },
    post(url, body) { return this.request('POST', url, body); },
    del(url) { return this.request('DELETE', url); },
};
const qs = (id) => document.getElementById(id);

/* ────────────────────────────────────
   Splash Screen
   ──────────────────────────────────── */
const Splash = {
    shown: sessionStorage.getItem('dstack-splash-shown') === '1',
    statusEl: null,
    progressEl: null,
    maxTime: 1200,
    minTime: 350,
    startTime: 0,
    resolved: false,

    init() {
        this.statusEl = qs('splash-status');
        this.progressEl = qs('splash-progress');
        if (!this.statusEl || !this.progressEl) return;
        if (this.shown) {
            qs('splash-screen')?.remove();
            return;
        }
        this.startTime = Date.now();
        this.show();
    },

    show() {
        const el = qs('splash-screen');
        if (el) el.classList.remove('hidden');
    },

    hide() {
        if (this.resolved) return;
        this.resolved = true;
        const elapsed = Date.now() - this.startTime;
        const remaining = Math.max(0, this.minTime - elapsed);
        setTimeout(() => {
            const el = qs('splash-screen');
            if (el) el.classList.add('hidden');
            sessionStorage.setItem('dstack-splash-shown', '1');
        }, remaining);
    },

    setProgress(percent) {
        if (this.progressEl) {
            this.progressEl.style.width = Math.min(100, Math.max(0, percent)) + '%';
        }
    },

    setStatus(text) {
        if (this.statusEl) this.statusEl.textContent = text;
    },

    dispose() {
        setTimeout(() => this.hide(), this.maxTime);
    },
};

/* ────────────────────────────────────
   Skeleton Markup Helpers
   ──────────────────────────────────── */
const Skeletons = {
    serviceCards(count = 6) {
        let html = '';
        for (let i = 0; i < count; i++) {
            html += `
            <div class="card service-card" aria-hidden="true">
                <div style="display:flex; justify-content:space-between; align-items:center;">
                    <div>
                        <div class="skeleton-line skeleton-title"></div>
                        <div class="skeleton-line skeleton-subtitle" style="margin-top:8px;"></div>
                    </div>
                    <div class="skeleton-line skeleton-btn" style="width:48px; height:10px; border-radius:999px;"></div>
                </div>
                <div style="margin-top:16px; display:flex; gap:8px;">
                    <div class="skeleton-line skeleton-btn"></div>
                    <div class="skeleton-line skeleton-btn"></div>
                    <div class="skeleton-line skeleton-btn"></div>
                </div>
            </div>`;
        }
        return html;
    },

    tableRows(columns = 5, rows = 4) {
        const widths = Array.from({ length: columns }, () => 50 + Math.floor(Math.random() * 40));
        let html = '';
        for (let r = 0; r < rows; r++) {
            html += '<tr aria-hidden="true">';
            for (let c = 0; c < columns; c++) {
                html += `<td><div class="skeleton-line" style="width:${widths[c]}%"></div></td>`;
            }
            html += '</tr>';
        }
        return html;
    },

    logsViewer(lines = 8) {
        let html = '';
        for (let i = 0; i < lines; i++) {
            const width = 55 + Math.floor(Math.random() * 40);
            html += `<span class="skeleton-line" style="display:block;width:${width}%;margin-bottom:10px;"></span>`;
        }
        return html;
    },
};

/* ────────────────────────────────────
   Button Loading State
   ──────────────────────────────────── */
function setButtonLoading(btn, isLoading) {
    if (!btn) return;
    if (isLoading) {
        btn.dataset.originalText = btn.innerHTML;
        btn.classList.add('is-loading');
        btn.disabled = true;
        const label = btn.textContent?.trim() || 'Loading';
        btn.innerHTML = `<span class="spinner"></span> ${label}...`;
    } else {
        btn.classList.remove('is-loading');
        btn.disabled = false;
        if (btn.dataset.originalText) {
            btn.innerHTML = btn.dataset.originalText;
            delete btn.dataset.originalText;
        }
    }
}

/* ────────────────────────────────────
   Section State Machine
   ──────────────────────────────────── */
async function withSkeleton(containerId, loaderFn, skeletonFn) {
    const container = qs('#' + containerId);
    if (!container) return;
    container.innerHTML = skeletonFn ? skeletonFn() : '';
    container.setAttribute('aria-busy', 'true');
    try {
        const data = await loaderFn();
        container.setAttribute('aria-busy', 'false');
        return data;
    } catch (e) {
        container.setAttribute('aria-busy', 'false');
        throw e;
    }
}

/* ────────────────────────────────────
   Health
   ──────────────────────────────────── */
const healthStatus = qs('health-status');
async function initHealth() {
    try {
        const data = await API.get('/api/health');
        const el = healthStatus?.querySelector('.status-text');
        if (data.status === 'ok') {
            if (el) el.textContent = 'API Healthy';
        } else {
            if (el) el.textContent = 'API Unhealthy';
        }
    } catch (e) {
        const el = healthStatus?.querySelector('.status-text');
        if (el) el.textContent = 'API Unreachable';
    }
}

/* ────────────────────────────────────
   Services
   ──────────────────────────────────── */
async function loadServices() {
    const container = qs('services-grid');
    if (!container) return;
    container.innerHTML = Skeletons.serviceCards(6);
    container.setAttribute('aria-busy', 'true');

    try {
        const data = await API.get('/api/services');
        container.setAttribute('aria-busy', 'false');
        container.innerHTML = '';
        const statusColors = { running: 'status-running', stopped: 'status-stopped', unknown: 'status-unknown' };
        const services = Object.entries(data || {}).map(([name, info]) => ({
            name,
            running: info.state === 'running',
            image: info.image || '',
            status: info.status || '',
            health: info.health || '',
        }));
        for (const service of services) {
            const card = document.createElement('div');
            card.className = 'card service-card section-content';
            card.innerHTML = `
                <div style="display:flex; justify-content:space-between; align-items:center;">
                    <div>
                        <div style="font-weight:700;">${service.name}</div>
                        <div style="font-size:12px; color:#9ca3af;">${service.image || ''}</div>
                    </div>
                    <div style="display:flex; gap:6px; align-items:center;">
                        <span class="status-dot ${statusColors[service.running ? 'running' : 'stopped'] || 'status-unknown'}"></span>
                        <span style="font-size:12px;">${service.running ? 'running' : 'stopped'}</span>
                    </div>
                </div>
                <div style="margin-top:10px; display:flex; gap:6px;">
                    <button class="btn btn-success" data-action="start" data-service="${service.name}">Start</button>
                    <button class="btn btn-danger" data-action="stop" data-service="${service.name}">Stop</button>
                    <button class="btn btn-secondary" data-action="restart" data-service="${service.name}">Restart</button>
                </div>
            `;
            container.appendChild(card);
        }
        qs('services-last-updated').textContent = `Updated ${new Date().toLocaleTimeString()}`;
    } catch (e) {
        container.setAttribute('aria-busy', 'false');
        container.innerHTML = `<div class="card" style="color:#fecaca;">Failed to load services: ${e.message}</div>`;
    }
}

document.addEventListener('click', function (e) {
    const btn = e.target.closest('[data-action][data-service]');
    if (!btn) return;
    const action = btn.dataset.action;
    const service = btn.dataset.service;
    if (service === 'all') {
        setButtonLoading(btn, true);
        const targets = document.querySelectorAll('#services-grid [data-service]');
        targets.forEach((t) => {
            const s = t.dataset.service;
            API.post(`/api/services/${s}/${action}`);
        });
        setButtonLoading(btn, false);
        loadServices();
        return;
    }
    if (['start', 'stop', 'restart'].includes(action)) {
        setButtonLoading(btn, true);
        API.post(`/api/services/${service}/${action}`).finally(() => setButtonLoading(btn, false));
        loadServices();
    }
});

/* ────────────────────────────────────
   Vhosts
   ──────────────────────────────────── */
async function loadVhosts() {
    const tbody = qs('vhosts-tbody');
    if (!tbody) return;
    tbody.innerHTML = Skeletons.tableRows(5, 4);

    try {
        const data = await API.get('/api/vhosts');
        tbody.innerHTML = '';
        for (const v of data || []) {
            const tr = document.createElement('tr');
            tr.className = 'section-content';
            tr.innerHTML = `
                <td>${v.domain}</td>
                <td>${v.framework}</td>
                <td>${v.root || '-'}</td>
                <td>${v.config_path || '-'}</td>
                <td><button class="btn btn-danger" data-delete-vhost="${v.domain}">Delete</button></td>
            `;
            tbody.appendChild(tr);
        }
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="5" style="color:#fecaca;">Failed to load vhosts: ${e.message}</td></tr>`;
    }
}
document.addEventListener('click', async function (e) {
    const btn = e.target.closest('[data-delete-vhost]');
    if (!btn) return;
    const domain = btn.dataset.deleteVhost;
    setButtonLoading(btn, true);
    await API.del(`/api/vhosts/${encodeURIComponent(domain)}`).finally(() => setButtonLoading(btn, false));
    loadVhosts();
});

/* ────────────────────────────────────
   SSL
   ──────────────────────────────────── */
async function loadSsl() {
    const tbody = qs('ssl-tbody');
    if (!tbody) return;
    tbody.innerHTML = Skeletons.tableRows(5, 4);

    try {
        const data = await API.get('/api/ssl');
        tbody.innerHTML = '';
        for (const cert of data.certs || []) {
            const tr = document.createElement('tr');
            tr.className = 'section-content';
            tr.innerHTML = `
                <td>${cert.domain}</td>
                <td>${cert.type}</td>
                <td>${cert.cert_path || '-'}</td>
                <td>${cert.key_path || '-'}</td>
                <td><span class="status-dot status-running"></span> Active</td>
                <td><button class="btn btn-danger" data-delete-ssl="${cert.domain}">Remove</button></td>
            `;
            tbody.appendChild(tr);
        }
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="6" style="color:#fecaca;">Failed to load SSL certificates: ${e.message}</td></tr>`;
    }
}

/* ────────────────────────────────────
   Backups
   ──────────────────────────────────── */
async function loadBackups() {
    const tbody = qs('backups-tbody');
    if (!tbody) return;
    tbody.innerHTML = Skeletons.tableRows(7, 4);

    try {
        const data = await API.get('/api/backups');
        tbody.innerHTML = '';
        for (const backup of data.backups || []) {
            const tr = document.createElement('tr');
            tr.className = 'section-content';
            tr.innerHTML = `
                <td>${backup.id}</td>
                <td>${backup.created_at}</td>
                <td>${backup.description || ''}</td>
                <td>${backup.database}</td>
                <td>${backup.size || '-'}</td>
                <td>${backup.files || '-'}</td>
                <td><button class="btn btn-primary" data-restore="${backup.id}">Restore</button></td>
            `;
            tbody.appendChild(tr);
        }
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="7" style="color:#fecaca;">Failed to load backups: ${e.message}</td></tr>`;
    }
}
document.addEventListener('click', async function (e) {
    const btn = e.target.closest('[data-restore]');
    if (!btn) return;
    const backupId = btn.dataset.restore;
    setButtonLoading(btn, true);
    let database = '';
    database = prompt('Restore database (leave empty for all):', database);
    if (database === null) {
        setButtonLoading(btn, false);
        return;
    }
    try {
        const data = await API.post('/api/restore', { backup_id: backupId, database });
        showToast(data.message, data.success);
        loadBackups();
    } catch (err) {
        showToast(err.message, false);
    } finally {
        setButtonLoading(btn, false);
    }
});

/* ────────────────────────────────────
   Logs
   ──────────────────────────────────── */
async function loadLogs(service) {
    const viewer = qs('logs-viewer');
    if (!viewer) return;
    viewer.innerHTML = Skeletons.logsViewer(8);
    try {
        const data = await API.get(`/api/logs/${service}`);
        if (!data.logs || data.logs.length === 0) {
            viewer.textContent = 'No logs available';
            return;
        }
        viewer.textContent = data.logs.map((l) => l.message || l.raw).join('\n');
    } catch (e) {
        viewer.textContent = `Error loading logs: ${e.message}`;
    }
}

async function initLogStream() {
    const service = qs('#logs-service-select')?.value || 'all';
    await loadLogs(service);
    setInterval(async () => {
        await loadLogs(service);
    }, 3000);
}

/* ────────────────────────────────────
   RDS Status
   ──────────────────────────────────── */
async function initRdsStatus() {
    const indicator = qs('#rds-status-indicator');
    const text = indicator?.querySelector('.status-text');
    const ports = ['rds-local-port', 'rds-rds-host', 'rds-ec2-host'];

    if (indicator) indicator.className = 'status-indicator status-unknown';
    if (text) text.textContent = 'Loading...';
    ports.forEach((id) => {
        const el = qs(`#${id}`);
        if (el) el.textContent = '-';
    });

    try {
        const data = await API.get('/api/rds/tunnel/status');
        if (data.connected) {
            if (indicator) indicator.className = 'status-indicator status-running';
            if (text) text.textContent = 'Connected';
        } else {
            if (indicator) indicator.className = 'status-indicator status-stopped';
            if (text) text.textContent = 'Disconnected';
        }
        const values = [data.local_port, data.rds_host, data.ec2_host];
        ports.forEach((id, idx) => {
            const el = qs(`#${id}`);
            if (el) el.textContent = values[idx] || '-';
        });
    } catch (e) {
        if (indicator) indicator.className = 'status-indicator status-unknown';
        if (text) text.textContent = 'Unreachable';
    }
}

/* ────────────────────────────────────
   Forms
   ──────────────────────────────────── */
function showToast(message, ok = true) {
    const container = qs('toast-container') || document.body;
    const el = document.createElement('div');
    el.style.padding = '10px 12px';
    el.style.border = '1px solid ' + (ok ? '#065f46' : '#7f1d1d');
    el.style.background = ok ? 'rgba(16,185,129,.12)' : 'rgba(220,38,38,.12)';
    el.style.color = ok ? '#a7f3d0' : '#fecaca';
    el.style.borderRadius = '10px';
    el.textContent = message;
    container.appendChild(el);
    setTimeout(() => el.remove(), 3000);
}

async function initForms() {
    qs('vhost-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const form = e.target;
        const payload = {
            domain: qs('#vhost-domain').value,
            root: qs('#vhost-root').value,
            framework: qs('#vhost-framework').value,
        };
        try {
            const data = await API.post('/api/vhosts', payload);
            showToast(data.message, data.success);
            form.reset();
            qs('vhost-modal')?.classList.add('hidden');
            loadVhosts();
        } catch (err) {
            showToast(err.message, false);
        }
    });

    qs('ssl-local-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        try {
            const data = await API.post('/api/ssl/local', { domain: qs('#ssl-local-domain').value });
            showToast(data.message, data.success);
            e.target.reset();
            loadSsl();
        } catch (err) {
            showToast(err.message, false);
        }
    });

    qs('ssl-letsencrypt-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        try {
            const data = await API.post('/api/ssl/letsencrypt', {
                domain: qs('#ssl-le-domain').value,
                email: qs('#ssl-le-email').value,
            });
            showToast(data.message, data.success);
            e.target.reset();
            loadSsl();
        } catch (err) {
            showToast(err.message, false);
        }
    });

    qs('rds-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const btn = e.target.querySelector('button[type="submit"]');
        setButtonLoading(btn, true);
        try {
            const data = await API.post('/api/rds/tunnel/start', {
                ec2_host: qs('#rds-ec2-host').value,
                ec2_user: qs('#rds-ec2-user').value,
                ec2_key_path: qs('#rds-ec2-key').value,
                rds_host: qs('#rds-rds-host').value,
                rds_port: qs('#rds-rds-port').value,
                local_port: qs('#rds-local-port').value,
            });
            showToast(data.message, data.success);
        } catch (err) {
            showToast(err.message, false);
        } finally {
            setButtonLoading(btn, false);
        }
    });

    qs('backup-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        try {
            const data = await API.post('/api/backup', {
                database: qs('#backup-database').value,
                description: qs('#backup-description').value,
            });
            showToast(data.message, data.success);
            e.target.reset();
            qs('backup-modal')?.classList.add('hidden');
            loadBackups();
        } catch (err) {
            showToast(err.message, false);
        }
    });
}

/* ────────────────────────────────────
   Modals
   ──────────────────────────────────── */
function initModals() {
    document.querySelectorAll('.modal-close, .modal-cancel').forEach((btn) => {
        btn.addEventListener('click', () => {
            btn.closest('.modal')?.classList.add('hidden');
        });
    });
    qs('#add-vhost-btn')?.addEventListener('click', () => qs('#vhost-modal')?.classList.remove('hidden'));
    qs('#create-backup-btn')?.addEventListener('click', () => qs('#backup-modal')?.classList.remove('hidden'));
}

/* ────────────────────────────────────
   Theme
   ──────────────────────────────────── */
function initThemeToggle() {
    qs('#theme-toggle')?.addEventListener('click', async () => {
        document.body.style.filter = document.body.style.filter ? '' : 'invert(1) hue-rotate(180deg)';
    });
}

/* ────────────────────────────────────
   Boot
   ──────────────────────────────────── */
Splash.init();
Splash.setStatus('Checking API...');
Splash.setProgress(20);

addEventListener('DOMContentLoaded', async () => {
    await initHealth();
    Splash.setStatus('Loading services...');
    Splash.setProgress(45);
    await loadServices();
    Splash.setStatus('Loading virtual hosts...');
    Splash.setProgress(65);
    await loadVhosts();
    Splash.setStatus('Loading SSL certificates...');
    Splash.setProgress(80);
    await loadSsl();
    Splash.setStatus('Preparing interface...');
    Splash.setProgress(95);
    await initForms();
    await initLogStream();
    await initRdsStatus();
    await initThemeToggle();
    initModals();
    await loadBackups();
    Splash.setProgress(100);
    Splash.dispose();

    setInterval(async () => {
        await loadServices();
        await loadVhosts();
        await loadSsl();
        await loadBackups();
        await initRdsStatus();
    }, 5000);
});
