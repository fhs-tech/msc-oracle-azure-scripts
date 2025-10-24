#!/bin/bash

. ~/.bash_profile

# ==============================
# Variáveis de ambiente
# ==============================

FILE_NAME="standby_monitor"
SID=${ORACLE_SID^^}
DT=$(date +%d-%m-%Y_%H%M)
RUN_ID=$(echo "$$-$(date +%s)" | md5sum | cut -c1-8)

# Diretórios e arquivos
STANDBY_DIR="/u01/scripts/standby"
LOG_DIR="${STANDBY_DIR}/log"
TEMP_DIR="${STANDBY_DIR}/temp"
LOG_FILE="${LOG_DIR}/${FILE_NAME}_${SID}_${RUN_ID}__${DT}.log"
SUMMARY_LOG="${LOG_DIR}/monitor_${SID}.log"

# Arquivos de monitoramento
LOCK_FILE="/tmp/${FILE_NAME}_${SID}.lock"

ZABBIX_MONITOR_DIR="/opt/discover/zabbix"
ZABBIX_MONITOR="${ZABBIX_MONITOR_DIR}/standby_last_sequence_applied_${SID}.out"
ZABBIX_LAST_SYNC="${ZABBIX_MONITOR_DIR}/standby_last_download_arch_min_${SID}.out"
MONITOR_JSON="${ZABBIX_MONITOR_DIR}/${FILE_NAME}_${SID}.json"

ARCHIVELOG_DEST="/u02/fra/MSCDBPR/archivelog/"

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

trap 'handle_interrupt' SIGINT SIGTERM SIGHUP

handle_interrupt() {
    echo "$(date '+%d-%m-%Y %H:%M:%S') - [TRAP] Script interrompido por sinal. Removendo lock..." | tee -a "$LOG_FILE"
    echo 1 > "$ZABBIX_MONITOR"
    rm -f "$LOCK_FILE"
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
    result=$(sqlplus -silent "${PROD_CONNECTION}" <<EOF 2>/dev/null | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT TRIM(max(l.sequence#))
FROM v\$log_history l, v\$database d
WHERE d.resetlogs_change# = l.resetlogs_change#;
EXIT;
EOF
)

    if [[ $? -eq 0 ]] && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "$(date '+%d-%m-%Y %H:%M:%S') - ERRO: Falha ao obter sequência da produção" | tee -a "$LOG_FILE" >&2
        echo "0"
    fi
}

# Obter sequência aplicada no DR
get_dr_sequence() {
    local result
    result=$(sqlplus -silent / as sysdba <<EOF | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT TRIM(max(l.sequence#))
FROM v\$log_history l, v\$database d
WHERE d.resetlogs_change# = l.resetlogs_change#;
EXIT;
EOF
)

    if [[ $? -eq 0 ]] && [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "$(date '+%d-%m-%Y %H:%M:%S') - ERRO: Falha ao obter sequência do DR" | tee -a "$LOG_FILE" >&2
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
    local archive_dir="${ARCHIVELOG_DEST}"
    if [[ -d "$archive_dir" ]]; then
        df "$archive_dir" | awk 'NR==2 {print $5}' | sed 's/%//'
    else
        echo "0"
    fi
}

# Verificar última execução do script de download (executado localmente no DR)
check_last_download() {
    local download_log="${LOG_DIR}/dr_sync_recover_${SID}.log"
    local last_download="-"

    if [[ -f "$download_log" ]]; then
        last_download=$(tail -1 "$download_log" 2>/dev/null | cut -d'|' -f1 | head -1)
    fi

    echo "${last_download}"
}

# Calcular minutos desde o último download
get_minutes_since_last_download() {
    local last_download_ts="$1"

    # Se não há timestamp, retornar -1 (indicando sem dados)
    if [[ -z "$last_download_ts" ]] || [[ "$last_download_ts" == "-" ]]; then
        echo "-1"
        return
    fi

    # Converter timestamp para epoch
    local last_epoch=$(date -d "$last_download_ts" +%s 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "-1"
        return
    fi

    # Timestamp atual
    local now_epoch=$(date +%s)

    # Calcular diferença em minutos
    local diff_seconds=$((now_epoch - last_epoch))
    local diff_minutes=$((diff_seconds / 60))

    echo "$diff_minutes"
}

# Gerar arquivo JSON de monitoramento
generate_monitor_json() {
    local prod_seq=$1
    local dr_seq=$2
    local gap=$3
    local prod_conn=$4
    local dr_conn=$5
    local disk_usage=$6
    local last_download=$7
    local overall_status=$8

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "$MONITOR_JSON" <<EOF
{
  "timestamp": "${timestamp}",
  "database_name": "${SID}",
  "sid": "${SID}",
  "prod_sequence": ${prod_seq},
  "dr_sequence": ${dr_seq},
  "sequence_gap": ${gap},
  "gap_threshold": ${SEQUENCE_GAP_THRESHOLD},
  "connectivity_prod": "${prod_conn}",
  "connectivity_dr": "${dr_conn}",
  "disk_usage_pct": ${disk_usage},
  "disk_threshold_pct": ${DISK_USAGE_THRESHOLD},
  "last_sync_download": "${last_download}",
  "status": "${overall_status}"
}
EOF
}

# Função principal
main() {
    log "=========================================="
    log "Início do monitoramento DR: ${SID}"
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

    # 5. Verificar última execução do download
    last_download=$(check_last_download)
    log "Último download: ${last_download}"

    # Calcular minutos desde último download
    minutes_since_download=$(get_minutes_since_last_download "$last_download")
    log "Minutos desde último download: ${minutes_since_download}"

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
                         "$last_download" "$overall_status"

    # 8. Escrever o valor do gap no arquivo Zabbix para monitoramento
    # O Zabbix pode usar este valor numérico para criar alertas (ex: gap > 10)
    echo "${sequence_gap}" > "$ZABBIX_MONITOR"

    # 9. Escrever minutos desde último download no arquivo Zabbix
    # O Zabbix pode usar este valor para alertar se download está atrasado (ex: > 30 minutos)
    echo "${minutes_since_download}" > "$ZABBIX_LAST_SYNC"

    # 10. Summary log
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${now_ts}|RUN_ID=${RUN_ID}|DB=${SID}|PROD=${prod_sequence}|DR=${dr_sequence}|GAP=${sequence_gap}|MINUTES=${minutes_since_download}|DISK=${disk_usage}%|STATUS=${overall_status}" >> "$SUMMARY_LOG"

    log "Monitoramento finalizado"
    log "=========================================="

    # Remover lock no final
    rm -f "$LOCK_FILE"
}

# Executar
main

## Enviar para o Zabbix
/opt/discover/zabbix/scripts/send_sync_zabbix.sh