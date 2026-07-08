# AWS 2. Service 배포 가이드

## 목차
1. [개요](#개요)
2. [사전 요구사항](#사전-요구사항)
3. [Terraform 인프라 배포](#terraform-인프라-배포)
4. [Kubernetes 애플리케이션 배포](#kubernetes-애플리케이션-배포)
5. [검증 및 확인](#검증-및-확인)
6. [트러블슈팅](#트러블슈팅)

---

## 개요

이 문서는 AWS EKS 기반 3-Tier 애플리케이션 배포 가이드입니다.

### 아키텍처

```
Internet
    ↓
CloudFront (Optional)
    ↓
ALB (Application Load Balancer)
    ↓
┌─────────────────────────────────────┐
│  EKS Cluster                        │
│  ┌──────────┐      ┌──────────┐   │
│  │ Web Tier │  →   │ WAS Tier │   │
│  │ (Nginx)  │      │ (Spring) │   │
│  └──────────┘      └──────────┘   │
└─────────────────────────────────────┘
                ↓
    RDS MySQL (Multi-AZ)
                ↓
    Azure Blob Storage (Backup)
```

### 주요 컴포넌트

- **VPC**: 10.0.0.0/16
- **EKS Cluster**: blue-eks
  - Web Node Group: t3.small × 2
  - WAS Node Group: t3.small × 2
- **RDS**: MySQL 8.0, Multi-AZ, db.t3.medium
- **Backup Instance**: EC2 t3.small (RDS → Azure Blob)
- **ALB**: AWS Load Balancer Controller가 Ingress로부터 자동 생성

---

## 사전 요구사항

### 필수 도구
- Terraform >= 1.14.0
- AWS CLI 설정 완료
- kubectl
- helm
- Azure CLI (백업 확인용)

### AWS 자격증명
```bash
# AWS 계정 확인
aws sts get-caller-identity

# 출력 예시:
# Account: ACCOUNT_ID
# Region: ap-northeast-2
```

### Azure Storage Account
백업용 Azure Blob Storage가 필요합니다:
- Storage Account: `bloberry01`
- Container: `mysql-backups`
- Storage Key는 `terraform.tfvars`에 설정

---

## Terraform 인프라 배포

### 1. 디렉토리 이동
```bash
cd ~/3tier-terraform/codes/aws/2.\ service
```

### 2. terraform.tfvars 확인 및 수정

주요 설정 확인:

```hcl
# 기본 설정
environment = "blue"
aws_region  = "ap-northeast-2"

# Azure 연동 (백업용)
azure_storage_account_name  = "bloberry01"
azure_storage_account_key   = "YOUR_STORAGE_KEY"  # 최신 키로 업데이트 필요
azure_backup_container_name = "mysql-backups"

# 백업 주기
backup_schedule_cron = "0 3 * * *"  # 매일 UTC 03시 (KST 12시)

# 데이터베이스
db_name     = "petclinic"
db_username = "admin"
db_password = "CHANGE_ME_DB_PASSWORD"

# RDS 설정
rds_instance_class = "db.t3.medium"
rds_multi_az       = true
```

**중요**: Azure Storage Key 업데이트
```bash
# 최신 Storage Key 가져오기
az storage account keys list \
  --account-name bloberry01 \
  --resource-group rg-dr-blue \
  --query "[0].value" -o tsv

# terraform.tfvars에 반영
```

### 3. Terraform 실행

```bash
# 초기화
terraform init

# 검증
terraform validate

# 계획 확인
terraform plan

# 배포 (약 20-25분 소요)
terraform apply -auto-approve
```

**배포 시간**:
- VPC & 네트워크: ~2분
- EKS 클러스터: ~10분
- RDS (Multi-AZ): ~20분
- 백업 인스턴스: ~3분

### 4. 출력 정보 확인

```bash
# 주요 출력 정보
terraform output

# 개별 출력
terraform output eks_cluster_name
terraform output rds_endpoint
terraform output backup_instance_id
```

출력 예시:
```
eks_cluster_name = "blue-eks"
eks_cluster_endpoint = "https://F1979D0409812D8A4A45FB4F0879D6E1.gr7.ap-northeast-2.eks.amazonaws.com"
rds_endpoint = "blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com:3306"
backup_instance_id = "i-0066dc51da5528f0f"
```

---

## Kubernetes 애플리케이션 배포

### 1. kubectl 설정

```bash
# EKS 클러스터 연결
aws eks update-kubeconfig --region ap-northeast-2 --name blue-eks

# 확인
kubectl cluster-info
kubectl get nodes
```

노드 상태 확인:
```
NAME                                             STATUS   ROLES    AGE
ip-10-0-11-118.ap-northeast-2.compute.internal   Ready    <none>   15m   # WAS Tier
ip-10-0-12-204.ap-northeast-2.compute.internal   Ready    <none>   15m   # WAS Tier
ip-10-0-21-107.ap-northeast-2.compute.internal   Ready    <none>   15m   # Web Tier
ip-10-0-22-168.ap-northeast-2.compute.internal   Ready    <none>   15m   # Web Tier
```

### 2. AWS Load Balancer Controller 설치

```bash
cd ~/3tier-terraform/codes/aws/2.\ service

# 스크립트 실행 (약 2분 소요)
bash scripts/install-lb-controller.sh
```

설치 확인:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 출력:
# aws-load-balancer-controller-xxx   1/1   Running
# aws-load-balancer-controller-xxx   1/1   Running
```

### 3. Namespace 생성

```bash
cd k8s-manifests

kubectl apply -f namespaces.yaml
```

생성된 namespace:
- `web`: Nginx 웹 서버
- `was`: Spring Boot 애플리케이션

### 4. Database Secret 생성

RDS 연결 정보를 Secret으로 생성:

```bash
# RDS 엔드포인트 가져오기
RDS_ENDPOINT=$(cd .. && terraform output -raw rds_endpoint | cut -d: -f1)

# Secret 생성
kubectl create secret generic db-credentials --namespace=was \
  --from-literal=url="jdbc:mysql://${RDS_ENDPOINT}:3306/petclinic" \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD"
```

Secret 확인:
```bash
kubectl get secret db-credentials -n was
kubectl describe secret db-credentials -n was
```

### 5. WAS Tier 배포

```bash
# WAS 애플리케이션 배포
kubectl apply -f was/

# 배포 확인
kubectl get pods -n was
kubectl get svc -n was
```

**배포되는 리소스**:
- ConfigMap: `was-config`
- Deployment: `was-spring` (Spring Boot)
- Service: `was-service` (ClusterIP)

Pod 상태 확인:
```bash
# Pod 로그 확인
kubectl logs -f deployment/was-spring -n was

# 정상 실행 확인 메시지:
# Started PetclinicApplication in X.XXX seconds
```

### 6. Web Tier 배포

```bash
# Web 애플리케이션 배포
kubectl apply -f web/

# 배포 확인
kubectl get pods -n web
kubectl get svc -n web
```

**배포되는 리소스**:
- ConfigMap: `nginx-config`
- Deployment: `web-nginx` (Nginx)
- Service: `web-service` (ClusterIP)

### 7. Ingress 생성 (ALB 자동 프로비저닝)

```bash
# Ingress 생성
kubectl apply -f ingress/ingress.yaml

# ALB 생성 확인 (약 2-3분 소요)
kubectl get ingress -n web -w
```

Ingress 상태:
```
NAME          CLASS   HOSTS   ADDRESS                                                          PORTS   AGE
web-ingress   alb     *       k8s-web-webingre-5d0cf16a97-840173904.ap-northeast-2.elb...     80      2m
```

**ALB가 생성되면 ADDRESS 필드에 DNS 이름이 표시됩니다.**

---

## 검증 및 확인

### 1. Pod 상태 확인

```bash
# 모든 Pod 확인
kubectl get pods -A

# Web Tier
kubectl get pods -n web -o wide

# WAS Tier
kubectl get pods -n was -o wide
```

정상 상태:
```
NAMESPACE   NAME                         READY   STATUS    RESTARTS   AGE
web         web-nginx-xxx                1/1     Running   0          5m
was         was-spring-xxx               1/1     Running   0          5m
```

### 2. Service 확인

```bash
kubectl get svc -n web
kubectl get svc -n was
```

### 3. Ingress 및 ALB 확인

```bash
# Ingress 상태
kubectl describe ingress web-ingress -n web

# ALB DNS 추출
ALB_DNS=$(kubectl get ingress web-ingress -n web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB_DNS
```

### 4. ALB 헬스체크 확인

```bash
# ALB를 통한 접속 테스트
curl -I http://${ALB_DNS}/

# 정상 응답:
# HTTP/1.1 200 OK
```

### 5. RDS 연결 확인

WAS Pod에서 RDS 연결 테스트:

```bash
# WAS Pod에 접속
kubectl exec -it deployment/was-spring -n was -- bash

# MySQL 연결 테스트 (Pod 내부)
mysql -h blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com \
  -u admin -pCHANGE_ME_DB_PASSWORD -e "SELECT 1;"

# 데이터베이스 확인
mysql -h blue-rds.ciyiccb2k2z8.ap-northeast-2.rds.amazonaws.com \
  -u admin -pCHANGE_ME_DB_PASSWORD -e "SHOW DATABASES;"
```

### 6. 백업 인스턴스 확인

```bash
# SSM으로 백업 인스턴스 접속
BACKUP_INSTANCE_ID=$(cd .. && terraform output -raw backup_instance_id)
aws ssm start-session --target $BACKUP_INSTANCE_ID

# 백업 로그 확인 (인스턴스 내부)
sudo tail -f /var/log/mysql-backup-to-azure.log

# Cron 작업 확인
sudo crontab -l

# Azure Blob Storage 백업 확인 (로컬)
az storage blob list \
  --account-name bloberry01 \
  --container-name mysql-backups \
  --prefix "backups/" \
  --output table
```

---

## 트러블슈팅

### 1. ALB가 생성되지 않음

**증상**:
```bash
kubectl get ingress -n web
# NAME          CLASS   HOSTS   ADDRESS   PORTS   AGE
# web-ingress   alb     *                 80      5m
```
ADDRESS가 비어있음

**해결**:

1. Load Balancer Controller 로그 확인:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

2. Ingress 상세 확인:
```bash
kubectl describe ingress web-ingress -n web
```

3. 공통 원인:
   - Public Subnet 태그 누락
   - ServiceAccount IAM Role 미설정
   - Controller Pod 비정상

### 2. WAS Pod CrashLoopBackOff

**증상**:
```bash
kubectl get pods -n was
# was-spring-xxx   0/1   CrashLoopBackOff
```

**해결**:

1. Pod 로그 확인:
```bash
kubectl logs was-spring-xxx -n was --tail=50
```

2. RDS 연결 실패 시:
```bash
# Secret 확인
kubectl get secret db-credentials -n was -o yaml

# Secret 재생성 (비밀번호 확인)
kubectl delete secret db-credentials -n was
kubectl create secret generic db-credentials --namespace=was \
  --from-literal=url="jdbc:mysql://RDS_HOST:3306/petclinic" \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD"
```

3. RDS 보안 그룹 확인:
```bash
# RDS Security Group에 WAS 서브넷 허용 확인
aws ec2 describe-security-groups --group-ids sg-xxx
```

### 3. 백업 실패 (mysqldump 권한 오류)

**증상**:
```
mysqldump: Couldn't execute 'FLUSH TABLES WITH READ LOCK'
```

**해결**:

이미 수정된 `backup-init.sh`에 `--set-gtid-purged=OFF` 옵션이 포함되어 있습니다.

만약 기존 백업 인스턴스에서 문제 발생 시:
```bash
# SSM 접속
aws ssm start-session --target i-0066dc51da5528f0f

# 스크립트 수정 (인스턴스 내부)
sudo sed -i 's/--single-transaction/--single-transaction --set-gtid-purged=OFF/g' \
  /usr/local/bin/mysql-backup-to-azure.sh

# 백업 테스트
sudo /usr/local/bin/mysql-backup-to-azure.sh
```

자세한 내용은 [troubleshooting.md](troubleshooting.md#72-mysqldump-권한-오류-rds) 참조

### 4. Web Pod Nginx 502 Bad Gateway

**증상**:
```bash
curl http://${ALB_DNS}/api/users
# 502 Bad Gateway
```

**해결**:

1. WAS Service 확인:
```bash
kubectl get svc was-service -n was
kubectl get endpoints was-service -n was
```

2. WAS Pod 상태 확인:
```bash
kubectl get pods -n was
```

3. Nginx ConfigMap 확인:
```bash
kubectl get configmap nginx-config -n web -o yaml
```

WAS Service DNS가 올바른지 확인: `was-service.was.svc.cluster.local:8080`

---

## 배포 요약

### 전체 배포 순서

1. **Terraform 인프라 배포** (20-25분)
   - VPC, EKS, RDS, Backup Instance

2. **kubectl 설정** (1분)
   - EKS kubeconfig 설정

3. **AWS Load Balancer Controller 설치** (2분)
   - IAM Role, ServiceAccount, Helm

4. **K8s 리소스 배포** (5분)
   - Namespace
   - DB Secret
   - WAS Deployment
   - Web Deployment
   - Ingress → ALB 자동 생성

5. **검증** (5분)
   - Pod, Service, Ingress 확인
   - ALB 접속 테스트
   - RDS 연결 테스트
   - 백업 확인

**총 소요 시간**: 약 30-40분

### 주요 엔드포인트

배포 후 확인:

```bash
# EKS Cluster
kubectl get nodes

# ALB DNS
kubectl get ingress web-ingress -n web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# RDS
terraform output rds_endpoint

# Backup Instance
terraform output backup_instance_id
```

### 다음 단계

1. **Route53/CloudFront 설정** (선택사항)
   - 도메인 연결
   - HTTPS 인증서
   - Multi-region failover

2. **모니터링 설정**
   - CloudWatch Logs
   - CloudWatch Metrics
   - RDS Enhanced Monitoring

3. **백업 검증**
   - Azure Blob Storage 백업 확인
   - 복구 테스트

---

## 참고 문서

- [Troubleshooting Guide](troubleshooting.md)
- [AWS Load Balancer Controller 공식 문서](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)

---

**문서 버전**: v1.0
**최종 수정**: 2026-01-04
**작성자**: I2ST-blue
