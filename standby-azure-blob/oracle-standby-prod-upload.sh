#!/bin/bash

###############################################################################
# Nome do Script: oracle-standby-prod-upload.sh
#
###############################################################################

. ~/.bash_profile

# ==============================
# Variáveis de ambiente
# ==============================

FILE_NAME="oracle_standby_prod_upload"
SID=${ORACLE_SID^^}
DT=$(date +%d-%m-%Y_%H%M)
RUN_ID=$(echo "$$-$(date +%s)" | md5sum | cut -c1-8)

# MONITORING
LOCK_FILE="/tmp/${FILE_NAME}_${SID}.lock"
ZABBIX_MONITOR="/opt/discover/zabbix/${FILE_NAME}_${SID}.out"

ARCHIVELOG_DEST="/u02/fra/MSCDBPR/archivelog/"

STANDBY_DIR="/u01/scripts/standby"
TRACKING_DIR="${STANDBY_DIR}/tracking"
LOG_DIR="${STANDBY_DIR}/log"
TEMP_DIR="${STANDBY_DIR}/temp"
OUTPUT_DIR="${STANDBY_DIR}/output"

LOG_FILE="${LOG_DIR}/${FILE_NAME}_${SID}_${RUN_ID}__${DT}.log"
UPLOAD_MONITOR_LOG="${LOG_DIR}/upload_blob_${SID}.log"

# AZCOPY & BLOB
export AZCOPY_CRED_TYPE="Anonymous"
export AZCOPY_LOCATION="/u01/app/azure"
export AZCOPY_LOG_LOCATION="${AZCOPY_LOCATION}/log"
AZ_BLOB_CONTAINER="https://br241ew1psa01.blob.core.windows.net/dump/BRMODALLPROD/STANDBY/MSCDBPR/"
AZ_BLOB_TOKEN="?sp=racwl&st=2025-10-17T13:37:20Z&se=2026-10-17T21:52:20Z&spr=https&sv=2024-11-04&sr=c&sig=ueihZmqV%2BTupF5APa4hXyBgrMti2LsqR3QPGbHZb5H4%3D"
AZ_BLOB_DEST="${AZ_BLOB_CONTAINER}${AZ_BLOB_TOKEN}"

# RETENÇÃO DE ARCHIVES NO BLOB
BLOB_RETENTION_DAYS=7
ENABLE_BLOB_CLEANUP="true"

# Criar diretórios
mkdir -p ${TRACKING_DIR} ${LOG_DIR} ${TEMP_DIR} ${OUTPUT_DIR} || { echo "ERRO: Falha ao criar diretórios necessários"; exit 1; }


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

