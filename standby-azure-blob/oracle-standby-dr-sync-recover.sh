#!/bin/bash
#================================================================
# Script: oracle-standby-dr-sync-recover.sh
# Descrição: Download archives e execução de recovery manual
# Servidor: DR1 / DR2 - Oracle Standard Edition (Standby Manual)
# Execução: A cada 10-15 minutos via cron
#================================================================

. ~/.bash_profile

# ==============================
# Variáveis de ambiente
# ==============================    

FILE_NAME="oracle_standby_dr_sync_recover"
SID=${ORACLE_SID^^}
DT=$(date +%d-%m-%Y_%H%M)
RUN_ID=$(echo "$$-$(date +%s)" | md5sum | cut -c1-8)

# Diretórios
ZABBIX_MONITOR="/opt/discover/zabbix/${FILE_NAME}_${SID}.out"

ARCHIVELOG_DEST="/u02/fra/MSCDBPR/archivelog"

STANDBY_DIR="/u01/scripts/standby"
TRACKING_DIR="${STANDBY_DIR}/tracking"
LOG_DIR="${STANDBY_DIR}/log"
TEMP_DIR="${STANDBY_DIR}/temp"
OUTPUT_DIR="${STANDBY_DIR}/output"

LOG_FILE="${LOG_DIR}/${FILE_NAME}_${SID}_${RUN_ID}__${DT}.log"
SUMMARY_LOG="${LOG_DIR}/dr_sync_recover_${SID}.log"

# AZCOPY & BLOB
export AZCOPY_CRED_TYPE="Anonymous"
export AZCOPY_LOCATION="/u01/app/azure"
export AZCOPY_LOG_LOCATION="${AZCOPY_LOCATION}/log"
AZ_BLOB_CONTAINER="https://br241ew1psa01.blob.core.windows.net/dump/BRMODALLPROD/STANDBY/MSCDBPR/"
AZ_BLOB_TOKEN="?sp=racwl&st=2025-10-17T13:37:20Z&se=2026-10-17T21:52:20Z&spr=https&sv=2024-11-04&sr=c&sig=ueihZmqV%2BTupF5APa4hXyBgrMti2LsqR3QPGbHZb5H4%3D"
AZ_BLOB_SOURCE="${AZ_BLOB_CONTAINER}${AZ_BLOB_TOKEN}"

# PRODUCTION CONNECTION
PROD_TNS_CONNECTION="zabbix/GRO92876@MSCDBPR_PRD"
GAP_ALERT_THRESHOLD=10  # Alert if gap > 10 sequences

# Criar diretórios
mkdir -p ${TRACKING_DIR} ${LOG_DIR} ${TEMP_DIR} ${OUTPUT_DIR} || { echo "ERRO: Falha ao criar diretórios necessários"; exit 1; }

# ==============================
# Controle de execução
# ==============================
LOCK_FILE="/tmp/${FILE_NAME}_${SID}.lock"
if [[ -f "$LOCK_FILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [LOCK] Já existe uma execução em andamento para SID ${SID}. Lockfile: ${LOCK_FILE}. Se não houver outro processo ativo, remova manualmente com: rm -f '${LOCK_FILE}'" | tee -a "$LOG_FILE"
    exit 1
fi

touch "$LOCK_FILE"
trap 'cleanup_lock' EXIT SIGINT SIGTERM SIGHUP

cleanup_lock() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Removendo lock e finalizando..." | tee -a "$LOG_FILE"
    rm -f "$LOCK_FILE"
}

#================================================================
# FUNÇÕES
#================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${LOG_FILE}
}

