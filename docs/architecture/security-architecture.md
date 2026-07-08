# Multi-Cloud DR 보안 아키텍처 상세 설명

**목적**: Defense in Depth 전략 기반 Multi-Layer 보안 구현

---

## 📋 개요

이 프로젝트는 **Defense in Depth (심층 방어)** 원칙에 따라 7개 계층의 보안을 구현합니다. 각 계층은 독립적으로 보안을 제공하며, 한 계층이 뚫려도 다음 계층에서 공격을 차단합니다.

### 보안 7 계층

```
┌──────────────────────────────────────────────────────┐
│ Layer 1: 네트워크 격리 (VPC/VNet, Subnet)             │
├──────────────────────────────────────────────────────┤
│ Layer 2: 방화벽 (Security Group, NSG)                │
├──────────────────────────────────────────────────────┤
│ Layer 3: 접근 제어 (IAM, RBAC)                       │
├──────────────────────────────────────────────────────┤
│ Layer 4: 암호화 (전송 중, 저장 시)                    │
├──────────────────────────────────────────────────────┤
│ Layer 5: 인증/인가 (K8s RBAC, OIDC)                  │
├──────────────────────────────────────────────────────┤
│ Layer 6: 로깅/감사 (CloudTrail, Activity Log)        │
├──────────────────────────────────────────────────────┤
│ Layer 7: 애플리케이션 보안 (Input Validation, CSRF)   │
└──────────────────────────────────────────────────────┘
```

---

## 🔑 Layer 1: 네트워크 격리

### AWS VPC 설계 (10.0.0.0/16)

#### Subnet 계층 분리 (3-Tier Architecture)

```
┌─────────────────────────────────────────────────────┐
│  Internet                                           │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│  Public Subnet (10.0.1.0/24, 10.0.2.0/24)          │
│  - NAT Gateway (아웃바운드 전용)                     │
│  - ALB (인바운드 전용)                               │
│  - IGW 연결                                          │
└────────────────────┬────────────────────────────────┘
                     │ (ALB → Private Subnet)
                     ▼
┌─────────────────────────────────────────────────────┐
│  Web Subnet (10.0.10.0/24, 10.0.11.0/24) - Private │
│  - EKS Web Pods (Nginx)                            │
│  - 외부 직접 접근 불가                               │
│  - NAT Gateway 경유 아웃바운드                       │
└────────────────────┬────────────────────────────────┘
                     │ (Web → WAS)
                     ▼
┌─────────────────────────────────────────────────────┐
│  WAS Subnet (10.0.20.0/24, 10.0.21.0/24) - Private │
│  - EKS WAS Pods (Spring Boot)                      │
│  - Web Subnet에서만 접근 가능                        │
└────────────────────┬────────────────────────────────┘
                     │ (WAS → RDS)
                     ▼
┌─────────────────────────────────────────────────────┐
│  RDS Subnet (10.0.30.0/24, 10.0.31.0/24) - Private │
│  - RDS MySQL Multi-AZ                              │
│  - WAS Subnet에서만 접근 가능                        │
│  - 인터넷 접근 완전 차단                             │
└─────────────────────────────────────────────────────┘
```

#### 네트워크 격리 원칙

**1. Private Subnet은 인터넷 직접 접근 불가**

```hcl
# Web/WAS/RDS Subnet Route Table (Private)
resource "aws_route_table" "private_2a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id  # NAT Gateway 경유
  }

  # ❌ Internet Gateway 라우트 없음 (인바운드 차단)
}
```

**의미**:
- Private Subnet의 리소스는 인터넷에서 직접 접근 불가
- 아웃바운드는 NAT Gateway 경유 (패치, 업데이트용)
- ALB/NLB를 통해서만 트래픽 허용

**2. Tier 간 명확한 경계**

```
Public → Web: ALB Target Group을 통해서만
Web → WAS: ClusterIP Service (K8s 내부)
WAS → RDS: Security Group으로 포트 3306만 허용
```

**3. Multi-AZ 배치 (가용성 + 격리)**

```
AZ-2a: Public, Web, WAS, RDS (Primary)
AZ-2c: Public, Web, WAS, RDS (Standby)
```

- AZ 간 트래픽: AWS 내부망 (암호화 권장)
- 한 AZ 장애 시 다른 AZ로 Failover

### Azure VNet 설계 (10.1.0.0/16)

#### Subnet 구성

```
┌─────────────────────────────────────────────────────┐
│  Internet                                           │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│  AppGW Subnet (10.1.1.0/24)                        │
│  - Application Gateway 전용                         │
│  - Azure 요구사항: Dedicated Subnet                 │
└────────────────────┬────────────────────────────────┘
                     │ (App Gateway → AKS)
                     ▼
┌─────────────────────────────────────────────────────┐
│  Web Subnet (10.1.10.0/24) - Private               │
│  - AKS Web Node Pool                               │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│  WAS Subnet (10.1.20.0/24) - Private               │
│  - AKS WAS Node Pool                               │
└────────────────────┬────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│  DB Subnet (10.1.30.0/24) - Private + Delegated    │
│  - MySQL Flexible Server 전용                       │
│  - Delegation: Microsoft.DBforMySQL/flexibleServers│
└─────────────────────────────────────────────────────┘
```

