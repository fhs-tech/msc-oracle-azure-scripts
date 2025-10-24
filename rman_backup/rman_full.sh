#!/bin/bash

###############################################################################
# Nome do Script: rman_full.sh
#
# Descrição:
#   Realiza o backup completo da base Oracle com RMAN e envia apenas os arquivos
#   da execução atual para o Azure Blob Storage. Usa RUN_ID exclusivo para rastrear
#   os arquivos da execução e remove logs antigos do AzCopy.
#
###############################################################################

. ~/.bash_profile

# ==============================
# Variáveis de ambiente
# ==============================

export FILE_NAME="rman_full"
export BACKUP_DIR="/u02/backup/rman"

export NLS_DATE_FORMAT="DD/MM/YYYY HH24:MI:SS"
export SID=${ORACLE_SID^^}

export DT=$(date +%d-%m-%Y_%H%M)
export ANO=$(date +%Y)
export MES=$(date +%m)
export DIA=$(date +%d)

export RUN_ID=$(echo "$$-$(date +%s)" | md5sum | cut -c1-8)

export LOG_DIR="${BACKUP_DIR}/log"
export LOG_FILE="${LOG_DIR}/${FILE_NAME}_${SID}_${RUN_ID}__${DT}.log"
export SUMMARY_LOG="${LOG_DIR}/${FILE_NAME}_${SID}.log"

export AZCOPY_CRED_TYPE="Anonymous"
export AZCOPY_LOCATION="/u01/app/azure"
export AZCOPY_LOG_LOCATION="/u01/app/azure/log"
export AZ_BLOB_CONTAINER="https://br241ew1psa01.blob.core.windows.net/dump/BRMODALLPROD/RMAN/DATABASE/MSCDBPR/$ANO/$MES/$DIA/"
export AZ_BLOB_TOKEN="?sp=racwl&st=2025-10-17T13:37:20Z&se=2026-10-17T21:52:20Z&spr=https&sv=2024-11-04&sr=c&sig=ueihZmqV%2BTupF5APa4hXyBgrMti2LsqR3QPGbHZb5H4%3D"
export AZ_BLOB_DEST="${AZ_BLOB_CONTAINER}${AZ_BLOB_TOKEN}"

export ZABBIX_MONITOR="/opt/discover/zabbix/rman_full_monitor_${SID}.out"
export LOCK_FILE="/tmp/${FILE_NAME}_${SID}.lock"

# Criar diretórios
mkdir -p "${LOG_DIR}" || { echo "ERRO: Falha ao criar diretório ${LOG_DIR}"; exit 1; }

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
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${now_ts}|RUN_ID=${RUN_ID}|STATUS=INTERRUPTED" >> "$SUMMARY_LOG"
    rm -f "$LOCK_FILE"
    exit 1
}


log() {
    DT_LOG=$(date '+%d-%m-%Y %H:%M:%S')
    echo "${DT_LOG}: $1" | tee -a "$LOG_FILE"
}

exit_with_error() {
    local error_msg="$1"
    log "[ERROR] ${error_msg}"
    echo 1 > "$ZABBIX_MONITOR"
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${now_ts}|RUN_ID=${RUN_ID}|STATUS=ERROR|MSG=${error_msg}" >> "$SUMMARY_LOG"
    rm -f "$LOCK_FILE"
    exit 1
}

log "[START] Backup RMAN full database: ${SID} - ${RUN_ID} - ${DT}"

