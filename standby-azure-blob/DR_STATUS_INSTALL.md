# DR Status Display - Installation Instructions

## Overview

The `dr_status_display.sh` script displays Oracle Standby DR synchronization status automatically when you login to the DR server.

## Features

- **Current Status Summary**: Shows latest gap, disk usage, and overall health from JSON monitor
- **Recent Sync Activity**: Last 5 synchronization operations (downloads and applies)
- **Gap History**: Last 5 gap measurements between Production and DR
- **Monitor Status**: Last 5 monitor executions with detailed metrics
- **Color-coded Output**: Green (OK), Yellow (Warning), Red (Error)
- **Professional Display**: Clean output with status indicators (✓ ✗ ⚠ ○)
- **Auto-Detection**: Automatically detects Oracle SID from environment or log files
- **Debug Mode**: Built-in diagnostics for troubleshooting (DR_STATUS_DEBUG=1)
- **Fast Execution**: Direct execution with no timeouts for quick login
- **File Locations**: Shows paths to all log files for easy access

## Installation

### Step 1: Copy Script to DR Server

Copy the `dr_status_display.sh` script to the DR server:

```bash
# Example using scp
scp dr_status_display.sh oracle@dr-server:/u01/scripts/standby/

# Or if already on the server, ensure it's in the right location
cp dr_status_display.sh /u01/scripts/standby/
chmod +x /u01/scripts/standby/dr_status_display.sh
```

### Step 2: Add to .bash_profile

Edit your `.bash_profile` (or `.bashrc`) on the DR server:

```bash
vi ~/.bash_profile
```

Add the following line at the **end** of the file:

```bash
# Display DR Standby Status on Login
if [ -f /u01/scripts/standby/dr_status_display.sh ]; then
    /u01/scripts/standby/dr_status_display.sh
fi
```

**Alternative**: If you want to make it optional with an environment variable:

```bash
# Display DR Standby Status on Login (optional, set SHOW_DR_STATUS=1 to enable)
if [ "${SHOW_DR_STATUS}" = "1" ] && [ -f /u01/scripts/standby/dr_status_display.sh ]; then
    /u01/scripts/standby/dr_status_display.sh
fi
```

Then enable it permanently by adding to `.bash_profile`:
```bash
export SHOW_DR_STATUS=1
```

### Step 3: Test the Installation

Logout and login again, or source the profile manually:

```bash
source ~/.bash_profile
```

You should see the DR status display immediately.

## Manual Execution

You can also run the script manually anytime:

```bash
/u01/scripts/standby/dr_status_display.sh
```

Or create an alias in your `.bash_profile`:

```bash
alias drstatus='/u01/scripts/standby/dr_status_display.sh'
```

Then simply type `drstatus` to see the status.

## Output Example

```
╔════════════════════════════════════════════════════════════════╗
║  Oracle Standby DR - Synchronization Status                   ║
║  Database: MSCDBDR                                             ║
╚════════════════════════════════════════════════════════════════╝

Current Status Summary:
   Location: /opt/discover/zabbix/standby_monitor_MSCDBDR.json

   Timestamp:      2025-10-24 10:30:15
   Status:         ✓ OK
   Production Seq: 12450
   DR Seq:         12445
   Gap:            5 sequences
   Last Sync:      2025-10-24 10:25:00
   Disk Usage:     45%

Recent Synchronization Activity:
   Location: /u01/scripts/standby/log/dr_sync_recover_MSCDBDR.log

   2025-10-24 10:25:00 [✓ OK] Down:3 Applied:3 Seq:12442→12445
   2025-10-24 10:15:00 [✓ OK] Down:2 Applied:2 Seq:12440→12442
   2025-10-24 10:05:00 [○ NOOP] Down:0 Applied:0 Seq:12440→12440

Recent Sequence Gap History:
   Location: /u01/scripts/standby/log/gap_history.log

   2025-10-24 10:25:30 Prod:12450 DR:12445 Gap:5 ✓
   2025-10-24 10:15:30 Prod:12447 DR:12442 Gap:5 ✓
   2025-10-24 10:05:30 Prod:12445 DR:12440 Gap:5 ✓

Recent Monitor Status:
   Location: /u01/scripts/standby/log/monitor_MSCDBDR.log

   2025-10-24 10:30:15 [✓ OK] Gap:5 LastSync:5m Disk:45%
   2025-10-24 10:00:15 [✓ OK] Gap:7 LastSync:10m Disk:45%
   2025-10-24 09:30:15 [✓ OK] Gap:4 LastSync:8m Disk:44%

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Logs Directory: /u01/scripts/standby/log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Color Coding

### Status Indicators
- **✓ Green**: Everything OK
- **⚠ Yellow**: Warning (gap moderate, disk usage high)
- **✗ Red**: Error or critical status

### Gap Colors
- **Green**: Gap ≤ 5 sequences (excellent)
- **Yellow**: Gap 6-10 sequences (acceptable)
- **Red**: Gap > 10 sequences (critical)

### Disk Colors
- **Green**: Usage ≤ 70%
- **Yellow**: Usage 71-85%
- **Red**: Usage > 85%

## Debug Mode

When troubleshooting issues, enable debug mode to see detailed variable values and execution flow:

```bash
# Method 1: Enable in .bash_profile (persistent)
export DR_STATUS_DEBUG=1

# Then reload:
source ~/.bash_profile
```

```bash
# Method 2: Enable for single execution
DR_STATUS_DEBUG=1 /u01/scripts/standby/dr_status_display.sh
```

Debug output example:
```
[DEBUG] Using ORACLE_SID: MSCDBPR
[DEBUG] Final SID: MSCDBPR
[DEBUG] SYNC_LOG: /u01/scripts/standby/log/dr_sync_recover_MSCDBPR.log
[DEBUG] MONITOR_JSON: /opt/discover/zabbix/standby_monitor_MSCDBPR.json

