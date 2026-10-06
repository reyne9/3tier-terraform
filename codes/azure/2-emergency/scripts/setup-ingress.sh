#!/usr/bin/env bash
# Existing App Gateway -> Web LoadBalancer route; Terraform owns the gateway.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
AKS_NAME=$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name)
RESOURCE_GROUP=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
AGIC_ENABLED=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" \
  --query addonProfiles.ingressApplicationGateway.enabled -o tsv)
if [[ "$AGIC_ENABLED" == "true" ]]; then
  echo "ERROR: AGIC가 활성화되어 있습니다. 기존 AGIC 설정을 정리한 뒤 실행하세요. Terraform과 동시에 Gateway를 변경할 수 없습니다." >&2
  exit 1
fi
WEB_LB_IP=""
for ((i=0; i<60; i++)); do
  WEB_LB_IP=$(kubectl get svc web-service -n web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [[ -n "$WEB_LB_IP" ]] && break
  sleep 5
done
if [[ ! "$WEB_LB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Web LoadBalancer IPv4 할당을 확인하지 못했습니다." >&2
  exit 1
fi
# Persist for subsequent apply runs so the backend cannot revert to a stale IP.
printf 'backend_ip_addresses = ["%s"]\nbackend_port = 80\n' "$WEB_LB_IP" > "$TF_DIR/backend.auto.tfvars"
terraform -chdir="$TF_DIR" apply "$@"
APPGW_IP=$(terraform -chdir="$TF_DIR" output -raw appgw_public_ip)
for ((i=0; i<30; i++)); do
  if curl --fail --silent --show-error --max-time 15 "http://$APPGW_IP/" > /dev/null; then
    echo "Application Gateway → Web → WAS 연결 확인: http://$APPGW_IP/"
    exit 0
  fi
  sleep 10
done
echo "ERROR: Application Gateway 응답 검증에 실패했습니다." >&2
exit 1
