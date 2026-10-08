#!/usr/bin/env bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
for tool in terraform az mysql gzip; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool 설치가 필요합니다." >&2; exit 1; }
done
echo "사설 DB 복원: VNet에 연결되고 Private DNS를 조회할 수 있는 작업 환경이 필요합니다."
MYSQL_HOST=$(terraform -chdir="$TF_DIR" output -raw mysql_fqdn)
DB_NAME=$(terraform -chdir="$TF_DIR" output -raw mysql_database_name)
DB_USER=$(terraform -chdir="$TF_DIR" output -raw mysql_username)
STORAGE_ACCOUNT=$(terraform -chdir="$TF_DIR" output -raw storage_account_name)
CONTAINER=$(terraform -chdir="$TF_DIR" output -raw backup_container_name)
if [[ -z "${DB_PASSWORD:-}" ]]; then
  read -r -s -p 'MySQL Password: ' DB_PASSWORD
  echo
fi
: "${DB_PASSWORD:?MySQL 비밀번호가 필요합니다.}"
# az login with Storage Blob Data Reader, or AZURE_STORAGE_KEY/SAS_TOKEN.
AUTH_ARGS=(--auth-mode login)
if [[ -n "${AZURE_STORAGE_KEY:-}" || -n "${AZURE_STORAGE_SAS_TOKEN:-}" ]]; then
  AUTH_ARGS=(--auth-mode key)
fi
LATEST_BACKUP=$(az storage blob list --account-name "$STORAGE_ACCOUNT" \
  "${AUTH_ARGS[@]}" --container-name "$CONTAINER" --prefix 'backups/' \
  --query "sort_by([?ends_with(name, '.sql.gz')], &properties.lastModified)[-1].name" -o tsv)
[[ -n "$LATEST_BACKUP" && "$LATEST_BACKUP" != "None" ]] || { echo "ERROR: 백업이 없습니다." >&2; exit 1; }
RESTORE_DIR=$(mktemp -d)
trap 'rm -rf "$RESTORE_DIR"' EXIT
az storage blob download --account-name "$STORAGE_ACCOUNT" \
  "${AUTH_ARGS[@]}" --container-name "$CONTAINER" --name "$LATEST_BACKUP" \
  --file "$RESTORE_DIR/backup.sql.gz" --only-show-errors
gzip -t "$RESTORE_DIR/backup.sql.gz"
gzip -d "$RESTORE_DIR/backup.sql.gz"
# Reject another database's dump before executing its embedded USE statement.
DUMP_DB=$(sed -n 's/^USE `\(.*\)`;$/\1/p' "$RESTORE_DIR/backup.sql" | sort -u)
if [[ "$DUMP_DB" != "$DB_NAME" ]]; then
  echo "ERROR: 백업 DB 이름과 대상 db_name이 다릅니다. 복원을 중단합니다." >&2
  exit 1
fi
export MYSQL_PWD="$DB_PASSWORD"
mysql --batch --ssl-mode=REQUIRED -h "$MYSQL_HOST" -u "$DB_USER" "$DB_NAME" < "$RESTORE_DIR/backup.sql"
TABLE_COUNT=$(mysql --batch --skip-column-names --ssl-mode=REQUIRED \
  -h "$MYSQL_HOST" -u "$DB_USER" "$DB_NAME" \
  -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();')
[[ "$TABLE_COUNT" -gt 0 ]] || { echo "ERROR: 대상 DB에 복원된 테이블이 없습니다. 양쪽 db_name을 확인하세요." >&2; exit 1; }
echo "복원 완료: $LATEST_BACKUP → $MYSQL_HOST/$DB_NAME ($TABLE_COUNT tables)"
echo "트래픽 전환 전에 실제 데이터와 애플리케이션 읽기·쓰기를 검증하세요."
