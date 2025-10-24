#!/bin/bash
#================================================================
# Script: dr_status_display.sh
# Purpose: Display DR standby synchronization status on login
# Usage: Add to .bash_profile: /path/to/dr_status_display.sh
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
LOG_DIR="${STANDBY_DIR}/log"
ZABBIX_MONITOR_DIR="/opt/discover/zabbix"

# Debug mode (set DR_STATUS_DEBUG=1 to enable)
DEBUG=${DR_STATUS_DEBUG:-0}

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

        # Look for dr_sync_recover_*.log files
        local sync_files=(${LOG_DIR}/dr_sync_recover_*.log)
        if [[ -f "${sync_files[0]}" ]]; then
            # Extract SID from filename: dr_sync_recover_MSCDBPR.log -> MSCDBPR
            local filename=$(basename "${sync_files[0]}")
            detected_sid=$(echo "$filename" | sed -n 's/dr_sync_recover_\(.*\)\.log/\1/p')
            [[ $DEBUG -eq 1 ]] && echo "[DEBUG] Auto-detected SID from logs: ${detected_sid}" >&2
        fi
    fi

    # Validate detected SID
    if [[ -z "${detected_sid}" ]]; then
        echo ""
        echo -e "${RED}ERROR: Could not determine Oracle SID${NC}" >&2
        echo "  - ORACLE_SID is not set" >&2
        echo "  - No log files found in ${LOG_DIR}" >&2
        echo "" >&2
        echo "To fix this:" >&2
        echo "  1. Ensure ORACLE_SID is exported in .bash_profile BEFORE calling this script" >&2
        echo "  2. Or ensure standby sync scripts have run at least once" >&2
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
SYNC_LOG="${LOG_DIR}/dr_sync_recover_${SID}.log"
GAP_LOG="${LOG_DIR}/gap_history.log"
MONITOR_LOG="${LOG_DIR}/monitor_${SID}.log"
MONITOR_JSON="${ZABBIX_MONITOR_DIR}/standby_monitor_${SID}.json"

[[ $DEBUG -eq 1 ]] && echo "[DEBUG] SYNC_LOG: ${SYNC_LOG}" >&2
[[ $DEBUG -eq 1 ]] && echo "[DEBUG] MONITOR_JSON: ${MONITOR_JSON}" >&2

# Number of lines to display
LINES_TO_SHOW=5

#================================================================
# Functions
#================================================================

