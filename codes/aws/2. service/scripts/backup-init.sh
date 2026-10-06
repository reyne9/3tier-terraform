#!/bin/bash
# Terraform template. Only config_b64 is expanded by Terraform.
set -euo pipefail
umask 077
exec > >(tee -a /var/log/backup-instance-init.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mysql-client awscli jq curl gzip cron util-linux
curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
install -d -m 700 /etc/mysql-backup /opt/mysql-backup
printf '%s' '${config_b64}' | base64 --decode > /etc/mysql-backup/config.json

cat > /usr/local/bin/mysql-backup-to-azure.sh <<'BACKUP_SCRIPT'
#!/bin/bash
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec >> /var/log/mysql-backup-to-azure.log 2>&1
exec 9>/run/lock/mysql-backup.lock
flock -n 9 || exit 0
CONFIG=/etc/mysql-backup/config.json
REGION=$(jq -er '.region' "$CONFIG")
RDS_HOST=$(jq -er '.rds_host' "$CONFIG")
DB_NAME=$(jq -er '.db_name' "$CONFIG")
DB_USERNAME=$(jq -er '.db_username' "$CONFIG")
AZURE_STORAGE_ACCOUNT=$(jq -er '.azure_storage_account' "$CONFIG")
AZURE_CONTAINER=$(jq -er '.azure_container' "$CONFIG")
SECRET_ARN=$(jq -er '.secret_arn' "$CONFIG")
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --region "$REGION" --query SecretString --output text)
MYSQL_PWD=$(printf '%s' "$SECRET_JSON" | jq -er '.rds_password | select(length > 0)')
AZURE_STORAGE_KEY=$(printf '%s' "$SECRET_JSON" | jq -er '.azure_storage_key | select(length > 0)')
export MYSQL_PWD AZURE_STORAGE_KEY
unset SECRET_JSON
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_FILE="/opt/mysql-backup/backup-$TIMESTAMP.sql.gz"
PARTIAL_FILE="$BACKUP_FILE.partial"
trap 'rm -f "$PARTIAL_FILE"' EXIT
# pipefail prevents uploading an empty/partial dump after a MySQL error.
mysqldump -h "$RDS_HOST" -u "$DB_USERNAME" \
  --single-transaction --set-gtid-purged=OFF --no-tablespaces \
  --column-statistics=0 --routines --triggers --events \
  --databases "$DB_NAME" | gzip > "$PARTIAL_FILE"
gzip -t "$PARTIAL_FILE"
mv "$PARTIAL_FILE" "$BACKUP_FILE"
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" \
  --container-name "$AZURE_CONTAINER" --name "backups/backup-$TIMESTAMP.sql.gz" \
  --file "$BACKUP_FILE" --overwrite --only-show-errors
find /opt/mysql-backup -name 'backup-*.sql.gz' -mtime +1 -delete
echo "Backup uploaded: backups/backup-$TIMESTAMP.sql.gz"
BACKUP_SCRIPT
chmod 700 /usr/local/bin/mysql-backup-to-azure.sh
BACKUP_CRON=$(jq -er '.backup_cron' /etc/mysql-backup/config.json)
printf '%s root /usr/local/bin/mysql-backup-to-azure.sh\n' "$BACKUP_CRON" > /etc/cron.d/mysql-backup
chmod 644 /etc/cron.d/mysql-backup
systemctl enable --now cron
/usr/local/bin/mysql-backup-to-azure.sh
