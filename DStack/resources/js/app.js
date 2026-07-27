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

const healthStatus = qs('health-status');
async function initHealth() {
    try {
        const data = await API.get('/api/health');
        const el = healthStatus.querySelector('.status-text');
        if (data.status === 'ok') {
            el.textContent = 'API Healthy';
        } else {
            el.textContent = 'API Unhealthy';
        }
    } catch (e) {
        const el = healthStatus.querySelector('.status-text');
        if (el) el.textContent = 'API Unreachable';
    }
}

async function loadServices() {
    const data = await API.get('/api/services');
    const grid = qs('services-grid');
    grid.innerHTML = '';
    const statusColors = { running: 'status-running', stopped: 'status-stopped', unknown: 'status-unknown' };
    for (const service of data.services || []) {
        const card = document.createElement('div');
        card.className = 'card service-card';
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
        grid.appendChild(card);
    }
    qs('services-last-updated').textContent = `Updated ${new Date().toLocaleTimeString()}`;
}

document.addEventListener('click', function (e) {
    const btn = e.target.closest('[data-action][data-service]');
    if (!btn) return;
    const action = btn.dataset.action;
    const service = btn.dataset.service;
    if (service === 'all') {
        const targets = document.querySelectorAll('#services-grid [data-service]');
        targets.forEach((t) => {
            const s = t.dataset.service;
            API.post(`/api/services/${s}/${action}`);
        });
        loadServices();
        return;
    }
    if (['start', 'stop', 'restart'].includes(action)) {
        API.post(`/api/services/${service}/${action}`);
        loadServices();
    }
});

async function loadVhosts() {
    const data = await API.get('/api/vhosts');
    const tbody = qs('vhosts-tbody');
    tbody.innerHTML = '';
    for (const v of data.vhosts || []) {
        const tr = document.createElement('tr');
        tr.innerHTML = `
            <td>${v.domain}</td>
            <td>${v.framework}</td>
            <td>${v.root || '-'}</td>
            <td>${v.config_path || '-'}</td>
            <td><button class="btn btn-danger" data-delete-vhost="${v.domain}">Delete</button></td>
        `;
        tbody.appendChild(tr);
    }
}
document.addEventListener('click', async function (e) {
    const btn = e.target.closest('[data-delete-vhost]');
    if (!btn) return;
    const domain = btn.dataset.deleteVhost;
    await API.del(`/api/vhosts/${encodeURIComponent(domain)}`);
    loadVhosts();
});

async function loadSsl() {
    const data = await API.get('/api/ssl');
    const tbody = qs('ssl-tbody');
    tbody.innerHTML = '';
    for (const cert of data.certs || []) {
        const tr = document.createElement('tr');
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
}

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
        const data = await API.post('/api/vhosts', payload);
        showToast(data.message, data.success);
        form.reset();
        qs('vhost-modal')?.classList.add('hidden');
        loadVhosts();
    });

    qs('ssl-local-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const data = await API.post('/api/ssl/local', { domain: qs('#ssl-local-domain').value });
        showToast(data.message, data.success);
        e.target.reset();
        loadSsl();
    });

    qs('ssl-letsencrypt-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const data = await API.post('/api/ssl/letsencrypt', {
            domain: qs('#ssl-le-domain').value,
            email: qs('#ssl-le-email').value,
        });
        showToast(data.message, data.success);
        e.target.reset();
        loadSsl();
    });

    qs('rds-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const data = await API.post('/api/rds/tunnel/start', {
            ec2_host: qs('#rds-ec2-host').value,
            ec2_user: qs('#rds-ec2-user').value,
            ec2_key_path: qs('#rds-ec2-key').value,
            rds_host: qs('#rds-rds-host').value,
            rds_port: qs('#rds-rds-port').value,
            local_port: qs('#rds-local-port').value,
        });
        showToast(data.message, data.success);
    });

    qs('backup-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const data = await API.post('/api/backup', {
            database: qs('#backup-database').value,
            description: qs('#backup-description').value,
        });
        showToast(data.message, data.success);
        e.target.reset();
        qs('backup-modal')?.classList.add('hidden');
        loadBackups();
    });
}

async function loadBackups() {
    const data = await API.get('/api/backups');
    const tbody = qs('backups-tbody');
    tbody.innerHTML = '';
    for (const backup of data.backups || []) {
        const tr = document.createElement('tr');
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
}
document.addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-restore]');
    if (!btn) return;
    const backupId = btn.dataset.restore;
    let database = '';
    database = prompt('Restore database (leave empty for all):', database);
    if (database === null) return;
    const data = await API.post('/api/restore', { backup_id: backupId, database });
    showToast(data.message, data.success);
    loadBackups();
});

function initModals() {
    document.querySelectorAll('.modal-close, .modal-cancel').forEach((btn) => {
        btn.addEventListener('click', () => {
            btn.closest('.modal')?.classList.add('hidden');
        });
    });
    qs('#add-vhost-btn')?.addEventListener('click', () => qs('#vhost-modal')?.classList.remove('hidden'));
    qs('#create-backup-btn')?.addEventListener('click', () => qs('#backup-modal')?.classList.remove('hidden'));
}

async function loadLogs(service) {
    const viewer = qs('logs-viewer');
    if (!viewer) return;
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

async function initRdsStatus() {
    const data = await API.get('/api/rds/tunnel/status');
    const card = qs('#rds-status-card');
    if (!card) return;
    const indicator = qs('#rds-status-indicator');
    const text = indicator?.querySelector('.status-text');
    if (data.connected) {
        indicator.className = 'status-indicator status-running';
        if (text) text.textContent = 'Connected';
    } else {
        indicator.className = 'status-indicator status-stopped';
        if (text) text.textContent = 'Disconnected';
    }
    const ports = ['rds-local-port', 'rds-rds-host', 'rds-ec2-host'];
    const values = [data.local_port, data.rds_host, data.ec2_host];
    ports.forEach((id, idx) => {
        const el = qs(`#${id}`);
        if (el) el.textContent = values[idx] || '-';
    });
}

async function initThemeToggle() {
    qs('#theme-toggle')?.addEventListener('click', async () => {
        document.body.style.filter = document.body.style.filter ? '' : 'invert(1) hue-rotate(180deg)';
    });
}

setInterval(async () => {
    await loadServices();
    await loadVhosts();
    await loadSsl();
    await loadBackups();
    await initRdsStatus();
}, 5000);

addEventListener('DOMContentLoaded', async () => {
    initHealth();
    await loadServices();
    await loadVhosts();
    await loadSsl();
    await initForms();
    await initLogStream();
    await initRdsStatus();
    await initThemeToggle();
    initModals();
    await loadBackups();
});