#### Azure와 AWS CIDR 충돌 방지

```
AWS VPC:   10.0.0.0/16  (10.0.0.0 ~ 10.0.255.255)
Azure VNet: 10.1.0.0/16  (10.1.0.0 ~ 10.1.255.255)
→ VPN/Peering 시 충돌 없음
```

---

## 🔑 Layer 2: 방화벽 (Security Group / NSG)

### AWS Security Group 규칙

#### 1. RDS Security Group (가장 제한적)

```hcl
resource "aws_security_group" "rds" {
  name        = "blue-rds-sg"
  description = "Security group for RDS MySQL"
  vpc_id      = aws_vpc.main.id

  # ✅ Ingress: EKS WAS Pod에서만 접근 허용
  ingress {
    description     = "MySQL from EKS"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  # ✅ Egress: 필요 시 응답만 (사실상 불필요)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "blue-rds-sg"
  }
}
```

**보안 원칙**:
- ✅ **Source = Security Group**: IP 대신 EKS SG 참조 (동적 IP 대응)
- ✅ **Port 3306만 허용**: MySQL만, SSH(22), HTTP(80) 차단
- ❌ **0.0.0.0/0 차단**: 인터넷에서 직접 접근 불가

**공격 시나리오 방어**:
```
공격자가 RDS 엔드포인트 스캔 시도:
petclinic-db.xxxx.ap-northeast-2.rds.amazonaws.com:3306

→ Security Group에서 차단 (EKS SG 외 모든 접근 거부)
→ Connection Timeout (응답 없음)
```

#### 2. EKS Cluster Security Group

```hcl
# EKS가 자동 생성하는 Cluster Security Group
# aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

# 자동 규칙:
# - Node → Control Plane: 443 (HTTPS)
# - Control Plane → Node: 443, 10250 (Kubelet)
# - Node ↔ Node: All traffic (Pod 간 통신)
```

**EKS 관리형 보안 그룹 장점**:
- AWS가 자동으로 필요한 규칙 추가
- Node 추가 시 자동 적용
- Control Plane과 Node 간 통신 보장

#### 3. ALB Security Group

```hcl
resource "aws_security_group" "alb" {
  name        = "blue-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  # ✅ Ingress: 인터넷에서 HTTP/HTTPS 허용
  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ✅ Egress: EKS Web Pods로 전달
  egress {
    description = "To EKS Pods"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.web_subnet_cidrs[0], var.web_subnet_cidrs[1]]
  }

  tags = {
    Name = "blue-alb-sg"
  }
}
```

**보안 고려사항**:
- ⚠️ **0.0.0.0/0 허용 이유**: Public 웹 서비스는 전 세계 접근 필요
- ✅ **DDoS 방어**: AWS Shield Standard 자동 활성화
- ✅ **Rate Limiting**: ALB에서 Connection 수 제한 가능

### Azure Network Security Group (NSG)

#### Application Gateway NSG

```hcl
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-appgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # ✅ Allow HTTP/HTTPS from Internet
  security_rule {
    name                       = "Allow-HTTP-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTPS-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # ✅ Allow App Gateway Infrastructure (필수)
  security_rule {
    name                       = "Allow-GatewayManager"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
}
```

**Azure NSG vs AWS Security Group 차이**

| 항목 | AWS Security Group | Azure NSG |
|------|-------------------|-----------|
| **Stateful** | ✅ Yes (자동 Return 트래픽) | ✅ Yes |
| **Default Deny** | ✅ Yes | ✅ Yes |
| **우선순위** | 없음 (모든 규칙 평가) | Priority 100~4096 |
| **Service Tag** | 없음 | Internet, VirtualNetwork, AzureLoadBalancer |
| **적용 대상** | ENI (Elastic Network Interface) | Subnet 또는 NIC |

---

## 🔑 Layer 3: 접근 제어 (IAM / RBAC)

### AWS IAM 설계

#### 1. EKS Node IAM Role (최소 권한)

```hcl
resource "aws_iam_role" "eks_node" {
  name = "blue-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# ✅ 필수 정책만 연결
resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ❌ AdministratorAccess 연결 금지
# ❌ PowerUserAccess 연결 금지
```

**최소 권한 원칙 (Least Privilege)**:
- ✅ EKS 노드 운영에 필요한 최소 권한만
- ✅ ECR 읽기 전용 (쓰기 권한 없음)
- ❌ S3 Full Access, RDS 관리 권한 불필요

#### 2. IRSA (IAM Roles for Service Accounts)

