# Production Status Display - Installation Instructions

## Overview

The `prod_status_display.sh` script displays Oracle Production backup and upload status automatically when you login to the production server.

## Features

- **Recent Archive Uploads**: Last 5 upload operations to Azure Blob Storage
- **RMAN Archive Backups**: Last 5 archivelog backup operations
- **RMAN Full Backups**: Last 5 full database backup operations
- **Production Statistics**: Current sequence, archives generated, disk usage
- **Color-coded Output**: Green (OK), Yellow (Warning/Partial), Blue (NOOP), Red (Error)
- **Professional Display**: Clean output with status indicators (✓ ✗ ⚠ ○)
- **Auto-Detection**: Automatically detects Oracle SID from environment or log files
- **Debug Mode**: Built-in diagnostics for troubleshooting (PROD_STATUS_DEBUG=1)
- **Fast Execution**: Direct SQL queries and file reads for quick login
- **File Locations**: Shows paths to all log directories

## Installation

### Step 1: Copy Script to Production Server

Copy the `prod_status_display.sh` script to the production server:

```bash
# Example using scp
scp prod_status_display.sh oracle@prod-server:/u01/scripts/standby/

# Or if already on the server, ensure it's in the right location
cp prod_status_display.sh /u01/scripts/standby/
chmod +x /u01/scripts/standby/prod_status_display.sh
```

### Step 2: Add to .bash_profile

Edit your `.bash_profile` (or `.bashrc`) on the production server:

```bash
vi ~/.bash_profile
```

Add the following line at the **end** of the file:

```bash
# Display Production Status on Login
if [ -f /u01/scripts/standby/prod_status_display.sh ]; then
    /u01/scripts/standby/prod_status_display.sh
fi
```

**Alternative**: If you want to make it optional with an environment variable:

```bash
# Display Production Status on Login (optional, set SHOW_PROD_STATUS=1 to enable)
if [ "${SHOW_PROD_STATUS}" = "1" ] && [ -f /u01/scripts/standby/prod_status_display.sh ]; then
    /u01/scripts/standby/prod_status_display.sh
fi
```

Then enable it permanently by adding to `.bash_profile`:
```bash
export SHOW_PROD_STATUS=1
```

### Step 3: Test the Installation

Logout and login again, or source the profile manually:

```bash
source ~/.bash_profile
```

You should see the production status display immediately.

## Manual Execution

You can also run the script manually anytime:

```bash
/u01/scripts/standby/prod_status_display.sh
```

Or create an alias in your `.bash_profile`:

```bash
alias prodstatus='/u01/scripts/standby/prod_status_display.sh'
```

Then simply type `prodstatus` to see the status.

## Output Example

```
╔════════════════════════════════════════════════════════════════╗
║  Oracle Production - Backup & Upload Status                   ║
║  Database: MSCDBPR                                             ║
╚════════════════════════════════════════════════════════════════╝

Recent Archive Uploads to Blob:
   Location: /u01/scripts/standby/log/upload_blob_MSCDBPR.log

   2025-10-24 10:25:00 [✓ OK] Uploads:15 Seq:12430→12445
   2025-10-24 10:15:00 [✓ OK] Uploads:12 Seq:12418→12430
   2025-10-24 10:05:00 [○ NOOP] Uploads:0

Recent RMAN Archive Backups:
   Location: /u02/backup/rman/log/rman_arch_MSCDBPR.log

   2025-10-24 06:00:15 [✓ OK] RUN_ID:a3b5c7d9
   2025-10-23 06:00:12 [✓ OK] RUN_ID:e4f6g8h0
   2025-10-22 06:00:10 [✓ OK] RUN_ID:i1j2k3l4

Recent RMAN Full Backups:
   Location: /u02/backup/rman/log/rman_full_MSCDBPR.log

   2025-10-24 02:00:30 [✓ OK] RUN_ID:m5n6o7p8
   2025-10-17 02:00:25 [✓ OK] RUN_ID:q9r0s1t2
   2025-10-10 02:00:22 [✓ OK] RUN_ID:u3v4w5x6

Production Statistics:

   Current Sequence:     12445
   Archives (24h):       285
   FRA Disk Usage:       52%
   Backup Disk Usage:    38%

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Upload Logs:    /u01/scripts/standby/log
RMAN Logs:      /u02/backup/rman/log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Color Coding

### Status Indicators
- **✓ Green**: Success (OK)
- **○ Blue**: No operation needed (NOOP)
- **⚠ Yellow**: Partial success (PARTIAL - some uploads/backups failed)
- **✗ Red**: Error or failure

### Disk Usage Colors
- **Green**: Usage ≤ 70%
- **Yellow**: Usage 71-85%
- **Red**: Usage > 85%

## Debug Mode

When troubleshooting issues, enable debug mode to see detailed variable values and execution flow:

```bash
# Method 1: Enable in .bash_profile (persistent)
export PROD_STATUS_DEBUG=1

