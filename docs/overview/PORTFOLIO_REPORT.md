# 3-Tier Multi-Cloud DR Infrastructure Project

## 프로젝트 개요

### 한 줄 소개
> AWS와 Azure를 활용한 엔터프라이즈급 3-Tier 멀티클라우드 재해복구(DR) 인프라 구축 프로젝트

### 프로젝트 기간
- 기간: 약 4주
- 역할: 클라우드 인프라 설계 및 구축

### 프로젝트 배경
기업 서비스의 고가용성 확보를 위해 단일 클라우드 장애 시에도 서비스 연속성을 보장하는 멀티클라우드 DR 환경이 필요했습니다. 금융 서비스(Spring PetClinic)를 기반으로 실제 운영 가능한 수준의 인프라를 구축했습니다.

---

## 아키텍처

### 전체 시스템 구성도

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CloudFront (CDN)                                │
│                         Origin Failover 패턴 적용                            │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │                                       │
          ▼                                       ▼
┌─────────────────────────┐           ┌─────────────────────────┐
│     AWS (Primary)       │           │    Azure (Secondary)    │
│     ap-northeast-2      │           │     Korea Central       │
├─────────────────────────┤           ├─────────────────────────┤
│                         │           │                         │
│  ┌───────────────────┐  │           │  ┌───────────────────┐  │
│  │       ALB         │  │           │  │  App Gateway      │  │
│  └─────────┬─────────┘  │           │  └─────────┬─────────┘  │
│            │            │           │            │            │
│  ┌─────────▼─────────┐  │           │  ┌─────────▼─────────┐  │
│  │   EKS Cluster     │  │           │  │   AKS Cluster     │  │
│  │  ┌─────┬─────┐    │  │           │  │  ┌─────┬─────┐    │  │
│  │  │ Web │ WAS │    │  │           │  │  │ Web │ WAS │    │  │
│  │  │Nginx│Spring│   │  │           │  │  │Nginx│Spring│   │  │
│  │  └─────┴─────┘    │  │           │  │  └─────┴─────┘    │  │
│  └─────────┬─────────┘  │           │  └─────────┬─────────┘  │
│            │            │           │            │            │
│  ┌─────────▼─────────┐  │  Backup   │  ┌─────────▼─────────┐  │
│  │   RDS MySQL       │──┼───────────┼─▶│  MySQL Flexible   │  │
│  │   (Multi-AZ)      │  │  (Daily)  │  │    Server         │  │
│  └───────────────────┘  │           │  └───────────────────┘  │
│                         │           │                         │
└─────────────────────────┘           └─────────────────────────┘
```

### 3-Tier 구조 상세

| Tier | AWS 구성 | Azure 구성 | 역할 |
|------|----------|------------|------|
| **Web** | EKS + Nginx | AKS + Nginx | 리버스 프록시, 정적 자원 |
| **WAS** | EKS + Spring Boot | AKS + Spring Boot | 비즈니스 로직 처리 |
| **DB** | RDS MySQL Multi-AZ | MySQL Flexible Server | 데이터 저장 |

### DR 전략: Pilot Light 패턴

```
평상시 (월 ~$5)                    장애 발생 시 (15-20분 내 활성화)
┌──────────────────┐               ┌──────────────────┐
│ Azure 최소 유지   │               │ Azure 전체 활성화 │
│ - VNet           │    ────▶      │ - AKS Cluster    │
│ - Storage        │   자동 배포    │ - MySQL Server   │
│ - 점검 페이지     │               │ - App Gateway    │
└──────────────────┘               └──────────────────┘
```

---

## 기술 스택

### Infrastructure as Code
| 기술 | 용도 |
|------|------|
| **Terraform** | 멀티클라우드 인프라 정의 및 관리 |
| **AWS Provider** | AWS 리소스 프로비저닝 |
| **Azure Provider** | Azure 리소스 프로비저닝 |

### AWS Services
| 서비스 | 용도 |
|--------|------|
| **VPC** | 네트워크 격리 (10.0.0.0/16) |
| **EKS** | Kubernetes 컨테이너 오케스트레이션 |
| **RDS MySQL** | 관계형 데이터베이스 (Multi-AZ) |
| **ALB** | L7 로드 밸런싱 |
| **CloudFront** | CDN + Origin Failover |
| **Route53** | DNS 관리 + Health Check |
| **CloudWatch** | 모니터링 + 알람 (40개) |
| **Lambda** | 자동 복구 함수 |
| **EventBridge** | 백업 스케줄링 |

### Azure Services
| 서비스 | 용도 |
|--------|------|
| **VNet** | 네트워크 격리 (172.16.0.0/16) |
| **AKS** | Kubernetes 컨테이너 오케스트레이션 |
| **MySQL Flexible Server** | DR용 데이터베이스 |
| **Application Gateway** | L7 로드 밸런싱 |
| **Blob Storage** | 백업 저장소 (30일 보관) |

### Application Stack
| 기술 | 용도 |
|------|------|
| **Spring Boot 3.x** | WAS 프레임워크 |
| **Nginx** | Web 리버스 프록시 |
| **MySQL 8.0** | 데이터베이스 |
| **Docker** | 컨테이너화 |

### CI/CD
| 기술 | 용도 |
|------|------|
| **GitHub Actions** | CI 파이프라인 |
| **ArgoCD** | GitOps CD |
| **Trivy** | 보안 스캔 |
| **SonarQube** | 코드 품질 분석 |

---

## 주요 구현 내용

### 1. 네트워크 설계

**AWS VPC 구성**
```
VPC: 10.0.0.0/16
├── Public Subnet (ALB)
│   ├── 10.0.1.0/24 (AZ-a)
│   └── 10.0.2.0/24 (AZ-c)
├── Web Subnet (Nginx)
│   ├── 10.0.11.0/24 (AZ-a)
│   └── 10.0.12.0/24 (AZ-c)
├── WAS Subnet (Spring)
│   ├── 10.0.21.0/24 (AZ-a)
│   └── 10.0.22.0/24 (AZ-c)
└── RDS Subnet (MySQL)
    ├── 10.0.31.0/24 (AZ-a)
    └── 10.0.32.0/24 (AZ-c)
