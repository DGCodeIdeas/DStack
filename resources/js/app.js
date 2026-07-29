// Configuration
const CONFIG = {
    apiBase: '/api',
};

// Utility: fetch with error handling
async function apiFetch(url, options = {}) {
    try {
        const response = await fetch(CONFIG.apiBase + url, {
            headers: { 'Content-Type': 'application/json', ...options.headers },
            ...options,
        });
        const data = await response.json();
        return { ok: response.ok, status: response.status, data };
    } catch (err) {
        return { ok: false, status: 0, data: { success: false, message: err.message } };
    }
}

// Toast notifications
function showToast(message, type = 'info') {
    const container = document.getElementById('toast-container');
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    container.appendChild(toast);
    setTimeout(() => toast.remove(), 4000);
}

// Services
async function loadServices() {
    const { data } = await apiFetch('/services');
    const grid = document.getElementById('services-grid');
    if (!grid) return;

    if (data.error) {
        grid.innerHTML = `<div class="card"><p>Error: ${data.error}</p></div>`;
        return;
    }

    const entries = Object.entries(data);
    grid.innerHTML = entries.map(([name, info]) => {
        const state = info.state || info.status || 'unknown';
        const health = info.health || '';
        const stateClass = state === 'running' ? 'status-healthy' : state === 'exited' ? 'status-error' : 'status-unknown';
        return `
            <div class="service-card card">
                <h3>${name}</h3>
                <span class="status-indicator ${stateClass}"><span class="status-dot"></span><span class="status-text">${state}</span></span>
                ${health ? `<span class="health-badge">${health}</span>` : ''}
                <div class="service-actions">
                    <button class="btn btn-sm btn-success" data-action="start" data-service="${name}">Start</button>
                    <button class="btn btn-sm btn-danger" data-action="stop" data-service="${name}">Stop</button>
                    <button class="btn btn-sm btn-secondary" data-action="restart" data-service="${name}">Restart</button>
                </div>
            </div>
        `;
    }).join('');

    document.getElementById('services-last-updated').textContent = `Updated: ${new Date().toLocaleTimeString()}`;
}

// Service actions
async function serviceAction(service, action) {
    const { data } = await apiFetch(`/services/${service}/${action}`, { method: 'POST' });
    if (data.success) {
        showToast(`${action} ${service} successful`, 'success');
        loadServices();
    } else {
        showToast(data.message || `Failed to ${action} ${service}`, 'error');
    }
}

// Vhosts
async function loadVhosts() {
    const { data } = await apiFetch('/vhosts');
    const tbody = document.getElementById('vhosts-tbody');
    if (!tbody) return;

    tbody.innerHTML = (data || []).map(v => `
        <tr>
            <td>${v.domain}</td>
            <td>${v.framework}</td>
            <td>${v.root || '-'}</td>
            <td>${v.config_path || '-'}</td>
            <td>
                <button class="btn btn-sm btn-danger" onclick="deleteVhost('${v.domain}')">Delete</button>
            </td>
        </tr>
    `).join('');
}

async function createVhost(domain, framework = 'php') {
    const { data } = await apiFetch('/vhosts', {
        method: 'POST',
        body: JSON.stringify({ domain, framework }),
    });
    if (data.success) {
        showToast(`Vhost ${domain} created`, 'success');
        loadVhosts();
    } else {
        showToast(data.message || 'Failed to create vhost', 'error');
    }
}

async function deleteVhost(domain) {
    if (!confirm(`Delete vhost ${domain}?`)) return;
    const { data } = await apiFetch(`/vhosts/${encodeURIComponent(domain)}`, { method: 'DELETE' });
    if (data.success) {
        showToast(`Vhost ${domain} deleted`, 'success');
        loadVhosts();
    } else {
        showToast(data.message || 'Failed to delete vhost', 'error');
    }
}

// SSL
async function loadCerts() {
    const { data } = await apiFetch('/ssl');
    const tbody = document.getElementById('ssl-tbody');
    if (!tbody) return;

    tbody.innerHTML = (data || []).map(c => `
        <tr>
            <td>${c.domain}</td>
            <td>${c.cert_path}</td>
            <td>${c.key_path}</td>
            <td><span class="status-indicator ${c.exists ? 'status-healthy' : 'status-error'}"><span class="status-dot"></span>${c.exists ? 'Exists' : 'Missing'}</span></td>
            <td></td>
        </tr>
    `).join('');
}

