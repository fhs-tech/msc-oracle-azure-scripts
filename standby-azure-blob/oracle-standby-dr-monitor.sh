#!/bin/bash

. ~/.bash_profile

# ==============================
# Variáveis de ambiente
# ==============================

FILE_NAME="oracle_standby_dr_monitor"
SID=${ORACLE_SID^^}
DT=$(date +%d-%m-%Y_%H%M)
RUN_ID=$(echo "$$-$(date +%s)" | md5sum | cut -c1-8)

# Configuração do DATABASE_NAME para diferenciar DR1/DR2
DATABASE_NAME=${DATABASE_NAME:-"DR1"}
if [[ -z "$DATABASE_NAME" ]]; then
    echo "ERRO: DATABASE_NAME deve ser definida (DR1, DR2, etc)"
    exit 1
fi

# Diretórios e arquivos
STANDBY_DIR="/u01/scripts/standby"
LOG_DIR="${STANDBY_DIR}/log"
TEMP_DIR="${STANDBY_DIR}/temp"
LOG_FILE="${LOG_DIR}/${FILE_NAME}_${SID}_${RUN_ID}__${DT}.log"
SUMMARY_LOG="${LOG_DIR}/monitor_${SID}.log"

# Arquivos de monitoramento
LOCK_FILE="/tmp/${FILE_NAME}_${SID}.lock"
ZABBIX_MONITOR="/opt/discover/zabbix/${FILE_NAME}_${SID}.out"
MONITOR_JSON="/opt/discover/zabbix/standby_monitor_${SID}_${DATABASE_NAME}.json"

# Configurações de alerta
SEQUENCE_GAP_THRESHOLD=10
DISK_USAGE_THRESHOLD=80

# Conexão com produção
PROD_CONNECTION="zabbix/GRO92876@MSCDBPR_PRD"

# Criar diretórios
mkdir -p "${LOG_DIR}" "${TEMP_DIR}" || { echo "ERRO: Falha ao criar diretórios necessários"; exit 1; }

# ==============================
# Controle de execução
# ==============================
if [[ -f "$LOCK_FILE" ]]; then
    echo "$(date '+%d-%m-%Y %H:%M:%S') - [LOCK] Já existe uma execução em andamento para SID ${SID}. Lockfile: ${LOCK_FILE}. Se não houver outro processo ativo, remova manualmente com: rm -f '${LOCK_FILE}'" | tee -a "$LOG_FILE"
    exit 1
fi

touch "$LOCK_FILE"

trap 'handle_exit' EXIT SIGINT SIGTERM SIGHUP

handle_exit() {
    echo "$(date '+%d-%m-%Y %H:%M:%S') - [TRAP] Script interrompido ou finalizado. Removendo lock..." | tee -a "$LOG_FILE"
    rm -f "$LOCK_FILE"
    echo 1 > "$ZABBIX_MONITOR"
    exit 1
}

# ==============================
# Funções
# ==============================

