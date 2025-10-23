# Oracle Standby Archives → Azure Blob (AzCopy)

Simple automation to upload Oracle standby archivelog files to Azure Blob Storage using AzCopy.

## Overview
- Scans Oracle archivelog directory for sequences not yet uploaded
- Uploads archives to a single Azure Blob container path via SAS
- Writes upload history locally and updates a `control.txt` on Blob
- Retries transient failures and logs all actions

Primary script: `oracle-standby-prod-upload.sh`

## Prerequisites
- Linux with Bash
- Oracle client with `sqlplus` available and access to the database views used
- AzCopy v10+ installed (binary path configured in the script)
- Azure Blob container and a valid SAS token

## Configuration (defaults in the script)
- Oracle and paths
  - `ORACLE_SID` (from your shell environment)
  - `ARCHIVELOG_DEST` (e.g., `/u02/fra/<DBNAME>/archivelog/`)
  - `STANDBY_DIR` base: `/u01/scripts/standby`
  - Creates: `tracking/`, `log/`, `temp/`
- AzCopy and Azure Blob
  - `AZCOPY_LOCATION` (folder where `azcopy` binary resides)
  - `AZ_BLOB_CONTAINER` (container URL prefix)
  - `AZ_BLOB_TOKEN` (SAS token appended to URLs)

Tip: Keep secrets (like SAS) out of git. Export them in your shell profile sourced by the script (it sources `~/.bash_profile`).

## Usage
```bash
# Ensure ORACLE_SID and SAS/token variables are set in your environment
bash oracle-standby-prod-upload.sh
```
The script will:
- Determine current DB archive sequence via `sqlplus`
- Compare with last uploaded sequence in `tracking/upload_history.log`
- Upload pending `*.dbf` files using AzCopy
- Update `control.txt` on the same Blob path

## Logs, tracking, and locking
- Logs: `standby/log/oracle_standby_prod_upload_<SID>_<RUN_ID>__<DATE>.log`
- Tracking: `standby/tracking/upload_history.log` and per-file `.uploaded` flags
- Lock file: `/tmp/oracle_standby_prod_upload_<SID>.lock` prevents concurrent runs
- Zabbix marker: `/opt/discover/zabbix/oracle_standby_prod_upload_<SID>.out`

## Cleanup
A cleanup routine exists to delete old local archives after confirmed upload, but it is disabled by default. Enable by uncommenting the `cleanup_old_archives` call in `main()` if desired.

## Security notes
- Do not commit credentials or SAS tokens
- Prefer providing secrets via environment variables or managed identity

## Disclaimer
Use with caution in production. Test thoroughly and verify connectivity and access before enabling scheduled runs.