```

### 2. 보안 구성

**Security Group 계층화**
```
Internet → ALB SG (80, 443)
              ↓
         EKS SG (Pod 포트)
              ↓
         RDS SG (3306)
```

**적용된 보안 기능**
- HTTPS 암호화 (ACM 인증서)
- IAM Role 기반 권한 관리
- Security Group 화이트리스트
- RDS 암호화 (AWS KMS)
- Secrets Manager 자격증명 관리

### 3. 모니터링 시스템

**CloudWatch 알람 (40개)**

| 분류 | 알람 수 | 주요 메트릭 |
|------|---------|-------------|
| 노드 메트릭 | 5 | CPU, Memory, Disk, 노드 수 |
| ALB 메트릭 | 5 | 5XX 에러, 응답시간, 큐 길이 |
| RDS 메트릭 | 7 | 저장소, 연결 수, IOPS |
| Pod 메트릭 | 8 | CPU, Memory, 재시작 횟수 |
| Health Check | 6 | AWS/Azure 헬스 상태 |

**자동 복구 Lambda**
- Pod 재시작 5회 초과 시 자동 조치
- 노드 장애 감지 시 스케일링 조정
- 복구 결과 SNS 알림

### 4. 백업 자동화

**일일 백업 파이프라인**
```
RDS MySQL
    ↓ EventBridge (03:00 UTC)
EC2 Backup Instance
    ↓ mysqldump + gzip
Azure Blob Storage
    ↓ 30일 보관
자동 삭제 (Lifecycle Policy)
```

### 5. CI/CD 파이프라인

```
GitHub Push
    ↓
Build & Test (Maven)
    ↓
Security Scan (Trivy, OWASP)
    ↓
Docker Build & Push
    ↓
GitOps Update (Kustomize)
    ↓
ArgoCD Sync
    ↓
Deployment Verification
```

---

## 성과 및 결과

### 정량적 성과

| 지표 | 목표 | 달성 |
|------|------|------|
| **RTO** (복구 시간) | 30분 | 21분 |
| **RPO** (데이터 손실) | 24시간 | 24시간 |
| **DR 대기 비용** | $20/월 | ~$10/월 |
| **가용성** | 99.9% | Multi-AZ + DR |
| **모니터링 커버리지** | - | 40개 알람 |

### 비용 최적화

| 구성 요소 | 월 비용 (추정) |
|-----------|---------------|
| AWS Primary | ~$150-200 |
| Azure Standby | ~$5-10 |
| **총 비용** | **~$160-210** |

*Pilot Light 패턴으로 상시 DR 비용 90% 절감*

---

## 트러블슈팅 경험

### 1. EKS 삭제 시 Security Group 종속성 에러

**문제**: `terraform destroy` 시 AWS Load Balancer Controller가 생성한 리소스가 남아 삭제 실패

**해결**: 490줄의 cleanup provisioner 스크립트 구현
- ENI 자동 정리
- Target Group 종속성 해제
- Load Balancer 삭제 대기

### 2. 백업 인스턴스 AZ 정렬 문제

**문제**: RDS와 백업 인스턴스가 다른 AZ에 배치되어 네트워크 지연 발생

**해결**: 동적 AZ 할당 로직 구현
```hcl
data "aws_db_instance" "rds" {
  db_instance_identifier = var.rds_identifier
}

