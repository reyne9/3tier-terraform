# 트러블슈팅 가이드

## 목차
- [1. AWS 관련 문제](#1-aws-관련-문제)
  - [1.1 AWS Load Balancer Controller 설치 실패](#11-aws-load-balancer-controller-설치-실패)
  - [1.2 WAS Pod CrashLoopBackOff](#12-was-pod-crashloopbackoff)
  - [1.3 ALB 생성 안됨](#13-alb-생성-안됨)
  - [1.4 Route53 DNS 전파 안됨](#14-route53-dns-전파-안됨)
- [2. Azure 관련 문제](#2-azure-관련-문제)
  - [2.1 Azure 백업 복구 실패](#21-azure-백업-복구-실패)
- [3. 백업 관련 문제](#3-백업-관련-문제)
  - [3.1 MySQL 백업 연결 문제](#31-mysql-백업-연결-문제)
- [4. Terraform 배포 관련 문제]

- [5. Kubernetes 배포 관련 문제]

- [6. Route53 및 DNS 관련 문제]


---

## 1. AWS 관련 문제

### 1.1 AWS Load Balancer Controller 설치 실패

#### 증상
```
aws-load-balancer-controller   0/2     0            0
```

#### 원인
- ServiceAccount가 없음
- IAM Role 설정 오류
- OIDC Provider 미설정

#### 해결
```bash
cd ~/3tier-terraform/codes/aws/service

# 1. 변수 확인
export CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Cluster: $CLUSTER_NAME"
echo "Account: $ACCOUNT_ID"

# 2. OIDC Provider 설정
eksctl utils associate-iam-oidc-provider \
  --region ap-northeast-2 \
  --cluster $CLUSTER_NAME \
  --approve

# 3. IAM Policy 확인/생성
if ! aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy &>/dev/null; then
    curl -o /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file:///tmp/iam-policy.json
fi

# 4. ServiceAccount 수동 생성
export OIDC_PROVIDER=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region ap-northeast-2 \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

export ROLE_NAME="AWSLoadBalancerControllerRole-$(date +%s)"

cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy

export ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

# 5. Deployment 재시작
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system

# 6. 확인
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 1.2 WAS Pod CrashLoopBackOff

#### 증상
```
was-spring-xxx   0/1     CrashLoopBackOff
```

#### 원인
- DB 연결 실패 (비밀번호 불일치)
- RDS 보안 그룹 설정 오류

#### 해결
```bash
# 1. Pod 로그 확인
kubectl logs -n was -l app=was-spring --tail=100

# 2. Secret 확인
kubectl get secret db-credentials -n was -o jsonpath='{.data.password}' | base64 -d
echo

# 3. 비밀번호가 틀렸다면 Secret 재생성
kubectl delete secret db-credentials -n was

export RDS_HOST=$(cd ~/3tier-terraform/codes/aws/service && terraform output -raw rds_address)

kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://${RDS_HOST}:3306/petclinic" \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was

# 4. Deployment 재시작
kubectl rollout restart deployment was-spring -n was

# 5. 로그 확인
kubectl logs -f deployment/was-spring -n was
```

### 1.3 ALB 생성 안됨

#### 증상
```
web-ingress   alb     *                 80      10m
```
(ADDRESS 비어있음)

#### 원인
- Public Subnet 태그 누락
- HTTPS 설정 오류 (리스너 443 없음)

#### 해결
```bash
# 1. Ingress 로그 확인
kubectl describe ingress web-ingress -n web

kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# 2. Public Subnet 태그 추가
cd ~/3tier-terraform/codes/aws/service
export VPC_ID=$(terraform output -raw vpc_id)
export CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
export PUBLIC_SUBNET_IDS=$(terraform output -json public_subnet_ids | jq -r '.[]')

for SUBNET_ID in $PUBLIC_SUBNET_IDS; do
  echo "Tagging subnet: $SUBNET_ID"
  aws ec2 create-tags \
    --resources $SUBNET_ID \
    --tags \
      Key=kubernetes.io/role/elb,Value=1 \
      Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared
done

# 3. HTTPS 설정 확인 (ingress.yaml)
# certificate-arn이 올바른지 확인
kubectl get ingress web-ingress -n web -o yaml | grep certificate-arn

# 4. Ingress 재생성
kubectl delete ingress web-ingress -n web
sleep 30
kubectl apply -f k8s-manifests/ingress/ingress.yaml

# 5. ALB 생성 확인
kubectl get ingress web-ingress -n web -w
```

### 1.4 Route53 DNS 전파 안됨

#### 증상
```bash
dig yourdomain.com
# ANSWER: 0
```

#### 원인
- 도메인 등록 업체 네임서버 미변경
- Hosted Zone ID 불일치

#### 해결
```bash
# 1. Route53 네임서버 확인
aws route53 get-hosted-zone \
  --id $(cd ~/3tier-terraform/codes/aws/route53 && terraform output -raw route53_zone_id) \
  --query 'DelegationSet.NameServers'

# 2. 도메인 등록 업체에서 네임서버 확인
whois yourdomain.com | grep -i "name server"

# 3. 일치하지 않으면 도메인 등록 업체 사이트에서 네임서버 변경

# 4. DNS 전파 대기
# 5. 임시로 /etc/hosts 사용
dig $(kubectl get ingress web-ingress -n web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') +short
# ALB IP 확인 후
echo "ALB_IP yourdomain.com" | sudo tee -a /etc/hosts
```

---

## 2. Azure 관련 문제

### 2.1 Azure 백업 복구 실패

#### 증상
```
ERROR: Backup file not found
```

#### 원인
- Storage Account Key 불일치
- Container 이름 오류

#### 해결
```bash
# 1. Storage Account 확인
az storage account show \
  --name drbackupprod2024 \
  --query 'name'

# 2. Container 확인
az storage container show \
  --account-name drbackupprod2024 \
  --name mysql-backups

# 3. 백업 파일 확인
az storage blob list \
  --account-name drbackupprod2024 \
  --container-name mysql-backups \
  --output table

# 4. 수동 복구
LATEST_BACKUP=$(az storage blob list \
  --account-name drbackupprod2024 \
  --container-name mysql-backups \
  --query "sort_by([].name, &properties.lastModified)[-1]" \
  --output tsv)

az storage blob download \
  --account-name drbackupprod2024 \
  --container-name mysql-backups \
  --name "$LATEST_BACKUP" \
  --file /tmp/backup.sql.gz

gunzip /tmp/backup.sql.gz

mysql -h $(cd ~/3tier-terraform/codes/azure/2-emergency && terraform output -raw mysql_fqdn) \
  -u mysqladmin -p < /tmp/backup.sql
```

---

## 3. 백업 관련 문제

### 3.1 MySQL 백업 연결 문제

#### 문제 원인

`-p` 옵션 뒤에 바로 비밀번호를 붙여야 하는데, 공백이 있거나 환경변수가 제대로 설정되지 않았을 수 있음

#### 해결 방법

##### 1단계: 환경변수 재설정

```bash
# RDS 엔드포인트 확인 (로컬 터미널에서)
cd ~/3tier-terraform/PlanB/aws
terraform output rds_address
```

**백업 인스턴스에 접속해서:**

```bash
# SSM으로 접속
aws ssm start-session --target i-0155f8568e2ed335d
```

**백업 인스턴스 내부에서:**

```bash
# RDS 정보 수동 설정
export RDS_HOST="blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com"
export DB_USERNAME="admin"
export DB_PASSWORD="CHANGE_ME_DB_PASSWORD"

echo "RDS Host: $RDS_HOST"
echo "DB Username: $DB_USERNAME"
```

##### 2단계: MySQL 연결 테스트 (여러 방법)

**방법 1: 비밀번호를 직접 붙여서 입력**
```bash
mysql -h "$RDS_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "SELECT 1;"
```

**방법 2: 비밀번호 프롬프트 사용**
```bash
mysql -h "$RDS_HOST" -u "$DB_USERNAME" -p
# Enter password: CHANGE_ME_DB_PASSWORD
```

**방법 3: 변수 없이 직접 입력**
```bash
mysql -h blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com -u admin -pCHANGE_ME_DB_PASSWORD -e "SELECT 1;"
```

**방법 4: 설정 파일 사용**
```bash
# MySQL 설정 파일 생성
cat > ~/.my.cnf <<EOF
[client]
host=blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com
user=admin
password=CHANGE_ME_DB_PASSWORD
EOF

chmod 600 ~/.my.cnf

# 간단하게 연결
mysql -e "SELECT 1;"
```

##### 3단계: 연결 성공 후 데이터베이스 확인

```bash
# 데이터베이스 목록
mysql -h "$RDS_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "SHOW DATABASES;"

# petclinic 데이터베이스 확인
mysql -h "$RDS_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "USE petclinic; SHOW TABLES;"
```

##### 4단계: 백업 스크립트 생성 (연결 성공 후)

```bash
# Secrets Manager에서 Azure 자격증명 가져오기
export REGION="ap-northeast-2"

# Secret ARN 찾기
export SECRET_ARN=$(aws secretsmanager list-secrets \
    --region $REGION \
    --query "SecretList[?contains(Name, 'backup-credentials-blue')].ARN | [0]" \
    --output text)

echo "Secret ARN: $SECRET_ARN"

# Secret 내용 가져오기
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" \
    --region $REGION \
    --query SecretString \
    --output text)

# Azure 자격증명 추출
export AZURE_STORAGE_ACCOUNT=$(echo $SECRET_JSON | jq -r '.azure_storage_account')
export AZURE_STORAGE_KEY=$(echo $SECRET_JSON | jq -r '.azure_storage_key')
export AZURE_CONTAINER="mysql-backups"

echo "Azure Storage Account: $AZURE_STORAGE_ACCOUNT"
```

##### 5단계: 백업 스크립트 생성

```bash
# 디렉토리 생성
sudo mkdir -p /opt/mysql-backup

# 백업 스크립트 생성
sudo tee /usr/local/bin/mysql-backup-to-azure.sh > /dev/null <<'SCRIPT_EOF'
#!/bin/bash
# MySQL → Azure Blob Storage 백업 스크립트

set -e

LOG_FILE="/var/log/mysql-backup-to-azure.log"
exec >> $LOG_FILE 2>&1

echo "=========================================="
echo "백업 시작: $(date)"
echo "=========================================="

# 환경 변수
RDS_HOST="blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com"
DB_NAME="petclinic"
DB_USERNAME="admin"
DB_PASSWORD="CHANGE_ME_DB_PASSWORD"
AZURE_STORAGE_ACCOUNT="bloberry01"
AZURE_STORAGE_KEY="AZURE_KEY_HERE"
AZURE_CONTAINER="mysql-backups"

# 백업 파일명
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/opt/mysql-backup"
BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.sql"
COMPRESSED_FILE="$BACKUP_FILE.gz"

# 1. MySQL Dump
echo "[1/3] MySQL Dump 실행..."
mysqldump \
    -h $RDS_HOST \
    -u $DB_USERNAME \
    -p"$DB_PASSWORD" \
    --single-transaction \
    --skip-lock-tables \
    --routines \
    --triggers \
    --events \
    --set-gtid-purged=OFF \
    --databases $DB_NAME \
    > $BACKUP_FILE

BACKUP_SIZE=$(du -h $BACKUP_FILE | cut -f1)
echo "Dump 완료: $BACKUP_FILE ($BACKUP_SIZE)"

# 2. 압축
echo "[2/3] 파일 압축..."
gzip -f $BACKUP_FILE
COMPRESSED_SIZE=$(du -h $COMPRESSED_FILE | cut -f1)
echo "압축 완료: $COMPRESSED_FILE ($COMPRESSED_SIZE)"

# 3. Azure Blob Storage 업로드
echo "[3/3] Azure Blob Storage 업로드..."
az storage blob upload \
    --account-name $AZURE_STORAGE_ACCOUNT \
    --account-key "$AZURE_STORAGE_KEY" \
    --container-name $AZURE_CONTAINER \
    --name "backups/backup-$TIMESTAMP.sql.gz" \
    --file $COMPRESSED_FILE \
    --overwrite

echo "Azure 업로드 완료: backups/backup-$TIMESTAMP.sql.gz"

# 4. 로컬 정리
echo "[4/4] 로컬 파일 정리..."
find $BACKUP_DIR -name "backup-*.sql.gz" -mtime +1 -delete
echo "로컬 정리 완료"

echo "백업 완료: $(date)"
echo "=========================================="
echo ""
SCRIPT_EOF

# Azure Storage Key를 실제 값으로 치환
sudo sed -i "s|YOUR_AZURE_STORAGE_KEY|$AZURE_STORAGE_KEY|g" /usr/local/bin/mysql-backup-to-azure.sh

# 실행 권한 부여
sudo chmod +x /usr/local/bin/mysql-backup-to-azure.sh
```

##### 6단계: 첫 백업 테스트

```bash
# 백업 스크립트 실행
sudo /usr/local/bin/mysql-backup-to-azure.sh

# 로그 확인
sudo tail -f /var/log/mysql-backup-to-azure.log

# 출력 예시:
# ==========================================
# 백업 시작: Sun Dec 21 21:03:14 UTC 2025
# ==========================================
# [1/3] MySQL Dump 실행...
# Dump 완료: /opt/mysql-backup/backup-20251221-210314.sql (45M)
# [2/3] 파일 압축...
# 압축 완료: /opt/mysql-backup/backup-20251221-210314.sql.gz (12M)
# [3/3] Azure Blob Storage 업로드...
# Azure 업로드 완료: backups/backup-20251221-210314.sql.gz
# [4/4] 로컬 파일 정리...
# 로컬 정리 완료
# 백업 완료: Sun Dec 21 21:03:18 UTC 2025
```

##### 7단계: Cron 설정

```bash
# 5분마다 백업 (테스트)
echo "*/5 * * * * /usr/local/bin/mysql-backup-to-azure.sh" | sudo crontab -

# Cron 확인
sudo crontab -l
```

##### 8단계: Azure Blob Storage 백업 확인

**로컬 터미널에서:**

```bash
az storage blob list \
  --account-name bloberry01 \
  --container-name mysql-backups \
  --output table
```

##### 추가 트러블슈팅

만약 계속 연결이 안된다면:

```bash
# 포트 연결 테스트
nc -zv $RDS_HOST 3306

# DNS 조회
nslookup $RDS_HOST

# 보안 그룹 재확인 (로컬 터미널)
aws ec2 describe-security-groups \
  --group-ids sg-xxxxx \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`3306`]'
```

---


## 4. Terraform 배포 관련 문제

### 4.1 AWS Secrets Manager 리소스 충돌

#### 증상
```
Error: creating Secrets Manager Secret (backup-credentials-blue): 
operation error Secrets Manager: CreateSecret, api error 
InvalidRequestException: You can't create this secret because a secret 
with this name is already scheduled for deletion.
```

#### 원인
- 이전에 삭제된 Secret이 복구 대기 기간(7-30일) 중
- 같은 이름의 Secret을 즉시 재생성 불가능

#### 해결방법

**방법 1: 강제 삭제 후 재생성**
```bash
# 강제 삭제 (복구 불가능)
aws secretsmanager delete-secret \
  --secret-id backup-credentials-blue \
  --force-delete-without-recovery \
  --region ap-northeast-2

# Terraform 재실행
terraform apply
```

**방법 2: 리소스 이름 변경**
```bash
# backup-instance.tf 수정
# 기존: name = "backup-credentials-${var.environment}"
# 변경: name = "backup-credentials-${var.environment}-v2"

# 또는 terraform.tfvars에서 environment 변경
# environment = "blue-v2"
```

**방법 3: 기존 Secret 복구 후 Import**
```bash
# Secret 복구
aws secretsmanager restore-secret \
  --secret-id backup-credentials-blue \
  --region ap-northeast-2

# Terraform state로 import
terraform import aws_secretsmanager_secret.backup_credentials backup-credentials-blue
```

---

### 4.2 IAM Role 이미 존재 오류

#### 증상
```
Error: creating IAM Role (AmazonEKSClusterRole-blue): 
EntityAlreadyExists: Role with name AmazonEKSClusterRole-blue already exists.
```

#### 원인
- 이전 배포에서 생성된 IAM 역할이 남아있음
- Terraform state와 실제 AWS 리소스 불일치

#### 해결방법

**방법 1: 기존 역할 삭제**
```bash
# 연결된 정책 확인
aws iam list-attached-role-policies --role-name AmazonEKSClusterRole-blue

# 정책 분리
aws iam detach-role-policy \
  --role-name AmazonEKSClusterRole-blue \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# 역할 삭제
aws iam delete-role --role-name AmazonEKSClusterRole-blue
```

**방법 2: Import 후 재사용**
```bash
# 기존 역할을 Terraform state로 가져오기
terraform import aws_iam_role.eks_cluster AmazonEKSClusterRole-blue
terraform import aws_iam_role.eks_node AmazonEKSNodeRole-blue
```

**방법 3: 역할 이름 변경**
```bash
# modules/eks/main.tf 수정
resource "aws_iam_role" "eks_cluster" {
  name = "AmazonEKSClusterRole-${var.environment}-${random_id.suffix.hex}"
  # ...
}
```

---

### 4.3 NAT Gateway EIP 연결 충돌

#### 증상
```
Error: creating EC2 NAT Gateway: operation error EC2: CreateNatGateway, 
InvalidElasticIpID.InUse: The Elastic IP address 'eipalloc-xxx' is 
already associated.
```

#### 원인
- EIP가 이미 다른 NAT Gateway에 연결되어 있음
- 이전 배포의 리소스가 완전히 삭제되지 않음

#### 해결방법

**방법 1: EIP 연결 해제 후 삭제**
```bash
# EIP 연결 상태 확인
aws ec2 describe-addresses --allocation-ids eipalloc-xxx

# NAT Gateway 삭제
aws ec2 delete-nat-gateway --nat-gateway-id nat-xxx

# 5분 대기 (NAT Gateway 삭제 완료)
sleep 300

# EIP 해제
aws ec2 disassociate-address --association-id eipassoc-xxx

# EIP 삭제
aws ec2 release-address --allocation-id eipalloc-xxx
```

**방법 2: Terraform 강제 재생성**
```bash
# NAT Gateway 리소스 삭제
terraform state rm module.vpc.aws_nat_gateway.main

# EIP 리소스 삭제
terraform state rm module.vpc.aws_eip.nat

# 재생성
terraform apply
```

---

### 4.4 Subnet 삭제 실패 (의존성 문제)

#### 증상
```
Error: deleting EC2 Subnet (subnet-xxx): DependencyViolation: 
The subnet 'subnet-xxx' has dependencies and cannot be deleted.
```

#### 원인
- ENI (Elastic Network Interface)가 서브넷에 남아있음
- Lambda, NAT Gateway, Load Balancer 등이 ENI 사용 중

#### 해결방법

**자동 정리 스크립트**
```bash
#!/bin/bash
# cleanup-subnet-dependencies.sh

VPC_ID="vpc-03ef812b69212db97"
REGION="ap-northeast-2"

echo "=== ENI 정리 시작 ==="

# 1. Lambda ENI 찾기 및 삭제
echo "[1/5] Lambda ENI 삭제..."
for ENI_ID in $(aws ec2 describe-network-interfaces \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=description,Values=AWS Lambda VPC ENI*" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text); do
  echo "  삭제: $ENI_ID"
  aws ec2 delete-network-interface --region $REGION --network-interface-id $ENI_ID || true
done

# 2. NAT Gateway 삭제
echo "[2/5] NAT Gateway 삭제..."
for NAT_GW in $(aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query 'NatGateways[*].NatGatewayId' \
  --output text); do
  echo "  삭제: $NAT_GW"
  aws ec2 delete-nat-gateway --region $REGION --nat-gateway-id $NAT_GW
done

# 3. VPN Connection 삭제
echo "[3/5] VPN Connection 삭제..."
for VPN_CONN in $(aws ec2 describe-vpn-connections \
  --region $REGION \
  --filters "Name=state,Values=available" \
  --query 'VpnConnections[*].VpnConnectionId' \
  --output text); do
  echo "  삭제: $VPN_CONN"
  aws ec2 delete-vpn-connection --region $REGION --vpn-connection-id $VPN_CONN
done

# 4. 10분 대기 (리소스 삭제 완료)
echo "[4/5] 10분 대기 중..."
sleep 600

# 5. 남은 ENI 강제 삭제
echo "[5/5] 남은 ENI 강제 삭제..."
for ENI_ID in $(aws ec2 describe-network-interfaces \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text); do
  echo "  강제 삭제: $ENI_ID"
  aws ec2 delete-network-interface --region $REGION --network-interface-id $ENI_ID 2>/dev/null || true
done

echo "=== 정리 완료 ==="
```

---

### 4.5 Internet Gateway Detach 실패

#### 증상
```
Error: detaching EC2 Internet Gateway (igw-xxx): DependencyViolation: 
Network vpc-xxx has some mapped public address(es). 
Please unmap those public address(es) before detaching the gateway.
```

#### 원인
- VPC에 Elastic IP가 남아있음
- NAT Gateway, Load Balancer 등이 EIP 사용 중

#### 해결방법

```bash
#!/bin/bash
# cleanup-eip.sh

REGION="ap-northeast-2"

echo "=== Elastic IP 정리 ==="

# 1. 모든 EIP 확인
echo "[1/3] EIP 목록 확인..."
aws ec2 describe-addresses \
  --region $REGION \
  --query 'Addresses[*].[PublicIp,AllocationId,AssociationId]' \
  --output table

# 2. 연결 해제
echo "[2/3] EIP 연결 해제..."
for ASSOC_ID in $(aws ec2 describe-addresses \
  --region $REGION \
  --query 'Addresses[?AssociationId!=`null`].AssociationId' \
  --output text); do
  echo "  해제: $ASSOC_ID"
  aws ec2 disassociate-address --region $REGION --association-id $ASSOC_ID || true
done

# 3. EIP 릴리스
echo "[3/3] EIP 릴리스..."
for ALLOC_ID in $(aws ec2 describe-addresses \
  --region $REGION \
  --query 'Addresses[*].AllocationId' \
  --output text); do
  echo "  릴리스: $ALLOC_ID"
  aws ec2 release-address --region $REGION --allocation-id $ALLOC_ID || true
done

echo "=== EIP 정리 완료 ==="
```

---

### 4.6 IAM User 삭제 실패

#### 증상
```
Error: deleting IAM User (azure-vm-s3-access-prod): DeleteConflict: 
Cannot delete entity, must delete policies first.
```

#### 원인
- IAM User에 정책이 연결되어 있음
- Access Key가 남아있음

#### 해결방법

```bash
#!/bin/bash
# cleanup-iam-user.sh

USER_NAME="azure-vm-s3-access-prod"

echo "=== IAM User 정리: $USER_NAME ==="

# 1. Inline Policy 삭제
echo "[1/4] Inline Policy 삭제..."
for POLICY in $(aws iam list-user-policies --user-name $USER_NAME --query 'PolicyNames[]' --output text); do
  echo "  삭제: $POLICY"
  aws iam delete-user-policy --user-name $USER_NAME --policy-name $POLICY
done

# 2. Managed Policy 분리
echo "[2/4] Managed Policy 분리..."
for POLICY_ARN in $(aws iam list-attached-user-policies --user-name $USER_NAME --query 'AttachedPolicies[*].PolicyArn' --output text); do
  echo "  분리: $POLICY_ARN"
  aws iam detach-user-policy --user-name $USER_NAME --policy-arn $POLICY_ARN
done

# 3. Access Key 삭제
echo "[3/4] Access Key 삭제..."
for KEY_ID in $(aws iam list-access-keys --user-name $USER_NAME --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
  echo "  삭제: $KEY_ID"
  aws iam delete-access-key --user-name $USER_NAME --access-key-id $KEY_ID
done

# 4. User 삭제
echo "[4/4] User 삭제..."
aws iam delete-user --user-name $USER_NAME

echo "=== IAM User 삭제 완료 ==="
```

---

## 5. Kubernetes 배포 관련 문제

### 5.1 ServiceAccount 생성 시 DNS 해석 실패

#### 증상
```
Error: unable to recognize "sa.yaml": Get 
"https://FEACDB00987EE9F39E4D7139AF69127D.gr7.ap-northeast-2.eks.amazonaws.com/...": 
dial tcp: lookup FEACDB00987EE9F39E4D7139AF69127D.gr7.ap-northeast-2.eks.amazonaws.com: 
no such host
```

#### 원인
- EKS 클러스터 엔드포인트가 DNS에 전파되지 않음
- 클러스터 생성 직후 발생 (1-2분 소요)

#### 해결방법

**방법 1: kubeconfig 재생성**
```bash
# kubeconfig 업데이트
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw eks_cluster_name)

# 클러스터 상태 확인
kubectl cluster-info

# 재시도
kubectl apply -f sa.yaml
```

**방법 2: DNS 캐시 초기화**
```bash
# systemd-resolved 재시작 (Ubuntu/Debian)
sudo systemctl restart systemd-resolved

# DNS 캐시 삭제
sudo resolvectl flush-caches

# 직접 DNS 조회 테스트
nslookup FEACDB00987EE9F39E4D7139AF69127D.gr7.ap-northeast-2.eks.amazonaws.com
```

**방법 3: 수동 대기 후 재시도**
```bash
# 2분 대기
sleep 120

# ServiceAccount 생성
kubectl apply -f sa.yaml
```

**방법 4: validation 비활성화 (임시)**
```bash
# OpenAPI validation 비활성화
kubectl apply -f sa.yaml --validate=false

# Helm으로 설치하는 경우
helm install aws-load-balancer-controller ... --wait --timeout 2m
```

---

### 5.2 WAS Pod CrashLoopBackOff (DB 연결 실패)

#### 증상
```
was-spring-xxx   0/1     CrashLoopBackOff   5   10m
```

#### 원인
- DB 비밀번호 불일치
- RDS 보안 그룹 설정 오류
- RDS 엔드포인트 잘못 설정

#### 해결방법

**1단계: Pod 로그 확인**
```bash
# 로그 확인
kubectl logs -n was -l app=was-spring --tail=100

# 에러 패턴 확인
# "Access denied for user 'admin'@'xxx'" -> 비밀번호 문제
# "Communications link failure" -> 네트워크 문제
# "Unknown database 'petclinic'" -> 데이터베이스 없음
```

**2단계: Secret 확인 및 재생성**
```bash
# 현재 Secret 확인
kubectl get secret db-credentials -n was -o jsonpath='{.data.password}' | base64 -d
echo

# Secret 삭제
kubectl delete secret db-credentials -n was

# RDS 정보 확인
cd ~/3tier-terraform/PlanB/aws
export RDS_HOST=$(terraform output -raw rds_address)
echo "RDS Host: $RDS_HOST"

# Secret 재생성
kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://${RDS_HOST}:3306/petclinic" \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was

# Deployment 재시작
kubectl rollout restart deployment was-spring -n was

# 로그 확인
kubectl logs -f deployment/was-spring -n was
```

**3단계: RDS 보안 그룹 확인**
```bash
# RDS 보안 그룹 ID 확인
export RDS_SG=$(aws rds describe-db-instances \
  --db-instance-identifier $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw rds_identifier) \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text)

# EKS 노드 보안 그룹 ID 확인
export NODE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=*node*" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "RDS SG: $RDS_SG"
echo "Node SG: $NODE_SG"

# MySQL 포트(3306) 인바운드 규칙 추가
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp \
  --port 3306 \
  --source-group $NODE_SG

# 규칙 확인
aws ec2 describe-security-groups --group-ids $RDS_SG
```

---

### 5.3 ALB 생성 안됨 (Subnet 태그 누락)

#### 증상
```bash
kubectl get ingress web-ingress -n web
# NAME          CLASS   HOSTS   ADDRESS   PORTS   AGE
# web-ingress   alb     *                 80      10m
```
(ADDRESS가 비어있음)

#### 원인
- Public Subnet에 필수 태그가 없음
- `kubernetes.io/role/elb` 태그 누락

#### 해결방법

**1단계: Ingress 로그 확인**
```bash
# Ingress 상세 정보
kubectl describe ingress web-ingress -n web

# AWS Load Balancer Controller 로그
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# 에러 패턴:
# "unable to resolve at least 2 subnets" -> Subnet 태그 문제
# "no matching subnets found" -> Public Subnet 없음
```

**2단계: Subnet 태그 추가**
```bash
cd ~/3tier-terraform/PlanB/aws
export VPC_ID=$(terraform output -raw vpc_id)
export CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
export PUBLIC_SUBNET_IDS=$(terraform output -json public_subnet_ids | jq -r '.[]')

# 각 Public Subnet에 태그 추가
for SUBNET_ID in $PUBLIC_SUBNET_IDS; do
  echo "Tagging subnet: $SUBNET_ID"
  aws ec2 create-tags \
    --resources $SUBNET_ID \
    --tags \
      Key=kubernetes.io/role/elb,Value=1 \
      Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared
done

# 태그 확인
aws ec2 describe-subnets --subnet-ids $PUBLIC_SUBNET_IDS --query 'Subnets[*].[SubnetId,Tags]'
```

**3단계: Ingress 재생성**
```bash
# Ingress 삭제
kubectl delete ingress web-ingress -n web

# 30초 대기 (ALB 완전 삭제)
sleep 30

# Ingress 재생성
kubectl apply -f k8s-manifests/ingress/ingress.yaml

# ALB 생성 모니터링
kubectl get ingress web-ingress -n web -w
```

---

### 5.4 HTTPS 연결 실패 (Security Group 443 포트 누락)

#### 증상
```bash
curl https://yourdomain.com
# curl: (7) Failed to connect to yourdomain.com port 443: Connection timed out
```

#### 원인
- ALB Security Group에 443 포트 인바운드 규칙 없음

#### 해결방법

```bash
# ALB Security Group ID 확인
export ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$(cd ~/3tier-terraform/PlanB/aws && terraform output -raw eks_cluster_name)" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

echo "ALB SG: $ALB_SG"

# HTTPS (443) 인바운드 규칙 추가
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0

# 규칙 확인
aws ec2 describe-security-groups \
  --group-ids $ALB_SG \
  --query 'SecurityGroups[0].IpPermissions'

# HTTPS 접속 테스트
curl -I https://yourdomain.com
```

---

## 6. Route53 및 DNS 관련 문제

### 6.1 ACM 인증서 검증 지연

#### 증상
```
aws_acm_certificate.main: Still creating... [18m20s elapsed]
```

#### 원인
- DNS 네임서버가 Route53으로 변경되지 않음
- 도메인 등록 업체에서 네임서버 미변경

#### 해결방법

**1단계: Route53 네임서버 확인**
```bash
# Hosted Zone 네임서버 확인
aws route53 get-hosted-zone \
  --id $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw route53_zone_id) \
  --query 'DelegationSet.NameServers'

# 출력 예시:
# [
#   "ns-123.awsdns-12.com",
#   "ns-456.awsdns-45.net",
#   "ns-789.awsdns-78.org",
#   "ns-012.awsdns-01.co.uk"
# ]
```

**2단계: 도메인 등록 업체 네임서버 확인**
```bash
# 현재 네임서버 확인
whois yourdomain.com | grep -i "name server"

# 또는
dig NS yourdomain.com +short
```

**3단계: 네임서버 변경 (도메인 등록 업체 사이트)**
- Gabia, Cafe24, AWS Route53 등 로그인
- 도메인 관리 > 네임서버 설정
- Route53 네임서버 4개 모두 입력

**4단계: DNS 전파 확인**
```bash
# 여러 DNS 서버에서 확인
dig @8.8.8.8 yourdomain.com NS
dig @1.1.1.1 yourdomain.com NS

# 전파 상태 체크 (웹)
# https://dnschecker.org

# ACM 검증 레코드 확인
dig _xxx.yourdomain.com CNAME +short
```

---

### 6.2 Route53 Failover 동작 안함

#### 증상
```bash
# AWS ALB가 정상인데도 Azure로 트래픽 전송
dig yourdomain.com +short
# 4.218.19.57 (Azure IP)
```

#### 원인
- Primary Health Check 설정 오류
- 잘못된 엔드포인트 설정 (도메인 대신 ALB DNS 사용)

#### 해결방법

**1단계: Health Check 상태 확인**
```bash
# Primary Health Check 상태
aws route53 get-health-check-status \
  --health-check-id $(cd ~/3tier-terraform/PlanB/aws && terraform output -json route53_health_check_ids | jq -r '.primary')

# 출력 예시:
# "Status": "Failure",  <- 문제!
# "StatusReport": {
#   "CheckedTime": "...",
#   "Status": "Failure"
# }
```

**2단계: Health Check 설정 확인**
```bash
# Health Check 상세 정보
aws route53 get-health-check \
  --health-check-id $(cd ~/3tier-terraform/PlanB/aws && terraform output -json route53_health_check_ids | jq -r '.primary')

# ResourcePath와 FullyQualifiedDomainName 확인
# 잘못된 예: FullyQualifiedDomainName = "k8s-web-xxx.elb.amazonaws.com"
# 올바른 예: FullyQualifiedDomainName = "yourdomain.com"
```

**3단계: route53.tf 수정**
```hcl
# route53.tf

# Primary Health Check (잘못된 설정)
resource "aws_route53_health_check" "primary" {
  fqdn              = local.alb_dns_name  # <- 문제!
  port              = 443
  type              = "HTTPS_STR_MATCH"
  resource_path     = "/"
  request_interval  = 30
  failure_threshold = 3
  measure_latency   = false
  search_string     = "PetClinic"
}

# Primary Health Check (올바른 설정)
resource "aws_route53_health_check" "primary" {
  fqdn              = var.domain_name  # <- 수정!
  port              = 80               # HTTP로 변경
  type              = "HTTP"           # HTTPS_STR_MATCH 제거
  resource_path     = "/"
  request_interval  = 30
  failure_threshold = 3
  measure_latency   = false
}
```

**4단계: Terraform 재적용**
```bash
cd ~/3tier-terraform/PlanB/aws
terraform apply

# Health Check 상태 재확인
aws route53 get-health-check-status \
  --health-check-id $(terraform output -json route53_health_check_ids | jq -r '.primary')

# "Status": "Success" 확인
```

---

### 6.3 브라우저 DNS 캐싱 문제

#### 증상
- 다른 브라우저에서는 정상 페이지 표시
- 기존 브라우저에서 유지보수 페이지 계속 표시

#### 원인
- 브라우저 DNS 캐시
- Route53 TTL(60초) 만료 전 DNS 조회

#### 해결방법

**Chrome**
```
chrome://net-internals/#dns
-> "Clear host cache" 클릭
```

**Firefox**
```
about:networking#dns
-> "Clear DNS Cache" 클릭
```

**Safari**
```
# 개발자 메뉴 활성화 후
개발자 > 캐시 비우기
```

**Linux 시스템 DNS 캐시**
```bash
# systemd-resolved
sudo systemd-resolve --flush-caches
sudo systemctl restart systemd-resolved

# nscd
sudo /etc/init.d/nscd restart

# dnsmasq
sudo /etc/init.d/dnsmasq restart
```

**확인**
```bash
# DNS 조회 (캐시 무시)
dig yourdomain.com +short @8.8.8.8

# 웹 접속 (캐시 무시)
curl -H "Cache-Control: no-cache" https://yourdomain.com
```

---

## 7. 백업 관련 문제

### 7.1 MySQL 백업 연결 실패 (RDS)

#### 증상
```bash
mysql -h $RDS_HOST -u $DB_USERNAME -p$DB_PASSWORD
# ERROR 2003 (HY000): Can't connect to MySQL server on 'xxx' (110)
```

#### 원인
- RDS 보안 그룹에 백업 인스턴스 IP 미허용
- RDS Public Access 비활성화

#### 해결방법

**1단계: 백업 인스턴스 보안 그룹 ID 확인**
```bash
# 백업 인스턴스 정보
aws ec2 describe-instances \
  --instance-ids $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw backup_instance_id) \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text

export BACKUP_SG=sg-xxx
```

**2단계: RDS 보안 그룹에 인바운드 규칙 추가**
```bash
# RDS 보안 그룹 ID
export RDS_SG=$(aws rds describe-db-instances \
  --db-instance-identifier $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw rds_identifier) \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text)

echo "RDS SG: $RDS_SG"
echo "Backup SG: $BACKUP_SG"

# MySQL(3306) 인바운드 규칙 추가
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp \
  --port 3306 \
  --source-group $BACKUP_SG

# 확인
aws ec2 describe-security-groups --group-ids $RDS_SG
```

**3단계: 연결 테스트**
```bash
# SSM으로 백업 인스턴스 접속
aws ssm start-session --target $(cd ~/3tier-terraform/PlanB/aws && terraform output -raw backup_instance_id)

# MySQL 연결 테스트
mysql -h $RDS_HOST -u admin -pCHANGE_ME_DB_PASSWORD -e "SELECT 1;"
```

---

### 7.2 mysqldump 권한 오류 (RDS)

#### 증상
```bash
mysqldump: Got error: 1045: Access denied for user 'admin'@'%' (using password: YES)
when executing 'FLUSH TABLES WITH READ LOCK'
```

또는

```bash
mysqldump: Couldn't execute 'FLUSH TABLES WITH READ LOCK':
Access denied for user 'admin'@'%' (using password: YES) (1045)
```

#### 원인
- RDS admin 계정은 SUPER 권한이 없음
- `--single-transaction` 옵션이 내부적으로 FLUSH TABLES WITH READ LOCK을 시도함
- RDS MySQL 8.0+에서는 GTID 관련 추가 권한 필요

#### 해결방법

**방법 1: mysqldump 옵션 수정 (권장)**

`--set-gtid-purged=OFF` 옵션을 추가하면 GTID 관련 권한 문제 해결:

```bash
# 올바른 옵션 조합
mysqldump -h $RDS_HOST \
  -u admin -pCHANGE_ME_DB_PASSWORD \
  --databases petclinic \
  --single-transaction \
  --set-gtid-purged=OFF \
  --routines \
  --triggers \
  --events \
  | gzip > /tmp/backup.sql.gz
```

**주요 옵션 설명:**
- `--single-transaction`: InnoDB 테이블에 대해 일관된 백업 (테이블 락 없이)
- `--set-gtid-purged=OFF`: GTID 정보를 백업에 포함하지 않음 (RDS SUPER 권한 불필요)
- `--skip-lock-tables`: 명시적 테이블 락 비활성화 (선택사항, --single-transaction과 함께 사용 시)

**방법 2: 백업 스크립트 영구 수정**

Terraform 코드를 수정하여 향후 백업 인스턴스 생성 시 자동 적용:

```bash
# codes/aws/2. service/scripts/backup-init.sh 수정
# Line 162-172 부분

mysqldump \
    -h $RDS_HOST \
    -u $DB_USERNAME \
    -p"$RDS_PASSWORD" \
    --single-transaction \
    --set-gtid-purged=OFF \    # 이 줄 추가
    --routines \
    --triggers \
    --events \
    --databases $DB_NAME \
    > $BACKUP_FILE
```

**방법 3: 기존 백업 인스턴스 스크립트 수정**

이미 실행 중인 백업 인스턴스에서 직접 수정:

```bash
# SSM으로 백업 인스턴스 접속
aws ssm start-session --target i-0066dc51da5528f0f

# 백업 스크립트 편집
sudo vi /usr/local/bin/mysql-backup-to-azure.sh

# mysqldump 부분 찾아서 수정:
# --single-transaction 다음 줄에 추가
# --set-gtid-purged=OFF \

# 또는 sed로 자동 수정:
sudo sed -i 's/--single-transaction/--single-transaction --set-gtid-purged=OFF/g' \
  /usr/local/bin/mysql-backup-to-azure.sh

# 수정 확인
grep -A 5 "mysqldump" /usr/local/bin/mysql-backup-to-azure.sh

# 백업 테스트 실행
sudo /usr/local/bin/mysql-backup-to-azure.sh

# 로그 확인
sudo tail -f /var/log/mysql-backup-to-azure.log
```

**참고: 다른 옵션들과의 차이**

```bash
# ❌ 잘못된 조합 (권한 에러 발생)
mysqldump --single-transaction

# ❌ 데이터 정합성 문제 가능
mysqldump --skip-lock-tables

# ✅ 권장 (RDS에서 안전하고 일관된 백업)
mysqldump --single-transaction --set-gtid-purged=OFF
```

#### 추가 트러블슈팅

**1. 여전히 권한 에러 발생 시**

RDS 사용자 권한 확인:

```bash
# 백업 인스턴스에서 실행
mysql -h $RDS_HOST -u admin -pCHANGE_ME_DB_PASSWORD -e "SHOW GRANTS FOR 'admin'@'%';"
```

필요한 권한:
- SELECT
- RELOAD (FLUSH TABLES용)
- LOCK TABLES
- SHOW VIEW
- EVENT
- TRIGGER

**2. 백업 성공 확인**

```bash
# 백업 파일 크기 확인
ls -lh /opt/mysql-backup/

# Azure Blob Storage 업로드 확인
az storage blob list \
  --account-name bloberry01 \
  --container-name mysql-backups \
  --prefix "backups/" \
  --output table
```

**3. Cron 로그 모니터링**

```bash
# Cron 작업 확인
sudo crontab -l

# 백업 로그 실시간 모니터링
sudo tail -f /var/log/mysql-backup-to-azure.log

# 최근 백업 결과만 확인
sudo tail -50 /var/log/mysql-backup-to-azure.log | grep -A 10 "백업 시작"
```

---

### 7.3 Azure Blob Storage 업로드 실패

#### 증상
```bash
az storage blob upload ... 
# Error: The specified container does not exist.
```

#### 원인
- Container 이름 오류
- Storage Account Key 불일치

#### 해결방법

**1단계: Storage Account 확인**
```bash
# Azure 로그인
az login

# Storage Account 존재 확인
az storage account show \
  --name drbackupprod2024 \
  --query 'name' \
  --output tsv
```

**2단계: Container 확인 및 생성**
```bash
# Container 목록
az storage container list \
  --account-name drbackupprod2024 \
  --output table

# Container 생성 (없는 경우)
az storage container create \
  --account-name drbackupprod2024 \
  --name mysql-backups \
  --public-access off
```

**3단계: Storage Key 재확인**
```bash
# Key 조회
az storage account keys list \
  --account-name drbackupprod2024 \
  --query "[0].value" \
  --output tsv

# 백업 인스턴스에서 환경변수 업데이트
export AZURE_STORAGE_KEY="새로운키"
```

---

## 8. Azure 관련 문제

### 8.1 Azure CLI 인증 실패 (백업 인스턴스)

#### 증상
```bash
az storage blob upload ...
# Error: Please run 'az login' to setup account.
```

#### 원인
- Service Principal 인증 정보 누락
- 환경변수 미설정

#### 해결방법

**1단계: Service Principal 생성 (로컬)**
```bash
# Azure 로그인
az login

# Service Principal 생성
az ad sp create-for-rbac \
  --name "backup-sp-$(date +%s)" \
  --role "Storage Blob Data Contributor" \
  --scopes /subscriptions/$(az account show --query id -o tsv)

# 출력 저장:
# {
#   "appId": "xxx",
#   "password": "yyy",
#   "tenant": "zzz"
# }
```

**2단계: 백업 인스턴스에 인증 정보 설정**
```bash
# SSM으로 접속
aws ssm start-session --target i-xxx

# 환경변수 설정
export AZURE_CLIENT_ID="appId"
export AZURE_CLIENT_SECRET="password"
export AZURE_TENANT_ID="tenant"

# 로그인
az login --service-principal \
  -u $AZURE_CLIENT_ID \
  -p $AZURE_CLIENT_SECRET \
  --tenant $AZURE_TENANT_ID

# 업로드 테스트
az storage blob upload \
  --account-name drbackupprod2024 \
  --container-name mysql-backups \
  --name test.txt \
  --file /tmp/test.txt
```

---

### 8.2 AKS kubectl 접속 실패

#### 증상
```bash
kubectl get nodes
# Unable to connect to the server: dial tcp: lookup xxx: no such host
```

#### 원인
- kubeconfig 미설정
- AKS 클러스터 미배포

#### 해결방법

**1단계: AKS 클러스터 확인**
```bash
# AKS 클러스터 존재 확인
az aks show \
  --resource-group rg-dr-blue \
  --name aks-dr-blue \
  --query 'name' \
  --output tsv
```

**2단계: kubeconfig 설정**
```bash
# AKS credentials 가져오기
az aks get-credentials \
  --resource-group rg-dr-blue \
  --name aks-dr-blue \
  --overwrite-existing

# 컨텍스트 확인
kubectl config current-context

# 노드 확인
kubectl get nodes
```

---

### 8.3 Application Gateway TLS 정책 오류

#### 증상
```
Error: creating Application Gateway: unexpected status 400 (400 Bad Request)
with error: ApplicationGatewayDeprecatedTlsVersionUsedInSslPolicy:
The TLS policy AppGwSslPolicy20150501 for Application Gateway is using
a deprecated TLS version.
```

#### 원인
- Application Gateway의 기본 TLS 정책이 deprecated됨
- `ssl_policy` 블록이 명시적으로 설정되지 않아 기본값 사용

#### 해결방법

**codes/azure/2-emergency/main.tf 수정**
```hcl
resource "azurerm_application_gateway" "main" {
  name                = "appgw-${var.environment}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  # ... 다른 설정 ...

  # SSL Policy 추가
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"  # TLS 1.2+ 지원
  }

  tags = var.tags
}
```

**지원되는 TLS 정책**:
- `AppGwSslPolicy20220101` - TLS 1.2+ (권장)
- `AppGwSslPolicy20170401S` - TLS 1.2+ Strict
- `AppGwSslPolicy20220101S` - TLS 1.2+ Strict (최신)

---

### 8.4 Application Gateway Backend Pool 참조 오류

#### 증상
```
Error: updating Application Gateway: unexpected status 400 (400 Bad Request)
with error: InvalidResourceReference: Resource backendAddressPools/aks-backend-pool
referenced by requestRoutingRules/http-routing-rule was not found.
```

#### 원인
- Terraform lifecycle의 `ignore_changes`가 backend pool 변경을 무시
- Backend pool 이름 변경 시 routing rule이 새 pool을 찾지 못함

#### 해결방법

**1단계: lifecycle ignore_changes 제거**
```hcl
resource "azurerm_application_gateway" "main" {
  # ... 설정 ...

  tags = var.tags

  # 문제가 되는 부분 제거
  # lifecycle {
  #   ignore_changes = [
  #     backend_address_pool,
  #     backend_http_settings,
  #     probe
  #   ]
  # }
}
```

**2단계: Terraform 재적용**
```bash
cd codes/azure/2-emergency
terraform apply
```

**참고**: `ignore_changes`는 수동으로 backend를 변경할 계획이 있을 때만 사용하세요.

---

### 8.5 AKS PetClinic Pod CrashLoopBackOff (MySQL 연결 실패)

#### 증상
```bash
kubectl get pods -n petclinic
# NAME                         READY   STATUS             RESTARTS
# petclinic-5974c78cd-c7dvf   0/1     CrashLoopBackOff   38
```

#### 원인
- MySQL 방화벽에 AKS outbound IP가 허용되지 않음
- `Communications link failure` 오류 발생

#### 해결방법

**1단계: Pod 로그 확인**
```bash
kubectl logs petclinic-5974c78cd-c7dvf -n petclinic --tail=50

# 오류 확인:
# Caused by: com.mysql.cj.exceptions.CJCommunicationsException:
# Communications link failure
```

**2단계: AKS Outbound IP 확인**
```bash
# AKS의 나가는 IP 확인
az aks show -g rg-dr-blue -n aks-dr-blue \
  --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id" \
  -o tsv

# Public IP 주소 조회
az network public-ip show --ids <IP_RESOURCE_ID> \
  --query ipAddress -o tsv
```

**3단계: MySQL 방화벽 규칙 추가**
```bash
# AKS outbound IP를 MySQL 방화벽에 추가
az mysql flexible-server firewall-rule create \
  -g rg-dr-blue \
  -n mysql-dr-blue \
  --rule-name AllowAKS \
  --start-ip-address <AKS_OUTBOUND_IP> \
  --end-ip-address <AKS_OUTBOUND_IP>

# 예시:
az mysql flexible-server firewall-rule create \
  -g rg-dr-blue \
  -n mysql-dr-blue \
  --rule-name AllowAKS \
  --start-ip-address 20.249.162.115 \
  --end-ip-address 20.249.162.115
```

**4단계: PetClinic 재시작**
```bash
kubectl rollout restart deployment petclinic -n petclinic

# Pod 상태 확인
kubectl get pods -n petclinic -w
```

**5단계: 연결 확인**
```bash
# Pod 로그에서 성공 메시지 확인
kubectl logs -f deployment/petclinic -n petclinic | grep "Started"

# 출력 예시:
# Started PetClinicApplication in 16.159 seconds
```

---

### 8.6 CloudFront Origin Failover POST/PUT/DELETE 메서드 제한

#### 증상
```
Error: The parameter AllowedMethods cannot include POST, PUT, PATCH, or DELETE
for a cached behavior associated with an origin group.
```

#### 원인
- CloudFront Origin Group(failover)은 캐시 가능한 요청(GET, HEAD)만 지원
- POST, PUT, DELETE 등 비캐시 메서드는 Origin Group과 함께 사용 불가

#### 해결방법

**방법 1: Origin Group 제거 (수동 failover)**

```bash
# CloudFront 설정 가져오기
aws cloudfront get-distribution-config --id E2OX3Z0XHNDUN > /tmp/cf-config.json

# Python 스크립트로 수정
cat > /tmp/remove-origin-group.py << 'EOF'
import json

with open('/tmp/cf-config.json', 'r') as f:
    data = json.load(f)

config = data['DistributionConfig']
etag = data['ETag']

# Origin Group 제거
config['OriginGroups'] = {
    "Quantity": 0,
    "Items": []
}

# 단일 origin 사용
config['DefaultCacheBehavior']['TargetOriginId'] = 'primary-aws-alb'

# 모든 HTTP 메서드 허용
config['DefaultCacheBehavior']['AllowedMethods'] = {
    "Quantity": 7,
    "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
    "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
    }
}

with open('/tmp/cf-config-updated.json', 'w') as f:
    json.dump(config, f)

print(f"ETag: {etag}")
EOF

python3 /tmp/remove-origin-group.py

# CloudFront 업데이트
aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file:///tmp/cf-config-updated.json \
  --if-match <ETAG>
```

**방법 2: 캐싱 완전 비활성화**

```bash
# CachingDisabled 정책 사용
cat > /tmp/update-cache-policy.py << 'EOF'
import json

with open('/tmp/cf-config.json', 'r') as f:
    data = json.load(f)

config = data['DistributionConfig']

# CachingDisabled 관리형 정책 적용
config['DefaultCacheBehavior']['CachePolicyId'] = '4135ea2d-6df8-44a3-9df3-4b5a84be39ad'

# ForwardedValues 제거 (CachePolicy 사용 시 불필요)
if 'ForwardedValues' in config['DefaultCacheBehavior']:
    del config['DefaultCacheBehavior']['ForwardedValues']

with open('/tmp/cf-config-nocache.json', 'w') as f:
    json.dump(config, f)
EOF

python3 /tmp/update-cache-policy.py
```

**참고**: Origin Group 제거 시 자동 failover가 불가능하므로, 장애 시 수동으로 origin을 변경해야 합니다.

---

### 8.7 CloudFront Secondary Origin으로 수동 전환

#### 배경
Origin Group을 제거한 후, AWS 장애 시 수동으로 Azure로 전환해야 함

#### 절차

**1단계: Application Gateway DNS 이름 설정**
```bash
# Public IP에 DNS 레이블 추가
az network public-ip update \
  -g rg-dr-blue \
  -n pip-appgw-blue \
  --dns-name appgw-blue-dr

# FQDN 확인
az network public-ip show \
  -g rg-dr-blue \
  -n pip-appgw-blue \
  --query "dnsSettings.fqdn" -o tsv

# 출력: appgw-blue-dr.koreacentral.cloudapp.azure.com
```

**2단계: CloudFront Origin을 Azure로 전환**
```bash
# 현재 설정 가져오기
aws cloudfront get-distribution-config \
  --id E2OX3Z0XHNDUN > /tmp/cf-switch.json

# Python으로 origin 변경
cat > /tmp/switch-to-azure.py << 'EOF'
import json

with open('/tmp/cf-switch.json', 'r') as f:
    data = json.load(f)

config = data['DistributionConfig']
etag = data['ETag']

# Secondary origin으로 전환
config['DefaultCacheBehavior']['TargetOriginId'] = 'secondary-azure'

with open('/tmp/cf-azure.json', 'w') as f:
    json.dump(config, f)

print(f"ETag: {etag}")
EOF

python3 /tmp/switch-to-azure.py

# CloudFront 업데이트
aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file:///tmp/cf-azure.json \
  --if-match <ETAG>
```

**3단계: 배포 완료 대기**
```bash
# 배포 상태 확인 (5-10분 소요)
while true; do
  STATUS=$(aws cloudfront get-distribution --id E2OX3Z0XHNDUN --query "Distribution.Status" --output text)
  echo "Status: $STATUS"
  if [ "$STATUS" = "Deployed" ]; then
    break
  fi
  sleep 15
done
```

**4단계: 접속 확인**
```bash
# 도메인으로 접속 테스트
curl -I https://blueisthenewblack.store/

# 출력에서 확인:
# HTTP/2 200
# x-cache: Miss from cloudfront
```

---

### 8.8 Application Gateway Backend IP 하드코딩 문제

#### 증상
Terraform 코드에서 AKS LoadBalancer IP가 하드코딩되어 있음

```hcl
backend_address_pool {
  name         = local.backend_address_pool_name
  ip_addresses = ["20.214.124.157"]  # 하드코딩!
}
```

#### 문제점
- AKS Service가 재생성되면 LoadBalancer IP 변경 가능
- 수동으로 IP 업데이트 필요
- 자동화 불가능

#### 해결방법 (권장)

**방법 1: Data Source로 동적 조회**

```hcl
# AKS Service 정보를 data source로 가져오기
data "kubernetes_service" "petclinic" {
  metadata {
    name      = "petclinic"
    namespace = "petclinic"
  }

  depends_on = [
    kubernetes_service.petclinic
  ]
}

# Application Gateway Backend Pool
resource "azurerm_application_gateway" "main" {
  # ...

  backend_address_pool {
    name         = local.backend_address_pool_name
    ip_addresses = [
      data.kubernetes_service.petclinic.status[0].load_balancer[0].ingress[0].ip
    ]
  }
}
```

**방법 2: 외부 스크립트로 자동 업데이트**

```bash
#!/bin/bash
# update-appgw-backend.sh

# AKS LoadBalancer IP 조회
AKS_LB_IP=$(kubectl get svc petclinic -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Application Gateway Backend Pool 업데이트
az network application-gateway address-pool update \
  -g rg-dr-blue \
  --gateway-name appgw-blue \
  -n aks-backend-pool \
  --servers $AKS_LB_IP

echo "Backend updated to: $AKS_LB_IP"
```

**방법 3: Terraform null_resource로 자동화**

```hcl
resource "null_resource" "update_appgw_backend" {
  triggers = {
    petclinic_service = kubernetes_service.petclinic.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      LB_IP=$(kubectl get svc petclinic -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
      az network application-gateway address-pool update \
        -g rg-dr-blue \
        --gateway-name appgw-blue \
        -n aks-backend-pool \
        --servers $LB_IP
    EOT
  }

  depends_on = [
    kubernetes_service.petclinic,
    azurerm_application_gateway.main
  ]
}
```

---

## 9. CloudFront 및 Multi-Cloud DR 관련 문제

### 9.1 CloudFront에서 502 Bad Gateway 에러

#### 증상
```bash
curl https://blueisthenewblack.store
# HTTP/2 502
# x-cache: Error from cloudfront
```

#### 원인
CloudFront Origin이 HTTPS로 설정되었지만 ALB의 SSL 인증서가 도메인과 일치하지 않음

#### 해결방법

**1단계: Origin Protocol 확인**
```bash
# CloudFront 설정 확인
aws cloudfront get-distribution-config --id E2OX3Z0XHNDUN \
  --query "DistributionConfig.Origins.Items[?Id=='primary-aws-alb'].CustomOriginConfig.OriginProtocolPolicy" \
  --output text

# 출력: https-only (문제!)
```

**2단계: HTTP로 변경**
```bash
# 설정 다운로드
aws cloudfront get-distribution-config --id E2OX3Z0XHNDUN > /tmp/cf-config.json

# OriginProtocolPolicy를 http-only로 변경
# (JSON 편집기 또는 jq 사용)

# 업데이트
ETAG=$(jq -r '.ETag' /tmp/cf-config.json)
jq '.DistributionConfig' /tmp/cf-config.json > /tmp/cf-update.json

aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file:///tmp/cf-update.json \
  --if-match "$ETAG"
```

---

### 9.2 Web Pod가 Pending 상태 (Node Affinity 불일치)

#### 증상
```bash
kubectl get pods -n web
# NAME                       READY   STATUS    RESTARTS   AGE
# web-nginx-xxx             0/1     Pending   0          5m
```

#### 원인
- Web deployment가 `tier=web` 라벨이 있는 노드를 요구
- 노드 그룹이 존재하지 않거나 스케일이 0으로 설정됨

#### 해결방법

**1단계: Pod 스케줄링 실패 원인 확인**
```bash
kubectl describe pod -n web | grep -A 10 "Events:"

# 출력 예시:
# Warning  FailedScheduling  node(s) didn't match Pod's node affinity/selector
```

**2단계: 노드 그룹 확인**
```bash
# EKS 노드 그룹 목록
aws eks list-nodegroups --cluster-name blue-eks --region ap-northeast-2

# 노드 그룹 상세 정보
aws eks describe-nodegroup \
  --cluster-name blue-eks \
  --nodegroup-name blue-web-nodes \
  --region ap-northeast-2 \
  --query "nodegroup.scalingConfig"

# 출력 예시:
# {
#   "minSize": 0,
#   "maxSize": 1,
#   "desiredSize": 0  <- 문제!
# }
```

**3단계: 노드 그룹 스케일 업**
```bash
# Web 노드 그룹을 2개로 스케일 업
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name blue-web-nodes \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --region ap-northeast-2

# 노드가 Ready 상태가 될 때까지 대기
kubectl get nodes -l tier=web -w
```

**4단계: Pod 상태 확인**
```bash
# Pod가 자동으로 스케줄링됨
kubectl get pods -n web

# 출력:
# NAME                       READY   STATUS    RESTARTS   AGE
# web-nginx-xxx             1/1     Running   0          2m
```

---

### 9.3 ALB에서 404 Not Found (Ingress Host 헤더 문제)

#### 증상
```bash
curl http://k8s-web-webingre-xxx.ap-northeast-2.elb.amazonaws.com
# HTTP/1.1 404 Not Found
```

#### 원인
- Ingress 규칙이 특정 Host 헤더를 요구함
- CloudFront는 Origin의 DNS 이름을 Host 헤더로 전송
- ALB 룰이 `Host: blueisthenewblack.store`만 허용

#### 해결방법

**1단계: ALB 리스너 규칙 확인**
```bash
# ALB ARN 확인
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName, 'k8s-web-webingre')].LoadBalancerArn" \
  --output text)

# 리스너 확인
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[0].ListenerArn" \
  --output text)

# 룰 확인
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[].Conditions[?Field=='host-header']"

# 출력:
# "Values": ["blueisthenewblack.store"]  <- Host 헤더 요구
```

**2단계: Ingress에서 Host 제한 제거**
```yaml
# k8s-manifests/ingress/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: web
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  ingressClassName: alb
  rules:
  - http:  # host 필드 제거
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

**3단계: Ingress 재적용**
```bash
kubectl apply -f k8s-manifests/ingress/ingress.yaml

# ALB 업데이트 대기 (30초)
sleep 30

# 테스트
curl -I http://k8s-web-webingre-xxx.ap-northeast-2.elb.amazonaws.com
# HTTP/1.1 200 OK
```

---

### 9.4 ALB SSL 리다이렉트 루프

#### 증상
```bash
curl http://k8s-web-webingre-xxx.ap-northeast-2.elb.amazonaws.com
# HTTP/1.1 301 Moved Permanently
# Location: https://...
```

CloudFront는 HTTP로 연결하려고 하는데 ALB가 HTTPS로 리다이렉트

#### 원인
Ingress 설정에 `alb.ingress.kubernetes.io/ssl-redirect: '443'` 존재

#### 해결방법

**Ingress에서 SSL 리다이렉트 제거**
```yaml
# k8s-manifests/ingress/ingress.yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'  # HTTPS 제거
    # alb.ingress.kubernetes.io/ssl-redirect: '443' <- 이 줄 삭제
```

```bash
# 적용
kubectl apply -f k8s-manifests/ingress/ingress.yaml

# 테스트
curl -I http://k8s-web-webingre-xxx.ap-northeast-2.elb.amazonaws.com
# HTTP/1.1 200 OK
```

---

### 9.5 CloudFront 캐시 무효화

#### 배경
CloudFront 설정 변경 후에도 이전 응답이 캐시되어 반환될 수 있음

#### 해결방법

```bash
# 모든 캐시 무효화
DISTRIBUTION_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[0].Id" \
  --output text)

aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"

# 무효화 상태 확인
aws cloudfront get-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --id <INVALIDATION_ID>
```

---

### 9.6 Web/WAS 노드 그룹 구성 요약

#### 정상 상태 확인

```bash
# 1. 노드 그룹 확인
kubectl get nodes --show-labels | grep tier

# 출력 예시:
# ip-10-0-11-89   Ready   tier=web
# ip-10-0-12-204  Ready   tier=web
# ip-10-0-21-63   Ready   tier=was
# ip-10-0-22-168  Ready   tier=was

# 2. Pod 배치 확인
kubectl get pods -n web -o wide
kubectl get pods -n was -o wide

# 3. EKS 노드 그룹 스케일 확인
aws eks describe-nodegroup \
  --cluster-name blue-eks \
  --nodegroup-name blue-web-nodes \
  --query "nodegroup.scalingConfig"
```

#### 권장 설정

```bash
# Web 노드 그룹
minSize: 2
maxSize: 4
desiredSize: 2

# WAS 노드 그룹
minSize: 2
maxSize: 4
desiredSize: 2
```

---

## 10. DockerHub 마이그레이션 및 배포 관련 문제 (2025-12-28)

### 10.1 Docker 이미지 빌드 및 푸시

#### 작업 내용
- ECR/ACR에서 DockerHub로 컨테이너 레지스트리 마이그레이션
- DockerHub 계정: cloud039
- 레포지토리: petclinic-web, petclinic-was

#### Docker 권한 문제

**증상**
```bash
docker build -t cloud039/petclinic-web:latest .
# permission denied while trying to connect to the Docker daemon socket
```

**해결방법**
```bash
sudo chmod 666 /var/run/docker.sock
```

### 10.2 EBS CSI Driver 설치 및 IAM 권한 문제

#### 증상
```bash
kubectl get pods -n kube-system | grep ebs-csi-controller
# ebs-csi-controller-xxx   1/6     CrashLoopBackOff
```

**로그**
```
Failed health check: dry-run EC2 API call failed:
no EC2 IMDS role found, operation error ec2imds
```

#### 원인
- EBS CSI Driver가 EBS 볼륨을 생성/연결할 IAM 권한 부족
- ServiceAccount에 IAM Role이 annotate되지 않음

#### 해결방법

**1단계: IAM Role 생성**
```bash
# OIDC Issuer URL 확인
OIDC_URL=$(aws eks describe-cluster --name blue-eks --region ap-northeast-2 \
  --query "cluster.identity.oidc.issuer" --output text)

# Trust Policy 생성
cat > /tmp/ebs-csi-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/${OIDC_URL#https://}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_URL#https://}:aud": "sts.amazonaws.com",
        "${OIDC_URL#https://}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      }
    }
  }]
}
EOF

# IAM Role 생성
aws iam create-role \
  --role-name AmazonEKS_EBS_CSI_DriverRole_blue \
  --assume-role-policy-document file:///tmp/ebs-csi-trust-policy.json

# Policy 연결
aws iam attach-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole_blue \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

**2단계: ServiceAccount Annotate**
```bash
kubectl annotate serviceaccount ebs-csi-controller-sa \
  -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole_blue \
  --overwrite

# Deployment 재시작
kubectl rollout restart deployment ebs-csi-controller -n kube-system
```

### 10.3 WAS Pod CrashLoopBackOff - RDS 연결 실패

#### 증상
```bash
kubectl logs was-spring-xxx -n was
# Access denied for user 'admin'@'10.0.22.108' (using password: YES)
```

#### 원인 1: 잘못된 비밀번호

Secret에 임시값 또는 이전 환경의 비밀번호를 넣으면 RDS 인증이 실패합니다. 실제 운영 비밀번호는 환경변수나 Secret Manager에서 가져와 주입해야 합니다.

**해결방법**
```bash
# Secret 확인
kubectl get secret db-credentials -n was -o yaml

# Secret 재생성
kubectl delete secret db-credentials -n was

kubectl create secret generic db-credentials \
  --from-literal=url=jdbc:mysql://RDS_HOST:3306/petclinic \
  --from-literal=username=admin \
  --from-literal=password="${DB_PASSWORD}" \
  -n was
```

#### 원인 2: RDS 보안 그룹이 WAS 서브넷 차단

WAS Pod IP가 10.0.21.0/24, 10.0.22.0/24인데 RDS 보안 그룹에 이 CIDR 미허용

**해결방법**
```bash
# RDS 보안 그룹에 WAS 서브넷 추가
aws ec2 authorize-security-group-ingress \
  --group-id sg-0b289d03cf95e02e3 \
  --protocol tcp \
  --port 3306 \
  --cidr 10.0.21.0/24

aws ec2 authorize-security-group-ingress \
  --group-id sg-0b289d03cf95e02e3 \
  --protocol tcp \
  --port 3306 \
  --cidr 10.0.22.0/24
```

### 10.4 WAS Pod Readiness Probe 실패

#### 증상
```bash
kubectl get pods -n was
# was-spring-xxx   0/1     Running   0   5m
```

Pod이 Running이지만 Ready 상태로 전환되지 않음

#### 원인
Readiness Probe가 `/` 경로를 확인하는데, Spring Boot Actuator는 `/actuator/health`를 사용

#### 해결방법

**deployment.yaml 수정**
```yaml
# 수정 전
readinessProbe:
  httpGet:
    path: /
    port: 8080

# 수정 후
readinessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
```

### 10.5 Nginx ConfigMap vs Docker 이미지 설정 충돌

#### 증상
ALB를 통해 접속하면 404 반환

#### 원인
- ConfigMap을 `/etc/nginx/conf.d/default.conf`에 마운트
- 실제 Docker 이미지의 nginx.conf는 `/etc/nginx/conf.d/nginx.conf`에 위치
- ConfigMap이 올바르게 적용되지 않음

#### 해결방법

**방법 1: ConfigMap 마운트 경로 수정**
```yaml
volumeMounts:
- name: nginx-config
  mountPath: /etc/nginx/conf.d/nginx.conf  # default.conf → nginx.conf
  subPath: default.conf
```

**방법 2: ConfigMap 마운트 제거 (채택)**
- Docker 이미지 내부의 nginx.conf를 직접 사용
- 이미지 빌드 시 nginx.conf 업데이트

```yaml
# volumeMounts 섹션 제거
# volumes 섹션 제거
```

### 10.6 Nginx 이미지 내 WAS 서비스 이름 오류

#### 증상
```
nginx: [emerg] host not found in upstream "petclinic-was"
```

#### 원인
Docker 이미지의 nginx.conf가 `petclinic-was`를 참조하지만 실제 서비스 이름은 `was-service.was.svc.cluster.local`

#### 해결방법

**nginx.conf 수정**
```nginx
# 수정 전
location /api/ {
  proxy_pass http://petclinic-was:8080/api/;
}

# 수정 후
location /api/ {
  proxy_pass http://was-service.was.svc.cluster.local:8080/api/;
}
```

**Docker 이미지 재빌드**
```bash
cd ~/spring-petclinic/web
docker build -t cloud039/petclinic-web:latest .
docker push cloud039/petclinic-web:latest

# Deployment 재시작
kubectl rollout restart deployment web-nginx -n web
```

### 10.7 WAS Pod 메모리 부족 (Pending)

#### 증상
```bash
kubectl describe pod was-spring-xxx -n was
# 0/4 nodes are available: 2 Insufficient memory
```

#### 원인
WAS Pod이 512Mi 메모리 요청, t3.small 노드(2GB)에 다른 Pod들로 인해 공간 부족

#### 해결방법

**리소스 요청 감소**
```yaml
# 수정 전
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi

# 수정 후
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### 10.8 CloudFront Default Target이 Azure로 설정됨

#### 증상
```bash
curl https://blueisthenewblack.store
# HTTP/2 504
```

CloudFront 배포 완료 후에도 504 Gateway Timeout

#### 원인
```bash
aws cloudfront get-distribution --id E2OX3Z0XHNDUN \
  --query 'Distribution.DistributionConfig.DefaultCacheBehavior.TargetOriginId'
# "secondary-azure"
```

DefaultCacheBehavior가 `secondary-azure`를 가리킴 (Azure Application Gateway)

#### 해결방법

**CloudFront Origin 변경**
```bash
# 설정 가져오기
aws cloudfront get-distribution-config --id E2OX3Z0XHNDUN > /tmp/cf-config.json

# TargetOriginId 변경
jq '.DistributionConfig.DefaultCacheBehavior.TargetOriginId = "primary-aws-alb"' \
  /tmp/cf-config.json > /tmp/cf-updated.json

# 적용
ETAG=$(jq -r '.ETag' /tmp/cf-config.json)
aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file:///tmp/cf-updated.json \
  --if-match "$ETAG"
```

### 10.9 전체 배포 플로우 요약

#### 성공적인 배포 순서

1. **Docker 이미지 빌드 및 푸시** → DockerHub
2. **AWS Load Balancer Controller 설치** → IAM Role + ServiceAccount
3. **EBS CSI Driver 설치** → PVC 생성 가능
4. **DB Secret 생성** → 올바른 비밀번호 사용
5. **RDS 보안 그룹 업데이트** → WAS 서브넷 허용
6. **WAS Deployment 배포** → Health Check 경로 수정
7. **Web Deployment 배포** → ConfigMap 제거, Docker 이미지 사용
8. **Ingress 생성** → ALB 자동 프로비저닝
9. **CloudFront Origin 업데이트** → ALB DNS로 변경
10. **CloudFront Target 수정** → primary-aws-alb로 설정

#### 최종 확인 사항

```bash
# 1. Pod 상태 확인
kubectl get pods -n web
kubectl get pods -n was

# 2. ALB 확인
kubectl get ingress -n web
curl -I http://ALB_DNS/

# 3. CloudFront 확인
aws cloudfront get-distribution --id DIST_ID --query 'Distribution.Status'

# 4. 도메인 접속 확인
curl -I https://blueisthenewblack.store/
```

---

## 11. Azure 2-emergency 배포 관련 문제

### 11.1 Azure MySQL 인증 실패 - "Access denied for user 'admin'"

#### 증상
WAS Pod가 CrashLoopBackOff 상태로 계속 재시작됨
```bash
kubectl get pods -n was
# NAME                          READY   STATUS             RESTARTS   AGE
# was-spring-xxxxx              0/1     CrashLoopBackOff   5          5m
```

로그 확인:
```bash
kubectl logs -n was -l app=was-spring
# java.sql.SQLException: Access denied for user 'admin'@'20.249.156.8' (using password: YES)
# Caused by: java.sql.SQLException: Access denied for user 'admin'@'20.249.156.8'
```

#### 원인
**Azure MySQL Flexible Server는 관리자 사용자명으로 'mysqladmin'을 사용합니다** (AWS RDS의 'admin'과 다름)

Terraform으로 MySQL을 생성할 때 `administrator_login = "mysqladmin"` 으로 설정되지만,
Kubernetes Secret 생성 시 AWS 습관대로 `username=admin`으로 설정하여 인증 실패 발생

#### 해결방법

**1. Azure MySQL 사용자명 확인**
```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency

# Terraform output으로 확인
terraform output -json | jq -r '.db_username.value'
# "mysqladmin"

# 또는 Azure CLI로 확인
az mysql flexible-server show \
  --resource-group rg-dr-blue \
  --name mysql-dr-blue \
  --query administratorLogin -o tsv
# mysqladmin
```

**2. Kubernetes Secret 재생성 (올바른 username 사용)**
```bash
# 기존 Secret 삭제
kubectl delete secret db-credentials -n was

# 올바른 username으로 재생성
kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://mysql-dr-blue.mysql.database.azure.com:3306/petclinic" \
  --from-literal=username="mysqladmin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was

# 확인
kubectl get secret db-credentials -n was -o jsonpath='{.data.username}' | base64 -d
# mysqladmin
```

**3. Pod 재시작**
```bash
kubectl delete pods -n was --all

# 상태 확인 (30초 후)
kubectl get pods -n was
# NAME                          READY   STATUS    RESTARTS   AGE
# was-spring-xxxxx              1/1     Running   0          45s

# 로그 확인
kubectl logs -n was -l app=was-spring | grep -i "started"
# Started PetClinicApplication in 45.2 seconds
```

#### 예방 조치

**Terraform validation 추가** ([codes/azure/2-emergency/variables.tf](/codes/azure/2-emergency/variables.tf)):
```hcl
variable "db_username" {
  description = "MySQL 관리자 사용자명 (Azure MySQL Flexible Server는 'mysqladmin' 사용)"
  type        = string
  default     = "mysqladmin"
  sensitive   = true

  validation {
    condition     = var.db_username == "mysqladmin"
    error_message = "Azure MySQL Flexible Server는 관리자 사용자명으로 'mysqladmin'을 사용해야 합니다. K8s Secret 생성 시 동일한 사용자명을 사용하세요."
  }
}
```

**자동 배포 스크립트 사용** ([codes/azure/2-emergency/scripts/deploy-complete.sh](/codes/azure/2-emergency/scripts/deploy-complete.sh)):
```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
./scripts/deploy-complete.sh
# ✓ Database Secret 생성 완료 (username: mysqladmin)
```

---

### 11.2 Application Gateway 502 Bad Gateway

#### 증상
WAS Pod는 정상 Running이지만 Application Gateway를 통한 접속 시 502 에러 발생
```bash
# WAS Pod 확인
kubectl get pods -n was
# NAME                          READY   STATUS    RESTARTS   AGE
# was-spring-xxxxx              1/1     Running   0          5m

# Application Gateway로 접속 시도
APPGW_IP=$(az network public-ip show \
  --resource-group rg-dr-blue \
  --name pip-appgw-blue \
  --query ipAddress -o tsv)

curl -I http://$APPGW_IP/
# HTTP/1.1 502 Bad Gateway
```

#### 원인
Application Gateway의 backend pool이 **하드코딩된 잘못된 IP**를 가리키고 있음

실제 WAS LoadBalancer IP: `4.230.96.174`
Application Gateway backend IP: `20.214.124.157` (terraform.tfvars의 초기 하드코딩 값)

#### 진단 과정

**1. WAS Service 확인**
```bash
kubectl get svc -n was was-service
# NAME          TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)          AGE
# was-service   LoadBalancer   10.0.123.45    4.230.96.174    8080:30123/TCP   10m
```

**2. Application Gateway Backend 확인**
```bash
az network application-gateway address-pool show \
  --resource-group rg-dr-blue \
  --gateway-name appgw-blue \
  --name aks-backend-pool \
  --query backendAddresses
# [
#   {
#     "ipAddress": "20.214.124.157"
#   }
# ]
```

**3. Backend Health 확인**
```bash
az network application-gateway show-backend-health \
  --resource-group rg-dr-blue \
  --name appgw-blue
# "backendHttpSettingsCollection": [{
#   "backendAddressPool": {
#     "backendIpConfigurations": [{
#       "health": "Unhealthy",
#       "healthProbeLog": "Connection timeout"
#     }]
#   }
# }]
```

#### 해결방법

**1. WAS LoadBalancer External IP 확인**
```bash
WAS_LB_IP=$(kubectl get svc -n was was-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "WAS LoadBalancer IP: $WAS_LB_IP"
# WAS LoadBalancer IP: 4.230.96.174
```

**2. Application Gateway backend pool 업데이트**
```bash
az network application-gateway address-pool update \
  --resource-group rg-dr-blue \
  --gateway-name appgw-blue \
  --name aks-backend-pool \
  --servers $WAS_LB_IP
```

**3. Health probe도 업데이트**
```bash
az network application-gateway probe update \
  --resource-group rg-dr-blue \
  --gateway-name appgw-blue \
  --name health-probe \
  --host $WAS_LB_IP
```

**4. Backend health 재확인 (2-3분 소요)**
```bash
az network application-gateway show-backend-health \
  --resource-group rg-dr-blue \
  --name appgw-blue \
  --query 'backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health'
# "Healthy"
```

**5. 접속 테스트**
```bash
curl -I http://$APPGW_IP/
# HTTP/1.1 200 OK
# Content-Type: text/html;charset=UTF-8

curl http://$APPGW_IP/ | grep -o "PetClinic.*v[0-9.]*"
# PetClinic v3.0
```

#### 예방 조치

**1. Terraform variables에서 default 제거** ([codes/azure/2-emergency/variables.tf](/codes/azure/2-emergency/variables.tf)):
```hcl
variable "backend_ip_addresses" {
  description = "Application Gateway Backend IP 주소 리스트 (WAS LoadBalancer External IP)"
  type        = list(string)
  # AKS 배포 후 WAS service의 External IP를 확인하여 설정:
  # kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}
```

**2. terraform.tfvars.example 업데이트**:
```hcl
# ⚠️ CRITICAL: Application Gateway Backend IP (필수)
# AKS 배포 후 WAS LoadBalancer External IP를 확인하여 설정해야 합니다:
# kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
backend_ip_addresses = ["REPLACE_WITH_WAS_LOADBALANCER_IP"]
```

**3. 자동 업데이트 스크립트 사용**:
```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
./scripts/deploy-complete.sh
# [6/7] WAS LoadBalancer IP 확인 및 Application Gateway 업데이트...
# ✓ WAS LoadBalancer IP: 4.230.96.174
# ✓ Application Gateway 업데이트 완료
```

---

### 11.3 Azure 2-emergency 완전 배포 플로우

#### 성공적인 배포 순서

**1. Terraform 인프라 배포 (15-20분)**
```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
terraform init
terraform plan
terraform apply
# Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
```

**2. AKS credentials 설정**
```bash
RESOURCE_GROUP=$(terraform output -raw resource_group_name)
AKS_NAME=$(terraform output -raw aks_cluster_name)

az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --overwrite-existing

kubectl get nodes
# NAME                                STATUS   ROLES   AGE   VERSION
# aks-web-xxxxx-vmss000000           Ready    agent   5m    v1.34.x
# aks-was-xxxxx-vmss000000           Ready    agent   5m    v1.34.x
```

**3. Kubernetes Namespaces 생성**
```bash
kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace was --dry-run=client -o yaml | kubectl apply -f -
```

**4. Database Secret 생성 (⚠️ CRITICAL: username은 mysqladmin)**
```bash
MYSQL_FQDN=$(terraform output -raw mysql_fqdn)
DB_PASSWORD=$(terraform output -json | jq -r '.db_password.value')

kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://${MYSQL_FQDN}:3306/petclinic" \
  --from-literal=username="mysqladmin" \
  --from-literal=password="${DB_PASSWORD}" \
  --namespace=was \
  --dry-run=client -o yaml | kubectl apply -f -
```

**5. PetClinic 애플리케이션 배포**
```bash
kubectl apply -f k8s-manifests/web/
kubectl apply -f k8s-manifests/was/

# Pod 시작 대기 (60초)
sleep 60

kubectl get pods -n web
kubectl get pods -n was
```

**6. WAS LoadBalancer IP 확인 및 Application Gateway 업데이트**
```bash
# LoadBalancer IP 할당 대기 (최대 3분)
for i in {1..36}; do
    WAS_LB_IP=$(kubectl get svc -n was was-service \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$WAS_LB_IP" ]; then
        echo "✓ WAS LoadBalancer IP: $WAS_LB_IP"
        break
    fi
    echo -n "."
    sleep 5
done

# Application Gateway backend 업데이트
az network application-gateway address-pool update \
  --resource-group "$RESOURCE_GROUP" \
  --gateway-name appgw-blue \
  --name aks-backend-pool \
  --servers "$WAS_LB_IP"

# Health probe 업데이트
az network application-gateway probe update \
  --resource-group "$RESOURCE_GROUP" \
  --gateway-name appgw-blue \
  --name health-probe \
  --host "$WAS_LB_IP"
```

**7. 배포 확인**
```bash
# Application Gateway Public IP 확인
APPGW_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name pip-appgw-blue \
  --query ipAddress -o tsv)

echo "Application Gateway IP: $APPGW_IP"
echo "WAS LoadBalancer IP: $WAS_LB_IP"

# 접근 테스트
curl http://$APPGW_IP/
# 🎯 Multi-Cloud DR Project - v3.0 Production Ready

# Pod 상태 확인
kubectl get pods -n web
kubectl get pods -n was

# 로그 확인
kubectl logs -n was -l app=was-spring | tail -20
```

#### 자동 배포 스크립트

위 모든 과정을 자동화한 스크립트 사용:
```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
chmod +x scripts/deploy-complete.sh
./scripts/deploy-complete.sh

# =========================================
# Azure DR 2-emergency 완전 배포 시작
# =========================================
# [1/7] Terraform 리소스 확인...
# ✓ Terraform 리소스 확인 완료
# [2/7] AKS credentials 설정...
# ✓ AKS credentials 설정 완료
# [3/7] Kubernetes Namespaces 생성...
# ✓ Namespaces 생성 완료
# [4/7] Database Secret 생성...
# ✓ Database Secret 생성 완료 (username: mysqladmin)
# [5/7] PetClinic 애플리케이션 배포...
# ✓ 애플리케이션 배포 완료
# [6/7] WAS LoadBalancer IP 확인 및 Application Gateway 업데이트...
# ✓ WAS LoadBalancer IP: 4.230.96.174
# ✓ Application Gateway 업데이트 완료
# [7/7] 배포 확인...
# =========================================
# 배포 완료!
# =========================================
```

---

### 11.4 Azure vs AWS 주요 차이점

#### MySQL 관리자 사용자명
| 클라우드 | 사용자명 | 설정 방법 |
|---------|---------|----------|
| AWS RDS | `admin` | `username = "admin"` (기본값) |
| Azure MySQL Flexible Server | `mysqladmin` | `administrator_login = "mysqladmin"` |

#### Load Balancer 동작
| 항목 | AWS (ALB) | Azure (Application Gateway) |
|------|-----------|----------------------------|
| 생성 방식 | Ingress Controller가 자동 생성 | Terraform으로 사전 생성 필요 |
| Backend | Target Group (자동 등록) | Backend Pool (수동 IP 등록 필요) |
| Health Check | Target Group 자동 설정 | Health Probe 별도 설정 |
| IP 업데이트 | 불필요 (자동 동기화) | 필요 (LoadBalancer IP 할당 후 수동 업데이트) |

#### Kubernetes Service Type
| 클라우드 | WAS Service Type | 이유 |
|---------|-----------------|------|
| AWS | ClusterIP | ALB Ingress가 ClusterIP로 라우팅 |
| Azure | LoadBalancer | Application Gateway가 외부 IP 필요 |

---

**문서 버전**: v1.7
**최종 수정**: 2026-01-13
**작성자**: I2ST-blue
