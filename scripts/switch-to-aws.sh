#!/usr/bin/env bash

# 승인된 AWS 복귀:
# CloudFront azure_dr -> normal
# Front Door azure_service -> maintenance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AZURE_ALWAYS_DIR="${REPO_ROOT}/codes/azure/1-always"
AWS_EDGE_DIR="${REPO_ROOT}/codes/aws/1. route53"

APPROVED=false
AUTO_APPROVE=false

usage() {
  echo "Usage: $0 --approved [--auto-approve]"
  echo ""
  echo "  --approved      AWS ALB/EKS/RDS 복구와 데이터 정합성 검증 후 failback을 승인함"
  echo "  --auto-approve  Terraform 확인 프롬프트 생략"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --approved)
      APPROVED=true
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

if [ "$APPROVED" != "true" ]; then
  echo "ERROR: AWS 복구·데이터 정합성 검증 후 failback 승인이 필요합니다." >&2
  usage >&2
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform 명령을 찾을 수 없습니다." >&2
  exit 1
fi

FRONTDOOR_HOSTNAME="$(terraform -chdir="${AZURE_ALWAYS_DIR}" output -raw frontdoor_endpoint)"
APPGW_IP="$(terraform -chdir="${AZURE_ALWAYS_DIR}" output -raw azure_appgw_ip 2>/dev/null || true)"

AWS_MODE_FILE="${AWS_EDGE_DIR}/dr-mode.auto.tfvars"
AZURE_MODE_FILE="${AZURE_ALWAYS_DIR}/dr-mode.auto.tfvars"

printf 'azure_frontdoor_domain_name = "%s"\ntraffic_mode = "normal"\n' \
  "$FRONTDOOR_HOSTNAME" >"$AWS_MODE_FILE"

TF_APPLY_ARGS=(apply)
if [ "$AUTO_APPROVE" = "true" ]; then
  TF_APPLY_ARGS+=("-auto-approve")
fi

echo "[1/2] CloudFront를 AWS ALB + Front Door 점검 페이지 failover로 복귀"
terraform -chdir="${AWS_EDGE_DIR}" "${TF_APPLY_ARGS[@]}"

if [ -n "$APPGW_IP" ]; then
  printf 'azure_appgw_ip = "%s"\nfrontdoor_backend_mode = "maintenance"\n' \
    "$APPGW_IP" >"$AZURE_MODE_FILE"
else
  printf 'frontdoor_backend_mode = "maintenance"\n' >"$AZURE_MODE_FILE"
fi

echo "[2/2] Front Door를 HTTPS Blob 점검 페이지 대기로 복귀"
terraform -chdir="${AZURE_ALWAYS_DIR}" "${TF_APPLY_ARGS[@]}"

echo ""
echo "AWS failback 완료"
echo "  정상: Route53 -> CloudFront -> AWS ALB -> EKS"
echo "  장애 시 GET/HEAD: CloudFront -> Front Door -> HTTPS Blob 점검 페이지"
echo ""
echo "Azure 2-emergency 리소스 삭제는 별도 승인 후 수행하십시오."