```hcl
# OIDC Provider 생성
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# AWS Load Balancer Controller IAM Role
resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "AmazonEKSLoadBalancerControllerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
```

**IRSA 보안 장점**:
- ✅ **Pod별 IAM Role**: 각 Pod가 다른 권한 (Node 공유 권한 X)
- ✅ **임시 자격증명**: STS Token (15분~1시간 유효)
- ✅ **자격증명 노출 방지**: AWS Access Key 하드코딩 불필요

**예시 시나리오**:
```
AWS Load Balancer Controller Pod:
  → IRSA로 ALB 생성/삭제 권한만 획득
  → S3, RDS 접근 불가

일반 Application Pod:
  → IAM Role 없음
  → AWS API 호출 불가 (보안)
```

### Kubernetes RBAC

#### 1. Namespace 격리

```yaml
# Web Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    tier: web

---
# WAS Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: was
  labels:
    tier: was
```

**Namespace 격리 효과**:
- Web Pod는 WAS Namespace 리소스 접근 불가
- Secret, ConfigMap 분리
- RBAC으로 개발자 권한 분리 가능

#### 2. ServiceAccount RBAC

```yaml
# AWS Load Balancer Controller ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole

---
# ClusterRole: ALB 관리 권한
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aws-load-balancer-controller
rules:
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]

---
# ClusterRoleBinding: ServiceAccount에 권한 부여
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aws-load-balancer-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aws-load-balancer-controller
subjects:
  - kind: ServiceAccount
    name: aws-load-balancer-controller
    namespace: kube-system
```

**RBAC 최소 권한**:
- ✅ Service, Ingress 읽기/수정만 허용
- ❌ Secret 읽기 불가
- ❌ Pod 생성/삭제 불가

---

## 🔑 Layer 4: 암호화

### 전송 중 암호화 (Encryption in Transit)

#### 1. CloudFront → Origin (HTTPS)

```hcl
resource "aws_cloudfront_distribution" "main" {
  # Viewer → CloudFront: HTTPS 강제
  viewer_protocol_policy = "redirect-to-https"

  # CloudFront → Origin: HTTP (AWS 내부망)
  origin {
    domain_name = "k8s-web-webingre-xxx.elb.amazonaws.com"
    custom_origin_config {
      origin_protocol_policy = "http-only"  # ⚠️ 내부망은 HTTP
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
}
```

**왜 Origin은 HTTP인가?**
- CloudFront ↔ ALB: AWS 내부망 (PrivateLink 가능)
- SSL Offloading: CloudFront에서 HTTPS 처리
- 성능: TLS Handshake 오버헤드 제거

**완전한 E2E 암호화 (선택 사항)**:
```hcl
origin {
  custom_origin_config {
    origin_protocol_policy = "https-only"  # E2E HTTPS
  }
}
```
- 장점: 완전 암호화
- 단점: TLS 오버헤드, ACM 인증서 추가 필요

#### 2. RDS 전송 암호화 (TLS 1.2)

```hcl
resource "aws_db_instance" "main" {
  # ✅ MySQL 8.0은 기본적으로 TLS 지원
  engine         = "mysql"
  engine_version = "8.0.35"

  # ✅ Storage 암호화 활성화
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn
}

# RDS Parameter Group - TLS 강제
resource "aws_db_parameter_group" "main" {
  name   = "blue-mysql8-params"
  family = "mysql8.0"

  parameter {
    name  = "require_secure_transport"
    value = "1"  # ✅ TLS 연결 강제 (비암호화 연결 거부)
  }
}
```

**Application 연결 (Spring Boot)**:
```yaml
spring:
  datasource:
    url: jdbc:mysql://petclinic-db.xxx.rds.amazonaws.com:3306/petclinic?useSSL=true&requireSSL=true&verifyServerCertificate=true
    # useSSL=true: TLS 연결 활성화
    # requireSSL=true: TLS 실패 시 연결 거부
    # verifyServerCertificate=true: 서버 인증서 검증 (MITM 방지)
```

**TLS 연결 검증**:
```bash
# MySQL 클라이언트로 TLS 연결 확인
mysql -h petclinic-db.xxx.rds.amazonaws.com \
      -u admin -p \
      --ssl-mode=REQUIRED

# 연결 후 TLS 상태 확인
mysql> SHOW STATUS LIKE 'Ssl_cipher';
+---------------+--------------------+
| Variable_name | Value              |
+---------------+--------------------+
| Ssl_cipher    | TLS_AES_256_GCM... |
+---------------+--------------------+
```

#### 3. WAS → RDS 연결 암호화

**JDBC Connection String 보안 설정**:
```properties
# application.properties
spring.datasource.url=jdbc:mysql://petclinic-db.xxx.rds.amazonaws.com:3306/petclinic?\
useSSL=true&\
requireSSL=true&\
verifyServerCertificate=true&\
enabledTLSProtocols=TLSv1.2,TLSv1.3&\
trustCertificateKeyStoreUrl=file:/path/to/rds-ca-bundle.pem

# TLS 프로토콜 제한
# - TLSv1.0, TLSv1.1 비활성화 (취약)
# - TLSv1.2, TLSv1.3만 허용
```

