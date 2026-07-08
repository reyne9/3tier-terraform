# Multi-Cloud DR Failover 절차

## 개요

이 문서는 AWS 한국 리전 장애 시 Azure로 완전히 전환하는 절차를 설명합니다.

## 아키텍처 개요

### 정상 운영 (Normal Operation)
```
User → blueisthenewblack.store (Route53)
     → CloudFront Distribution
     → Primary Origin: AWS ALB (Korea ap-northeast-2)
     → AWS EKS PetClinic
```

### 단기 장애 (Short-term Failure)
```
User → blueisthenewblack.store
     → CloudFront Distribution
     → Primary Origin: AWS ALB (5xx Error)
     → [Automatic Failover]
     → Secondary Origin: Azure Blob Storage
     → 정적 유지보수 페이지 표시
```

### 장기 DR (Long-term DR)
```
User → blueisthenewblack.store
     → CloudFront Distribution
     → Primary Origin: AWS ALB (5xx Error)
     → [Manual Switch to App Gateway]
     → Secondary Origin: Azure Application Gateway
     → Azure AKS PetClinic (완전한 서비스)
```

---

## 1단계: Azure 2-emergency 인프라 배포

### 1.1 배포 전 확인사항

```bash
# Azure CLI 로그인 확인
az account show

# Terraform 디렉토리 이동
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
```

### 1.2 terraform.tfvars 확인

```bash
cat terraform.tfvars
```

필수 확인 항목:
- `subscription_id`: Azure 구독 ID
- `tenant_id`: Azure 테넌트 ID
- `resource_group_name`: "rg-blue" (1-always에서 생성됨)
- `vnet_name`: "vnet-blue" (1-always에서 생성됨)
- `storage_account_name`: "bloberry01" (1-always에서 생성됨)
- `db_username`: MySQL 관리자 계정
- `db_password`: MySQL 비밀번호

### 1.3 Terraform 배포 실행

```bash
# 초기화
terraform init

# 계획 확인
terraform plan

# 배포 실행 (약 15-20분 소요)
terraform apply -auto-approve
```

### 1.4 배포되는 리소스

- **Azure MySQL Flexible Server**: PetClinic 데이터베이스
- **Azure AKS Cluster**: Kubernetes 클러스터 (2-4 노드)
- **Application Gateway**: CloudFront Secondary Origin용 엔드포인트
- **Public IP**: Application Gateway용 고정 IP

---

## 2단계: Azure MySQL 데이터베이스 복구

### 2.1 AWS RDS에서 최종 백업 생성

AWS가 여전히 접근 가능한 경우:

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/service

# RDS 스냅샷 생성
aws rds create-db-snapshot \
  --db-instance-identifier $(terraform output -raw rds_instance_id) \
  --db-snapshot-identifier petclinic-final-backup-$(date +%Y%m%d-%H%M%S) \
  --region ap-northeast-2

# S3로 백업 (mysqldump 방식)
kubectl exec -n petclinic deploy/petclinic -- \
  mysqldump -h $(terraform output -raw rds_endpoint | cut -d: -f1) \
  -u admin -p${DB_PASSWORD} petclinic > /tmp/petclinic-backup.sql

# S3 업로드
aws s3 cp /tmp/petclinic-backup.sql s3://your-backup-bucket/petclinic-backup.sql
```

### 2.2 Azure MySQL로 데이터 복구

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency

# Azure MySQL 엔드포인트 확인
AZURE_MYSQL_HOST=$(terraform output -raw mysql_fqdn)
AZURE_MYSQL_USER=$(terraform output -raw mysql_admin_username)

# 방화벽 규칙 추가 (현재 IP 허용)
MY_IP=$(curl -s ifconfig.me)
az mysql flexible-server firewall-rule create \
  --resource-group rg-blue \
  --name mysql-dr-blue \
  --rule-name allow-my-ip \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP

# 데이터 복구 (S3에서 다운로드 후)
aws s3 cp s3://your-backup-bucket/petclinic-backup.sql /tmp/petclinic-backup.sql

mysql -h $AZURE_MYSQL_HOST \
  -u $AZURE_MYSQL_USER \
  -p${DB_PASSWORD} \
  petclinic < /tmp/petclinic-backup.sql
```

**대안: 정기 백업 사용**

1-always 단계에서 설정된 정기 백업 스크립트가 Azure Blob Storage에 백업을 저장하므로:

