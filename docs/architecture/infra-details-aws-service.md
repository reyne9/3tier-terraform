# AWS Service 인프라 상세 설명

**디렉토리**: `/codes/aws/2. service/`

**목적**: AWS Primary Site의 핵심 인프라 구성 (VPC, EKS, RDS, Backup Instance)

---

## 📋 개요

이 디렉토리는 Multi-Cloud DR 솔루션의 Primary Site를 구성하는 모든 AWS 리소스를 포함합니다. 3-Tier 아키텍처(Web-WAS-DB)를 Kubernetes 기반으로 구현하며, Multi-AZ 고가용성 및 자동 백업 기능을 제공합니다.

### 주요 구성 요소

- **VPC Module**: 10.0.0.0/16, 4개 Tier별 Private/Public Subnet, Multi-AZ NAT Gateway
- **EKS Module**: Kubernetes 1.34, 별도 Web/WAS Node Pool, OIDC Provider IRSA
- **RDS Module**: MySQL 8.0 Multi-AZ, db.t3.medium, 20GB gp3, 자동 백업
- **Backup Instance**: EC2 t3.micro, 매일 Azure Blob Storage로 mysqldump 전송

---

## 🏗️ 아키텍처 구성

```
┌─────────────────────────────────────────────────────────────┐
│                      AWS ap-northeast-2                      │
│                                                              │
│  ┌───────────────────── VPC (10.0.0.0/16) ────────────────┐ │
│  │                                                          │ │
│  │  ┌─────── AZ-2a ───────┐  ┌─────── AZ-2c ───────┐     │ │
│  │  │                       │  │                      │     │ │
│  │  │ [Public Subnet]       │  │ [Public Subnet]     │     │ │
│  │  │  - NAT Gateway        │  │  - NAT Gateway      │     │ │
│  │  │  - ALB (Ingress)      │  │  - ALB (Standby)    │     │ │
│  │  │                       │  │                      │     │ │
│  │  │ [Web Subnet]          │  │ [Web Subnet]        │     │ │
│  │  │  - EKS Web Pods       │  │  - EKS Web Pods     │     │ │
│  │  │                       │  │                      │     │ │
│  │  │ [WAS Subnet]          │  │ [WAS Subnet]        │     │ │
│  │  │  - EKS WAS Pods       │  │  - EKS WAS Pods     │     │ │
│  │  │                       │  │                      │     │ │
│  │  │ [RDS Subnet]          │  │ [RDS Subnet]        │     │ │
│  │  │  - RDS Primary        │  │  - RDS Standby      │     │ │
│  │  │  - Backup Instance    │  │                      │     │ │
│  │  └───────────────────────┘  └─────────────────────┘     │ │
│  │                                                          │ │
│  │  Internet Gateway ─── CloudFront Origin                 │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔑 핵심 설계 결정

### 1. VPC CIDR 및 서브넷 설계

#### 선택: 10.0.0.0/16 (65,536개 IP)

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}
```

#### 서브넷 구성 (2 AZ × 4 Tier = 8 subnets)

| Tier | CIDR | 가용 IP | 용도 | 배치 리소스 |
|------|------|---------|------|-------------|
| Public-2a | 10.0.1.0/24 | 251 | NAT, ALB | NAT Gateway, Internet-facing ALB |
| Public-2c | 10.0.2.0/24 | 251 | NAT, ALB | NAT Gateway, ALB Standby |
| Web-2a | 10.0.10.0/24 | 251 | EKS Pods | PetClinic Web (Nginx) Pods |
| Web-2c | 10.0.11.0/24 | 251 | EKS Pods | PetClinic Web (Nginx) Pods |
| WAS-2a | 10.0.20.0/24 | 251 | EKS Pods | PetClinic WAS (Spring Boot) Pods |
| WAS-2c | 10.0.21.0/24 | 251 | EKS Pods | PetClinic WAS (Spring Boot) Pods |
| RDS-2a | 10.0.30.0/24 | 251 | RDS, Backup | RDS Primary, EC2 Backup Instance |
| RDS-2c | 10.0.31.0/24 | 251 | RDS | RDS Standby (Multi-AZ) |

