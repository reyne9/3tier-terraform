#!/bin/bash
# Azure 2-emergency 완전 배포 스크립트
# 사용법: ./deploy-complete.sh

set -e

echo "========================================="
echo "Azure DR 2-emergency 완전 배포 시작"
echo "========================================="

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 에러 시 중단
trap 'echo -e "${RED}Error occurred at line $LINENO${NC}"; exit 1' ERR

# Step 1: Terraform 배포 확인
echo -e "\n${YELLOW}[1/7] Terraform 리소스 확인...${NC}"
if [ ! -f "../terraform.tfstate" ]; then
    echo -e "${RED}Error: Terraform이 배포되지 않았습니다. 먼저 'terraform apply'를 실행하세요.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Terraform 리소스 확인 완료${NC}"

# Step 2: AKS credentials 설정
echo -e "\n${YELLOW}[2/7] AKS credentials 설정...${NC}"
RESOURCE_GROUP=$(cd .. && terraform output -raw resource_group_name 2>/dev/null || echo "rg-dr-blue")
AKS_NAME=$(cd .. && terraform output -raw aks_cluster_name 2>/dev/null || echo "aks-dr-blue")

az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
echo -e "${GREEN}✓ AKS credentials 설정 완료${NC}"

# Step 3: Namespace 생성
echo -e "\n${YELLOW}[3/7] Kubernetes Namespaces 생성...${NC}"
kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace was --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespaces 생성 완료${NC}"

# Step 4: DB Secret 생성
echo -e "\n${YELLOW}[4/7] Database Secret 생성...${NC}"
MYSQL_FQDN=$(cd .. && terraform output -raw mysql_fqdn 2>/dev/null || echo "mysql-dr-blue.mysql.database.azure.com")
if [ -z "${DB_PASSWORD:-}" ]; then
    echo -e "${RED}Error: DB_PASSWORD 환경변수를 먼저 설정하세요.${NC}"
    echo "예: export DB_PASSWORD='<azure-mysql-password>'"
    exit 1
fi

echo "MySQL FQDN: $MYSQL_FQDN"

# ⚠️ CRITICAL: Azure MySQL username은 'mysqladmin'
kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://${MYSQL_FQDN}:3306/petclinic" \
  --from-literal=username="mysqladmin" \
  --from-literal=password="${DB_PASSWORD}" \
  --namespace=was \
  --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓ Database Secret 생성 완료 (username: mysqladmin)${NC}"

# Step 5: 애플리케이션 배포
echo -e "\n${YELLOW}[5/7] PetClinic 애플리케이션 배포...${NC}"
kubectl apply -f ../k8s-manifests/web/
kubectl apply -f ../k8s-manifests/was/

echo "Pod 시작 대기 중 (60초)..."
sleep 60

kubectl get pods -n web
kubectl get pods -n was
echo -e "${GREEN}✓ 애플리케이션 배포 완료${NC}"

# Step 6: WAS LoadBalancer IP 확인
echo -e "\n${YELLOW}[6/7] WAS LoadBalancer IP 확인 및 Application Gateway 업데이트...${NC}"
echo "LoadBalancer IP 할당 대기 중 (최대 3분)..."
for i in {1..36}; do
    WAS_LB_IP=$(kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$WAS_LB_IP" ]; then
        echo -e "${GREEN}✓ WAS LoadBalancer IP: $WAS_LB_IP${NC}"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

if [ -z "$WAS_LB_IP" ]; then
    echo -e "${RED}Error: LoadBalancer IP를 가져올 수 없습니다.${NC}"
    echo "kubectl get svc -n was was-service로 수동 확인하세요."
    exit 1
fi

# Application Gateway 업데이트
echo "Application Gateway backend 업데이트 중..."
az network application-gateway address-pool update \
  --resource-group "$RESOURCE_GROUP" \
  --gateway-name appgw-blue \
  --name aks-backend-pool \
  --servers "$WAS_LB_IP"

az network application-gateway probe update \
  --resource-group "$RESOURCE_GROUP" \
  --gateway-name appgw-blue \
  --name health-probe \
  --host "$WAS_LB_IP"

echo -e "${GREEN}✓ Application Gateway 업데이트 완료${NC}"

# Step 7: 배포 확인
echo -e "\n${YELLOW}[7/7] 배포 확인...${NC}"
APPGW_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name pip-appgw-blue \
  --query ipAddress -o tsv)

echo ""
echo "========================================="
echo -e "${GREEN}배포 완료!${NC}"
echo "========================================="
echo ""
echo "Application Gateway IP: $APPGW_IP"
echo "WAS LoadBalancer IP: $WAS_LB_IP"
echo ""
echo "접근 테스트:"
echo "  curl http://$APPGW_IP/"
echo ""
echo "Pod 상태 확인:"
echo "  kubectl get pods -n web"
echo "  kubectl get pods -n was"
echo ""
echo "로그 확인:"
echo "  kubectl logs -n was -l app=was-spring"
echo ""
echo "========================================="