resource "aws_instance" "backup" {
  availability_zone = data.aws_db_instance.rds.availability_zone
  # ...
}
```

### 3. CloudFront Origin Failover 구성

**문제**: 자동 페일오버 시 캐시 무효화 지연

**해결**:
- Health Check 간격 최적화 (10초)
- 캐시 TTL 조정
- Custom Error Response 설정

---

## 프로젝트 구조

```
3tier-terraform/
├── codes/
│   ├── aws/
│   │   ├── 1. route53/          # DNS + Failover
│   │   ├── 2. service/          # 메인 인프라
│   │   │   ├── modules/
│   │   │   │   ├── vpc/         # 네트워크
│   │   │   │   ├── eks/         # Kubernetes
│   │   │   │   ├── rds/         # 데이터베이스
│   │   │   │   └── alb/         # 로드밸런서
│   │   │   └── k8s-manifests/   # K8s 배포 파일
│   │   ├── 3. monitoring/       # CloudWatch
│   │   └── 4-cicd/              # ArgoCD
│   │
│   └── azure/
│       ├── 1-always/            # 상시 대기 (~$5/월)
│       └── 2-emergency/         # 긴급 복구
│           └── modules/
│               ├── db/          # MySQL
│               ├── aks/         # Kubernetes
│               └── appgw/       # App Gateway
│
├── docs/                        # 문서 (20개)
└── scripts/                     # 운영 스크립트
```

---

## 학습 및 성장

### 기술적 역량 향상

| 영역 | 학습 내용 |
|------|-----------|
| **Terraform** | 모듈 설계, 상태 관리, 복잡한 종속성 처리 |
| **Kubernetes** | EKS/AKS 클러스터 관리, Helm, 리소스 최적화 |
| **AWS** | VPC 설계, EKS, RDS Multi-AZ, CloudWatch |
| **Azure** | VNet, AKS, MySQL Flexible Server |
| **DR 전략** | Pilot Light, RTO/RPO 설계, Failover 자동화 |
| **CI/CD** | GitHub Actions, ArgoCD, GitOps |

### 얻은 인사이트

1. **IaC의 중요성**: 재현 가능한 인프라로 DR 테스트 시간 대폭 단축
2. **비용 최적화**: Pilot Light 패턴으로 DR 비용 90% 절감 가능
3. **모니터링 필수**: 40개 알람으로 사전 장애 감지 및 자동 복구
4. **문서화**: 20개 가이드 문서로 운영 효율성 향상

---

## 향후 개선 계획

| 우선순위 | 개선 사항 | 기대 효과 |
|----------|-----------|-----------|
| 높음 | DMS를 통한 실시간 DB 복제 | RPO 24시간 → 분 단위 |
| 높음 | Route53 자동 Failover | 수동 전환 → 자동 전환 |
| 중간 | VPC Endpoint 적용 | 보안 강화 |
| 중간 | Chaos Engineering 도입 | DR 테스트 자동화 |
| 낮음 | 비용 알람 추가 | 예산 관리 개선 |

---

## 관련 링크

- **GitHub Repository**: [3tier-terraform](https://github.com/c1oud9/3tier-terraform)
- **기술 문서**: [docs/README.md](/docs/README.md)
- **트러블슈팅 가이드**: [docs/runbooks/troubleshooting.md](/docs/runbooks/troubleshooting.md)
- **DR 절차서**: [docs/dr-failover-procedure.md](/docs/runbooks/dr-failover-procedure.md)

---

## 기술 키워드

`Terraform` `AWS` `Azure` `Multi-Cloud` `DR` `EKS` `AKS` `Kubernetes` `RDS` `MySQL` `CloudFront` `Route53` `CloudWatch` `Lambda` `GitHub Actions` `ArgoCD` `GitOps` `Spring Boot` `Nginx` `Docker` `IaC` `High Availability` `Pilot Light`