#### 왜 이렇게 설계했는가?

**1. Tier별 서브넷 분리**
- **장점**:
  - Security Group 규칙 단순화 (Tier 간 명확한 경계)
  - 네트워크 ACL로 Tier 간 트래픽 제어 가능
  - 장애 격리 (한 Tier 문제가 다른 Tier에 영향 최소화)
- **트레이드오프**: 서브넷 개수 증가 (관리 복잡도 약간 증가)

**2. /24 서브넷 크기 선택**
- **이유**:
  - 251개 IP는 EKS Node (최대 5개) + Pod (Node당 최대 29개) 충분
  - AWS 예약 IP 5개 (0, 1, 2, 3, 255) 제외
  - 향후 확장 여유 (현재 사용률 20% 미만)
- **대안 고려**: /26 (62개 IP) - 너무 작아 확장성 부족

**3. Public Subnet은 왜 필요한가?**
- **용도**:
  - NAT Gateway 배치 (Private Subnet 아웃바운드 인터넷 경로)
  - ALB 배치 (Kubernetes Ingress Controller가 자동 생성)
  - Bastion Host (선택 사항, 현재 미배포)
- **Public IP 자동 할당**:
  ```hcl
  map_public_ip_on_launch = true
  ```
  - NAT Gateway Elastic IP 자동 연결
  - ALB는 자체 Public IP 사용

**4. Kubernetes 태그**
```hcl
tags = {
  "kubernetes.io/role/elb" = "1"                    # Public Subnet
  "kubernetes.io/role/internal-elb" = "1"           # Private Subnet
  "kubernetes.io/cluster/${var.environment}-eks" = "shared"
}
```
- **목적**: AWS Load Balancer Controller가 서브넷 자동 발견
- **elb vs internal-elb**:
  - `elb`: Internet-facing ALB 배치 (Public Subnet)
  - `internal-elb`: Internal ALB/NLB 배치 (Private Subnet)

---

### 2. Multi-AZ NAT Gateway (고가용성 vs 비용)

#### 선택: AZ별 NAT Gateway (2개)

```hcl
resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)  # 2개 (2a, 2c)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}
```

#### 라우팅 테이블 구성
```hcl
# AZ-2a의 Private Subnet → NAT Gateway-2a
resource "aws_route_table" "private_2a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id  # NAT-2a
  }
}

# AZ-2c의 Private Subnet → NAT Gateway-2c
resource "aws_route_table" "private_2c" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[1].id  # NAT-2c
  }
}
```

#### 설계 근거

**장점**:
- **단일 AZ 장애 시 다른 AZ 정상 운영**: NAT Gateway-2a 장애 시에도 2c의 Pod는 정상 아웃바운드 가능
- **크로스 AZ 데이터 전송 비용 절감**: 각 AZ의 Pod가 같은 AZ의 NAT 사용 ($0.01/GB 절약)
- **대역폭 분산**: NAT Gateway당 45Gbps → 총 90Gbps

**비용**:
- NAT Gateway: $0.045/시간 × 2개 × 730시간/월 = **$65.7/월**
- 데이터 처리: $0.045/GB × 100GB/월 = **$4.5/월**
- **월 합계**: 약 $70

**대안: 단일 NAT Gateway (비용 절감)**
```
# 모든 Private Subnet → 단일 NAT Gateway
route {
  cidr_block     = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.main[0].id  # 단일 NAT
}
```
- ❌ **기각 사유**:
  - 해당 AZ 장애 시 전체 아웃바운드 불가
  - 크로스 AZ 데이터 전송 비용 발생
  - 단일 장애점 (SPOF)
- **절감 금액**: ~$33/월 (고가용성 대비 가치 낮음)

---

### 3. EKS Endpoint Access Control (보안 vs 편의성)

#### 선택: Public + Private Hybrid

