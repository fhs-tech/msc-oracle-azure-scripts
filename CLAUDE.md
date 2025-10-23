# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a manual Oracle Standby Database synchronization system that uses Azure Blob Storage as the archive log transport mechanism. It implements a custom disaster recovery solution for Oracle Standard Edition (which lacks Oracle Data Guard).

**Architecture:**
- **Production Side** (`oracle-standby-prod-upload.sh`): Uploads archive logs to Azure Blob Storage
- **DR Side** (`oracle-standby-dr-sync-recover.sh`): Downloads archives and applies them to standby database
- **Monitoring** (`oracle-standby-dr-monitor.sh`): Monitors replication lag and disk usage
- **RMAN Backups** (`rman/`): Additional backup scripts for full database and archivelog backups

## Key Architecture Concepts

### Archive Log Synchronization Flow

1. **Production**: Archive logs are generated in `/u02/fra/MSCDBPR/archivelog/`
2. **Upload**: `oracle-standby-prod-upload.sh` uploads new archives to Azure Blob (single flat folder structure)
3. **Download**: `oracle-standby-dr-sync-recover.sh` downloads missing archives to `/u01/app/oracle/archives_standby`
4. **Recovery**: Automatic recovery applies archives using `RECOVER AUTOMATIC STANDBY DATABASE`
5. **Tracking**: Both sides maintain `.uploaded` and `.downloaded` flag files to track processed archives

### Archive Naming Convention

Archives follow the format: `{thread}_{sequence}_{resetlogs}.arc`
- Example: `1_12345_1234567890.arc`
- Thread: RAC instance number (single instance = 1)
- Sequence: Archive log sequence number
- Resetlogs: Database incarnation identifier

### State Tracking System

Both scripts use flag files in tracking directories to maintain idempotent operations:
- Production: `/u01/scripts/standby/tracking/{archive}.uploaded`
- DR: `/u01/app/oracle/admin/tracking_dr/{archive}.downloaded`

### Azure Blob Storage Structure

**Single Folder Design**: All archives stored in flat structure at:
`https://br241ew1psa01.blob.core.windows.net/dump/BRMODALLPROD/RMAN/ARCHIVE/MSCDBPR/`

**Control File**: `control.txt` contains metadata:
```
LAST_SEQUENCE={number}
LAST_UPDATE={timestamp}
SOURCE_HOST={hostname}
SOURCE_SID={oracle_sid}
```

## Environment Configuration

### Production Server (MSCDBPR)

- Oracle SID: `MSCDBPR`
- Archive Source: `/u02/fra/MSCDBPR/archivelog/`
- Tracking Dir: `/u01/scripts/standby/tracking/`
- Log Dir: `/u01/scripts/standby/log/`
- AzCopy Location: `/u01/app/azure/azcopy`

### DR Server (MSCDBDR)

- Oracle SID: `MSCDBDR`
- Oracle Home: `/u01/app/oracle/product/19c/dbhome_1`
- Archive Destination: `/u01/app/oracle/archives_standby`
- Tracking Dir: `/u01/app/oracle/admin/tracking_dr`
- Log Dir: `/u01/app/oracle/admin/logs`

## Common Operations

### Testing Scripts Locally

All scripts require Oracle environment variables and Azure credentials. They cannot be executed without:
1. Oracle database access (sqlplus connectivity)
2. Valid Azure Blob SAS token
3. Proper directory structure

### Script Execution Pattern

All scripts use flock-based locking to prevent concurrent execution:
```bash
LOCK_FILE="/tmp/{script_name}.lock"
exec 200>${LOCK_FILE}
flock -n 200 || exit 1
```

### Typical Cron Schedule

- Production upload: Every 5-10 minutes
- DR recovery: Every 10-15 minutes
- Monitoring: Every 30 minutes

## Key SQL Queries Used

**Get Current Sequence (Production)**:
```sql
SELECT trim(max(l.sequence#))
FROM v$log_history l, v$database d, v$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
```

**Get Last Applied Sequence (Standby)**:
```sql
SELECT NVL(MAX(SEQUENCE#), 0) FROM V$LOG_HISTORY;
```

**Verify Database Status**:
```sql
SELECT DATABASE_ROLE, OPEN_MODE FROM V$DATABASE;
```

## Important Implementation Details

### Upload Retry Logic

Production script retries failed uploads up to 3 times with 5-second delays between attempts.

### Download Filtering

DR script only downloads archives with sequence > last applied sequence to minimize unnecessary transfers.

### Automatic Cleanup

Scripts include cleanup functions (some commented out by default):
- Production: Removes archives older than 3 days after upload confirmation
- DR: Removes applied archives older than 3 days and logs older than 30 days

### Recovery Mode

DR script requires database in `MOUNTED` state (not OPEN). The recovery command is:
```sql
RECOVER AUTOMATIC FROM '{archivelog_dest}' STANDBY DATABASE;
```

## Azure Blob Configuration

### Authentication

Uses Anonymous credential type with SAS token embedded in URLs:
```bash
export AZCOPY_CRED_TYPE="Anonymous"
```

SAS tokens are time-limited and need periodic renewal (current expiry: 2026-10-17).

### AzCopy Parameters

Critical flags used:
- `--overwrite=false`: Prevents re-uploading existing archives
- `--check-length=true`: Verifies file integrity
- `--log-level=ERROR`: Reduces log verbosity

## Monitoring and Alerting

### Gap Threshold

Monitor script alerts when gap > 10 sequences (configurable via `ALERT_THRESHOLD`).

### Disk Usage Alert

Warns when archive destination disk usage exceeds 80%.

### Log Files

All operations logged with timestamps in format: `YYYY-MM-DD HH:MM:SS`

## Troubleshooting Common Issues

### Upload Failures

Check: Blob connectivity, SAS token validity, source archive existence, disk space.

### Recovery Failures

Verify: Database in MOUNT mode, archives downloaded, archive naming format, sufficient disk space.

### Gap Growth

Causes: Network issues, blob storage throttling, DR script not running, production generating archives faster than DR can apply.

## Security Notes

**SAS Token Exposure**: Current implementation has SAS tokens hardcoded in scripts. Consider using:
- Environment variables
- Azure Key Vault integration
- Managed identities (if running on Azure VMs)

**Permissions Required**: SAS token permissions = `racwl` (read, add, create, write, list)

## RMAN Backup Scripts

The repository includes additional RMAN backup scripts in the `rman/` directory:

### rman_arch.sh
- Performs archivelog backup using RMAN
- Uploads backup files to Azure Blob Storage with date-organized path structure
- Uses unique RUN_ID for execution tracking
- Target path: `RMAN/ARCHIVE/MSCDBPR/YYYY/MM/DD`

### rman_full.sh
- Performs full database backup using RMAN
- Uploads backup files to Azure Blob Storage
- Uses unique RUN_ID for execution tracking
- Target path: `RMAN/DATABASE/MSCDBPR/YYYY/MM/DD`

### RMAN Configuration
- Backup Directory: `/u02/backup/rman`
- Uses same Azure Blob authentication as standby scripts
- Implements file locking to prevent concurrent execution
- Generates detailed logs with RUN_ID tracking

### RMAN vs Standby Scripts
- **RMAN scripts**: Traditional backup/restore approach with organized folder structure
- **Standby scripts**: Real-time archive log shipping for continuous recovery
- Both use the same Azure Blob storage but different path hierarchies