# Obter último archive sequence do banco
get_current_sequence() {
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

# Obter última sequência uploaded do histórico
get_last_uploaded_sequence() {
    if [ -f "${TRACKING_DIR}/upload_history.log" ]; then
        tail -1 "${TRACKING_DIR}/upload_history.log" | cut -d'|' -f3
    else
        echo "0"
    fi
}

# Listar archives prontos usando V$ARCHIVED_LOG (garante consistência)
list_completed_archives() {
    log "Buscando archives completos no Oracle..." >&2

    # Obter última sequência uploaded
    local last_uploaded=$(get_last_uploaded_sequence)
    log "Última sequência uploaded: ${last_uploaded}" >&2

    # Obter sequência atual do banco
    local current_seq=$(get_current_sequence)
    log "Sequência atual do banco: ${current_seq}" >&2

    # Buffer de segurança: não upload o archive mais recente
    local safe_max_seq=$((current_seq - 1))
    log "Sequência máxima segura: ${safe_max_seq}" >&2

    # Buscar archives completos no Oracle e validar existência
    while read archive_path; do
        if [ -n "${archive_path}" ] && [ -f "${archive_path}" ]; then
            echo "${archive_path}"
        fi
    done < <(sqlplus -s / as sysdba <<EOF | grep -v '^$'
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT name
FROM v\$archived_log
WHERE sequence# > ${last_uploaded}
  AND sequence# <= ${safe_max_seq}
  AND dest_id = 1
  AND deleted = 'NO'
  AND status = 'A'
  AND resetlogs_change# = (SELECT resetlogs_change# FROM v\$database)
ORDER BY sequence#;
EXIT;
EOF
)
}


# Listar archives pendentes de upload
list_pending_archives() {
    log "Buscando archives para upload..." >&2

    # Obter última sequência uploaded
    local last_uploaded=$(get_last_uploaded_sequence)
    log "Última sequência uploaded: ${last_uploaded}" >&2

    # Obter sequência atual do banco
    local current_seq=$(get_current_sequence)
    log "Sequência atual do banco: ${current_seq}" >&2

    # Buscar TODOS os archives (sem filtro de tempo)
    local count=0
    while read archive_path; do
        archive_name=$(basename -- "${archive_path}")
        sequence=$(echo ${archive_name} | cut -d'_' -f2)

        # Upload se: sequence > last_uploaded AND sequence <= current_seq
        if [ -n "${sequence}" ] && [ ${sequence} -gt ${last_uploaded} ] && [ ${sequence} -le ${current_seq} ]; then
            echo "${archive_path}"
            count=$((count + 1))
        fi
    done < <(find ${ARCHIVELOG_DEST} -name "*.dbf" -type f 2>/dev/null | sort)

    log "Total de archives encontrados para upload: ${count}" >&2
}

# Upload de um archive
upload_single_archive() {
    local archive_path=$1
    local archive_name=$(basename -- "${archive_path}")
    local archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || echo "0")
    
    # Extrair informações do nome do archive (formato: thread_sequence_resetlogs.dbf)
    local thread=$(echo ${archive_name} | cut -d'_' -f1)
    local sequence=$(echo ${archive_name} | cut -d'_' -f2)
    
    log "Uploading: ${archive_name} | Sequence: ${sequence} | Size: $((archive_size/1024/1024))MB" >&2
    
    # Destino no blob - PASTA ÚNICA
    DEST_URL="${AZ_BLOB_CONTAINER}${archive_name}${AZ_BLOB_TOKEN}"
    
    # Upload com retry
    RETRY=0
    MAX_RETRY=3
    
    while [ ${RETRY} -lt ${MAX_RETRY} ]; do
        ${AZCOPY_LOCATION}/azcopy copy "${archive_path}" "${DEST_URL}" \
            --overwrite=false \
            --check-length=true \
            --log-level=ERROR >> "${LOG_FILE}" 2>&1

        if [ $? -eq 0 ]; then
            log "Upload OK: ${archive_name}"
            
            # Criar flag de sucesso
            touch "${TRACKING_DIR}/${archive_name}.uploaded"
            echo "$(date '+%Y-%m-%d %H:%M:%S')|${archive_name}|${sequence}|${archive_size}" \
                >> "${TRACKING_DIR}/upload_history.log"
            
            return 0
        else
            RETRY=$((RETRY + 1))
            log "Upload falhou (tentativa ${RETRY}/${MAX_RETRY})"
            sleep 5
        fi
    done
    
    log "ERRO: Falha definitiva no upload de ${archive_name}"
    return 1
}

# Atualizar arquivo de controle no blob
update_control_file() {
    local last_sequence=$1
    local control_file="/tmp/control_${DT}.txt"
    
    cat > ${control_file} <<EOF
LAST_SEQUENCE=${last_sequence}
LAST_UPDATE=$(date '+%Y-%m-%d %H:%M:%S')
SOURCE_HOST=$(hostname)
SOURCE_SID=${ORACLE_SID}
EOF
    
    # Upload do arquivo de controle - NA MESMA PASTA
    CONTROL_URL="${AZ_BLOB_CONTAINER}control.txt${AZ_BLOB_TOKEN}"
    ${AZCOPY_LOCATION}/azcopy copy "${control_file}" "${CONTROL_URL}" \
        --overwrite=true --log-level=ERROR 2>&1 >> ${LOG_FILE} 2>&1
    
    rm -f ${control_file}
}

# Limpeza de archives antigos locais (após confirmar backup)
cleanup_old_archives() {
    local days_to_keep=3
    log "Limpando archives com mais de ${days_to_keep} dias..."

    find ${TRACKING_DIR} -name "*.uploaded" -mtime +${days_to_keep} | while read flag_file; do
        archive_name=$(basename -- "${flag_file}" .uploaded)
        archive_path="${ARCHIVELOG_DEST}/${archive_name}"

        if [ -f "${archive_path}" ]; then
            log "Removendo archive antigo: ${archive_name}"
            rm -f "${archive_path}"
        fi
        rm -f "${flag_file}"
    done
}