```hcl
resource "aws_eks_cluster" "main" {
  vpc_config {
    endpoint_public_access  = true   # 외부에서 kubectl 접근 가능
    endpoint_private_access = true   # VPC 내부에서도 접근 가능
    public_access_cidrs     = ["0.0.0.0/0"]  # 전체 허용
  }
}
```

#### 3가지 접근 방식 비교

| 방식 | Public | Private | 장점 | 단점 |
|------|--------|---------|------|------|
| **Public Only** | ✅ | ❌ | 외부에서 바로 kubectl | Node → API 서버 인터넷 경유 (느림) |
| **Private Only** | ❌ | ✅ | 완전 격리 (높은 보안) | Bastion Host 필수, VPN 필요 |
| **Hybrid** ✅ | ✅ | ✅ | 편의성 + 성능 | 공격 표면 증가 (방화벽 필요) |

#### 왜 Hybrid를 선택했는가?

**1. 운영 편의성**
- **개발자 워크스테이션에서 직접 접근**: Bastion Host/VPN 불필요
- **CI/CD 파이프라인 단순화**: GitHub Actions에서 직접 kubectl 실행
- **빠른 트러블슈팅**: 장애 시 즉시 로그 확인 가능

**2. 내부 성능**
- **Pod → API 서버 통신은 Private Endpoint 사용**: VPC PrivateLink 경유 (저지연)
- **Node → API 서버도 Private**: Kubelet과 API 서버 간 빠른 통신

**3. 보안 보완 방안**
```hcl
public_access_cidrs = ["YOUR_OFFICE_IP/32", "YOUR_HOME_IP/32"]
```
- **개선**: 특정 IP만 허용하도록 제한 (현재는 0.0.0.0/0)
- **CloudTrail 활성화**: EKS API 호출 로깅으로 감사 추적

**트레이드오프**:
- 공격자가 EKS API 엔드포인트를 스캔 가능 (실제 인증 없이는 접근 불가)
- IAM 기반 인증이므로 AWS 자격증명 탈취 시 위험 (MFA 필수)

#### 대안: Private Only + VPN (기각)
```
VPN Gateway → VPC → Private EKS API
```
- ❌ **기각 사유**:
  - VPN Gateway 비용: $36/월 추가
  - 모든 개발자 VPN 클라이언트 설치 필요
  - CI/CD 복잡도 증가 (VPN 연결 자동화)
- **프로젝트 목적과 맞지 않음**: 개인 포트폴리오/학습 프로젝트에서는 과도한 보안

---

### 4. EKS Node Group 분리 (Web vs WAS)

#### 설계: 별도 Node Pool

```hcl
# Web Tier Node Group
resource "aws_eks_node_group" "web" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "web-nodes"
  subnet_ids      = var.web_subnet_ids

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 5
  }

  instance_types = ["t3.medium"]

  labels = {
    tier = "web"
  }

  taints {
    key    = "tier"
    value  = "web"
    effect = "NoSchedule"
  }
}

# WAS Tier Node Group
resource "aws_eks_node_group" "was" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "was-nodes"
  subnet_ids      = var.was_subnet_ids

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 5
  }

  instance_types = ["t3.medium"]

  labels = {
    tier = "was"
  }

  taints {
    key    = "tier"
    value  = "was"
    effect = "NoSchedule"
  }
}
```

#### Pod 배치 제어 (NodeSelector + Tolerations)

**Web Pod Manifest**:
```yaml
spec:
  nodeSelector:
    tier: web
  tolerations:
    - key: tier
      operator: Equal
      value: web
      effect: NoSchedule
```

**WAS Pod Manifest**:
```yaml
spec:
  nodeSelector:
    tier: was
  tolerations:
    - key: tier
      operator: Equal
      value: was
      effect: NoSchedule
```

#### 왜 Node Pool을 분리하는가?

**1. 리소스 격리**
- **Web (Nginx)**: CPU 낮음, 메모리 낮음 (프록시 역할만)
- **WAS (Spring Boot)**: CPU 높음, 메모리 높음 (비즈니스 로직 + JVM)
- **분리 시**: WAS의 높은 리소스 사용이 Web에 영향 없음

