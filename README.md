# rippled → xrpld Migration Scripts

These scripts automate the migration of the XRP Ledger daemon from **rippled** to the renamed **xrpld** binary and package. They handle detection, package replacement, configuration patching, service restart, and verification in one run.

---

## Prerequisites

| Platform | Requirement |
|----------|-------------|
| Linux / macOS | Bash 4.0 or later (`bash --version`) |
| Windows | PowerShell 5.1 or later (Windows 10 / Server 2019+) |
| All | Run as **root** (Linux/macOS) or **Administrator** (Windows) |
| All | Internet access to download the xrpld package |

> **macOS note:** Bash 3.x ships with macOS. Install a newer version via `brew install bash` and run the script with `/usr/local/bin/bash migrate_to_xrpld.sh`.

---

## Files

| File | Platform |
|------|----------|
| `migrate_to_xrpld.sh` | Linux, macOS |
| `migrate_to_xrpld.ps1` | Windows |

---

## Linux / macOS

### 1. Download and make executable

```bash
chmod +x migrate_to_xrpld.sh
```

### 2. Run interactively (recommended for first-time use)

```bash
sudo bash migrate_to_xrpld.sh
```

The script will detect your environment, print a summary of what it found, and prompt you before each optional step. Required changes (creating missing directories, patching the systemd unit) proceed automatically.

### 3. Run in auto mode (production / unattended)

```bash
sudo bash migrate_to_xrpld.sh --auto
```

`--auto` applies **only the changes required** for xrpld to start successfully. Optional actions (directory renames, symlink creation) are skipped without prompting. A full change log is printed at the end.

### 4. Run fully non-interactive (accept all defaults)

```bash
sudo bash migrate_to_xrpld.sh --yes
```

Accepts all prompts with their default answers (including optional actions).

---

## Command-line Options

| Option | Description |
|--------|-------------|
| `--auto` | Unattended mode — required changes only, no prompts |
| `--yes` | Non-interactive — accept all defaults including optional steps |
| `--config-dir <path>` | Override the directory searched for rippled.cfg |
| `--scan-dir <path>` | Add an extra directory to the filesystem rippled scan (repeatable) |
| `-h`, `--help` | Print usage summary |

### Examples

```bash
# Auto mode
sudo bash migrate_to_xrpld.sh --auto

# Non-interactive, accepting all defaults
sudo bash migrate_to_xrpld.sh --yes

# Override where the script looks for the config file
sudo bash migrate_to_xrpld.sh --config-dir /opt/ripple/etc

# Add extra directories to the rippled reference scan
sudo bash migrate_to_xrpld.sh --scan-dir /data/scripts --scan-dir /srv/ripple
```

---

## Windows

### 1. Open PowerShell as Administrator

Right-click **Windows PowerShell** → **Run as Administrator**.

### 2. Allow script execution (one-time)

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 3. Run interactively

```powershell
.\migrate_to_xrpld.ps1
```

### 4. Run in auto mode

```powershell
.\migrate_to_xrpld.ps1 -Auto
```

### 5. Run fully non-interactive

```powershell
.\migrate_to_xrpld.ps1 -Yes
```

### Windows Options

| Parameter | Description |
|-----------|-------------|
| `-Auto` | Required changes only, no prompts |
| `-Yes` | Accept all defaults |
| `-ConfigDir <path>` | Override config file search directory |

---

## What the Script Does (in order)

1. **Detects** OS, package manager, and installation type (RPM / Debian / binary / Homebrew / MSI / Chocolatey / Scoop)
2. **Detects** if rippled is running inside Docker, Docker Compose, or Kubernetes — and migrates the container image if so
3. **Locates** the rippled config file (it is **never moved**)
4. **Detects** startup method: systemd, SysV init, launchd, cron, or manual
5. **Detects** monitoring tools (monit, Supervisor, Nagios, Prometheus, Datadog), logrotate config, and cron jobs
6. **Scans** `/etc`, `/usr`, `/usr/local`, `/opt` (and any `--scan-dir` paths) for files referencing rippled
7. **Stops** and removes rippled (`apt-get remove`, not `purge` — config files are preserved)
8. **Installs** the xrpld package
9. **Patches** the xrpld systemd unit to add `--conf <original_config_path>` to ExecStart
10. **Validates** that every filesystem path declared in the config file actually exists; creates missing directories
11. **Updates** cron jobs, monitoring configs, logrotate files, and scanned files
12. **Starts** xrpld and waits up to 60 seconds for it to become active
13. **Verifies** xrpld is running via systemd state and an RPC `server_info` probe
14. **Prints** a full change log of every action taken

---

## Docker / Kubernetes

The script detects container environments and handles them automatically:

- **docker run:** stops and removes the old container, pulls the new xrpld image, and starts a new container with the same volumes, ports, and environment variables
- **docker-compose:** rewrites the `image:` field in the compose file and runs `docker compose up -d`
- **Kubernetes:** uses `kubectl set image` to update the Deployment or StatefulSet and waits for the rollout to complete

Set the `XRPLD_DOCKER_IMAGE` environment variable to override the target image:

```bash
XRPLD_DOCKER_IMAGE=myregistry.example.com/xrpld:1.0.0 sudo bash migrate_to_xrpld.sh
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Migration completed and xrpld is running |
| `1` | Fatal error (unsupported OS, package install failed, xrpld failed to start) |

---

## Troubleshooting

**xrpld fails to start after migration**

```bash
journalctl -u xrpld -n 100 --no-pager
systemctl status xrpld
```

**The script could not find the config file**

Pass the directory explicitly:

```bash
sudo bash migrate_to_xrpld.sh --config-dir /path/to/config/dir
```

**ExecStart patch warning ("Could not inject --conf")**

The xrpld systemd unit's ExecStart line calls a wrapper script rather than `xrpld` directly. Create a drop-in override manually:

```bash
mkdir -p /etc/systemd/system/xrpld.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/xrpld --conf /etc/rippled/rippled.cfg\n' \
  > /etc/systemd/system/xrpld.service.d/config.conf
systemctl daemon-reload
systemctl start xrpld
```

**RPC probe shows "connection refused"**

xrpld is running but the RPC port is not open yet (the server may still be loading the ledger). Wait a minute and probe manually:

```bash
curl -s http://127.0.0.1:5005 \
  -H 'Content-Type: application/json' \
  -d '{"method":"server_info","params":[{}]}' | python3 -m json.tool
```

**Filesystem scan produced UNKNOWN references**

The script lists these files at the end of the run for manual review. Inspect each file and update any rippled references that should become xrpld.

---

## Change Log Output

At the end of every run the script prints a categorised list of everything it changed, for example:

```
Changes made during this migration:
────────────────────────────────────────────────────────────────
  [SERVICE STOP       ] systemctl stop + disable rippled
  [PKG REMOVE         ] apt-get remove rippled
  [PKG INSTALL        ] apt-get install xrpld
  [UNIT PATCH         ] Injected --conf /etc/rippled/rippled.cfg into /lib/systemd/system/xrpld.service
  [CONFIG PATH        ] Created missing directory /var/lib/rippled/db
  [LOGROTATE          ] Renamed /etc/logrotate.d/rippled → xrpld
  [SERVICE START      ] systemctl enable + start xrpld
────────────────────────────────────────────────────────────────
```

---

## Support

For issues or questions, file a ticket in the internal Ripple Engineering tracker or contact the XRP Ledger infrastructure team.