# Limpeza de archives antigos no Azure Blob Storage
cleanup_blob_archives() {
    if [ "${ENABLE_BLOB_CLEANUP}" != "true" ]; then
        log "Cleanup do blob desabilitado"
        return 0
    fi

    log "Iniciando limpeza de archives antigos no blob (>${BLOB_RETENTION_DAYS} dias)..."

    # Calcular data limite (formato Unix timestamp para comparação)
    local cutoff_date=$(date -d "${BLOB_RETENTION_DAYS} days ago" +%s)
    local removed_count=0
    local error_count=0

    # Listar arquivos no blob e processar linha por linha
    "${AZCOPY_LOCATION}/azcopy" list "${AZ_BLOB_DEST}" --machine-readable | \
    grep '"ContentType":"application/octet-stream"' | \
    while IFS= read -r line; do
        # Extrair nome do arquivo e data de modificação do JSON
        local blob_name=$(echo "$line" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4)
        local last_modified=$(echo "$line" | grep -o '"LastModified":"[^"]*"' | cut -d'"' -f4)

        # Verificar se é um archive (.dbf)
        if [[ "$blob_name" == *.dbf ]]; then
            # Converter data de modificação para timestamp Unix
            local file_timestamp=$(date -d "$last_modified" +%s 2>/dev/null)

            if [ $? -eq 0 ] && [ "$file_timestamp" -lt "$cutoff_date" ]; then
                log "Removendo archive antigo do blob: ${blob_name} (${last_modified})"

                # Remover arquivo do blob
                local blob_url="${AZ_BLOB_CONTAINER}${blob_name}${AZ_BLOB_TOKEN}"
                "${AZCOPY_LOCATION}/azcopy" remove "$blob_url" --log-level=ERROR >> "${LOG_FILE}" 2>&1

                if [ $? -eq 0 ]; then
                    removed_count=$((removed_count + 1))
                    log "Archive removido com sucesso: ${blob_name}"
                else
                    error_count=$((error_count + 1))
                    log "Erro ao remover archive: ${blob_name}"
                fi
            fi
        fi
    done

    log "Cleanup do blob finalizado: ${removed_count} archives removidos, ${error_count} erros"
}

#================================================================
# MAIN
#================================================================

main() {
    log "========================================="
    log "Início do upload de archives para Blob"
    log "========================================="
    
    # Verificar conectividade - PASTA ÚNICA
    ${AZCOPY_LOCATION}/azcopy list "${AZ_BLOB_CONTAINER}${AZ_BLOB_TOKEN}" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "ERRO: Sem conectividade com o Blob Storage"
        exit 1
    fi
    
    # Processar archives
    UPLOAD_COUNT=0
    ERROR_COUNT=0
    FIRST_SEQUENCE=0
    LAST_SEQUENCE=0

    # Obter lista de archives em array (usando Oracle para garantir consistência)
    mapfile -t archives_to_upload < <(list_completed_archives)

    log "Processando ${#archives_to_upload[@]} archives..."

    # Processar cada archive
    for archive_path in "${archives_to_upload[@]}"; do
        if [ -n "${archive_path}" ]; then
            upload_single_archive "${archive_path}"
            if [ $? -eq 0 ]; then
                UPLOAD_COUNT=$((UPLOAD_COUNT + 1))

                # Extrair sequence number
                archive_name=$(basename -- "${archive_path}")
                seq_num=$(echo ${archive_name} | cut -d'_' -f2)
                if [ ${FIRST_SEQUENCE} -eq 0 ] || [ ${seq_num} -lt ${FIRST_SEQUENCE} ]; then
                    FIRST_SEQUENCE=${seq_num}
                fi
                if [ ${seq_num} -gt ${LAST_SEQUENCE} ]; then
                    LAST_SEQUENCE=${seq_num}
                fi
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    done
    
    # Atualizar arquivo de controle se houve uploads
    if [ ${UPLOAD_COUNT} -gt 0 ]; then
        current_seq=$(get_current_sequence)
        update_control_file ${current_seq}
    fi
    
    # Registrar linha de monitoramento concisa do upload para operação
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    status="OK"
    if [ ${UPLOAD_COUNT} -eq 0 ]; then
        status="NOOP"
    fi
    if [ ${ERROR_COUNT} -gt 0 ]; then
        status="PARTIAL"
    fi
    first_out="-"
    last_out="-"
    if [ ${UPLOAD_COUNT} -gt 0 ]; then
        first_out=${FIRST_SEQUENCE}
        last_out=${LAST_SEQUENCE}
    fi
    echo "${now_ts}|RUN_ID=${RUN_ID}|COUNT=${UPLOAD_COUNT}|FIRST=${first_out}|LAST=${last_out}|STATUS=${status}" >> "${UPLOAD_MONITOR_LOG}"

    # Limpeza do blob (archives antigos)
    cleanup_blob_archives

    # Limpeza local (opcional - comentar se quiser manter archives locais)
    # cleanup_old_archives

    log "Finalizado: ${UPLOAD_COUNT} uploads, ${ERROR_COUNT} erros"
    log "========================================="
}

# Executar
main