**2. 독립적 스케일링**
- **트래픽 급증**: Web Node만 5개로 증가 (WAS는 2개 유지)
- **배치 작업**: WAS Node만 증가 (대량 데이터 처리 시)

**3. 보안 경계**
```
Internet → ALB → Web Node (DMZ) → WAS Node (Internal) → RDS
```
- Web Node는 외부 노출 (ALB 연결)
- WAS Node는 완전 내부 (Web에서만 접근)

**4. 서브넷 분리 효과**
- Web Node: 10.0.10.0/24 (Web Subnet)
- WAS Node: 10.0.20.0/24 (WAS Subnet)
- Security Group으로 Tier 간 트래픽 제어

**트레이드오프**:
- Node 개수 증가 (최소 4개 vs 2개) → 비용 증가 (~$60/월)
- 관리 복잡도 증가 (2개 Auto Scaling Group)

**대안: 단일 Node Pool (기각)**
```hcl
resource "aws_eks_node_group" "mixed" {
  # Web + WAS 혼재
  desired_size = 4
}
```
- ❌ **기각 사유**:
  - WAS Pod의 높은 CPU 사용률이 Web에 영향
  - Security Group 규칙 복잡 (같은 서브넷에 Web/WAS 혼재)
  - 스케일링 비효율 (WAS만 늘리고 싶어도 Web도 함께 증가)

---

### 5. RDS MySQL 구성

#### 선택: Multi-AZ db.t3.medium

```hcl
resource "aws_db_instance" "main" {
  identifier     = "petclinic-db"
  engine         = "mysql"
  engine_version = "8.0.35"

  instance_class        = "db.t3.medium"
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"

  multi_az               = true  # 🔑 Multi-AZ 활성화
  db_subnet_group_name   = aws_db_subnet_group.main.name

  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  skip_final_snapshot = false
  final_snapshot_identifier = "petclinic-db-final-snapshot"
}
```

#### Multi-AZ 작동 방식

```
┌─────────── AZ-2a ───────────┐  ┌─────────── AZ-2c ───────────┐
│                              │  │                              │
│  ┌──────────────────────┐   │  │   ┌──────────────────────┐  │
│  │  RDS Primary         │   │  │   │  RDS Standby         │  │
│  │  10.0.30.x           │◄──┼──┼───┤  10.0.31.x           │  │
│  │                      │   │  │   │                      │  │
│  │  - 읽기/쓰기 담당    │   │  │   │  - 동기 복제 대기    │  │
│  │  - DNS: petclinic-db │   │  │   │  - 자동 Failover     │  │
│  └──────────────────────┘   │  │   └──────────────────────┘  │
│           ▲                  │  │            ▲                 │
│           │                  │  │            │                 │
│           │                  │  │            │                 │
│    WAS Pod 읽기/쓰기         │  │     (장애 시 자동 승격)     │
└──────────────────────────────┘  └──────────────────────────────┘
```

#### 왜 Multi-AZ인가?

**1. 자동 Failover (RTO: 1-2분)**
- Primary 장애 감지 → Standby로 자동 승격
- DNS 레코드 자동 업데이트 (애플리케이션 코드 변경 불필요)
- EKS Pod는 연결 재시도만 하면 복구

**2. 동기 복제 (RPO: 0)**
- Primary에 쓴 데이터가 Standby에도 즉시 복제
- Failover 시 데이터 손실 없음

**3. 자동 백업 유지 관리**
- 백업은 Standby에서 수행 (Primary 부하 없음)
- OS 패치도 Standby 먼저 적용 후 Failover

**비용**:
- Single-AZ: $36/월 (db.t3.medium)
- Multi-AZ: **$72/월** (2배)

**대안: Single-AZ + 수동 스냅샷 복원 (기각)**
```
Single-AZ → 장애 → 스냅샷에서 복원 (RTO: 10-15분)
```
- ❌ **기각 사유**:
  - RTO 10배 증가 (1분 → 10분)
  - 수동 개입 필요 (자동화 어려움)
  - 최근 스냅샷 이후 데이터 손실 가능 (RPO: 1시간)

