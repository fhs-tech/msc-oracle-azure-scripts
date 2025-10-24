#!/bin/bash
#================================================================
# Script: prod_status_display.sh
# Purpose: Display Production backup and upload status on login
# Usage: Add to .bash_profile: /path/to/prod_status_display.sh
#================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
STANDBY_DIR="/u01/scripts/standby"
STANDBY_LOG_DIR="${STANDBY_DIR}/log"
RMAN_BACKUP_DIR="/u02/backup/rman"
RMAN_LOG_DIR="${RMAN_BACKUP_DIR}/log"

# Debug mode (set PROD_STATUS_DEBUG=1 to enable)
DEBUG=${PROD_STATUS_DEBUG:-0}

# Detect SID with validation and fallback
detect_sid() {
    local detected_sid=""

    # Try 1: Use ORACLE_SID if defined
    if [[ -n "${ORACLE_SID}" ]]; then
        detected_sid="${ORACLE_SID^^}"
        [[ $DEBUG -eq 1 ]] && echo "[DEBUG] Using ORACLE_SID: ${detected_sid}" >&2
    fi

    # Try 2: Auto-detect from log files if ORACLE_SID is empty
    if [[ -z "${detected_sid}" ]]; then
        [[ $DEBUG -eq 1 ]] && echo "[DEBUG] ORACLE_SID not set, attempting auto-detection..." >&2

        # Look for upload_blob_*.log files
        local upload_files=(${STANDBY_LOG_DIR}/upload_blob_*.log)
        if [[ -f "${upload_files[0]}" ]]; then
            # Extract SID from filename: upload_blob_MSCDBPR.log -> MSCDBPR
            local filename=$(basename "${upload_files[0]}")
            detected_sid=$(echo "$filename" | sed -n 's/upload_blob_\(.*\)\.log/\1/p')
            [[ $DEBUG -eq 1 ]] && echo "[DEBUG] Auto-detected SID from logs: ${detected_sid}" >&2
        fi
    fi

    # Validate detected SID
    if [[ -z "${detected_sid}" ]]; then
        echo ""
        echo -e "${RED}ERROR: Could not determine Oracle SID${NC}" >&2
        echo "  - ORACLE_SID is not set" >&2
        echo "  - No log files found in ${STANDBY_LOG_DIR}" >&2
        echo "" >&2
        echo "To fix this:" >&2
        echo "  1. Ensure ORACLE_SID is exported in .bash_profile BEFORE calling this script" >&2
        echo "  2. Or ensure production upload scripts have run at least once" >&2
        echo "" >&2
        return 1
    fi

    echo "${detected_sid}"
    return 0
}

# Detect SID
SID=$(detect_sid)
if [[ $? -ne 0 ]] || [[ -z "${SID}" ]]; then
    exit 0  # Exit silently if SID cannot be determined
fi

[[ $DEBUG -eq 1 ]] && echo "[DEBUG] Final SID: ${SID}" >&2

# Log files
UPLOAD_LOG="${STANDBY_LOG_DIR}/upload_blob_${SID}.log"
RMAN_ARCH_LOG="${RMAN_LOG_DIR}/rman_arch_${SID}.log"
RMAN_FULL_LOG="${RMAN_LOG_DIR}/rman_full_${SID}.log"

[[ $DEBUG -eq 1 ]] && echo "[DEBUG] UPLOAD_LOG: ${UPLOAD_LOG}" >&2
[[ $DEBUG -eq 1 ]] && echo "[DEBUG] RMAN_ARCH_LOG: ${RMAN_ARCH_LOG}" >&2
[[ $DEBUG -eq 1 ]] && echo "[DEBUG] RMAN_FULL_LOG: ${RMAN_FULL_LOG}" >&2

# Number of lines to display
LINES_TO_SHOW=5

#================================================================
# Functions
#================================================================