print_header() {
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Oracle Standby DR - Synchronization Status${NC}                    ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${CYAN}Database: ${SID}${NC}                                             ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

parse_and_display_sync_log() {
    echo -e "${BOLD}${YELLOW}Recent Synchronization Activity:${NC}"
    echo -e "${CYAN}   Location: ${SYNC_LOG}${NC}"
    echo ""

    if [[ ! -f "${SYNC_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${SYNC_LOG}" | while IFS='|' read -r timestamp run_id down applied start_seq end_seq status; do
        # Parse fields
        ts=$(echo "$timestamp" | xargs)
        downloads=$(echo "$down" | cut -d'=' -f2)
        applied_count=$(echo "$applied" | cut -d'=' -f2)
        start=$(echo "$start_seq" | cut -d'=' -f2)
        end=$(echo "$end_seq" | cut -d'=' -f2)
        status_val=$(echo "$status" | cut -d'=' -f2)

        # Color based on status
        if [[ "$status_val" == "OK" ]]; then
            status_color="${GREEN}"
            status_icon="✓"
        elif [[ "$status_val" == "NOOP" ]]; then
            status_color="${BLUE}"
            status_icon="○"
        else
            status_color="${RED}"
            status_icon="✗"
        fi

        # Display formatted line
        echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} Down:${downloads} Applied:${applied_count} Seq:${start}→${end}"
    done
    echo ""
}

parse_and_display_gap_log() {
    echo -e "${BOLD}${YELLOW}Recent Sequence Gap History:${NC}"
    echo -e "${CYAN}   Location: ${GAP_LOG}${NC}"
    echo ""

    if [[ ! -f "${GAP_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${GAP_LOG}" | while read -r line; do
        # Extract timestamp and values
        if [[ $line =~ \[([0-9-]+\ [0-9:]+)\]\ PROD=([0-9]+)\ STANDBY=([0-9]+)\ GAP=([0-9]+) ]]; then
            ts="${BASH_REMATCH[1]}"
            prod="${BASH_REMATCH[2]}"
            standby="${BASH_REMATCH[3]}"
            gap="${BASH_REMATCH[4]}"

            # Color based on gap size
            if [[ $gap -le 5 ]]; then
                gap_color="${GREEN}"
                gap_icon="✓"
            elif [[ $gap -le 10 ]]; then
                gap_color="${YELLOW}"
                gap_icon="⚠"
            else
                gap_color="${RED}"
                gap_icon="✗"
            fi

            echo -e "   ${ts} Prod:${prod} DR:${standby} ${gap_color}Gap:${gap} ${gap_icon}${NC}"
        fi
    done
    echo ""
}

parse_and_display_monitor_log() {
    echo -e "${BOLD}${YELLOW}Recent Monitor Status:${NC}"
    echo -e "${CYAN}   Location: ${MONITOR_LOG}${NC}"
    echo ""

    if [[ ! -f "${MONITOR_LOG}" ]]; then
        echo -e "${RED}   Log file not found${NC}"
        echo ""
        return
    fi

    # Get last N entries
    tail -n ${LINES_TO_SHOW} "${MONITOR_LOG}" | while IFS='|' read -r timestamp run_id db prod_info dr_info gap_info minutes disk status_info; do
        ts=$(echo "$timestamp" | xargs)
        prod=$(echo "$prod_info" | cut -d'=' -f2)
        dr=$(echo "$dr_info" | cut -d'=' -f2)
        gap=$(echo "$gap_info" | cut -d'=' -f2)
        mins=$(echo "$minutes" | cut -d'=' -f2)
        disk_val=$(echo "$disk" | cut -d'=' -f2)
        status_val=$(echo "$status_info" | cut -d'=' -f2)

        # Color based on status
        case "$status_val" in
            "OK")
                status_color="${GREEN}"
                status_icon="✓"
                ;;
            "GAP_HIGH")
                status_color="${YELLOW}"
                status_icon="⚠"
                ;;
            *)
                status_color="${RED}"
                status_icon="✗"
                ;;
        esac

        echo -e "   ${ts} ${status_color}[${status_icon} ${status_val}]${NC} Gap:${gap} LastSync:${mins}m Disk:${disk_val}"
    done
    echo ""
}

display_current_status() {
    echo -e "${BOLD}${YELLOW}Current Status Summary:${NC}"

    if [[ -f "${MONITOR_JSON}" ]]; then
        echo -e "${CYAN}   Location: ${MONITOR_JSON}${NC}"
        echo ""

        # Parse JSON (simple grep/sed approach)
        timestamp=$(grep -o '"timestamp": "[^"]*"' "${MONITOR_JSON}" | cut -d'"' -f4)
        prod_seq=$(grep -o '"prod_sequence": [0-9]*' "${MONITOR_JSON}" | cut -d' ' -f2)
        dr_seq=$(grep -o '"dr_sequence": [0-9]*' "${MONITOR_JSON}" | cut -d' ' -f2)
        gap=$(grep -o '"sequence_gap": [0-9]*' "${MONITOR_JSON}" | cut -d' ' -f2)
        disk=$(grep -o '"disk_usage_pct": [0-9]*' "${MONITOR_JSON}" | cut -d' ' -f2)
        status=$(grep -o '"status": "[^"]*"' "${MONITOR_JSON}" | cut -d'"' -f4)
        last_sync=$(grep -o '"last_sync_download": "[^"]*"' "${MONITOR_JSON}" | cut -d'"' -f4)

        # Status color
        if [[ "$status" == "OK" ]]; then
            status_color="${GREEN}"
            status_icon="✓"
        else
            status_color="${RED}"
            status_icon="✗"
        fi

        # Gap color
        if [[ $gap -le 5 ]]; then
            gap_color="${GREEN}"
        elif [[ $gap -le 10 ]]; then
            gap_color="${YELLOW}"
        else
            gap_color="${RED}"
        fi

        # Disk color
        if [[ $disk -le 70 ]]; then
            disk_color="${GREEN}"
        elif [[ $disk -le 85 ]]; then
            disk_color="${YELLOW}"
        else
            disk_color="${RED}"
        fi

        echo -e "   ${BOLD}Timestamp:${NC}      ${timestamp}"
        echo -e "   ${BOLD}Status:${NC}         ${status_color}${status_icon} ${status}${NC}"
        echo -e "   ${BOLD}Production Seq:${NC} ${prod_seq}"
        echo -e "   ${BOLD}DR Seq:${NC}         ${dr_seq}"
        echo -e "   ${BOLD}Gap:${NC}            ${gap_color}${gap} sequences${NC}"
        echo -e "   ${BOLD}Last Sync:${NC}      ${last_sync}"
        echo -e "   ${BOLD}Disk Usage:${NC}     ${disk_color}${disk}%${NC}"
        echo ""
    else
        echo -e "${RED}   Monitor JSON not found${NC}"
        echo ""
    fi
}

print_footer() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Logs Directory: ${LOG_DIR}${NC}"
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
    display_current_status
    parse_and_display_sync_log
    parse_and_display_gap_log
    parse_and_display_monitor_log
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