#### RDS Subnet Group (왜 2개 서브넷?)

```hcl
resource "aws_db_subnet_group" "main" {
  name       = "petclinic-db-subnet-group"
  subnet_ids = [
    aws_subnet.rds[0].id,  # RDS-2a
    aws_subnet.rds[1].id,  # RDS-2c
  ]
}
```

- **AWS 요구사항**: Multi-AZ RDS는 최소 2개 서브넷 필요
- Primary가 2a에 있으면 Standby는 2c에 자동 배치

---

### 6. RDS Storage 설정 (gp3 vs gp2)

#### 선택: gp3 (General Purpose SSD)

```hcl
storage_type          = "gp3"
allocated_storage     = 20   # GB
max_allocated_storage = 100  # 자동 확장 최대치
iops                  = 3000 # 기본 IOPS
```

#### gp3 vs gp2 비교

| 항목 | gp2 | gp3 |
|------|-----|-----|
| 기본 IOPS | 100 IOPS (20GB 기준) | 3,000 IOPS |
| 처리량 | 250 MB/s | 125 MB/s (기본) |
| 가격 (20GB) | $2.30/월 | $1.84/월 |
| IOPS 확장 | 볼륨 크기에 비례 (3 IOPS/GB) | 독립적으로 확장 가능 |

**선택 이유**:
- **20% 비용 절감**: $0.10/GB (gp2) → $0.08/GB (gp3)
- **더 높은 기본 IOPS**: 3,000 IOPS는 소규모 DB에 충분
- **독립적 IOPS 확장**: 스토리지 크기와 무관하게 IOPS 증가 가능

**Auto Scaling Storage**:
```hcl
max_allocated_storage = 100
```
- **작동 방식**: 여유 공간 10% 미만 시 자동으로 10% 증가
- **장점**: 수동 개입 없이 디스크 풀 방지
- **비용**: 실제 사용량만큼만 과금 (최대 100GB까지)

---

### 7. RDS 백업 전략

#### 자동 백업 설정

```hcl
backup_retention_period = 7            # 7일 보관
backup_window          = "03:00-04:00" # UTC 03:00-04:00 (한국 시간 12:00-13:00)
maintenance_window     = "sun:04:00-sun:05:00"  # 일요일 UTC 04:00 (한국 13:00)

skip_final_snapshot       = false
final_snapshot_identifier = "petclinic-db-final-snapshot"
```

#### 백업 시간대 선택 이유

**Backup Window: 03:00-04:00 UTC**
- **한국 시간 12:00-13:00 (점심시간)**
- 트래픽이 낮은 시간대 (새벽 시간)
- Standby에서 백업 수행으로 Primary 영향 최소

**Maintenance Window: 일요일 04:00 UTC**
- **한국 시간 일요일 13:00**
- 주말 트래픽 최저 시간대
- OS 패치, 엔진 업그레이드 자동 적용

#### Final Snapshot (중요!)

```hcl
skip_final_snapshot = false
```

- **terraform destroy 시 자동 스냅샷 생성**
- 실수로 삭제해도 데이터 복구 가능
- **주의**: `skip_final_snapshot = true`로 변경 시 영구 삭제

---

### 8. EKS OIDC Provider (IRSA)

#### 선택: IAM Roles for Service Accounts

```hcl
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
```

#### IRSA 작동 방식

```
┌──────────────────────────────────────────────────────┐
│  EKS Pod (ServiceAccount: aws-load-balancer-controller) │
│  ↓                                                    │
│  1. Pod가 AWS API 호출 (ALB 생성)                    │
│  ↓                                                    │
│  2. OIDC Token 자동 주입 (/var/run/secrets/...)     │
│  ↓                                                    │
│  3. AWS STS가 Token 검증                             │
│  ↓                                                    │
│  4. IAM Role 임시 자격증명 반환                      │
│  ↓                                                    │
│  5. Pod가 ALB 생성/삭제 권한 획득                    │
└──────────────────────────────────────────────────────┘
```

