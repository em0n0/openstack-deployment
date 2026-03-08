**OpenStack Complete** automates the full lifecycle of a self-hosted OpenStack cloud:

- **Deploy** - interactive wizard + single command installs the entire stack
- **Operate** - health dashboard, backup/restore, SSL, Kubernetes on top
- **Harden** - CIS Benchmark audit with scored report and auto-fix
- **Remove** - safe uninstaller with multiple confirmation interlocks

Everything is driven by a single configuration file (`configs/main.env`) that the wizard fills in automatically. You never need to touch any of the numbered install scripts.

---

## Table of Contents

- [Quick Start](#quick-start)
- [System Requirements](#system-requirements)
- [Project Structure](#project-structure)
- [Configuration Reference](#configuration-reference)
- [All Commands](#all-commands)
- [Module Reference](#module-reference)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/openstack-complete.git
cd openstack-complete

# Run — the wizard launches automatically on first use
sudo bash deploy.sh
```

The **Setup Wizard** detects your IP and network interface automatically and asks you to confirm them. It only requires manual input for passwords. The entire deployment takes 20–40 minutes.

### Skip the wizard (advanced)

```bash
# Accept auto-detected settings, only ask for passwords
sudo bash deploy.sh --quick

# Or edit the config manually, then deploy
nano configs/main.env
sudo bash deploy.sh --full
```

---

## System Requirements

| Resource | Minimum (All-in-One) | Recommended |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | Ubuntu Server 24.04 LTS |
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16+ GB |
| Disk | 50 GB free | 100+ GB |
| Network | 1 NIC | 2 NICs (see [Network Architecture](docs/ARCHITECTURE.md)) |

> ⚠️ **Use a fresh Ubuntu 24.04 installation.** Do not run on a server with existing services — the installer modifies MariaDB, Apache, networking, and system packages.

Pre-flight checks (distro, disk space, RAM, internet) run automatically before deployment begins.

---

## Project Structure

```
openstack-complete/
│
├── deploy.sh                    ← THE ENTRY POINT — run this
├── uninstall.sh                 ← Safe full removal
├── configs/
│   └── main.env                 ← THE ONLY CONFIG FILE — wizard fills this in
│
├── scripts/
│   ├── lib.sh                   ← Shared library (logging, guards, rollback, health)
│   │
│   ├── base/                    ← Core OpenStack — always installed
│   │   ├── 01_prerequisites.sh  │  MariaDB, RabbitMQ, Memcached, NTP, Etcd
│   │   ├── 02_keystone.sh       │  Identity & Authentication
│   │   ├── 03_glance.sh         │  VM Image Storage
│   │   ├── 04_placement.sh      │  Resource Tracking
│   │   ├── 05_nova.sh           │  Compute (VM lifecycle)
│   │   ├── 06_neutron.sh        │  Virtual Networking
│   │   ├── 07_horizon.sh        │  Web Dashboard
│   │   └── 08_verify.sh         │  Post-install health checks
│   │
│   ├── services/                ← Optional services (enable in main.env)
│   │   ├── 09_cinder.sh         │  Block Storage    (like AWS EBS)
│   │   ├── 10_swift.sh          │  Object Storage   (like AWS S3)
│   │   ├── 11_heat.sh           │  Orchestration    (like CloudFormation)
│   │   ├── 12_ceilometer.sh     │  Telemetry        (like CloudWatch)
│   │   ├── 13_barbican.sh       │  Secrets Manager  (like Secrets Manager)
│   │   ├── 14_octavia.sh        │  Load Balancer    (like ALB/NLB)
│   │   ├── 15_manila.sh         │  Shared Filesystem (like EFS)
│   │   └── 16_designate.sh      │  DNS Service       (like Route 53)
│   │
│   ├── multinode/               ← Multi-node cluster support
│   │   ├── 00_preflight.sh      │  Hostname, hosts, NTP, firewall (all nodes)
│   │   ├── 02_compute.sh        │  Nova + Neutron agent (compute nodes)
│   │   └── 03_storage.sh        │  Cinder + Swift backend (storage nodes)
│   │
│   ├── monitoring/              ← Health Dashboard & Alerting
│   │   ├── monitor.sh           │  Live dashboard + Slack/email alerts
│   │   └── install-cron.sh      │  Schedule monitoring (every 5 min)
│   │
│   ├── backup/                  ← Backup & Disaster Recovery
│   │   ├── backup.sh            │  VMs, databases, configs, images
│   │   └── restore.sh           │  Restore from any backup point
│   │
│   ├── k8s/
│   │   └── deploy-k8s.sh        ← Kubernetes cluster on OpenStack VMs
│   │
│   ├── ssl/
│   │   ├── ssl-manager.sh       ← Let's Encrypt cert management
│   │   └── reload-services.sh   │  Post-renewal hook
│   │
│   └── hardening/
│       └── server-harden.sh     ← CIS Benchmark audit & scored auto-fix
│
├── docs/
│   ├── ARCHITECTURE.md          ← Network layout, service dependency chain
│   └── MULTINODE.md             ← Step-by-step multi-node setup guide
│
├── logs/                        ← Auto-created; deployment logs land here
│
├── CHANGELOG.md
├── CONTRIBUTING.md
└── SECURITY.md
```

---

## Configuration Reference

The wizard writes all values automatically. These are the most important settings:

```bash
# ── Deployment topology ────────────────────────────────────────────────────
DEPLOY_MODE="all-in-one"        # or "multi-node"
HOST_IP=""          # auto-detected; wizard confirms

# ── Optional services (set "true" to install) ─────────────────────────────
INSTALL_CINDER="false"          # Block storage    ~200 MB RAM
INSTALL_SWIFT="false"           # Object storage   ~300 MB RAM
INSTALL_HEAT="false"            # Orchestration    ~150 MB RAM
INSTALL_CEILOMETER="false"      # Telemetry  ⚠ resource-heavy: 1-2 GB RAM
INSTALL_BARBICAN="false"        # Secrets          ~100 MB RAM
INSTALL_OCTAVIA="false"         # Load balancer    ~300 MB RAM
INSTALL_MANILA="false"          # Shared FS        ~200 MB RAM
INSTALL_DESIGNATE="false"       # DNS              ~100 MB RAM

# ── Monitoring & Alerts ───────────────────────────────────────────────────
SLACK_WEBHOOK_URL=""            # Incoming webhook URL — leave blank to disable
ALERT_EMAIL=""                  # Alert recipient — leave blank to disable

# ── Backup ────────────────────────────────────────────────────────────────
BACKUP_PATH="/var/backups/openstack"
BACKUP_KEEP_DAYS=7

# ── SSL ───────────────────────────────────────────────────────────────────
ACME_EMAIL="admin@yourdomain.com"
OPENSTACK_DOMAIN="cloud.yourdomain.com"
```

> 💡 **Security tip:** Move passwords out of `main.env` and into `configs/.secrets.env` (mode `600`). That file is gitignored and overrides `main.env` at runtime. Never commit `main.env` with real passwords.

---

## All Commands

```bash
# First-time setup
sudo bash deploy.sh                    # Interactive menu (launches wizard on first run)
sudo bash deploy.sh --wizard           # Re-run the setup wizard
sudo bash deploy.sh --quick            # Wizard: accept auto-detected settings, only ask passwords

# Deployment
sudo bash deploy.sh --full             # Deploy everything configured in main.env
sudo bash deploy.sh --base             # Base OpenStack only (Keystone → Horizon)
sudo bash deploy.sh --services         # Optional services only
sudo bash deploy.sh --resume           # Continue an interrupted deployment
sudo bash deploy.sh --dry-run          # Preview all actions without executing

# Recovery
sudo bash deploy.sh --rollback-step nova   # Undo one failed step, then --resume

# Operations
sudo bash deploy.sh --verify           # Health check — status table of all services
sudo bash deploy.sh --monitor          # Live health dashboard
sudo bash deploy.sh --backup           # Backup VMs, databases, configs
sudo bash deploy.sh --restore          # Restore from a backup point
sudo bash deploy.sh --harden           # CIS Benchmark audit + auto-fix
sudo bash deploy.sh --ssl              # SSL certificate management
sudo bash deploy.sh --k8s              # Deploy Kubernetes on your OpenStack cloud
sudo bash deploy.sh --multinode        # Multi-node cluster setup

# Utility
sudo bash deploy.sh --config           # Show current configuration
sudo bash deploy.sh --help             # Show all flags
```

---

## Module Reference

### Base OpenStack

Installs in order: **Keystone → Glance → Placement → Nova → Neutron → Horizon → Verify**

After deployment:
```bash
# Dashboard
open http://YOUR_IP/horizon      # admin / your ADMIN_PASS

# CLI access (after sourcing main.env)
source configs/main.env
openstack service list
openstack compute service list
openstack image list
```

### Optional Services

Enable any service in `main.env` with `INSTALL_*="true"`, then run `--services` or `--full`.

| Service | Enable flag | Quick test |
|---|---|---|
| Cinder | `INSTALL_CINDER="true"` | `openstack volume create --size 5 test-vol` |
| Swift | `INSTALL_SWIFT="true"` | `openstack container create my-bucket` |
| Heat | `INSTALL_HEAT="true"` | `openstack stack create -t template.yaml my-stack` |
| Barbican | `INSTALL_BARBICAN="true"` | `openstack secret store --name pw --payload 'MyPass'` |
| Designate | `INSTALL_DESIGNATE="true"` | `openstack zone create --email a@b.com example.com.` |

### Backup & Restore

```bash
sudo bash deploy.sh --backup     # Full backup: VMs, databases, configs, images
sudo bash deploy.sh --restore    # Interactive restore — shows backup points, pick what to restore
```

Backups are stored at `BACKUP_PATH` (default `/var/backups/openstack`) and auto-pruned after `BACKUP_KEEP_DAYS` days. Automated daily backups can be installed via the menu.

### Kubernetes on OpenStack

```bash
sudo bash deploy.sh --k8s
# Creates VMs, bootstraps cluster, joins workers, writes kubeconfig

export KUBECONFIG=scripts/k8s/configs/kubeconfig
kubectl get nodes
```

### Security Hardening

```bash
sudo bash deploy.sh --harden
# Choose: Audit only (read-only) or Harden (audit + auto-fix)
# Generates a scored report: 47/52 checks passed (90%) — Grade: A
```

Checks include: SSH hardening, firewall rules, kernel parameters, file permissions, password policy, unused service removal, and OpenStack-specific security settings.

---

## Troubleshooting

### A deployment step failed

```bash
# See what went wrong (the script shows this automatically on failure)
less logs/deploy_TIMESTAMP.log

# Fix the issue, then continue where you left off
sudo bash deploy.sh --resume

# Or roll back just the failed step and re-run it
sudo bash deploy.sh --rollback-step nova    # replace 'nova' with the failed step name
sudo bash deploy.sh --resume
```

### A service is down after deployment

```bash
# Check the health table
sudo bash deploy.sh --verify

# Check a specific service
systemctl status nova-api
journalctl -u nova-api -n 50 --no-pager

# Re-run a single install script
sudo bash scripts/base/05_nova.sh
```

### Common errors

| Error | Fix |
|---|---|
| `HOST_IP = __CHANGE_ME__` | Run `sudo bash deploy.sh --wizard` |
| `Access denied` in DB step | Check `DB_PASS` in `main.env` matches MariaDB root |
| `Address already in use` | Another service is on a required port — check `sudo ss -tlnp` |
| `No space left on device` | Free up disk — OpenStack needs 20 GB+ free |
| `Connection refused` after deploy | Services may still be starting — wait 30s and run `--verify` |

### Logs

```bash
# View latest deployment log
sudo bash deploy.sh --config          # shows log path
tail -f logs/deploy_*.log             # follow live during deployment

# All logs are in logs/ and auto-pruned after LOG_KEEP_DAYS (default 30) days
```

---

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on bug reports, feature requests, and pull requests.

---

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). Do not open a public issue for security problems.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## Acknowledgements

Built on [OpenStack Caracal (2024.1)](https://releases.openstack.org/caracal/) — the open-source cloud platform. Designed for Ubuntu Server 24.04 LTS.