$ORACLE_HOME/bin/rman target / msglog "$LOG_FILE" <<EOF
run {
    allocate channel ch01 type disk maxpiecesize 10g maxopenfiles 2;

    configure backup optimization off;
    configure controlfile autobackup on;

    crosscheck backup device type disk;
    crosscheck archivelog all;

    delete noprompt expired backup;
    delete noprompt expired archivelog all;

    sql 'alter system archive log current';

    backup as compressed backupset database format '${BACKUP_DIR}/%d_full_%s_%p__${DT}_${RUN_ID}' filesperset 8 tag '${SID}_DB_${DT}';

    sql 'alter system archive log current';
    backup as compressed backupset archivelog all format '${BACKUP_DIR}/%d_arch_%s_%p__${DT}_${RUN_ID}' filesperset 8 not backed up 2 times tag '${SID}_ARCH_${DT}';

    backup as compressed backupset current controlfile format '${BACKUP_DIR}/%d_ctrl_%s_%p__${DT}_${RUN_ID}' tag '${SID}_CTRL_${DT}';
    backup as compressed backupset spfile format '${BACKUP_DIR}/%d_spfile_%s_%p__${DT}_${RUN_ID}' tag '${SID}_SPFILE_${DT}';

    delete noprompt obsolete redundancy 1 device type disk;
    delete noprompt archivelog all backed up 2 times to disk completed before 'sysdate-2' device type disk;

    release channel ch01;
}
show all;
report schema;
report need backup;
report unrecoverable;
show exclude;
list backup of database summary;
list backup of archivelog all summary;
list archivelog all;

exit;
EOF

RMAN_EXIT_STATUS=$?

# ==============================
# Verificação de Erros
# ==============================

log "[RMAN] Verificando erros no log..."

if [[ $RMAN_EXIT_STATUS -ne 0 ]]; then
    egrep 'ORA-|RMAN-|FAILED|ERROR-' "$LOG_FILE" | tee -a "$LOG_FILE"
    exit_with_error "RMAN retornou código diferente de zero (exit status: ${RMAN_EXIT_STATUS})"
fi

if [[ ! -s "$LOG_FILE" ]]; then
    exit_with_error "Log de RMAN está vazio. Verifique o ambiente."
fi

egrep 'ORA-|FAILED|ERROR-' "$LOG_FILE" >> /dev/null
if [[ $? -eq 0 ]]; then
    log "[ERROR] Encontrado erro no log RMAN:"
    egrep 'ORA-|FAILED|ERROR-' "$LOG_FILE" | tee -a "$LOG_FILE"
    exit_with_error "Erros detectados no log RMAN"
else
    log "[OK] Nenhum erro detectado no log RMAN."
fi

# ==============================
# Upload para Azure Blob
# ==============================

log "[AZCOPY] Iniciando envio dos arquivos com RUN_ID: $RUN_ID para Azure..."

"${AZCOPY_LOCATION}/azcopy" sync "${BACKUP_DIR}" "${AZ_BLOB_DEST}" \
  --from-to LocalBlob \
  --include-pattern "*${RUN_ID}" \
  --recursive --exclude-pattern "*.log" --log-level=INFO --check-md5 FailIfDifferent >> "$LOG_FILE" 2>&1

AZCOPY_EXIT_STATUS=$?

if [[ $AZCOPY_EXIT_STATUS -ne 0 ]]; then
    exit_with_error "Falha no upload para Azure Blob (exit status: ${AZCOPY_EXIT_STATUS})"
else
    log "[AZCOPY] Upload concluído com sucesso."
fi

# ==============================
# Limpeza de logs antigos
# ==============================

log "[CLEANUP] Limpando logs antigos do AzCopy com mais de 30 dias..."
find "$AZCOPY_LOG_LOCATION" -name "*.log" -type f -mtime +30 -exec rm -f {} \;

log "[CLEANUP] Limpando logs RMAN com mais de 30 dias..."
find "$LOG_DIR" -name "*.log" -type f -mtime +30 -exec rm -f {} \;

echo 0 > "$ZABBIX_MONITOR"
now_ts=$(date '+%Y-%m-%d %H:%M:%S')
echo "${now_ts}|RUN_ID=${RUN_ID}|STATUS=OK" >> "$SUMMARY_LOG"
rm -f "$LOCK_FILE"
log "[END] Script finalizado com sucesso."