#### 왜 IRSA를 사용하는가?

**기존 방식 (Node IAM Role) vs IRSA**

| 항목 | Node IAM Role | IRSA |
|------|---------------|------|
| 권한 범위 | Node의 모든 Pod | 특정 ServiceAccount만 |
| 보안 | 낮음 (모든 Pod가 권한 공유) | 높음 (Pod별 최소 권한) |
| 감사 추적 | Node 수준 | Pod 수준 (CloudTrail) |
| 자격증명 관리 | 불필요 | 자동 (OIDC Token) |

**예시: AWS Load Balancer Controller**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole
```

- 이 ServiceAccount를 사용하는 Pod만 ALB 생성 가능
- 다른 Pod는 ALB 권한 없음 (최소 권한 원칙)

---

### 9. VPC Endpoints (S3 Gateway Endpoint)

#### 선택: S3 Gateway Endpoint

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.ap-northeast-2.s3"

  route_table_ids = [
    aws_route_table.private_2a.id,
    aws_route_table.private_2c.id,
  ]
}
```

#### 왜 S3 Gateway Endpoint인가?

**비용 절감**:
```
Without Endpoint: Pod → NAT Gateway ($0.045/GB) → S3
With Endpoint:    Pod → S3 (무료)
```
- **월 100GB 전송 시 $4.5 절감**
- Gateway Endpoint 자체는 무료

**성능 향상**:
- NAT Gateway 경유 불필요 (지연시간 감소)
- AWS 내부 네트워크로 직접 연결

**보안**:
- S3 트래픽이 인터넷 미경유 (VPC 내부)
- S3 Bucket Policy로 특정 VPC만 허용 가능

#### Interface Endpoint vs Gateway Endpoint

| 항목 | Gateway Endpoint | Interface Endpoint |
|------|------------------|-------------------|
| 지원 서비스 | S3, DynamoDB | EC2, RDS, Secrets Manager 등 |
| 비용 | 무료 | $0.01/시간 + 데이터 처리 비용 |
| 설정 | Route Table 수정 | ENI 생성 |

**S3는 Gateway Endpoint 사용 권장** (무료 + 간단)

---

### 10. Backup Instance (Azure 전송)

#### 구성: EC2 t3.micro

```hcl
resource "aws_instance" "backup" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t3.micro"
  subnet_id     = module.vpc.rds_subnet_ids[0]

  vpc_security_group_ids = [aws_security_group.backup_instance.id]

  iam_instance_profile = aws_iam_instance_profile.backup.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y mysql

    # Azure CLI 설치
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    yum install -y azure-cli

    # 백업 스크립트 생성
    cat > /usr/local/bin/backup-to-azure.sh <<'SCRIPT'
    #!/bin/bash
    DATE=$(date +%Y%m%d)
    BACKUP_FILE="/tmp/petclinic-$DATE.sql.gz"

    # mysqldump
    mysqldump -h ${aws_db_instance.main.address} \
              -u admin \
              -p${var.db_password} \
              petclinic | gzip > $BACKUP_FILE

    # Azure Blob Storage 업로드
    az storage blob upload \
      --account-name drbackupprod2024 \
      --container-name backups \
      --name "petclinic-$DATE.sql.gz" \
      --file $BACKUP_FILE

    # 로컬 파일 삭제
    rm $BACKUP_FILE
    SCRIPT

    chmod +x /usr/local/bin/backup-to-azure.sh

    # Cron 등록 (매일 03:00 UTC)
    echo "0 3 * * * /usr/local/bin/backup-to-azure.sh >> /var/log/backup.log 2>&1" | crontab -
  EOF

  tags = {
    Name = "backup-instance"
  }
}
```

#### 왜 EC2 Backup Instance인가?

**1. Multi-Cloud 백업 전략**
- AWS RDS 자동 백업은 AWS 내부에만 저장
- Azure Blob Storage에 복사하여 AWS 리전 전체 장애 대비