print_header() {
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Oracle Production - Backup & Upload Status${NC}                    ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Database: ${SID}${NC}                                             ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

parse_and_display_upload_log() {
    echo -e "${BOLD}${YELLOW}Recent Archive Uploads to Blob:${NC}"
    echo -e "${CYAN}   Location: ${UPLOAD_LOG}${NC}"
    echo ""

    if [[ ! -f "${UPLOAD_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${UPLOAD_LOG}" | while IFS='|' read -r timestamp run_id count first last status_info; do
        ts=$(echo "$timestamp" | xargs)
        upload_count=$(echo "$count" | cut -d'=' -f2)
        first_seq=$(echo "$first" | cut -d'=' -f2)
        last_seq=$(echo "$last" | cut -d'=' -f2)
        status_val=$(echo "$status_info" | cut -d'=' -f2)

        # Color based on status
        if [[ "$status_val" == "OK" ]]; then
            status_color="${GREEN}"
            status_icon="✓"
        elif [[ "$status_val" == "NOOP" ]]; then
            status_color="${BLUE}"
            status_icon="○"
        elif [[ "$status_val" == "PARTIAL" ]]; then
            status_color="${YELLOW}"
            status_icon="⚠"
        else
            status_color="${RED}"
            status_icon="✗"
        fi

        # Display formatted line
        if [[ "$first_seq" == "-" ]] || [[ "$last_seq" == "-" ]]; then
            echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} Uploads:${upload_count}"
        else
            echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} Uploads:${upload_count} Seq:${first_seq}→${last_seq}"
        fi
    done
    echo ""
}

parse_and_display_rman_arch_log() {
    echo -e "${BOLD}${YELLOW}Recent RMAN Archive Backups:${NC}"
    echo -e "${CYAN}   Location: ${RMAN_ARCH_LOG}${NC}"
    echo ""

    if [[ ! -f "${RMAN_ARCH_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${RMAN_ARCH_LOG}" | while IFS='|' read -r timestamp run_id status_info rest; do
        ts=$(echo "$timestamp" | xargs)
        run=$(echo "$run_id" | cut -d'=' -f2)
        status_val=$(echo "$status_info" | cut -d'=' -f2)

        # Color based on status
        if [[ "$status_val" == "OK" ]]; then
            status_color="${GREEN}"
            status_icon="✓"
        else
            status_color="${RED}"
            status_icon="✗"
        fi

        # Display formatted line
        echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} RUN_ID:${run}"
    done
    echo ""
}

parse_and_display_rman_full_log() {
    echo -e "${BOLD}${YELLOW}Recent RMAN Full Backups:${NC}"
    echo -e "${CYAN}   Location: ${RMAN_FULL_LOG}${NC}"
    echo ""

    if [[ ! -f "${RMAN_FULL_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${RMAN_FULL_LOG}" | while IFS='|' read -r timestamp run_id status_info rest; do
        ts=$(echo "$timestamp" | xargs)
        run=$(echo "$run_id" | cut -d'=' -f2)
        status_val=$(echo "$status_info" | cut -d'=' -f2)

        # Color based on status
        if [[ "$status_val" == "OK" ]]; then
            status_color="${GREEN}"
            status_icon="✓"
        else
            status_color="${RED}"
            status_icon="✗"
        fi

        # Display formatted line
        echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} RUN_ID:${run}"
    done
    echo ""
}

display_production_stats() {
    echo -e "${BOLD}${YELLOW}Production Statistics:${NC}"
    echo ""

    # Get current sequence
    local current_seq=$(sqlplus -s / as sysdba <<EOF 2>/dev/null | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT TRIM(MAX(l.sequence#))
FROM v\$log_history l, v\$database d, v\$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;
EXIT;
EOF
)

    # Get archives generated in last 24h
    local archives_24h=$(sqlplus -s / as sysdba <<EOF 2>/dev/null | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT COUNT(*)
FROM v\$archived_log
WHERE first_time >= SYSDATE - 1
AND dest_id = 1;
EXIT;
EOF
)

    # Get FRA disk usage
    local fra_usage=""
    if [[ -d "/u02/fra" ]]; then
        fra_usage=$(df -h /u02/fra 2>/dev/null | tail -1 | awk '{print $5}')
    fi

    # Get backup directory usage
    local backup_usage=""
    if [[ -d "${RMAN_BACKUP_DIR}" ]]; then
        backup_usage=$(df -h ${RMAN_BACKUP_DIR} 2>/dev/null | tail -1 | awk '{print $5}')
    fi

    # Display stats
    if [[ -n "${current_seq}" ]] && [[ "${current_seq}" =~ ^[0-9]+$ ]]; then
        echo -e "   ${BOLD}Current Sequence:${NC}     ${current_seq}"
    else
        echo -e "   ${BOLD}Current Sequence:${NC}     ${RED}Unable to query${NC}"
    fi

    if [[ -n "${archives_24h}" ]] && [[ "${archives_24h}" =~ ^[0-9]+$ ]]; then
        echo -e "   ${BOLD}Archives (24h):${NC}       ${archives_24h}"
    else
        echo -e "   ${BOLD}Archives (24h):${NC}       ${RED}Unable to query${NC}"
    fi

    if [[ -n "${fra_usage}" ]]; then
        # Color based on usage
        local usage_pct=$(echo ${fra_usage} | sed 's/%//')
        if [[ ${usage_pct} -le 70 ]]; then
            fra_color="${GREEN}"
        elif [[ ${usage_pct} -le 85 ]]; then
            fra_color="${YELLOW}"
        else
            fra_color="${RED}"
        fi
        echo -e "   ${BOLD}FRA Disk Usage:${NC}       ${fra_color}${fra_usage}${NC}"
    fi

    if [[ -n "${backup_usage}" ]]; then
        local usage_pct=$(echo ${backup_usage} | sed 's/%//')
        if [[ ${usage_pct} -le 70 ]]; then
            backup_color="${GREEN}"
        elif [[ ${usage_pct} -le 85 ]]; then
            backup_color="${YELLOW}"
        else
            backup_color="${RED}"
        fi
        echo -e "   ${BOLD}Backup Disk Usage:${NC}    ${backup_color}${backup_usage}${NC}"
    fi

    echo ""
}

print_footer() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Upload Logs:    ${STANDBY_LOG_DIR}${NC}"
    echo -e "${CYAN}RMAN Logs:      ${RMAN_LOG_DIR}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

#================================================================
# Main
#================================================================

main() {
    # SID validation already done at script start
    # Execute functions directly (no timeout/subshell to avoid variable inheritance issues)

    print_header
    parse_and_display_upload_log
    parse_and_display_rman_arch_log
    parse_and_display_rman_full_log
    display_production_stats
    print_footer
}

# Execute only if sourced from profile (not when running directly)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly
    main
else
    # Script is being sourced - execute immediately
    main
fi