async function createLocalSsl(domain) {
    const { data } = await apiFetch('/ssl/local', {
        method: 'POST',
        body: JSON.stringify({ domain }),
    });
    if (data.success) {
        showToast(`SSL cert for ${domain} created via mkcert`, 'success');
        loadCerts();
    } else {
        showToast(data.message || 'Failed to create SSL cert', 'error');
    }
}

async function createLetsEncryptSsl(domain, email, mode, webrootPath) {
    const { data } = await apiFetch('/ssl/letsencrypt', {
        method: 'POST',
        body: JSON.stringify({ domain, email, mode, webroot_path: webrootPath }),
    });
    if (data.success) {
        showToast(`SSL cert for ${domain} created via Let's Encrypt`, 'success');
        loadCerts();
    } else {
        showToast(data.message || 'Failed to create SSL cert', 'error');
    }
}

// RDS Tunnel
async function loadRdsStatus() {
    const { data } = await apiFetch('/rds/tunnel/status');
    const indicator = document.getElementById('rds-status-indicator');
    const details = document.getElementById('rds-status-details');

    if (data.connected) {
        indicator.className = 'status-indicator status-healthy';
        indicator.querySelector('.status-text').textContent = 'Connected';
        document.getElementById('rds-local-port').textContent = data.local_port;
        document.getElementById('rds-rds-host').textContent = data.rds_host;
        document.getElementById('rds-ec2-host').textContent = data.ec2_host;
        details.classList.remove('hidden');
    } else {
        indicator.className = 'status-indicator status-unknown';
        indicator.querySelector('.status-text').textContent = 'Disconnected';
        details.classList.add('hidden');
    }
}

async function startRdsTunnel(ec2Host, ec2User, ec2KeyPath, rdsHost, rdsPort, localPort) {
    const { data } = await apiFetch('/rds/tunnel/start', {
        method: 'POST',
        body: JSON.stringify({ ec2_host: ec2Host, ec2_user: ec2User, ec2_key_path: ec2KeyPath, rds_host: rdsHost, rds_port: rdsPort, local_port: localPort }),
    });
    if (data.success) {
        showToast('RDS tunnel started', 'success');
        loadRdsStatus();
    } else {
        showToast(data.message || 'Failed to start tunnel', 'error');
    }
}

async function stopRdsTunnel() {
    const { data } = await apiFetch('/rds/tunnel/stop', { method: 'POST' });
    if (data.success) {
        showToast('RDS tunnel stopped', 'success');
        loadRdsStatus();
    } else {
        showToast(data.message || 'Failed to stop tunnel', 'error');
    }
}

// Logs
async function loadLogs(service = 'all', lines = 100) {
    const { data } = await apiFetch(`/logs/${service}?lines=${lines}`);
    const viewer = document.getElementById('logs-viewer');
    if (!viewer) return;

    if (data.success) {
        viewer.textContent = (data.lines || []).join('\n');
    } else {
        viewer.textContent = data.message || 'Failed to load logs';
    }
}

// Backups
async function loadBackups() {
    const { data } = await apiFetch('/backups');
    const tbody = document.getElementById('backups-tbody');
    if (!tbody) return;

    tbody.innerHTML = (data || []).map(b => `
        <tr>
            <td>${b.id}</td>
            <td>${b.timestamp}</td>
            <td>${b.description || '-'}</td>
            <td>${b.database || 'all'}</td>
            <td>${formatBytes(b.size_bytes || 0)}</td>
            <td>${(b.files || []).join(', ')}</td>
            <td>
                <button class="btn btn-sm btn-danger" onclick="restoreBackup('${b.id}')">Restore</button>
            </td>
        </tr>
    `).join('');
}

async function createBackup(database, description) {
    const { data } = await apiFetch('/backup', {
        method: 'POST',
        body: JSON.stringify({ database, description }),
    });
    if (data.success) {
        showToast(`Backup ${data.backup_id} created`, 'success');
        loadBackups();
    } else {
        showToast(data.message || 'Failed to create backup', 'error');
    }
}

async function restoreBackup(backupId) {
    if (!confirm(`Restore from backup ${backupId}?`)) return;
    const { data } = await apiFetch('/restore', {
        method: 'POST',
        body: JSON.stringify({ backup_id: backupId }),
    });
    if (data.success) {
        showToast('Restore completed', 'success');
        loadBackups();
    } else {
        showToast(data.message || 'Restore failed', 'error');
    }
}