**2. mysqldump 사용 이유**
- **논리 백업**: SQL 문 형태로 덤프 (클라우드 간 이식성)
- **물리 백업 (스냅샷) 대비 장점**:
  - Azure MySQL에서 직접 복원 가능
  - MySQL 버전 차이 호환 (AWS 8.0.35 → Azure 8.0.x)

**3. 비용**:
- EC2 t3.micro: $7/월 (730시간)
- Azure Blob Storage: $5/월 (100GB 기준)
- **총 $12/월**

**대안: AWS Database Migration Service (기각)**
```
AWS DMS: RDS → Azure MySQL 실시간 복제
```
- ❌ **기각 사유**:
  - 비용 높음: $50+/월 (t3.medium DMS 인스턴스)
  - 실시간 복제 불필요 (Backup & Restore 전략)
  - Azure MySQL이 평상시 중지되어 있음

**보안**:
```hcl
resource "aws_security_group" "backup_instance" {
  egress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.rds_subnet_cidrs]  # RDS Subnet만
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Azure CLI HTTPS
  }
}
```

---

## 💰 비용 분석

### 월 예상 비용 (AWS 2. service)

| 항목 | 스펙 | 수량 | 단가 | 월 비용 |
|------|------|------|------|---------|
| **EKS Control Plane** | - | 1 | $0.10/시간 | $73 |
| **EKS Worker Nodes** | t3.medium | 4 (Web 2 + WAS 2) | $0.0416/시간 | $121 |
| **RDS MySQL** | db.t3.medium Multi-AZ | 1 | $0.099/시간 | $72 |
| **RDS Storage** | gp3 20GB | 20GB | $0.08/GB | $1.6 |
| **NAT Gateway** | - | 2 | $0.045/시간 | $66 |
| **NAT 데이터 처리** | - | 100GB | $0.045/GB | $4.5 |
| **Backup Instance** | t3.micro | 1 | $0.0104/시간 | $7.6 |
| **EBS** | gp3 | 4개 (Node당 20GB) | $0.08/GB | $6.4 |
| **ALB** | - | 1 | $0.0225/시간 | $16.4 |
| **Elastic IP** | NAT용 | 2 | $0/사용 중 | $0 |
| **S3 Endpoint** | Gateway | 1 | 무료 | $0 |
| **총 합계** | | | | **$368.5** |

### 비용 최적화 포인트

1. **Reserved Instances** (1년 예약 시 40% 할인):
   - EKS Nodes: $121 → $72 (-$49)
   - RDS: $72 → $43 (-$29)

2. **Spot Instances** (개발 환경):
   - WAS Node에 Spot 적용: $60 → $18 (-$42)
   - 주의: Production에서는 비권장

3. **Single NAT Gateway** (고가용성 포기):
   - NAT Gateway: $66 → $33 (-$33)
   - 트레이드오프: AZ 장애 시 전체 아웃바운드 불가

---

## 🚀 배포 절차

### 1. Terraform 초기화 및 배포

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/2.\ service/

# Terraform 초기화
terraform init

# 변수 파일 생성
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 편집 (AWS 자격증명, DB 비밀번호 등)

# 실행 계획 확인
terraform plan -out=tfplan

# 배포 (약 15-20분 소요)
terraform apply tfplan
```

### 2. 배포 순서 (의존성)

```
1. VPC (3분)
   ↓
2. EKS Cluster (10분)
   ↓
3. EKS Node Groups (5분)
   ↓
4. RDS (7분)
   ↓
5. Backup Instance (2분)
```

### 3. 배포 후 확인

```bash
# VPC 확인
terraform output vpc_id

# EKS 클러스터 상태 확인
aws eks describe-cluster --name blue-eks --query 'cluster.status'

# kubectl 설정
aws eks update-kubeconfig --name blue-eks --region ap-northeast-2