# Then reload:
source ~/.bash_profile
```

```bash
# Method 2: Enable for single execution
PROD_STATUS_DEBUG=1 /u01/scripts/standby/prod_status_display.sh
```

Debug output example:
```
[DEBUG] Using ORACLE_SID: MSCDBPR
[DEBUG] Final SID: MSCDBPR
[DEBUG] UPLOAD_LOG: /u01/scripts/standby/log/upload_blob_MSCDBPR.log
[DEBUG] RMAN_ARCH_LOG: /u02/backup/rman/log/rman_arch_MSCDBPR.log
[DEBUG] RMAN_FULL_LOG: /u02/backup/rman/log/rman_full_MSCDBPR.log

╔════════════════════════════════════════════════════════════════╗
║  Oracle Production - Backup & Upload Status                   ║
║  Database: MSCDBPR                                             ║
╚════════════════════════════════════════════════════════════════╝
...
```

**Disable debug mode:**
```bash
unset PROD_STATUS_DEBUG
# or
export PROD_STATUS_DEBUG=0
```

## Customization

### Change Number of Lines Displayed

Edit the script and modify the `LINES_TO_SHOW` variable:

```bash
# Number of lines to display
LINES_TO_SHOW=10  # Change from 5 to 10
```

### Disable Specific Sections

Comment out function calls in the `main()` function:

```bash
main() {
    print_header
    parse_and_display_upload_log
    # parse_and_display_rman_arch_log  # Commented out
    parse_and_display_rman_full_log
    display_production_stats
    print_footer
}
```

### Disable for Specific Users

If you don't want the status to show for certain users, add a check in `.bash_profile`:

```bash
if [ "$USER" != "root" ] && [ -f /u01/scripts/standby/prod_status_display.sh ]; then
    /u01/scripts/standby/prod_status_display.sh
fi
```

## Troubleshooting

### SID Not Detected / Files Not Found

If you see errors like "Log file not found", the script cannot determine the Oracle SID.

**Enable Debug Mode** to diagnose:

```bash
# Add to .bash_profile BEFORE calling the script:
export PROD_STATUS_DEBUG=1

