# Backup Scripts

This repository contains two backup scripts for managing both offsite and local backups:
- **`backup_offsite.sh`** - Uses restic to create backups to Backblaze B2 cloud storage
- **`backup_local.sh`** - Uses rsync to create versioned backups to a connected local drive

## Features

### Common Features
- **Dual backup support** - Run offsite, local, or both backups per target
- **Complete backup runner** - Processes all backup targets in sequence
- **Path validation** - Checks if backup paths exist before attempting backup
- **Telegram notifications** - Sends notifications with backup summaries
- **Error handling** - Continues with other targets if one fails

### Offsite Backups (`backup_offsite.sh`)
- **Restic integration** - Uses restic for backups to Backblaze B2
- **Repository management** - Automatically creates repositories if they don't exist
- **Retention policies** - Configurable retention with automatic pruning
- **Integrity checks** - Optional weekly integrity checks

### Local Backups (`backup_local.sh`)
- **Rsync-based backups** - Efficient incremental backups to local storage
- **Soft delete grace period** - Deleted files remain in backup for 60 days
- **Smart pruning** - Only removes files that no longer exist on source and are older than 60 days
- **Direct access** - Files stored plaintext on local drive (no encryption overhead)

## Prerequisites

### Required Tools
- **jq** - For JSON parsing
  ```bash
  apt-get update && apt-get install -y jq  # Ubuntu/Debian
  # or
  brew install jq # Mac OS
  ```
- **rsync** - For local backups (usually pre-installed)
  ```bash
  apt-get install -y rsync  # Ubuntu/Debian
  # or
  brew install rsync # Mac OS
  ```

### For Offsite Backups
- **Restic** (v0.16.2 or later)
  ```bash
  curl -L https://github.com/restic/restic/releases/download/v0.16.2/restic_0.16.2_linux_amd64.bz2 | bunzip2 > /usr/local/bin/restic
  chmod +x /usr/local/bin/restic
  ```
- **Backblaze B2 Account**
  - Create a Backblaze B2 account
  - Create a bucket for backups
  - Generate application keys

### For Local Backups
- A connected local storage device (e.g., external hard drive, NAS)
- Mount point accessible by the backup script (default: `/mnt/backup`)

## Setup

1. **Copy configuration files:**
   ```bash
   cp .env.example .env
   cp targets.example.json targets.json
   ```

2. **Edit `.env` file:**
   - For offsite backups: Set your Backblaze B2 credentials and restic password
   - For local backups: Set `LOCAL_BACKUP_ROOT` to point to your backup storage
   - Configure Telegram notifications (optional)

3. **Edit `targets.json` file:**
   - Add your backup targets with paths
   - Set `offsite: true` for targets you want backed up to Backblaze B2
   - Set `local: true` for targets you want backed up to local storage
   - Configure retention policies (for offsite backups only)

## Configuration

### Environment Variables

The scripts read environment variables from a `.env` file in the same directory. Copy `.env.example` to `.env` and edit the values:

```bash
# Backblaze B2 (required for offsite backups)
B2_BUCKET_NAME=my-b2-bucket
B2_ACCOUNT_ID=your_b2_account_id
B2_ACCOUNT_KEY=your_b2_account_key

# Restic password (required for offsite backups)
RESTIC_PASSWORD=supersecret

# Local backup root directory (optional for local backups)
# LOCAL_BACKUP_ROOT=/mnt/backup

# Telegram notifications (optional)
# TELEGRAM_BOT_TOKEN=123456:ABCDEF...
# TELEGRAM_CHAT_ID=123456789

# Custom paths (optional)
# ENV_FILE=/custom/path/.env
# TARGETS_FILE=/custom/path/targets.json
```

### Backup Targets Configuration

Create a `targets.json` file in the same directory as the scripts with your backup targets. Copy `targets.example.json` to `targets.json` and edit it.

Example `targets.json`:

