#!/bin/bash
set -euo pipefail

# Redis Backup Script - Backs up Redis RDB to S3-compatible storage
# This script is designed to run inside the redis-backup container

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="redis_backup_${TIMESTAMP}.rdb"
LOCAL_BACKUP_DIR="/tmp/redis-backups"

# Create backup directory
mkdir -p "${LOCAL_BACKUP_DIR}"

echo "[$(date)] Starting Redis backup..."

# Trigger a BGSAVE on Redis to ensure we have the latest RDB
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" BGSAVE

# Wait for BGSAVE to complete
echo "[$(date)] Waiting for BGSAVE to complete..."
while [ "$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" LASTSAVE)" == "$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" LASTSAVE)" ]; do
    sleep 1
done
sleep 2  # Give it a moment to finish writing

# Copy the RDB file
if [ -f /data/dump.rdb ]; then
    cp /data/dump.rdb "${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"
    echo "[$(date)] RDB file copied to ${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"
else
    echo "[$(date)] ERROR: dump.rdb not found at /data/dump.rdb"
    exit 1
fi

# Compress the backup
gzip "${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"
BACKUP_FILE="${BACKUP_FILE}.gz"
echo "[$(date)] Backup compressed: ${BACKUP_FILE}"

# Configure AWS CLI for S3-compatible storage
export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"

# Build S3 endpoint URL option
S3_ENDPOINT_URL=""
if [ -n "${S3_ENDPOINT:-}" ]; then
    S3_ENDPOINT_URL="--endpoint-url ${S3_ENDPOINT}"
fi

# Upload to S3
S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE}"
echo "[$(date)] Uploading to ${S3_PATH}..."
aws s3 cp ${S3_ENDPOINT_URL} "${LOCAL_BACKUP_DIR}/${BACKUP_FILE}" "${S3_PATH}"
echo "[$(date)] Upload complete!"

# Clean up old backups (retention policy)
if [ -n "${BACKUP_KEEP_DAYS:-}" ] && [ "${BACKUP_KEEP_DAYS}" -gt 0 ]; then
    echo "[$(date)] Cleaning up backups older than ${BACKUP_KEEP_DAYS} days..."
    CUTOFF_DATE=$(date -d "-${BACKUP_KEEP_DAYS} days" +%Y%m%d)

    # List and delete old backups
    aws s3 ls ${S3_ENDPOINT_URL} "s3://${S3_BUCKET}/${S3_PREFIX}/" | while read -r line; do
        FILE_NAME=$(echo "$line" | awk '{print $4}')
        if [ -n "$FILE_NAME" ]; then
            # Extract date from filename (format: redis_backup_YYYYMMDD_HHMMSS.rdb.gz)
            FILE_DATE=$(echo "$FILE_NAME" | sed -n 's/redis_backup_\([0-9]\{8\}\)_.*/\1/p')
            if [ -n "$FILE_DATE" ] && [ "$FILE_DATE" -lt "$CUTOFF_DATE" ]; then
                echo "[$(date)] Deleting old backup: ${FILE_NAME}"
                aws s3 rm ${S3_ENDPOINT_URL} "s3://${S3_BUCKET}/${S3_PREFIX}/${FILE_NAME}"
            fi
        fi
    done
fi

# Clean up local backup
rm -f "${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"
echo "[$(date)] Redis backup completed successfully!"
