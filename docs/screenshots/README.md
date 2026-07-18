# DStack Screenshots

This directory contains placeholder references for documentation screenshots. Since the sandbox environment has no browser, these images must be captured manually by the user after installation.

---

## How to Capture Screenshots

### 1. Start DStack

```bash
# From the DStack project root
./cloud/install-local.sh
```

Wait for the installation to complete. The script will output access URLs.

### 2. Open the Dashboard

**URL:** `http://localhost:5000`

The Flask dashboard should open automatically if you have a display. If not, open it manually in your browser.

### 3. Capture Each Screen

| Screenshot | Description | How to Capture |
|------------|-------------|----------------|
| `dashboard.png` | Main dashboard with Services, VHosts, SSL, RDS, Logs, Backups tabs | Navigate to `http://localhost:5000`, wait for data to load, capture full page |
| `services.png` | Services tab showing nginx, php, mysql, redis, phpmyadmin status | Click "Services" tab, capture |
| `vhosts.png` | Virtual Hosts tab with list and "Add Vhost" modal | Click "Virtual Hosts" tab, click "Add Vhost", capture modal open |
| `ssl.png` | SSL Certificates tab with mkcert and Let's Encrypt forms | Click "SSL" tab, capture |
| `rds.png` | RDS Tunnel tab with configuration form | Click "RDS Tunnel" tab, capture |
| `logs.png` | Logs tab with service selector and live log viewer | Click "Logs" tab, select "nginx", capture with some log lines |
| `backups.png` | Backups tab with list and "Create Backup" modal | Click "Backups" tab, click "Create Backup", capture modal |
| `tui.png` | Terminal UI (TUI) running in terminal | Run `python3 cli/tui.py`, navigate with arrows, capture terminal |
| `phpmyadmin.png` | phpMyAdmin interface | Open `http://localhost:8080`, login with root/DB_ROOT_PASSWORD, capture |
| `vhost-example.png` | Example vhost (testapp.local) working in browser | Open `http://testapp.local` (after adding to /etc/hosts), capture |

### 4. Save Screenshots

Save all screenshots as **PNG** files in this directory:

```
docs/screenshots/
├── dashboard.png
├── services.png
├── vhosts.png
├── ssl.png
├── rds.png
├── logs.png
├── backups.png
├── tui.png
├── phpmyadmin.png
└── vhost-example.png
```

### 5. Recommended Tools

| OS | Tool |
|----|------|
| Linux (Kubuntu/Ubuntu) | `Spectacle`, `Flameshot`, `gnome-screenshot`, `shutter` |
| macOS | `Cmd+Shift+4`, `Screenshot.app`, `CleanShot X` |
| Windows | `Win+Shift+S`, `Snipping Tool`, `ShareX` |

**Tip**: Use a tool that captures the full scrolling page for the dashboard (e.g., Flameshot, browser dev tools "Capture full size screenshot").

---

## Placeholder References in Documentation

The following markdown image references are used in documentation files. They will render once you add the actual PNG files:

### In `README.md`:
```markdown
![Dashboard](docs/screenshots/dashboard.png)
![TUI](docs/screenshots/tui.png)
```

### In `docs/LOCAL_SETUP.md`:
```markdown
![Dashboard](docs/screenshots/dashboard.png)
![VHosts](docs/screenshots/vhosts.png)
![SSL](docs/screenshots/ssl.png)
```

### In `docs/API.md`:
```markdown
![API Response](docs/screenshots/api-response.png)
```

---

## Screenshot Specifications

| Property | Value |
|----------|-------|
| Format | PNG |
| Max Width | 1920px |
| Quality | High (lossless) |
| Background | Light theme (default) |
| Browser | Chrome/Firefox/Edge (any modern) |
| Zoom | 100% (default) |

---

## Automated Capture (Optional)

If you have Playwright/Puppeteer installed, you can automate captures:

```bash
# Install Playwright
npm init -y && npm install playwright
npx playwright install chromium

# Capture dashboard
npx playwright screenshot --full-page http://localhost:5000 docs/screenshots/dashboard.png

# Capture TUI (requires terminal automation - more complex)
```

---

## Notes

- **No browser in sandbox**: This documentation is written for the user to capture screenshots after local installation
- **Theme**: Dashboard defaults to light theme; you can toggle dark mode with the sun/moon icon
- **Data**: Screenshots look best with some data (at least one vhost, one backup, running services)
- **Permissions**: phpMyAdmin requires MySQL root password from `.env`

---

## Checklist

- [ ] `dashboard.png` - Main dashboard overview
- [ ] `services.png` - Services management
- [ ] `vhosts.png` - Virtual hosts list + add modal
- [ ] `ssl.png` - SSL certificate management
- [ ] `rds.png` - RDS tunnel configuration
- [ ] `logs.png` - Log viewer with live tail
- [ ] `backups.png` - Backup list + create modal
- [ ] `tui.png` - Terminal UI in action
- [ ] `phpmyadmin.png` - phpMyAdmin interface
- [ ] `vhost-example.png` - Working vhost in browser

Once all screenshots are captured, the documentation will render with actual images.