```bash
# 최신 백업 확인
az storage blob list \
  --account-name bloberry01 \
  --container-name backups \
  --prefix petclinic- \
  --query "sort_by([].{name:name, lastModified:properties.lastModified}, &lastModified)[-1]"

# 백업 다운로드
LATEST_BACKUP=$(az storage blob list \
  --account-name bloberry01 \
  --container-name backups \
  --prefix petclinic- \
  --query "sort_by([].name, &[-1])" -o tsv | tail -1)

az storage blob download \
  --account-name bloberry01 \
  --container-name backups \
  --name $LATEST_BACKUP \
  --file /tmp/petclinic-backup.sql

# 데이터 복구
mysql -h $AZURE_MYSQL_HOST -u $AZURE_MYSQL_USER -p${DB_PASSWORD} petclinic < /tmp/petclinic-backup.sql
```

---

## 3단계: Azure AKS에 PetClinic 배포

### 3.1 AKS 자격증명 구성

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency

# AKS 자격증명 가져오기
az aks get-credentials \
  --resource-group rg-blue \
  --name $(terraform output -raw aks_cluster_name) \
  --overwrite-merge

# 컨텍스트 전환
kubectl config use-context $(terraform output -raw aks_cluster_name)

# 노드 확인
kubectl get nodes
```

### 3.2 PetClinic 배포

```bash
# Namespace 생성
kubectl create namespace petclinic

# MySQL 연결 정보를 ConfigMap으로 생성
kubectl create configmap petclinic-config -n petclinic \
  --from-literal=MYSQL_HOST=$(terraform output -raw mysql_fqdn) \
  --from-literal=MYSQL_PORT=3306 \
  --from-literal=MYSQL_DATABASE=$(terraform output -raw mysql_database_name)

# MySQL 비밀번호를 Secret으로 생성
kubectl create secret generic petclinic-secret -n petclinic \
  --from-literal=MYSQL_USER=$(terraform output -raw mysql_admin_username) \
  --from-literal=MYSQL_PASSWORD=${DB_PASSWORD}

# PetClinic Deployment 생성
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petclinic
  namespace: petclinic
spec:
  replicas: 2
  selector:
    matchLabels:
      app: petclinic
  template:
    metadata:
      labels:
        app: petclinic
    spec:
      containers:
      - name: petclinic
        image: springcommunity/spring-petclinic:latest
        ports:
        - containerPort: 8080
        env:
        - name: SPRING_PROFILES_ACTIVE
          value: mysql
        - name: SPRING_DATASOURCE_URL
          value: jdbc:mysql://\$(MYSQL_HOST):\$(MYSQL_PORT)/\$(MYSQL_DATABASE)
        - name: SPRING_DATASOURCE_USERNAME
          valueFrom:
            secretKeyRef:
              name: petclinic-secret
              key: MYSQL_USER
        - name: SPRING_DATASOURCE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: petclinic-secret
              key: MYSQL_PASSWORD
        envFrom:
        - configMapRef:
            name: petclinic-config
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
EOF

# Service 생성 (ClusterIP)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: petclinic
  namespace: petclinic
spec:
  type: ClusterIP
  selector:
    app: petclinic
  ports:
  - port: 80
    targetPort: 8080
EOF

# 배포 상태 확인
kubectl rollout status deployment/petclinic -n petclinic
kubectl get pods -n petclinic
```

---

## 4단계: Application Gateway를 AKS로 연결

### 4.1 AKS Service의 Private IP 확인

```bash
# PetClinic Service의 ClusterIP 확인
PETCLINIC_IP=$(kubectl get svc petclinic -n petclinic -o jsonpath='{.spec.clusterIP}')
echo "PetClinic ClusterIP: $PETCLINIC_IP"
```

### 4.2 Application Gateway Backend Pool 업데이트

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency

# Application Gateway 이름 확인
APPGW_NAME=$(terraform output -raw appgw_name)
APPGW_RG="rg-blue"

# 기존 Backend Pool 업데이트 (Blob Storage → AKS Service)
az network application-gateway address-pool update \
  --resource-group $APPGW_RG \
  --gateway-name $APPGW_NAME \
  --name blob-backend-pool \
  --servers $PETCLINIC_IP

# HTTP Settings 업데이트 (HTTPS → HTTP)
az network application-gateway http-settings update \
  --resource-group $APPGW_RG \
  --gateway-name $APPGW_NAME \
  --name blob-http-settings \
  --port 80 \
  --protocol Http \
  --probe health-probe

# Health Probe 업데이트
az network application-gateway probe update \
  --resource-group $APPGW_RG \
  --gateway-name $APPGW_NAME \
  --name health-probe \
  --protocol Http \
  --path / \
  --host-name-from-http-settings false \
  --host $PETCLINIC_IP
```