# Obter última sequência aplicada no standby
get_last_applied_sequence() {
    sqlplus -s / as sysdba <<EOF | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT trim(max(l.sequence#))
FROM v\$log_history l, v\$database d, v\$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;
EXIT;
EOF
}

# Obter sequência atual da produção via TNS
get_production_current_sequence() {
    local prod_seq=""

    # Tentar conectar na produção com timeout
    prod_seq=$(timeout 30 sqlplus -s "${PROD_TNS_CONNECTION}" <<EOF 2>/dev/null | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT trim(max(l.sequence#))
FROM v\$log_history l, v\$database d, v\$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;
EXIT;
EOF
    )

    # Verificar se conseguiu conectar e obter resultado válido
    if [ $? -eq 0 ] && [ -n "${prod_seq}" ] && [[ "${prod_seq}" =~ ^[0-9]+$ ]]; then
        echo "${prod_seq}"
    else
        log "ERRO: Não foi possível conectar na produção ou obter sequência válida"
        echo "ERROR"
    fi
}

# Listar archives disponíveis no blob - PASTA ÚNICA
list_blob_archives() {
${AZCOPY_LOCATION}/azcopy list "${AZ_BLOB_SOURCE}" 2>/dev/null |  grep -E "\.dbf" | awk '{print $1}' | sed 's/;$//'  | sort -t'_' -k2 -n
}

# Listar archives que precisam ser baixados
list_archives_to_download() {
    log "Buscando archives para download..." >&2

    # Obter última sequência aplicada
    local last_applied=$(get_last_applied_sequence)
    log "Última sequência aplicada: ${last_applied}" >&2

    # Buscar TODOS os archives disponíveis no blob
    local count=0
    while read archive_name; do
        if [ -z "${archive_name}" ]; then
            continue
        fi

        # Extrair sequence do nome do arquivo
        sequence=$(echo ${archive_name} | cut -d'_' -f2)

        # Verificar se já foi baixado
        flag_file="${TRACKING_DIR}/${archive_name}.downloaded"

        # Download se: não foi baixado AND sequence > last_applied
        if [ ! -f "${flag_file}" ] && [ -n "${sequence}" ] && [ -n "${last_applied}" ] && [ ${sequence} -gt ${last_applied} ]; then
            echo "${archive_name}"
            count=$((count + 1))
        fi
    done < <(list_blob_archives)

    log "Total de archives encontrados para download: ${count}" >&2
}

# Download de archives novos
download_new_archives() {
    log "Verificando novos archives no blob..."

    DOWNLOAD_COUNT=0

    # Obter lista de archives em array
    mapfile -t archives_to_download < <(list_archives_to_download)
    log "Processando ${#archives_to_download[@]} archives..."

    # Processar cada archive
    for archive_name in "${archives_to_download[@]}"; do
        if [ -n "${archive_name}" ]; then
            # Extrair sequence do nome do arquivo
            sequence=$(echo ${archive_name} | cut -d'_' -f2)

            log "Baixando archive: ${archive_name} (seq: ${sequence})"

            # URL do arquivo - PASTA ÚNICA
            SOURCE_URL="${AZ_BLOB_CONTAINER}${archive_name}${AZ_BLOB_TOKEN}"
            DEST_FILE="${ARCHIVELOG_DEST}/${archive_name}"

            # Download
            ${AZCOPY_LOCATION}/azcopy copy "${SOURCE_URL}" "${DEST_FILE}" \
                --overwrite=false \
                --check-length=true \
                --log-level=ERROR >> "${LOG_FILE}" 2>&1

            if [ $? -eq 0 ]; then
                log "Download OK: ${archive_name}"
                # Marcar como baixado
                flag_file="${TRACKING_DIR}/${archive_name}.downloaded"
                touch "${flag_file}"
                DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
            else
                log "ERRO no download: ${archive_name}"
                rm -f "${DEST_FILE}"
            fi
        fi
    done

    log "DOWNLOADED: ${DOWNLOAD_COUNT}"
    return ${DOWNLOAD_COUNT}
}

# Executar recovery automático
execute_recovery() {
    log "Executando recovery..."

    # Obter sequência antes do recovery
    SEQUENCE_BEFORE=$(get_last_applied_sequence)

    # Criar script SQL para recovery
    cat > ${TEMP_DIR}/recover_standby.sql <<EOF
SET ECHO ON TIMING ON
SPOOL ${LOG_FILE} APPEND

-- Verificar status antes
SELECT DATABASE_ROLE, OPEN_MODE FROM V\$DATABASE;

-- Executar recovery
RECOVER AUTOMATIC FROM '${ARCHIVELOG_DEST}' STANDBY DATABASE;

-- Verificar status depois
SELECT trim(max(l.sequence#)) LAST_APPLIED
FROM v\$log_history l, v\$database d, v\$thread t
WHERE d.resetlogs_change# = l.resetlogs_change#
AND t.thread# = l.thread#
GROUP BY l.thread#, d.resetlogs_change#
ORDER BY l.thread#;

SPOOL OFF
EXIT;
EOF

    # Executar recovery
    sqlplus -s / as sysdba @${TEMP_DIR}/recover_standby.sql >> ${LOG_FILE} 2>&1

    # Verificar resultado
    if [ $? -eq 0 ]; then
        # Obter nova sequência aplicada
        SEQUENCE_AFTER=$(get_last_applied_sequence)
        APPLIED_COUNT=$((SEQUENCE_AFTER - SEQUENCE_BEFORE))

        log "APPLIED: ${APPLIED_COUNT}"

        # Exportar para uso no main
        export RECOVERY_APPLIED_COUNT=${APPLIED_COUNT}
    else
        log "ERRO na execução do recovery"
        export RECOVERY_APPLIED_COUNT=0
        return 1
    fi

    # Limpar script temporário
    rm -f ${TEMP_DIR}/recover_standby.sql
}

# Verificar gap de archives
check_archive_gap() {
    log "Verificando gap de archives..."
    
    sqlplus -s / as sysdba <<EOF | tee -a ${LOG_FILE}
SET LINESIZE 200
SET PAGESIZE 50

PROMPT
PROMPT === STATUS DO STANDBY DATABASE ===
SELECT DATABASE_ROLE, OPEN_MODE, PROTECTION_MODE 
FROM V\$DATABASE;

PROMPT
PROMPT === ÚLTIMO ARCHIVE APLICADO ===
SELECT MAX(SEQUENCE#) AS LAST_APPLIED_SEQ,
       TO_CHAR(MAX(FIRST_TIME), 'DD/MM/YYYY HH24:MI:SS') AS LAST_APPLIED_TIME
FROM V\$LOG_HISTORY;

PROMPT
PROMPT === ARCHIVES NO DIRETÓRIO LOCAL ===
HOST ls -ltr ${ARCHIVELOG_DEST} | tail -5

EXIT;
EOF
}

# Limpeza de arquivos antigos
cleanup_old_files() {
    log "Executando limpeza de arquivos antigos..."

    # Obter última sequência aplicada uma única vez
    local last_applied=$(get_last_applied_sequence)

    # Remover archives aplicados com mais de 3 dias
    find ${ARCHIVELOG_DEST} -name "*.dbf" -mtime +3 -type f | while read archive_file; do
        archive_name=$(basename -- "${archive_file}")
        sequence=$(echo ${archive_name} | cut -d'_' -f2)

        if [ -n "${sequence}" ] && [ -n "${last_applied}" ] && [ ${sequence} -lt ${last_applied} ]; then
            log "Removendo archive aplicado: ${archive_name}"
            rm -f ${archive_file}
            rm -f "${TRACKING_DIR}/${archive_name}.downloaded"
        fi
    done
    
    # Limpar logs antigos
    find ${LOG_DIR} -name "*.log" -mtime +30 -delete
    
    # Limpar flags antigas
    find ${TRACKING_DIR} -name "*.downloaded" -mtime +7 -delete
}

# Verificar gap entre produção e standby
check_prod_standby_gap() {
    log "Verificando gap entre Produção e Standby..."

    # Obter sequência atual da produção
    local prod_seq=$(get_production_current_sequence)

    # Obter última sequência aplicada no standby
    local standby_seq=$(get_last_applied_sequence)

    if [ "${prod_seq}" = "ERROR" ]; then
        log "AVISO: Não foi possível conectar na produção - pulando verificação de gap"
        return 1
    fi

    if [ -z "${standby_seq}" ] || [ -z "${prod_seq}" ]; then
        log "ERRO: Não foi possível obter sequências válidas (Prod: ${prod_seq}, Standby: ${standby_seq})"
        return 1
    fi

    # Calcular gap
    local gap=$((prod_seq - standby_seq))

    # Log das informações - formato conciso
    log "PROD: ${prod_seq} | DR: ${standby_seq} | GAP: ${gap}"

    # Verificar se gap excede o threshold
    if [ ${gap} -gt ${GAP_ALERT_THRESHOLD} ]; then
        log "ALERTA: Gap crítico (${gap} > ${GAP_ALERT_THRESHOLD})"

        # Escrever alerta no arquivo do Zabbix
        echo "${gap}" > "${ZABBIX_MONITOR}.gap"

        # Aqui você pode adicionar outras notificações
        # echo "Gap crítico: ${gap} sequences entre Prod e Standby" | mail -s "DR Gap Alert" dba@empresa.com
    else
        # Limpar arquivo de alerta se existir
        rm -f "${ZABBIX_MONITOR}.gap"
    fi

    # Escrever métricas para monitoramento
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROD=${prod_seq} STANDBY=${standby_seq} GAP=${gap}" >> "${LOG_DIR}/gap_history.log"

    return 0
}

# Verificar utilização de disco e outras métricas operacionais
check_operational_status() {
    # Verificar espaço em disco do destino dos archives
    local disk_usage=$(df "${ARCHIVELOG_DEST}" | tail -1 | awk '{print $5}' | sed 's/%//')
    local disk_threshold=80

    # Contar arquivos locais
    local local_files=$(find ${ARCHIVELOG_DEST} -name "*.dbf" -type f | wc -l)

    # Log formato conciso
    log "DISK: ${disk_usage}% | LOCAL_FILES: ${local_files}"

    # Alertas apenas se necessário
    if [ ${disk_usage} -gt ${disk_threshold} ]; then
        log "ALERTA: Disco alto (${disk_usage}% > ${disk_threshold}%)"
        echo "${disk_usage}" > "${ZABBIX_MONITOR}.disk"
    else
        rm -f "${ZABBIX_MONITOR}.disk"
    fi

    # Verificar se diretórios necessários existem (silencioso)
    for dir in "${TRACKING_DIR}" "${LOG_DIR}" "${TEMP_DIR}"; do
        if [ ! -d "${dir}" ]; then
            log "AVISO: Diretório não existe: ${dir}"
        fi
    done
}

#================================================================
# MAIN
#================================================================

main() {
    log "========================================="
    log "Iniciando sincronização e recovery do DR"
    log "========================================="
    
    # Verificar se banco está mounted
    db_status=$(
        sqlplus -s / as sysdba <<EOF | grep -v '^$' | tail -1
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT OPEN_MODE FROM V\$DATABASE;
EXIT;
EOF
    )
    
    if [[ ! "${db_status}" =~ "MOUNTED" ]]; then
        log "ERRO: Banco não está em modo MOUNTED (status: ${db_status})"
        log "Execute: STARTUP MOUNT"
        exit 1
    fi
    
    # Sequência inicial da janela (via banco)
    START_SEQ=$(get_last_applied_sequence)
    if ! [[ "${START_SEQ}" =~ ^[0-9]+$ ]]; then
        START_SEQ=0
    fi
    
    # 1. Download de novos archives
    download_new_archives
    downloaded=$?

    # 2. Executar recovery se houver novos archives
    recovery_rc=0
    if [ ${downloaded} -gt 0 ]; then
        if execute_recovery; then
            recovery_rc=0
        else
            recovery_rc=1
        fi
    else
        log "Nenhum archive novo para aplicar"
        export RECOVERY_APPLIED_COUNT=0
    fi
    
    # 3. Verificar status
    check_archive_gap

    # 4. Verificar gap Produção vs Standby
    check_prod_standby_gap

    # 5. Verificar status operacional
    check_operational_status

    # 6. Limpeza
    cleanup_old_files

    # 7. Summary conciso da execução
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    applied=${RECOVERY_APPLIED_COUNT:-0}
    END_SEQ=$(get_last_applied_sequence)
    if ! [[ "${END_SEQ}" =~ ^[0-9]+$ ]]; then
        END_SEQ=${START_SEQ}
    fi
    status="OK"
    if [ ${downloaded} -eq 0 ] && [ ${applied} -eq 0 ]; then
        status="NOOP"
    fi
    if [ ${recovery_rc} -ne 0 ]; then
        status="ERROR"
    fi
    echo "${now_ts}|RUN_ID=${RUN_ID}|DOWN=${downloaded}|APPLIED=${applied}|START=${START_SEQ}|END=${END_SEQ}|STATUS=${status}" >> "${SUMMARY_LOG}"
    
    log "Processo finalizado"
    log "========================================="
}

# Executar
main