log() {
    echo "$(date '+%d-%m-%Y %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Obter sequência atual da produção
get_production_sequence() {
    local result
    result=$(sqlplus -silent "${PROD_CONNECTION}" <<EOF | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT TRIM(max(l.sequence#))
FROM v\\$log_history l, v\\$database d, v\\$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;
EXIT;
EOF
)

    if [[ $? -eq 0 ]] && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        log "ERRO: Falha ao obter sequência da produção"
        echo "0"
    fi
}

# Obter sequência aplicada no DR
get_dr_sequence() {
    local result
    result=$(sqlplus -silent / as sysdba <<EOF | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT NVL(MAX(SEQUENCE#), 0)
FROM V\\$LOG_HISTORY;
EXIT;
EOF
)

    if [[ $? -eq 0 ]] && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        log "ERRO: Falha ao obter sequência do DR"
        echo "0"
    fi
}

# Testar conectividade com a produção
check_prod_connectivity() {
    sqlplus -silent "${PROD_CONNECTION}" <<EOF >/dev/null 2>&1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT 1 FROM DUAL;
EXIT;
EOF

    if [[ $? -eq 0 ]]; then
        echo "OK"
    else
        echo "ERROR"
    fi
}

# Testar conectividade com o DR
check_dr_connectivity() {
    sqlplus -silent / as sysdba <<EOF >/dev/null 2>&1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT 1 FROM DUAL;
EXIT;
EOF

    if [[ $? -eq 0 ]]; then
        echo "OK"
    else
        echo "ERROR"
    fi
}

# Verificar uso de disco do diretório de archives
get_disk_usage() {
    local archive_dir="/u01/app/oracle/archives_standby"
    if [[ -d "$archive_dir" ]]; then
        df "$archive_dir" | awk 'NR==2 {print $5}' | sed 's/%//'
    else
        echo "0"
    fi
}

# Verificar última execução dos scripts de sync
check_sync_scripts_status() {
    local upload_log="/u01/scripts/standby/log/upload_blob_${SID}.log"
    local download_log="/u01/app/oracle/admin/logs/download_blob_${SID}.log"

    local last_upload="-"
    local last_download="-"

    if [[ -f "$upload_log" ]]; then
        last_upload=$(tail -1 "$upload_log" 2>/dev/null | cut -d'|' -f1 | head -1)
    fi

    if [[ -f "$download_log" ]]; then
        last_download=$(tail -1 "$download_log" 2>/dev/null | cut -d'|' -f1 | head -1)
    fi

    echo "${last_upload}|${last_download}"
}

# Gerar arquivo JSON de monitoramento
generate_monitor_json() {
    local prod_seq=$1
    local dr_seq=$2
    local gap=$3
    local prod_conn=$4
    local dr_conn=$5
    local disk_usage=$6
    local sync_status=$7
    local overall_status=$8

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local last_upload=$(echo "$sync_status" | cut -d'|' -f1)
    local last_download=$(echo "$sync_status" | cut -d'|' -f2)

    cat > "$MONITOR_JSON" <<EOF
{
  "timestamp": "${timestamp}",
  "database_name": "${DATABASE_NAME}",
  "sid": "${SID}",
  "prod_sequence": ${prod_seq},
  "dr_sequence": ${dr_seq},
  "sequence_gap": ${gap},
  "connectivity_prod": "${prod_conn}",
  "connectivity_dr": "${dr_conn}",
  "disk_usage_pct": ${disk_usage},
  "last_sync_upload": "${last_upload}",
  "last_sync_download": "${last_download}",
  "status": "${overall_status}"
}
EOF
}

# Função principal
main() {
    log "=========================================="
    log "Início do monitoramento DR: ${DATABASE_NAME}"
    log "=========================================="

    # 1. Verificar conectividade
    log "Verificando conectividade..."
    prod_connectivity=$(check_prod_connectivity)
    dr_connectivity=$(check_dr_connectivity)

    log "Conectividade PROD: ${prod_connectivity}"
    log "Conectividade DR: ${dr_connectivity}"

    # 2. Obter sequências
    log "Obtendo sequências..."
    prod_sequence=$(get_production_sequence)
    dr_sequence=$(get_dr_sequence)

    log "Sequência PROD: ${prod_sequence}"
    log "Sequência DR: ${dr_sequence}"

    # 3. Calcular gap
    sequence_gap=$((prod_sequence - dr_sequence))
    log "Gap de sequências: ${sequence_gap}"

    # 4. Verificar uso de disco
    disk_usage=$(get_disk_usage)
    log "Uso de disco: ${disk_usage}%"

    # 5. Status dos scripts de sync
    sync_status=$(check_sync_scripts_status)
    log "Status dos scripts de sync: ${sync_status}"

    # 6. Determinar status geral
    overall_status="OK"

    if [[ "$prod_connectivity" != "OK" ]] || [[ "$dr_connectivity" != "OK" ]]; then
        overall_status="CONNECTIVITY_ERROR"
    elif [[ $sequence_gap -gt $SEQUENCE_GAP_THRESHOLD ]]; then
        overall_status="GAP_HIGH"
    elif [[ $disk_usage -gt $DISK_USAGE_THRESHOLD ]]; then
        overall_status="DISK_HIGH"
    fi

    log "Status geral: ${overall_status}"

    # 7. Gerar arquivo JSON de monitoramento
    generate_monitor_json "$prod_sequence" "$dr_sequence" "$sequence_gap" \
                         "$prod_connectivity" "$dr_connectivity" "$disk_usage" \
                         "$sync_status" "$overall_status"

    # 8. Manter compatibilidade com arquivo .out original para Zabbix
    if [[ "$overall_status" == "OK" ]]; then
        echo "0" > "$ZABBIX_MONITOR"
    else
        echo "1" > "$ZABBIX_MONITOR"
    fi

    # 9. Summary log
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${now_ts}|RUN_ID=${RUN_ID}|DB=${DATABASE_NAME}|PROD=${prod_sequence}|DR=${dr_sequence}|GAP=${sequence_gap}|DISK=${disk_usage}%|STATUS=${overall_status}" >> "$SUMMARY_LOG"

    log "Monitoramento finalizado"
    log "=========================================="

    # Remover lock no final
    rm -f "$LOCK_FILE"
}

# Executar
main