### 4.3 Application Gateway 테스트

```bash
# Application Gateway Public IP 확인
APPGW_PUBLIC_IP=$(terraform output -raw appgw_public_ip)
echo "Application Gateway IP: $APPGW_PUBLIC_IP"

# HTTP 테스트
curl -I http://$APPGW_PUBLIC_IP

# 정상 응답 확인 (200 OK 및 PetClinic HTML)
curl http://$APPGW_PUBLIC_IP | grep -i "petclinic"
```

---

## 5단계: CloudFront Secondary Origin 전환

### 5.1 CloudFront Distribution Config 백업

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/route53

CLOUDFRONT_ID=$(terraform output -raw cloudfront_distribution_id)

# 현재 설정 백업
aws cloudfront get-distribution-config \
  --id $CLOUDFRONT_ID \
  --query 'DistributionConfig' > /tmp/cloudfront-config-backup.json
```

### 5.2 Secondary Origin을 App Gateway로 변경

```bash
# Application Gateway Public IP 가져오기
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
APPGW_IP=$(terraform output -raw appgw_public_ip)

# CloudFront 설정 업데이트
cd /home/ubuntu/3tier-terraform/codes/aws/route53
CLOUDFRONT_ID=$(terraform output -raw cloudfront_distribution_id)

# Python으로 설정 수정
aws cloudfront get-distribution-config --id $CLOUDFRONT_ID --query 'DistributionConfig' | \
python3 -c "
import json
import sys

config = json.load(sys.stdin)