**RDS CA Certificate 다운로드**:
```bash
# AWS RDS CA Bundle 다운로드
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

# Kubernetes Secret으로 저장
kubectl create secret generic rds-ca-cert \
  --from-file=ca-bundle.pem=global-bundle.pem \
  --namespace=was

# WAS Deployment에 마운트
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-deployment
spec:
  template:
    spec:
      containers:
        - name: spring-boot
          volumeMounts:
            - name: rds-ca-cert
              mountPath: /etc/ssl/certs/rds
              readOnly: true
      volumes:
        - name: rds-ca-cert
          secret:
            secretName: rds-ca-cert
```

### 저장 시 암호화 (Encryption at Rest)

#### 1. RDS Storage 암호화 (AWS KMS)

```hcl
# KMS Key 생성 (RDS 전용)
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true  # ✅ 자동 키 로테이션 (1년마다)

  # Key Policy: RDS 서비스에만 사용 허용
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow RDS to use the key"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "blue-rds-kms-key"
  }
}

# KMS Key Alias (사람이 읽기 쉬운 이름)
resource "aws_kms_alias" "rds" {
  name          = "alias/blue-rds-encryption"
  target_key_id = aws_kms_key.rds.key_id
}

# RDS Instance에 KMS 적용
resource "aws_db_instance" "main" {
  identifier = "petclinic-db"

  # ✅ Storage 암호화 활성화
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  # 암호화 범위
  # - DB 데이터 파일 (InnoDB 테이블스페이스)
  # - 자동 백업 (Automated Backups)
  # - DB 스냅샷 (Manual Snapshots)
  # - Read Replica
  # - 로그 파일 (Binary Log, Error Log)
}
```

**RDS 암호화 특징**:
- **AES-256 암호화**: 산업 표준 암호화 알고리즘
- **투명한 암호화 (TDE)**: 애플리케이션 코드 변경 불필요
- **성능 영향 최소**: 하드웨어 가속 (Intel AES-NI)
- **키 로테이션**: KMS가 자동으로 1년마다 새 키 생성

**암호화된 RDS 백업 복원**:
```bash
# 암호화된 스냅샷에서 복원 시 KMS 키 필요
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier petclinic-db-restored \
  --db-snapshot-identifier manual-snapshot-2026-01-13 \
  --kms-key-id arn:aws:kms:ap-northeast-2:xxx:key/xxx

# ✅ 같은 KMS 키 사용
# ❌ 다른 리전 복원 시: 리전별 KMS 키 필요 (Cross-Region Copy)
```

**Azure MySQL 암호화**:
```hcl
resource "azurerm_mysql_flexible_server" "main" {
  name = "mysql-dr-blue"

  # ✅ Azure는 기본적으로 Storage 암호화됨 (Platform-Managed Key)
  # Microsoft.Storage 서비스가 자동 관리

  # Customer-Managed Key (선택 사항)
  customer_managed_key {
    key_vault_key_id                  = azurerm_key_vault_key.mysql.id
    primary_user_assigned_identity_id = azurerm_user_assigned_identity.mysql.id
  }
}
```

#### 2. EBS Volume 암호화 (EKS Node)

```hcl
# KMS Key 생성 (EBS 전용)
resource "aws_kms_key" "ebs" {
  description             = "KMS key for EKS Node EBS encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "blue-ebs-kms-key"
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/blue-ebs-encryption"
  target_key_id = aws_kms_key.ebs.key_id
}

# EKS Node Launch Template
resource "aws_launch_template" "eks_node" {
  name_prefix = "blue-eks-node-"

  block_device_mappings {
    device_name = "/dev/xvda"  # Root Volume

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true  # ✅ EBS 암호화 활성화
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  # Metadata v2 (IMDSv2) 강제 (보안)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 강제
    http_put_response_hop_limit = 1
  }
}
```

**EBS 암호화 범위**:
```
/dev/xvda (20GB)
├── /boot (부트 파티션)
├── /var/lib/docker (Container Image 레이어)
│   ├── nginx:latest (Web Image)
│   └── petclinic-was:v3 (WAS Image)
├── /var/lib/kubelet (Pod 임시 데이터)
│   ├── EmptyDir 볼륨
│   └── Container writable layer
└── /var/log (시스템 로그)
    ├── kubelet.log
    └── container logs

모두 AES-256으로 암호화됨
```

**암호화 성능 영향**:
- **CPU 오버헤드**: Intel AES-NI 하드웨어 가속으로 1-3% 미만
- **IOPS 영향 없음**: gp3 3000 IOPS 그대로 유지
- **Throughput 영향 없음**: 125 MB/s 유지

