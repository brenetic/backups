# Backup Script to Backblaze B2

This bash script (`backup.sh`) uses restic to create backups to Backblaze B2 cloud storage.

## Features

- ✅ **Complete backup runner** - Processes all backup targets in sequence
- ✅ **Restic integration** - Uses restic for backups to Backblaze B2
- ✅ **Repository management** - Automatically creates repositories if they don't exist
- ✅ **Path validation** - Checks if backup paths exist before attempting backup
- ✅ **Telegram notifications** - Sends notifications with backup summaries per repo
- ✅ **Retention policies** - Configurable retention with automatic pruning
- ✅ **Error handling** - Continues with other targets if one fails
- ✅ **Integrity checks** - Optional weekly integrity checks

## Prerequisites

### 1. Restic Installation (e.g)
```bash
curl -L https://github.com/restic/restic/releases/download/v0.16.2/restic_0.16.2_linux_amd64.bz2 | bunzip2 > /usr/local/bin/restic
chmod +x /usr/local/bin/restic
```

### 2. jq Installation (for JSON parsing)
```bash
apt-get update && apt-get install -y jq  # Ubuntu/Debian
# or
brew install jq # Mac OS
```

### 3. Backblaze B2 Account
- Create a Backblaze B2 account
- Create a bucket for backups
- Generate application keys

## Setup

1. **Copy configuration files:**
   ```bash
   cp .env.example .env
   cp targets.example.json targets.json
   ```

2. **Edit `.env` file:**
   - Set your Backblaze B2 credentials
   - Set a restic password
   - Configure Telegram notifications (optional)

3. **Edit `targets.json` file:**
   - Add your backup targets with paths and retention policies

## Configuration

### Environment Variables

The script reads environment variables from a `.env` file in the same directory. Copy `.env.example` to `.env` and edit the values:

```bash
# Backblaze B2 (required)
B2_BUCKET_NAME=my-b2-bucket
B2_ACCOUNT_ID=your_b2_account_id
B2_ACCOUNT_KEY=your_b2_account_key

# Restic password (required)
RESTIC_PASSWORD=supersecret

# Telegram notifications (optional)
# TELEGRAM_BOT_TOKEN=123456:ABCDEF...
# TELEGRAM_CHAT_ID=123456789

# Custom paths (optional)
# ENV_FILE=/custom/path/.env
# TARGETS_FILE=/custom/path/targets.json
```

### Backup Targets Configuration

Create a `targets.json` file in the same directory as `backup.sh` with your backup targets. Copy `targets.example.json` to `targets.json` and edit it.

Example `targets.json`:

```json
[
  {
    "repo": "documents",
    "enabled": true,
    "locations": ["/home/user/Documents", "/home/user/Desktop"],
    "retention": { "keepWithin": "1m" },
    "checkWeekly": true
  },
  {
    "repo": "photos",
    "enabled": true,
    "locations": ["/home/user/Pictures"],
    "retention": { "keepLast": 10, "keepDaily": 7 }
  }
]
```

- `repo`: Unique name for the restic repository (required)
- `enabled`: Set to `true` to include this target in backups (default: true)
- `locations`: Array of paths to backup (required, can be strings or objects with "path" key)
- `retention`: Retention policy for pruning old backups (optional, defaults to keep within 1 month)
- `checkWeekly`: Run integrity check every Sunday (optional, default: false)

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
# Make script executable
chmod +x backup.sh

# Run the backup
./backup.sh
```

### Automation Integration

Cron is probably easiest. Alternatives could also be n8N or a CI/CD pipeline.

The script reads configuration from `.env` and `targets.json` in its directory.

## Output and Notifications

Current output:

- **Console logging** - Detailed progress information to stderr
- **Telegram notifications** - Real-time updates for each backup operation

Example notification flow:
1. Backup started
2. Repository initialization (if needed)
3. Backup completion for each repo with summary
4. Retention policy application for each repo
5. Weekly integrity check (if enabled and on Sunday)
6. Final completion summary

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