# Node 확인
kubectl get nodes
# NAME                                               STATUS   ROLES    AGE
# ip-10-0-10-123.ap-northeast-2.compute.internal    Ready    <none>   5m   (Web Node)
# ip-10-0-10-124.ap-northeast-2.compute.internal    Ready    <none>   5m   (Web Node)
# ip-10-0-20-123.ap-northeast-2.compute.internal    Ready    <none>   5m   (WAS Node)
# ip-10-0-20-124.ap-northeast-2.compute.internal    Ready    <none>   5m   (WAS Node)

# RDS 엔드포인트 확인
terraform output rds_endpoint

# Backup Instance 확인
aws ec2 describe-instances --filters "Name=tag:Name,Values=backup-instance" --query 'Reservations[0].Instances[0].State.Name'
```

---

## 🔧 운영 가이드

### EKS Node Group 스케일링

```bash
# Web Node 수동 스케일 아웃
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name web-nodes \
  --scaling-config desiredSize=5,minSize=2,maxSize=10

# WAS Node 스케일 인
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name was-nodes \
  --scaling-config desiredSize=1,minSize=1,maxSize=5
```

### RDS 수동 백업

```bash
# 스냅샷 생성
aws rds create-db-snapshot \
  --db-instance-identifier petclinic-db \
  --db-snapshot-identifier manual-backup-$(date +%Y%m%d)

# 스냅샷 목록 확인
aws rds describe-db-snapshots \
  --db-instance-identifier petclinic-db
```

### Backup Instance 로그 확인

```bash
# Backup Instance 접속
BACKUP_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=backup-instance" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

ssh -i your-key.pem ec2-user@$BACKUP_IP

# 백업 로그 확인
tail -f /var/log/backup.log

# 수동 백업 실행
sudo /usr/local/bin/backup-to-azure.sh
```

---

## 📊 모니터링 지표

### EKS 핵심 지표
- Node CPU 사용률 (목표: 70% 이하)
- Node 메모리 사용률 (목표: 80% 이하)
- Pod Restart Count (목표: 0)
- ALB 5xx 에러율 (목표: 0.1% 이하)

### RDS 핵심 지표
- CPU 사용률 (목표: 80% 이하)
- FreeableMemory (목표: 1GB 이상)
- DatabaseConnections (목표: 100개 이하)
- ReadLatency / WriteLatency (목표: 10ms 이하)

### NAT Gateway 지표
- BytesOut (월 100GB 미만 정상)
- PacketsDropCount (패킷 드롭 발생 시 대역폭 증설 고려)

---

## 🗑️ 인프라 삭제 절차

**중요**: 순서를 반드시 지켜야 합니다!

```bash
# 1. Kubernetes 리소스 먼저 삭제 (ALB, NLB 정리)
kubectl delete ingress --all --all-namespaces
kubectl delete svc --type=LoadBalancer --all --all-namespaces

# 2. ENI 정리 대기 (3분)
sleep 180

# 3. Terraform destroy
cd /home/ubuntu/3tier-terraform/codes/aws/2.\ service/
terraform destroy

# 주의: RDS Final Snapshot 생성 확인
# 실수로 삭제 시 복구 가능
```

---

## 📝 관련 문서

- **[AWS 서비스 Terraform 코드](/codes/aws/2.%20service/)**: VPC, EKS, RDS, Backup 인프라 구현
- **[배포 가이드](/docs/runbooks/deployment-guide.md)**: 전체 배포 순서
- **[트러블슈팅](/docs/runbooks/troubleshooting.md)**: 문제 해결 가이드

---

## ✅ 체크리스트

### 배포 전 확인
- [ ] AWS CLI 인증 설정 완료
- [ ] terraform.tfvars 파일 생성 및 변수 설정
- [ ] DB 비밀번호 안전하게 관리 (Secrets Manager 권장)
- [ ] Route53 Hosted Zone 먼저 배포 완료

### 배포 후 확인
- [ ] EKS 클러스터 상태 ACTIVE
- [ ] kubectl 명령 정상 작동
- [ ] RDS 엔드포인트 연결 가능
- [ ] Backup Instance Cron 작동 확인
- [ ] NAT Gateway 정상 작동 (Private Pod에서 인터넷 접근 테스트)

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/aws/2. service/`