**EBS 스냅샷도 자동 암호화**:
```bash
# EBS 스냅샷 생성 (자동으로 암호화됨)
aws ec2 create-snapshot \
  --volume-id vol-xxx \
  --description "EKS Node snapshot"

# 스냅샷 암호화 상태 확인
aws ec2 describe-snapshots \
  --snapshot-ids snap-xxx \
  --query 'Snapshots[0].[Encrypted,KmsKeyId]'
# 출력: [true, "arn:aws:kms:ap-northeast-2:xxx:key/xxx"]
```

#### 3. Container Image 보안 (Docker Hub)

**Image Signing (Docker Content Trust)**:
```bash
# Docker Content Trust 활성화
export DOCKER_CONTENT_TRUST=1

# Image Push 시 자동 서명
docker push cloud039/petclinic-was:v3
# → Notary 서버에 서명 저장

# Image Pull 시 서명 검증
docker pull cloud039/petclinic-was:v3
# → 서명 불일치 시 Pull 실패 (위조 방지)
```

**Trivy 취약점 스캔 (CI/CD)**:
```yaml
# GitHub Actions
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: cloud039/petclinic-was:v3
    format: 'sarif'
    severity: 'CRITICAL,HIGH'
    exit-code: '1'  # CRITICAL 발견 시 빌드 실패
```

#### 4. Azure Blob Storage 암호화

```hcl
resource "azurerm_storage_account" "backups" {
  name                = "bloberry01"
  resource_group_name = azurerm_resource_group.main.name
  location            = "koreacentral"

  # ✅ 기본 암호화: Microsoft-Managed Key (무료)
  # AES-256 암호화 자동 적용

  # 선택 사항: Customer-Managed Key (Azure Key Vault)
  # customer_managed_key {
  #   key_vault_key_id = azurerm_key_vault_key.storage.id
  #   user_assigned_identity_id = azurerm_user_assigned_identity.storage.id
  # }

  # ✅ HTTPS 전송 강제
  enable_https_traffic_only = true

  # ✅ TLS 버전 제한
  min_tls_version = "TLS1_2"
}
```

**Blob 암호화 범위**:
- ✅ MySQL 백업 파일 (petclinic-*.sql.gz)
- ✅ 점검 페이지 (index.html)
- ✅ Blob 메타데이터
- ✅ Blob 인덱스

---

## 🔑 Layer 4.5: WAF (Web Application Firewall)

### AWS WAF (CloudFront 연동)

```hcl
# WAF Web ACL 생성
resource "aws_wafv2_web_acl" "main" {
  name  = "blue-cloudfront-waf"
  scope = "CLOUDFRONT"  # CloudFront용 (us-east-1 리전)

  default_action {
    allow {}
  }

  # Rule 1: AWS Managed Rules - Core Rule Set (OWASP Top 10)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # SQL Injection 방어
        # XSS (Cross-Site Scripting) 방어
        # Local File Inclusion (LFI) 방어
        # Remote File Inclusion (RFI) 방어
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Rate Limiting (DDoS 방어)
  rule {
    name     = "RateLimitRule"
    priority = 2

    action {
      block {
        custom_response {
          response_code = 429  # Too Many Requests
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 2000  # 5분당 2000 요청
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Known Bad Inputs (SQL Injection 추가 방어)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: IP Reputation List (악성 IP 차단)
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationListMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "blue-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "blue-cloudfront-waf"
  }
}

# CloudFront에 WAF 연결
resource "aws_cloudfront_distribution" "main" {
  web_acl_id = aws_wafv2_web_acl.main.arn

  # ... (기존 CloudFront 설정)
}
```

**WAF 방어 시나리오**:

**1. SQL Injection 공격 차단**:
```
공격 요청:
GET /owners?lastName='; DROP TABLE owners;--

WAF 탐지:
- AWSManagedRulesCommonRuleSet
- Rule: SQLi_QUERYARGUMENTS
- Action: BLOCK (403 Forbidden)

사용자에게 전달 안됨 (CloudFront에서 차단)
```

**2. XSS 공격 차단**:
```
공격 요청:
POST /owners/new
Content: <script>alert('XSS')</script>

WAF 탐지:
- AWSManagedRulesCommonRuleSet
- Rule: XSS_BODY
- Action: BLOCK

애플리케이션 도달 전 차단
```

**3. DDoS 공격 방어**:
```
공격:
IP 1.2.3.4에서 5분간 5000 요청

WAF 탐지:
- RateLimitRule (2000 요청 초과)
- Action: BLOCK (429 Too Many Requests)

5분 후 자동 해제
```

**WAF 로그 분석 (CloudWatch Logs Insights)**:
```
fields @timestamp, httpRequest.clientIp, httpRequest.uri, action
| filter action = "BLOCK"
| stats count() by httpRequest.clientIp
| sort count desc
| limit 10

# 가장 많이 차단된 IP 확인
```

### Azure Application Gateway WAF