# Secondary Origin의 DomainName을 App Gateway IP로 변경
for origin in config['Origins']['Items']:
    if origin['Id'] == 'secondary-azure':
        origin['DomainName'] = '$APPGW_IP'
        origin['CustomOriginConfig']['OriginProtocolPolicy'] = 'http-only'
        origin['CustomOriginConfig']['HTTPPort'] = 80
        print(f\"Updated secondary origin to {origin['DomainName']}\", file=sys.stderr)

json.dump(config, sys.stdout, indent=2)
" > /tmp/cloudfront-config-appgw.json

# CloudFront 업데이트
ETAG=$(aws cloudfront get-distribution-config --id $CLOUDFRONT_ID --query 'ETag' --output text)

aws cloudfront update-distribution \
  --id $CLOUDFRONT_ID \
  --distribution-config file:///tmp/cloudfront-config-appgw.json \
  --if-match "$ETAG"
```

### 5.3 CloudFront 배포 대기

```bash
# CloudFront 배포 상태 확인 (약 5-10분 소요)
watch -n 10 "aws cloudfront get-distribution --id $CLOUDFRONT_ID --query 'Distribution.Status'"

# 또는 스크립트로 대기
while true; do
  STATUS=$(aws cloudfront get-distribution --id $CLOUDFRONT_ID --query 'Distribution.Status' --output text)
  echo "CloudFront Status: $STATUS"
  if [ "$STATUS" = "Deployed" ]; then
    echo "CloudFront updated successfully!"
    break
  fi
  sleep 20
done
```

---

## 6단계: 서비스 전환 확인

### 6.1 도메인 접속 테스트

```bash
# 도메인으로 접속 테스트
curl -L https://blueisthenewblack.store | grep -i "petclinic"

# 응답 헤더 확인
curl -I https://blueisthenewblack.store
```

**예상 결과:**
- Status: 200 OK
- PetClinic HTML 응답
- Server: CloudFront

### 6.2 CloudFront 캐시 무효화 (필요 시)

```bash
# CloudFront 캐시 전체 무효화
aws cloudfront create-invalidation \
  --distribution-id $CLOUDFRONT_ID \
  --paths "/*"
```

### 6.3 End-to-End 테스트

브라우저에서 접속하여 확인:
1. `https://blueisthenewblack.store` 접속
2. PetClinic 홈페이지 정상 표시 확인
3. "Find Owners" 메뉴에서 데이터 조회 확인 (DB 연결 확인)
4. 새 Owner 추가 테스트 (DB 쓰기 확인)

---

## 7단계: AWS 복구 시 Rollback 절차

### 7.1 AWS EKS 노드 복구

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/service

# EKS 노드 그룹 스케일업
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name blue-web-nodes \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --region ap-northeast-2

# 노드 복구 대기
kubectl get nodes -w
```

### 7.2 CloudFront Secondary Origin 원복

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/route53
CLOUDFRONT_ID=$(terraform output -raw cloudfront_distribution_id)

# Blob Storage로 원복
aws cloudfront get-distribution-config --id $CLOUDFRONT_ID --query 'DistributionConfig' | \
python3 -c "
import json
import sys

config = json.load(sys.stdin)

for origin in config['Origins']['Items']:
    if origin['Id'] == 'secondary-azure':
        origin['DomainName'] = 'bloberry01.z12.web.core.windows.net'
        origin['CustomOriginConfig']['OriginProtocolPolicy'] = 'https-only'
        origin['CustomOriginConfig']['HTTPSPort'] = 443

json.dump(config, sys.stdout, indent=2)
" > /tmp/cloudfront-config-rollback.json

ETAG=$(aws cloudfront get-distribution-config --id $CLOUDFRONT_ID --query 'ETag' --output text)

aws cloudfront update-distribution \
  --id $CLOUDFRONT_ID \
  --distribution-config file:///tmp/cloudfront-config-rollback.json \
  --if-match "$ETAG"
```

### 7.3 정상 서비스 확인

```bash
# AWS ALB로 정상 응답 확인
curl -I https://blueisthenewblack.store

# Primary Origin (AWS) 사용 확인
# X-Cache: Hit from cloudfront (캐시 히트)
# X-Cache: Miss from cloudfront (Primary에서 새로 가져옴)
```

---

## 트러블슈팅

### CloudFront 400 에러 발생 시

**원인**: CloudFront가 `Host` 헤더를 Secondary Origin으로 전달
**해결**:
```bash
# CloudFront 설정에서 Host 헤더 제거
# (이미 적용되어 있어야 함)
```

### Application Gateway 502 에러

**원인**: Backend Pool이 AKS Service에 연결되지 않음
**해결**:
```bash
# AKS Service ClusterIP 재확인
kubectl get svc petclinic -n petclinic

# Backend Pool 재설정
az network application-gateway address-pool update \
  --resource-group rg-blue \
  --gateway-name appgw-blue \
  --name blob-backend-pool \
  --servers <CORRECT_CLUSTER_IP>
```

### Azure MySQL 연결 실패

**원인**: 방화벽 규칙 미설정
**해결**:
```bash
# AKS Subnet CIDR 확인
az network vnet subnet show \
  --resource-group rg-blue \
  --vnet-name vnet-blue \
  --name snet-aks \
  --query addressPrefix -o tsv

# 방화벽 규칙 추가
az mysql flexible-server firewall-rule create \
  --resource-group rg-blue \
  --name mysql-dr-blue \
  --rule-name allow-aks \
  --start-ip-address <SUBNET_START> \
  --end-ip-address <SUBNET_END>
```

---

## 요약

### 정상 운영 → 장기 DR 전환 체크리스트

- [ ] Azure 2-emergency 배포 완료
- [ ] Azure MySQL 데이터 복구 완료
- [ ] Azure AKS PetClinic 배포 완료
- [ ] Application Gateway → AKS 연결 완료
- [ ] Application Gateway HTTP 테스트 성공
- [ ] CloudFront Secondary Origin을 App Gateway로 변경
- [ ] CloudFront 배포 완료 (Status: Deployed)
- [ ] 도메인 접속 테스트 성공
- [ ] End-to-End 기능 테스트 완료

### DR 복구 → 정상 운영 복귀 체크리스트

- [ ] AWS EKS 노드 그룹 복구
- [ ] AWS ALB 정상 응답 확인
- [ ] CloudFront Secondary Origin을 Blob Storage로 원복
- [ ] CloudFront 배포 완료
- [ ] Primary Origin(AWS) 정상 사용 확인
- [ ] Azure 리소스 정리 (선택사항)

---

## 참고 자료

- CloudFront Origin Failover: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/high_availability_origin_failover.html
- Azure Application Gateway: https://learn.microsoft.com/en-us/azure/application-gateway/
- Azure AKS: https://learn.microsoft.com/en-us/azure/aks/