```json
[
  {
    "name": "documents",
    "enabled": true,
    "locations": ["/home/user/Documents", "/home/user/Desktop"],
    "offsite": true,
    "local": true,
    "retention": { "keepWithin": "1m" },
    "checkWeekly": false
  },
  {
    "name": "photos",
    "enabled": true,
    "locations": ["/home/user/Pictures"],
    "offsite": true,
    "local": false,
    "retention": { "keepLast": 10, "keepDaily": 7 },
    "checkWeekly": false
  },
  {
    "name": "local_only",
    "enabled": true,
    "locations": ["/home/user/Projects"],
    "offsite": false,
    "local": true,
    "checkWeekly": false
  }
]
```

#### Target Configuration Fields

- `name`: Unique name for the backup target (required)
- `enabled`: Set to `true` to include this target in backups (default: true)
- `locations`: Array of paths to backup (required, can be strings or objects with "path" key)
- `offsite`: Set to `true` to backup to Backblaze B2 via `backup_offsite.sh` (default: false)
- `local`: Set to `true` to backup to local storage via `backup_local.sh` (default: false)
- `retention`: Retention policy for pruning old backups (offsite only, optional, defaults to keep within 1 month)
- `checkWeekly`: Run integrity check every Sunday (offsite only, optional, default: false)

### Retention Policies

Retention policies control how long backups are kept. Supported options:

- `keepLast`: Keep the last N snapshots
- `keepHourly`: Keep one snapshot per hour for the last N hours
- `keepDaily`: Keep one snapshot per day for the last N days
- `keepWeekly`: Keep one snapshot per week for the last N weeks
- `keepMonthly`: Keep one snapshot per month for the last N months
- `keepYearly`: Keep one snapshot per year for the last N years
- `keepWithin`: Keep all snapshots within the given duration (e.g., "1y", "30d", "1m")

Example: `{"keepDaily": 7, "keepWeekly": 4, "keepMonthly": 12}`

## Usage

### Direct Execution

```bash
# Make scripts executable (if not already)
chmod +x backup_offsite.sh backup_local.sh

# Run offsite backups (to Backblaze B2)
./backup_offsite.sh

# Run local backups (to connected local drive)
./backup_local.sh

# Run both (in sequence)
./backup_offsite.sh && ./backup_local.sh
```

### Automation Integration

Cron is probably easiest. Alternatives could also be n8N or a CI/CD pipeline.

The scripts read configuration from `.env` and `targets.json` in their directory.

#### Example Cron Setup

```bash
# Run offsite backups daily at 2 AM
0 2 * * * /path/to/backup_offsite.sh

# Run local backups daily at 3 AM
0 3 * * * /path/to/backup_local.sh

# Or run both together
0 2 * * * /path/to/backup_offsite.sh && /path/to/backup_local.sh
```

## Output and Notifications

Both scripts provide:

- **Console logging** - Detailed progress information to stderr
- **Telegram notifications** - Real-time updates for each backup operation

### Offsite Backup Notifications
1. Backup started
2. Repository initialization (if needed)
3. Backup completion for each target with summary
4. Retention policy application for each target
5. Weekly integrity check (if enabled and on Sunday)
6. Final completion summary

### Local Backup Notifications
1. Backup started (with local backup root path)
2. Backup completion for each target with rsync summary
3. Pruning of old files that no longer exist on source (older than 60 days)
4. Count of deleted old files
5. Final completion summary

## Error Handling

- Script exits on critical errors (missing restic, invalid JSON)
- Continues processing other targets if one fails
- Provides detailed error messages in notifications
- Logs all activities to stderr

## Security Considerations

- Store B2 credentials securely (in .env file, not committed to version control)
- Ensure the backup script has read access to backup paths
- Consider encrypting sensitive configuration files
- Use strong restic passwords

### Debug Mode

Add debugging by modifying the script:
```bash
# Add at the top of the script
set -x  # Enable debug tracing
```

### Logs

Check the console output and any automation tool logs (n8n, cron, etc.) for detailed error information.

## Performance Notes

- Backups run sequentially (one repo at a time, all locations per repo in one command)
- Large backups may take significant time
- Monitor B2 costs for large backup sets

## Support

May your last backup not be your only backup.