```hcl
resource "azurerm_application_gateway" "main" {
  name = "appgw-blue"

  sku {
    name     = "WAF_v2"  # ✅ WAF 활성화 (Standard_v2 → WAF_v2)
    tier     = "WAF_v2"
    capacity = 1
  }

  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention"  # Detection: 탐지만, Prevention: 차단
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"

    disabled_rule_group {
      rule_group_name = "REQUEST-920-PROTOCOL-ENFORCEMENT"
      rules           = [920300]  # 특정 규칙 비활성화 (False Positive)
    }

    file_upload_limit_mb     = 100
    max_request_body_size_kb = 128

    request_body_check = true
  }

  # ... (기존 App Gateway 설정)
}
```

**OWASP Core Rule Set (CRS) 3.2 포함 규칙**:
- **Protocol Enforcement**: HTTP 프로토콜 위반 차단
- **SQL Injection**: `' OR 1=1`, `UNION SELECT` 등
- **XSS**: `<script>`, `onerror=`, `javascript:` 등
- **Local File Inclusion**: `../../etc/passwd`
- **Remote File Inclusion**: `http://evil.com/shell.php`
- **Command Injection**: `; ls -la`, `| cat /etc/passwd`

---

## 🔑 Layer 4.6: Secret 관리

### Kubernetes Secret (기본)

```bash
# ✅ Database Credentials Secret 생성
kubectl create secret generic db-credentials \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was

# Secret 확인 (Base64 인코딩됨)
kubectl get secret db-credentials -n was -o yaml
```

**Kubernetes Secret 한계**:
- ❌ **Base64 인코딩만**: 암호화 아님 (누구나 디코딩 가능)
  ```bash
  echo "YnllbXlibHVl" | base64 -d
  # 출력: CHANGE_ME_DB_PASSWORD
  ```
- ❌ **etcd 평문 저장**: Kubernetes etcd에 평문 저장 (etcd 암호화 필요)
- ❌ **Git 커밋 불가**: Secret을 Git에 올리면 노출

### AWS Secrets Manager (권장)

```hcl
# Secrets Manager Secret 생성
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "blue/rds/petclinic"
  description             = "RDS MySQL credentials"
  recovery_window_in_days = 7

  tags = {
    Name = "blue-rds-credentials"
  }
}

# Secret 값 저장
resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = "admin"
    password = "CHANGE_ME_DB_PASSWORD"
    host     = aws_db_instance.main.address
    port     = 3306
    dbname   = "petclinic"
  })
}

# IAM Policy: WAS Pod가 Secret 읽기 허용
resource "aws_iam_policy" "read_secrets" {
  name = "blue-read-db-secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = aws_secretsmanager_secret.db_credentials.arn
    }]
  })
}

# IRSA: WAS Pod ServiceAccount에 연결
resource "aws_iam_role" "was_pod" {
  name = "blue-was-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:was:was-serviceaccount"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "was_pod_secrets" {
  role       = aws_iam_role.was_pod.name
  policy_arn = aws_iam_policy.read_secrets.arn
}
```

**Spring Boot에서 Secrets Manager 사용**:
```xml
<!-- pom.xml -->
<dependency>
    <groupId>software.amazon.awssdk</groupId>
    <artifactId>secretsmanager</artifactId>
    <version>2.20.0</version>
</dependency>
```

```java
// SecretsManagerConfig.java
@Configuration
public class SecretsManagerConfig {
    @Bean
    public DataSource dataSource() {
        SecretsManagerClient client = SecretsManagerClient.builder()
            .region(Region.AP_NORTHEAST_2)
            .build();

        GetSecretValueRequest request = GetSecretValueRequest.builder()
            .secretId("blue/rds/petclinic")
            .build();

        GetSecretValueResponse response = client.getSecretValue(request);
        JSONObject secret = new JSONObject(response.secretString());

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl("jdbc:mysql://" + secret.getString("host") + ":" +
                          secret.getInt("port") + "/" + secret.getString("dbname"));
        config.setUsername(secret.getString("username"));
        config.setPassword(secret.getString("password"));

        return new HikariDataSource(config);
    }
}
```

**Secrets Manager 장점**:
- ✅ **KMS 암호화**: Secret이 KMS로 암호화되어 저장
- ✅ **자동 로테이션**: 30일마다 비밀번호 자동 변경 가능
- ✅ **감사 로깅**: CloudTrail로 Secret 접근 추적
- ✅ **버전 관리**: Secret 변경 이력 추적
- ✅ **Cross-Account 공유**: 다른 AWS 계정과 공유 가능

**Secrets Manager 자동 로테이션 (RDS)**:
```hcl
resource "aws_secretsmanager_secret_rotation" "db_credentials" {
  secret_id           = aws_secretsmanager_secret.db_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn

  rotation_rules {
    automatically_after_days = 30  # 30일마다 자동 로테이션
  }
}

# Lambda 함수가 RDS 비밀번호 자동 변경
# 1. 새 비밀번호 생성
# 2. RDS에 새 사용자 생성 (temp)
# 3. 애플리케이션 검증
# 4. 기존 사용자 비밀번호 변경
# 5. temp 사용자 삭제
```

