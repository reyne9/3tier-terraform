#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
: "${DB_PASSWORD:?DB_PASSWORD 환경변수를 설정하세요.}"
AKS_NAME=$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name)
RESOURCE_GROUP=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)
MYSQL_FQDN=$(terraform -chdir="$TF_DIR" output -raw mysql_fqdn)
DB_NAME=$(terraform -chdir="$TF_DIR" output -raw mysql_database_name)
DB_USER=$(terraform -chdir="$TF_DIR" output -raw mysql_username)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl apply -f "$TF_DIR/k8s-manifests/namespaces.yaml"
kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://$MYSQL_FQDN:3306/$DB_NAME?sslMode=REQUIRED&serverTimezone=UTC" \
  --from-literal=username="$DB_USER" --from-literal=password="$DB_PASSWORD" \
  --namespace=was --dry-run=client -o yaml | kubectl apply -f -
# Deploy Services before Nginx tries to resolve the WAS upstream.
kubectl apply -f "$TF_DIR/k8s-manifests/was/service.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/was/deployment.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/web/service.yaml"
kubectl apply -f "$TF_DIR/k8s-manifests/web/deployment.yaml"
kubectl rollout status deployment/was-spring -n was --timeout=600s
kubectl rollout status deployment/web-nginx -n web --timeout=300s
echo "Web/WAS 배포 완료. setup-ingress.sh를 실행해 App Gateway를 연결하세요."
