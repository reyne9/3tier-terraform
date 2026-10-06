# AWS Service 인프라 상세

**코드 위치**: `codes/aws/2. service/`

## 구성

- VPC와 Subnet
- Internet Gateway와 NAT Gateway
- EKS
- Web/WAS node group
- RDS MySQL
- Backup EC2
- Kubernetes Ingress와 AWS Load Balancer Controller가 생성하는 ALB

사용자 진입 ALB는 Kubernetes Ingress와 AWS Load Balancer Controller가 생성하고 관리한다. Terraform은 ALB를 직접 생성하지 않는다.

## 네트워크

- VPC 기본 CIDR: 변수
- Public Subnet: ALB/NAT
- Web Subnet: EKS Web node
- WAS Subnet: EKS WAS node
- RDS Subnet: RDS subnet group
- Private route: NAT Gateway

Kubernetes subnet discovery tag는 VPC module의 실제 tag를 기준으로 한다.

## EKS

### API endpoint

```hcl
endpoint_private_access = true
endpoint_public_access  = true
public_access_cidrs     = ["0.0.0.0/0"]
```

Private endpoint가 켜져 있어도 public endpoint가 전체 CIDR에 열려 있다. 운영 보안 개선 항목이다.

### Node group

- Web/WAS node group 분리
- `tier=web`, `tier=was` label
- 서로 다른 subnet group 사용

### Add-on

- VPC CNI
- kube-proxy
- CoreDNS
- CloudWatch Observability

### OIDC

Root service module에서 EKS OIDC provider를 생성한다. AWS Load Balancer Controller 설치 스크립트가 IRSA role과 ServiceAccount 연동에 사용한다.

## Kubernetes workload

- Namespace: `web`, `was`
- Web: Nginx Deployment와 ClusterIP Service
- WAS: Spring Boot Deployment와 ClusterIP Service
- AWS Ingress class: `alb`
- Nginx upstream: `was-service.was.svc.cluster.local:8080`

Ingress annotation과 Controller가 실제 ALB 및 target을 만든다.

## RDS

- MySQL 8.0
- gp3 encrypted storage
- Private subnet
- Public access 비활성
- Security Group: EKS cluster security group에서 3306
- Multi-AZ: 변수
- Backup retention: 7일
- Enhanced Monitoring: 활성
- Error/general/slow query log export

## Backup Instance

- EC2와 encrypted root volume
- RDS 접근용 security group rule
- Azure Blob upload용 outbound
- `backup-init.sh`에서 MySQL dump와 Azure upload 설정

Storage key와 DB password는 Terraform state에 남을 수 있으므로 운영에서는 secret manager가 필요하다.

## ALB 구성

`k8s-manifests/ingress/ingress.yaml`:

- ALB의 단일 정의 지점
- `ingressClassName: alb`
- AWS Load Balancer Controller가 ALB를 생성
- Internet-facing ALB와 IP Target Group을 생성
- 정상 Web Pod IP를 Target Group에 등록
- `/health` 상태 검사를 통과한 Web Pod로 라우팅

Terraform은 ALB, Listener, Target Group을 직접 생성하지 않는다. Ingress가 배포된 후
`codes/aws/1. route53` 단계가 EKS 클러스터 태그로 ALB를 조회하여 CloudFront Origin으로 사용한다.

삭제 의존성 문제는 주로 Controller가 만든 ALB/Target Group/ENI가 Terraform VPC 삭제보다 늦게 정리될 때 발생한다.

## 배포

```bash
cd "codes/aws/2. service"
terraform init
terraform validate
terraform plan
terraform apply

aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name "$(terraform output -raw eks_cluster_name)"

./scripts/install-lb-controller.sh

kubectl apply -f k8s-manifests/namespaces.yaml
kubectl apply -f k8s-manifests/was/
kubectl apply -f k8s-manifests/web/
kubectl apply -f k8s-manifests/ingress/

# ADDRESS가 생성될 때까지 확인
kubectl get ingress web-ingress -n web -w
```

## 검증

```bash
kubectl get nodes --show-labels
kubectl get pods -A
kubectl get svc -n web
kubectl get svc -n was
kubectl get ingress -n web

terraform output rds_endpoint
terraform output backup_instance_id
```

Output 이름은 `outputs.tf`와 대조한다. 문서에 cluster/ALB/RDS ID를 고정하지 않는다.

## 알려진 개선점

- EKS public endpoint CIDR 제한
- DB/Storage credential secret manager 이관
- 중복 ALB 관리 경로 정리
- Remote state와 locking
- Ingress/ALB 삭제 lifecycle 자동 검증
- Pod scheduling이 node label 분리 의도와 일치하는지 지속 검증
