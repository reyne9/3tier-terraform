#!/usr/bin/env bash

# 승인된 전체 DR 전환:
# Front Door maintenance -> azure_service
# CloudFront normal -> azure_dr

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AZURE_ALWAYS_DIR="${REPO_ROOT}/codes/azure/1-always"
AZURE_EMERGENCY_DIR="${REPO_ROOT}/codes/azure/2-emergency"
AWS_EDGE_DIR="${REPO_ROOT}/codes/aws/1. route53"

APPROVED=false
DB_RESTORED=false
AUTO_APPROVE=false

usage() {
  echo "Usage: $0 --approved --db-restored [--auto-approve]"
  echo ""
  echo "  --approved      장애대응 회의에서 전체 Azure DR 전환을 승인함"
  echo "  --db-restored   2-emergency 배포 후 최신 dump 복원과 서비스 검증을 완료함"
  echo "  --auto-approve  Terraform 확인 프롬프트 생략"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --approved)
      APPROVED=true
      ;;
    --db-restored)
      DB_RESTORED=true
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: 알 수 없는 옵션: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$APPROVED" != "true" ] || [ "$DB_RESTORED" != "true" ]; then
  echo "ERROR: 회의 승인과 최신 dump 복원·검증을 모두 확인해야 합니다." >&2
  usage >&2
  exit 1
fi

for command_name in terraform curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: 필요한 명령을 찾을 수 없습니다: ${command_name}" >&2
    exit 1
  fi
done

APPGW_IP="$(terraform -chdir="${AZURE_EMERGENCY_DIR}" output -raw appgw_public_ip)"
FRONTDOOR_HOSTNAME="$(terraform -chdir="${AZURE_ALWAYS_DIR}" output -raw frontdoor_endpoint)"

if [ -z "$APPGW_IP" ] || [ -z "$FRONTDOOR_HOSTNAME" ]; then
  echo "ERROR: Application Gateway IP 또는 Front Door endpoint를 확인할 수 없습니다." >&2
  exit 1
fi

echo "[1/4] Application Gateway/AKS 응답 확인: http://${APPGW_IP}/"
curl --fail --silent --show-error --max-time 15 "http://${APPGW_IP}/" >/dev/null

AZURE_MODE_FILE="${AZURE_ALWAYS_DIR}/dr-mode.auto.tfvars"
AWS_MODE_FILE="${AWS_EDGE_DIR}/dr-mode.auto.tfvars"

printf 'azure_appgw_ip = "%s"\nfrontdoor_backend_mode = "azure_service"\n' \
  "$APPGW_IP" >"$AZURE_MODE_FILE"
printf 'azure_frontdoor_domain_name = "%s"\ntraffic_mode = "azure_dr"\n' \
  "$FRONTDOOR_HOSTNAME" >"$AWS_MODE_FILE"

TF_APPLY_ARGS=(apply)
if [ "$AUTO_APPROVE" = "true" ]; then
  TF_APPLY_ARGS+=("-auto-approve")
fi

echo "[2/4] Front Door backend를 Application Gateway로 전환"
terraform -chdir="${AZURE_ALWAYS_DIR}" "${TF_APPLY_ARGS[@]}"

echo "[3/4] Front Door HTTPS 경로 확인: https://${FRONTDOOR_HOSTNAME}/"
curl --fail --silent --show-error --max-time 15 "https://${FRONTDOOR_HOSTNAME}/" >/dev/null

echo "[4/4] CloudFront를 Front Door 직접 Origin으로 전환"
terraform -chdir="${AWS_EDGE_DIR}" "${TF_APPLY_ARGS[@]}"

echo ""
echo "전체 Azure DR 전환 완료"
echo "  Route53 -> CloudFront -> Front Door -> Application Gateway -> AKS"
echo "  CloudFront traffic_mode: azure_dr"
echo "  Front Door backend_mode: azure_service"
echo ""
echo "상태 파일:"
echo "  ${AZURE_MODE_FILE}"
echo "  ${AWS_MODE_FILE}"