### Azure Key Vault

```hcl
# Key Vault 생성
resource "azurerm_key_vault" "main" {
  name                = "kv-dr-blue"
  resource_group_name = azurerm_resource_group.main.name
  location            = "koreacentral"
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Soft Delete 활성화 (실수 삭제 방지)
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  network_acls {
    default_action = "Deny"
    ip_rules       = ["YOUR_OFFICE_IP/32"]

    # AKS Subnet 허용
    virtual_network_subnet_ids = [
      azurerm_subnet.was.id
    ]
  }
}

# Secret 저장
resource "azurerm_key_vault_secret" "mysql_password" {
  name         = "mysql-admin-password"
  value        = "mysqladmin-password-here"
  key_vault_id = azurerm_key_vault.main.id

  content_type = "text/plain"

  tags = {
    Environment = "Production"
  }
}

# AKS Managed Identity에 Key Vault 접근 권한 부여
resource "azurerm_key_vault_access_policy" "aks" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_kubernetes_cluster.main.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}
```

**AKS에서 Key Vault Secret 사용 (CSI Driver)**:
```yaml
# SecretProviderClass
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-keyvault
  namespace: was
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: "<AKS-IDENTITY-CLIENT-ID>"
    keyvaultName: "kv-dr-blue"
    objects: |
      array:
        - |
          objectName: mysql-admin-password
          objectType: secret
          objectVersion: ""
    tenantId: "<TENANT-ID>"

---
# WAS Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-deployment
spec:
  template:
    spec:
      containers:
        - name: spring-boot
          volumeMounts:
            - name: secrets-store
              mountPath: "/mnt/secrets"
              readOnly: true
          env:
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: mysql-admin-password
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "azure-keyvault"
```

---

## 🔑 Layer 4.7: OIDC (OpenID Connect) - EKS IRSA

### OIDC Provider 설정

```hcl
# EKS OIDC Provider 생성
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "blue-eks-oidc-provider"
  }
}
```

**OIDC 동작 방식**:
```
1. Pod 시작
   └─> Kubernetes가 ServiceAccount Token 주입
       (/var/run/secrets/eks.amazonaws.com/serviceaccount/token)

2. Pod가 AWS API 호출
   └─> AWS SDK가 Token 읽기
       └─> STS AssumeRoleWithWebIdentity 호출
           └─> OIDC Token 전달

3. AWS STS가 Token 검증
   └─> OIDC Provider의 JWKS (JSON Web Key Set) 확인
       └─> Token Signature 검증
           └─> Token Claims 확인 (sub, aud, exp)

4. IAM Role 임시 자격증명 반환
   └─> Access Key ID, Secret Access Key, Session Token
       └─> 15분~1시간 유효

5. Pod가 AWS 서비스 접근
   └─> S3, Secrets Manager, ECR 등
```

**OIDC Token 예시** (JWT):
```json
{
  "iss": "https://oidc.eks.ap-northeast-2.amazonaws.com/id/xxxxx",
  "sub": "system:serviceaccount:was:was-serviceaccount",
  "aud": "sts.amazonaws.com",
  "exp": 1705147200,
  "iat": 1705143600,
  "kubernetes.io": {
    "namespace": "was",
    "serviceaccount": {
      "name": "was-serviceaccount",
      "uid": "abc-123"
    }
  }
}
```

**보안 장점**:
- ✅ **단기 자격증명**: 15분~1시간 후 자동 만료 (탈취 위험 낮음)
- ✅ **Pod별 권한**: 각 Pod가 독립적인 IAM Role
- ✅ **자격증명 노출 방지**: AWS Access Key 하드코딩 불필요
- ✅ **감사 추적**: CloudTrail에서 어떤 Pod가 어떤 API 호출했는지 추적

---

## 🔑 Layer 5: 인증/인가

### Kubernetes Secret 관리

#### 1. Database Credentials

```bash
# ✅ 올바른 방법: Kubernetes Secret
kubectl create secret generic db-credentials \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was

# ❌ 잘못된 방법: ConfigMap (평문 저장)
# ❌ 잘못된 방법: Deployment YAML에 하드코딩
```

**WAS Deployment에서 사용**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-deployment
spec:
  template:
    spec:
      containers:
        - name: spring-boot
          env:
            - name: SPRING_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
```

**Secret 보안 강화 (선택 사항)**:
```yaml
# Sealed Secrets (Bitnami)
# Secret을 암호화하여 Git에 저장 가능
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-credentials
  namespace: was
spec:
  encryptedData:
    username: AgBY8... (암호화된 값)
    password: AgCX9... (암호화된 값)