╔════════════════════════════════════════════════════════════════╗
║  Oracle Standby DR - Synchronization Status                   ║
║  Database: MSCDBPR                                             ║
╚════════════════════════════════════════════════════════════════╝
...
```

**Disable debug mode:**
```bash
unset DR_STATUS_DEBUG
# or
export DR_STATUS_DEBUG=0
```

## Customization

### Change Number of Lines Displayed

Edit the script and modify the `LINES_TO_SHOW` variable:

```bash
# Number of lines to display
LINES_TO_SHOW=10  # Change from 5 to 10
```

### Disable for Specific Users

If you don't want the status to show for certain users, add a check in `.bash_profile`:

```bash
if [ "$USER" != "root" ] && [ -f /u01/scripts/standby/dr_status_display.sh ]; then
    /u01/scripts/standby/dr_status_display.sh
fi
```

### Add to Global Profile

To show for all users, add to `/etc/profile.d/dr_status.sh`:

```bash
# As root
cat > /etc/profile.d/dr_status.sh <<'EOF'
if [ -n "${ORACLE_SID}" ] && [ -f /u01/scripts/standby/dr_status_display.sh ]; then
    /u01/scripts/standby/dr_status_display.sh
fi
EOF

chmod +x /etc/profile.d/dr_status.sh
```

## Troubleshooting

### SID Not Detected / Files Not Found

If you see errors like "Monitor JSON not found" or "Log file not found", the script cannot determine the Oracle SID.

**Enable Debug Mode** to diagnose:

```bash
# Add to .bash_profile BEFORE calling the script:
export DR_STATUS_DEBUG=1

# Then reload:
source ~/.bash_profile
```

Debug output will show:
```
[DEBUG] Using ORACLE_SID: MSCDBPR
[DEBUG] Final SID: MSCDBPR
[DEBUG] SYNC_LOG: /u01/scripts/standby/log/dr_sync_recover_MSCDBPR.log
[DEBUG] MONITOR_JSON: /opt/discover/zabbix/standby_monitor_MSCDBPR.json
```

**Common Causes:**

1. **ORACLE_SID not set when script runs**

   Solution: Ensure ORACLE_SID is exported BEFORE calling dr_status_display.sh in .bash_profile:
   ```bash
   # .bash_profile example - CORRECT ORDER:

   # 1. Set Oracle environment FIRST
   export ORACLE_SID=MSCDBPR
   export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
   export PATH=$ORACLE_HOME/bin:$PATH

   # 2. THEN call status display
   if [ -f /u01/scripts/standby/dr_status_display.sh ]; then
       /u01/scripts/standby/dr_status_display.sh
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

3. **Script runs before environment is loaded**

   If you source another file (like `.bash_profile` calling another script), ensure it's sourced BEFORE dr_status_display.sh:
   ```bash
   # Source Oracle environment first
   . /u01/app/oracle/product/19c/dbhome_1/oracle_env.sh

   # Then display status
   /u01/scripts/standby/dr_status_display.sh
   ```

**Auto-Detection Fallback:**

If ORACLE_SID is not available, the script will automatically try to detect it from existing log files. For this to work:
- At least one sync script must have run successfully
- Log file must exist: `/u01/scripts/standby/log/dr_sync_recover_*.log`

### Script Doesn't Run on Login

1. Check if `.bash_profile` is being sourced:
   ```bash
   echo "Profile loaded" >> ~/.bash_profile
   # Logout and login - you should see the message
   ```

2. Check script permissions:
   ```bash
   ls -l /u01/scripts/standby/dr_status_display.sh
   # Should show: -rwxr-xr-x
   ```

3. Check ORACLE_SID is set:
   ```bash
   echo $ORACLE_SID
   # Should show: MSCDBPR or your database SID
   ```

4. Verify ORACLE_SID is exported:
   ```bash
   # This should show your SID:
   bash -c 'echo $ORACLE_SID'

   # If empty, ORACLE_SID is not exported
   ```

### Script Runs Slowly

The script reads log files directly and should complete in under 1 second. If it's slow:

1. Check disk I/O on log directories:
   ```bash
   df -h /u01/scripts/standby/log
   iostat 1 5
   ```

2. Check if log files are extremely large:
   ```bash
   ls -lh /u01/scripts/standby/log/*.log
   # Files over 100MB may slow down tail operations
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
ls -l /opt/discover/zabbix/

# If different, edit the script variables:
STANDBY_DIR="/u01/scripts/standby"  # Adjust if needed
ZABBIX_MONITOR_DIR="/opt/discover/zabbix"  # Adjust if needed
```

### No Colors Showing

Your terminal might not support ANSI colors. Check:

```bash
echo $TERM
# Should show: xterm, xterm-256color, etc.
```

If using PuTTY or other terminal emulator, enable ANSI colors in settings.

## Log Files Reference

The script displays information from these files:

| File | Purpose | Format |
|------|---------|--------|
| `dr_sync_recover_${SID}.log` | Sync operations summary | Pipe-delimited |
| `gap_history.log` | Gap measurements | Bracketed timestamp format |
| `monitor_${SID}.log` | Monitor executions | Pipe-delimited |
| `standby_monitor_${SID}.json` | Current status | JSON |

## Security Notes

- Script runs with the privileges of the logged-in user
- Requires read access to log directories
- Does not modify any files
- Safe to run on every login
- 3-second timeout prevents hanging logins

## Support

For issues or customization requests, check:
- Main documentation: `CLAUDE.md`
- Script location: `standby-azure-blob/dr_status_display.sh`
- Log locations shown in script output