# Then reload:
source ~/.bash_profile
```

**Common Causes:**

1. **ORACLE_SID not set when script runs**

   Solution: Ensure ORACLE_SID is exported BEFORE calling prod_status_display.sh in .bash_profile:
   ```bash
   # .bash_profile example - CORRECT ORDER:

   # 1. Set Oracle environment FIRST
   export ORACLE_SID=MSCDBPR
   export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
   export PATH=$ORACLE_HOME/bin:$PATH

   # 2. THEN call status display
   if [ -f /u01/scripts/standby/prod_status_display.sh ]; then
       /u01/scripts/standby/prod_status_display.sh
   fi
   ```

2. **ORACLE_SID not exported**

   If you only set `ORACLE_SID=value` without `export`, child processes won't see it:
   ```bash
   # WRONG:
   ORACLE_SID=MSCDBPR

   # CORRECT:
   export ORACLE_SID=MSCDBPR
   ```

**Auto-Detection Fallback:**

If ORACLE_SID is not available, the script will automatically try to detect it from existing log files. For this to work:
- At least one upload script must have run successfully
- Log file must exist: `/u01/scripts/standby/log/upload_blob_*.log`

### SQL Queries Fail / Statistics Not Shown

If you see "Unable to query" for statistics:

1. Check Oracle environment is properly set:
   ```bash
   echo $ORACLE_HOME
   echo $ORACLE_SID
   which sqlplus
   ```

2. Test sqlplus connectivity:
   ```bash
   sqlplus / as sysdba <<EOF
   SELECT 'Connected' FROM DUAL;
   EXIT;
   EOF
   ```

3. Check if database is running:
   ```bash
   ps -ef | grep pmon
   ```

### Script Runs Slowly

The script queries the database and reads log files. If it's slow:

1. Check database performance:
   ```bash
   sqlplus / as sysdba
   SQL> SELECT * FROM v$session WHERE username IS NOT NULL;
   ```

2. Check disk I/O on log directories:
   ```bash
   df -h /u01/scripts/standby/log
   df -h /u02/backup/rman/log
   iostat 1 5
   ```

3. Reduce number of lines displayed (edit script):
   ```bash
   # Change from 5 to 3:
   LINES_TO_SHOW=3
   ```

### Logs Not Found

Verify the log file paths match your environment:

```bash
# Check if logs exist
ls -l /u01/scripts/standby/log/
ls -l /u02/backup/rman/log/

# If different, edit the script variables:
STANDBY_DIR="/u01/scripts/standby"  # Adjust if needed
RMAN_BACKUP_DIR="/u02/backup/rman"  # Adjust if needed
```

### Permission Issues

Ensure the oracle user has read access to all log directories:

```bash
# Check permissions
ls -ld /u01/scripts/standby/log
ls -ld /u02/backup/rman/log

# Should show readable by oracle user
# If not, adjust permissions (as root):
chmod 755 /u01/scripts/standby/log
chmod 755 /u02/backup/rman/log
```

## Log Files Reference

The script displays information from these files:

| File | Purpose | Format | Location |
|------|---------|--------|----------|
| `upload_blob_${SID}.log` | Archive uploads to blob | Pipe-delimited | /u01/scripts/standby/log |
| `rman_arch_${SID}.log` | RMAN archive backups | Pipe-delimited | /u02/backup/rman/log |
| `rman_full_${SID}.log` | RMAN full backups | Pipe-delimited | /u02/backup/rman/log |

## Production Statistics Queries

The script executes these SQL queries:

### Current Sequence Number
```sql
SELECT TRIM(MAX(l.sequence#))
FROM v$log_history l, v$database d, v$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;
```

### Archives Generated in Last 24 Hours
```sql
SELECT COUNT(*)
FROM v$archived_log
WHERE first_time >= SYSDATE - 1
AND dest_id = 1;
```

## Security Notes

- Script runs with the privileges of the logged-in user
- Requires read access to log directories (/u01/scripts/standby/log, /u02/backup/rman/log)
- Requires database connectivity (sqlplus / as sysdba)
- Does not modify any files or database objects
- Safe to run on every login

## Comparison with DR Status Script

| Feature | Production Script | DR Script |
|---------|------------------|-----------|
| **Focus** | Backups and uploads | Sync and recovery |
| **Main Logs** | upload_blob, rman_arch, rman_full | dr_sync_recover, gap_history, monitor |
| **SQL Queries** | Current sequence, archives generated | Last applied sequence |
| **Key Metrics** | Upload count, backup status, disk usage | Gap prod-dr, recovery progress |
| **Install Location** | Production server | DR server |

## Support

For issues or customization requests, check:
- Main documentation: `CLAUDE.md`
- Script location: `standby-azure-blob/prod_status_display.sh`
- Log locations shown in script output

## Related Scripts

- **DR Status Display**: `dr_status_display.sh` - For DR server status
- **Upload Script**: `oracle-standby-prod-upload.sh` - Uploads archives to blob
- **RMAN Archive**: `rman_backup/rman_arch.sh` - Archive log backups
- **RMAN Full**: `rman_backup/rman_full.sh` - Full database backups