```

### EKS Endpoint 접근 제어

```hcl
resource "aws_eks_cluster" "main" {
  vpc_config {
    endpoint_public_access  = true
    endpoint_private_access = true

    # ✅ 특정 IP만 허용 (권장)
    public_access_cidrs = [
      "YOUR_OFFICE_IP/32",
      "YOUR_HOME_IP/32"
    ]

    # ⚠️ 현재 설정: 전체 허용 (개발 편의성)
    # public_access_cidrs = ["0.0.0.0/0"]
  }
}
```

**보안 강화 옵션**:
- ✅ Private Only + VPN
- ✅ Public Access CIDR 제한
- ✅ MFA 강제

---

## 🔑 Layer 6: 로깅 및 감사

### AWS CloudTrail (API 감사)

```hcl
resource "aws_cloudtrail" "main" {
  name                          = "blue-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # ✅ Data Events 로깅 (S3, Lambda)
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::*/"]
    }
  }

  tags = {
    Name = "blue-cloudtrail"
  }
}
```

**CloudTrail 로깅 예시**:
```json
{
  "eventTime": "2026-01-13T10:30:00Z",
  "eventName": "DeleteDBInstance",
  "userIdentity": {
    "type": "IAMUser",
    "principalId": "AIDAI...",
    "arn": "arn:aws:iam::123456789012:user/admin",
    "userName": "admin"
  },
  "requestParameters": {
    "dBInstanceIdentifier": "petclinic-db",
    "skipFinalSnapshot": false
  },
  "responseElements": null,
  "errorCode": "AccessDenied",
  "errorMessage": "User is not authorized to perform: rds:DeleteDBInstance"
}
```

**감사 시나리오**:
- 누가 RDS를 삭제하려 했는가?
- 누가 EKS 클러스터에 접근했는가?
- 어떤 IAM 권한이 사용되었는가?

### Kubernetes Audit Logs

```yaml
# EKS Control Plane Logging 활성화
resource "aws_eks_cluster" "main" {
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
}
```

**Audit Log 예시**:
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "xxx",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/was/secrets",
  "verb": "get",
  "user": {
    "username": "system:serviceaccount:was:default",
    "uid": "xxx",
    "groups": ["system:serviceaccounts"]
  },
  "sourceIPs": ["10.0.20.50"],
  "responseStatus": {
    "code": 403
  }
}
```

**감사 시나리오**:
- 누가 Secret을 읽으려 했는가? (403 Forbidden)
- 어떤 ServiceAccount가 권한 없는 API 호출?

---

## 🔑 Layer 7: 애플리케이션 보안

### Spring Boot Security 설정

#### 1. CSRF 보호

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf()
                .csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse())
            .and()
            .authorizeHttpRequests()
                .requestMatchers("/", "/resources/**", "/webjars/**").permitAll()
                .anyRequest().authenticated();

        return http.build();
    }
}
```

#### 2. SQL Injection 방어

```java
// ✅ 올바른 방법: Prepared Statement (JPA)
@Repository
public interface OwnerRepository extends JpaRepository<Owner, Long> {
    @Query("SELECT o FROM Owner o WHERE o.lastName LIKE :lastName%")
    List<Owner> findByLastName(@Param("lastName") String lastName);
}

// ❌ 잘못된 방법: String Concatenation
// String sql = "SELECT * FROM owners WHERE last_name = '" + lastName + "'";
// → SQL Injection 취약점
```

#### 3. XSS (Cross-Site Scripting) 방어

```html
<!-- ✅ Thymeleaf 자동 이스케이프 -->
<p th:text="${owner.firstName}">John</p>
<!-- 입력: <script>alert('XSS')</script> -->
<!-- 출력: &lt;script&gt;alert('XSS')&lt;/script&gt; -->

<!-- ❌ th:utext 사용 금지 (Raw HTML) -->
<!-- <p th:utext="${owner.firstName}"></p> -->
```

---

## 🛡️ 보안 체크리스트

### 배포 전 확인

- [ ] Security Group에 0.0.0.0/0:22 (SSH) 없음
- [ ] RDS는 Private Subnet에만 배치
- [ ] IAM Role에 AdministratorAccess 없음
- [ ] EKS Endpoint Public Access CIDR 제한
- [ ] RDS Storage Encryption 활성화
- [ ] CloudTrail 활성화
- [ ] Kubernetes Secret 사용 (ConfigMap 금지)

### 운영 중 모니터링

- [ ] CloudTrail 로그 정기 검토
- [ ] 비정상 API 호출 감지
- [ ] Failed Authentication 모니터링
- [ ] Security Group 변경 알림
- [ ] IAM 권한 변경 알림

---

## 📝 참고 문서

- **[AWS Security Best Practices](https://aws.amazon.com/architecture/security-identity-compliance/)**
- **[CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)**
- **[OWASP Top 10](https://owasp.org/www-project-top-ten/)**

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