function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

// Event listeners
document.addEventListener('DOMContentLoaded', () => {
    // Initial loads
    loadServices();
    loadVhosts();
    loadCerts();
    loadRdsStatus();
    loadLogs();
    loadBackups();

    // Auto-refresh services
    setInterval(loadServices, 5000);
    setInterval(loadRdsStatus, 5000);

    // Auto-refresh logs
    const autoRefresh = document.getElementById('logs-auto-refresh');
    if (autoRefresh && autoRefresh.checked) {
        setInterval(() => {
            const service = document.getElementById('logs-service-select')?.value || 'all';
            loadLogs(service);
        }, 3000);
    }

    // Start/Stop All buttons
    document.getElementById('start-all')?.addEventListener('click', () => serviceAction('all', 'start'));
    document.getElementById('stop-all')?.addEventListener('click', () => serviceAction('all', 'stop'));

    // Service card actions (delegated)
    document.getElementById('services-grid')?.addEventListener('click', (e) => {
        const btn = e.target.closest('button[data-action]');
        if (!btn) return;
        const service = btn.dataset.service;
        const action = btn.dataset.action;
        serviceAction(service, action);
    });

    // Add Vhost button
    document.getElementById('add-vhost-btn')?.addEventListener('click', () => {
        document.getElementById('vhost-modal').classList.remove('hidden');
    });

    // Vhost form
    document.getElementById('vhost-form')?.addEventListener('submit', (e) => {
        e.preventDefault();
        const domain = document.getElementById('vhost-domain').value;
        const framework = document.getElementById('vhost-framework').value;
        createVhost(domain, framework);
        document.getElementById('vhost-modal').classList.add('hidden');
    });

    // SSL local form
    document.getElementById('ssl-local-form')?.addEventListener('submit', (e) => {
        e.preventDefault();
        const domain = document.getElementById('ssl-local-domain').value;
        createLocalSsl(domain);
    });

    // SSL letsencrypt form
    document.getElementById('ssl-letsencrypt-form')?.addEventListener('submit', (e) => {
        e.preventDefault();
        const domain = document.getElementById('ssl-le-domain').value;
        const email = document.getElementById('ssl-le-email').value;
        createLetsEncryptSsl(domain, email, 'standalone');
    });

    // RDS form
    document.getElementById('rds-form')?.addEventListener('submit', (e) => {
        e.preventDefault();
        const ec2Host = document.getElementById('rds-ec2-host').value;
        const ec2User = document.getElementById('rds-ec2-user').value;
        const ec2KeyPath = document.getElementById('rds-ec2-key').value;
        const rdsHost = document.getElementById('rds-rds-host').value;
        const rdsPort = parseInt(document.getElementById('rds-rds-port').value) || 3306;
        const localPort = parseInt(document.getElementById('rds-local-port').value) || 3307;
        startRdsTunnel(ec2Host, ec2User, ec2KeyPath, rdsHost, rdsPort, localPort);
    });

    document.getElementById('rds-stop-btn')?.addEventListener('click', stopRdsTunnel);

    // Backup form
    document.getElementById('create-backup-btn')?.addEventListener('click', () => {
        document.getElementById('backup-modal').classList.remove('hidden');
    });

    document.getElementById('backup-form')?.addEventListener('submit', (e) => {
        e.preventDefault();
        const database = document.getElementById('backup-database').value || 'all';
        const description = document.getElementById('backup-description').value;
        createBackup(database, description);
        document.getElementById('backup-modal').classList.add('hidden');
    });

    // Restore confirm
    document.getElementById('restore-confirm-btn')?.addEventListener('click', () => {
        const backupId = document.getElementById('restore-backup-id').textContent;
        const database = document.getElementById('restore-database').value || null;
        restoreBackup(backupId);
        document.getElementById('restore-modal').classList.add('hidden');
    });

    // Modal close buttons
    document.querySelectorAll('.modal-close, .modal-cancel').forEach(btn => {
        btn.addEventListener('click', () => {
            btn.closest('.modal').classList.add('hidden');
        });
    });

    // Dismiss banner
    document.getElementById('dismiss-banner')?.addEventListener('click', () => {
        document.getElementById('daemon-banner').classList.add('hidden');
    });

    // Logs clear
    document.getElementById('logs-clear-btn')?.addEventListener('click', () => {
        document.getElementById('logs-viewer').textContent = '';
    });
});