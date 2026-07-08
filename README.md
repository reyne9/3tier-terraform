# Multi-Cloud Disaster Recovery Solution

**AWS (Primary) ↔ Azure (Secondary DR)**

엔터프라이즈급 3-tier 웹 애플리케이션을 위한 Multi-Cloud 재해 복구(DR) 솔루션입니다. Infrastructure as Code(Terraform)를 활용하여 AWS 장애 시 Azure로 전환되는 고가용성 아키텍처를 구현했습니다.

---

## 🎯 프로젝트 목표

- **고가용성(HA)**: 단일 클라우드 장애에도 서비스 지속
- **자동화**: Terraform을 통한 인프라 코드화 및 재현 가능한 배포
- **비용 최적화**: Backup & Restore 패턴으로 DR 사이트 대기 비용 최소화
- **실전 적용**: 실제 Spring PetClinic 애플리케이션 기반 검증

---

## 🏗️ 시스템 아키텍처

### 전체 구조

포트폴리오용 최신 아키텍처 다이어그램은 [docs/interview-prep/architecture-slides](/docs/interview-prep/architecture-slides)에서 확인할 수 있습니다.

![Multi-Cloud DR Overview](/docs/interview-prep/architecture-slides/01-overview-flow.png)


### 기술 스택

#### Infrastructure as Code
- **Terraform** 1.14.0+
  - AWS Provider ~> 6.0
  - Azure Provider ~> 3.0
  - Kubernetes Provider

#### AWS Services
- **Compute**: EKS (Kubernetes 1.34)
- **Database**: RDS MySQL Multi-AZ
- **Networking**: VPC, ALB, Route53, CloudFront
- **Backup**: EC2 Instance + Azure Blob Storage
- **Monitoring**: CloudWatch

#### Azure Services
- **Compute**: AKS (Azure Kubernetes Service)
- **Database**: MySQL Flexible Server
- **Networking**: VNet, Application Gateway
- **Storage**: Blob Storage (백업 수신)

#### Application
- **Spring PetClinic**: Spring Boot 3.x 기반 동물병원 관리 애플리케이션
  - WAS: `cloud039/petclinic-was:v3` (Spring Boot + MySQL)
  - Web: `cloud039/petclinic-web:v1` (Nginx reverse proxy)
- **Container**: Docker + Kubernetes Deployment

---

## 📂 프로젝트 구조

```
3tier-terraform/
├── codes/
│   ├── aws/
│   │   ├── 1. route53/       # DNS 및 CloudFront Failover
│   │   ├── 2. service/       # AWS 인프라 (VPC, EKS, RDS, Backup)
│   │   ├── 3. monitoring/    # CloudWatch 알람, 대시보드, 자동 복구 Lambda
│   │   └── 4-cicd/          # CI/CD (GitHub Actions, Keptn)
│   └── azure/
│       ├── 1-always/         # 상시 대기 리소스 (Storage, VNet, 점검 페이지)
│       └── 2-emergency/      # 재해 복구 리소스 (MySQL, AKS, App Gateway)
├── docs/
│   ├── overview/                 # 포트폴리오와 프로젝트 개요
│   ├── runbooks/                 # 배포, DR, 테스트, 삭제, 트러블슈팅 절차
│   ├── architecture/             # AWS/Azure/보안/Failover 상세 설계
│   └── interview-prep/           # 면접 복습 자료 및 최신 아키텍처 다이어그램
└── README.md
```

### 디렉토리별 상세 설명

| 디렉토리 | 설명 | 관련 문서 |
|----------|------|-----------|
| `codes/aws/1. route53/` | CloudFront Origin Failover, Route53 DNS 관리 | [route53-health-check-guide.md](/docs/architecture/route53-health-check-guide.md) |
| `codes/aws/2. service/` | VPC, EKS, RDS, 백업 인스턴스 - AWS Primary Site 핵심 인프라 | [deployment-guide.md](/docs/runbooks/deployment-guide.md) |
| `codes/aws/3. monitoring/` | CloudWatch 알람 (20+), 대시보드, 자동 복구 Lambda | [PORTFOLIO_REPORT.md](/docs/overview/PORTFOLIO_REPORT.md) |
| `codes/aws/4-cicd/` | GitHub Actions, Keptn 기반 CI/CD 파이프라인 | [README.md](codes/aws/4-cicd/README.md) |
| `codes/azure/1-always/` | 상시 대기 (~$5/월): VNet, Storage, 점검 페이지 | [README.md](codes/azure/1-always/README.md) |
| `codes/azure/2-emergency/` | 긴급 복구 시 배포: MySQL, AKS, Application Gateway, PetClinic 매니페스트 | [README.md](codes/azure/2-emergency/README.md) |
| `docs/` | 포트폴리오, 실행 절차, 아키텍처 상세, 면접 대비 자료 | [README.md](/docs/README.md) |
| `docs/interview-prep/` | 면접 대비 복습 자료, 실제 구현 상세, Q&A 카드, 포트폴리오 다이어그램 | [README.md](/docs/interview-prep/README.md) |

---

## 🚀 핵심 기능

### 1. **Backup & Restore DR 패턴**
- **평상시**: Azure에 최소 리소스만 유지 (Storage, VNet, 점검 페이지)
- **장애 시**: 15-20분 내 전체 인프라 배포 및 백업 복구
- **비용 효율**: 대기 비용 ~$5/월, 복구 시에만 전체 비용 발생

### 2. **자동 백업 시스템**
```
AWS RDS → EC2 Backup Instance → Azure Blob Storage
         (매일 03:00 UTC)         (30일 보관)
```
- mysqldump 기반 논리 백업
- 압축 후 Azure Blob Storage 전송
- Blob Lifecycle Policy로 자동 정리

### 3. **Multi-Cloud Failover**
- **CloudFront Origin Failover**: Primary(AWS) 장애 시 Secondary(Azure 점검 페이지)로 자동 전환
- **수동 DR**: Azure 2-emergency 배포 후 CloudFront origin 업데이트
- **Application Gateway**: Azure AKS → PetClinic 서비스 프록시
- **SSL/TLS**: AppGwSslPolicy20220101 (TLS 1.2+)

### 4. **Infrastructure as Code**
```bash
# 예시: Azure 2-emergency 배포
cd codes/azure/2-emergency
terraform init
terraform apply
# → 15-20분 내 MySQL, AKS, App Gateway 자동 생성

# PetClinic 애플리케이션 배포
cd scripts
./deploy-complete.sh
# → 5-10분 내 WAS/Web Pod 배포 및 LoadBalancer 설정
```

### 5. **모니터링 및 로깅**
- CloudWatch 대시보드 (EKS, RDS 메트릭)
- Kubernetes Pod 로그 수집
- Azure Monitor (AKS, MySQL)

---

## 🔑 핵심 기술 결정 사항

### 1. CloudFront Origin Failover
- **1단계 Failover**: AWS 장애 시 Azure 점검 페이지로 자동 전환
- **2단계 DR**: Azure 2-emergency 배포 후 CloudFront origin 수동 업데이트
- **장점**:
  - HTTPS 종단점 제공
  - 전 세계 엣지 캐싱으로 성능 향상
  - 1단계는 자동 failover (점검 페이지)
- **트레이드오프**: 완전한 서비스 복구는 수동 작업 필요

### 2. Kubernetes 기반 배포
- **선택**: EKS(AWS) + AKS(Azure)
- **이유**:
  - 컨테이너 기반 일관된 배포
  - Auto-scaling으로 트래픽 대응
  - 양쪽 클라우드에서 동일한 배포 방식
- **트레이드오프**: VM 대비 복잡성 증가

### 3. MySQL Backup 전략
- **선택**: mysqldump + Azure Blob Storage
- **이유**:
  - 클라우드 간 이동 가능한 논리 백업
  - 압축으로 전송 비용 절감
  - Azure에서 직접 복원 가능
- **대안 고려**: AWS Database Migration Service (실시간 복제, 비용 높음)

### 4. Application Gateway Backend
- **선택**: AKS LoadBalancer IP 직접 참조
- **이유**: 간단한 구조, 빠른 구현
- **개선 필요**: Terraform data source로 동적 조회 (현재 하드코딩)

---

## 📊 재해 복구 시나리오

### 시나리오: AWS ap-northeast-2 리전 완전 마비

| 단계 | 작업 | 소요 시간 | 상태 |
|------|------|-----------|------|
| T+0  | AWS 장애 감지 | - | 🔴 서비스 중단 |
| T+0  | CloudFront 자동 failover → Azure 점검 페이지 | 즉시 | 🟡 점검 중 |
| T+1  | 담당자 Azure 2-emergency 리소스 배포 시작 | 1분 | 🟡 복구 중 |
| T+15 | MySQL + AKS + App Gateway 프로비저닝 완료 | 14분 | 🟡 복구 중 |
| T+20 | PetClinic 애플리케이션 배포 완료 | 5분 | 🟡 복구 중 |
| T+21 | CloudFront origin을 Azure App Gateway로 수동 전환 | 1분 | 🟢 Azure로 서비스 |
| 합계 | | **21분** | ✅ 복구 완료 |

**RTO (Recovery Time Objective)**: 21분 (Backup & Restore 패턴)
**RPO (Recovery Point Objective)**: 24시간 (마지막 백업 기준)
**Failover to Maintenance Page**: 즉시 (자동)

---

## 🧪 테스트 및 검증

### 장애 시뮬레이션 테스트

```bash
# 1. AWS EKS 노드 그룹 스케일 다운
aws eks update-nodegroup-config \
  --cluster-name eks-prod \
  --nodegroup-name web-nodes \
  --scaling-config minSize=0,maxSize=0,desiredSize=0

# 2. CloudFront origin을 Azure로 전환
aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file://azure-config.json

# 3. 접속 확인
curl -I https://blueisthenewblack.store/
# HTTP/2 200 ✅
```

**검증 결과**: 5분 내 정상 서비스 복구 확인

---

## 💰 비용 분석

### 평상시 (AWS Primary + Azure Standby)
| 항목 | AWS | Azure | 합계 |
|------|-----|-------|------|
| Compute | EKS: $73/월 | - | $73 |
| Database | RDS Multi-AZ: $145/월 | - | $145 |
| Storage | - | Blob: $5/월 | $5 |
| Network | ALB: $25/월 | VNet: $0 | $25 |
| **월 합계** | **$243** | **$5** | **$248** |

### 장애 복구 시 (Azure Full Activation)
| 항목 | 비용 | 기간 |
|------|------|------|
| AKS | $73/월 | 복구 기간 |
| MySQL | $50/월 | 복구 기간 |
| App Gateway | $30/월 | 복구 기간 |
| **시간당** | **약 $0.21** | - |

---

## 🔧 개선 계획

### 완료된 기능
- [✅] CloudFront Origin Failover (점검 페이지 자동 전환)
- [✅] CI/CD 파이프라인 (GitHub Actions + Keptn)
- [✅] Azure 2-emergency 자동 배포 스크립트
- [✅] MySQL username 검증 로직 추가

### 개선 계획
- [ ] Application Gateway Backend IP 동적 조회 (Terraform data source)
- [ ] Azure Front Door 도입 (WAF, DDoS 보호)
- [ ] Prometheus + Grafana 모니터링
- [ ] 실시간 데이터베이스 복제 (AWS DMS)

---

## 📚 문서

### 핵심 문서
- **[포트폴리오 보고서](/docs/overview/PORTFOLIO_REPORT.md)**: 전체 프로젝트 개요 및 설계 철학
- **[배포 가이드](/docs/runbooks/deployment-guide.md)**: AWS 및 Azure 인프라 배포 가이드
- **[DR 절차서](/docs/runbooks/dr-failover-procedure.md)**: 재해 복구 체크리스트
- **[트러블슈팅](/docs/runbooks/troubleshooting.md)**: 문제 해결 가이드

### 세부 문서
- **[DR 테스트 가이드](/docs/runbooks/DR_TEST_GUIDE.md)**: 재해 복구 시뮬레이션 테스트
- **[인프라 삭제 가이드](/docs/runbooks/DESTROY_GUIDE.md)**: Terraform destroy 순서
- **[Route53 헬스체크 가이드](/docs/architecture/route53-health-check-guide.md)**: CloudFront failover 설정
- **[Failover 구성](/docs/architecture/FAILOVER_CONFIGURATION.md)**: Failover 상세 설정

---

## 🤝 기여

이슈와 PR은 언제나 환영합니다!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 라이선스

이 프로젝트는 MIT 라이선스를 따릅니다.

---

## ✨ 주요 학습 포인트

이 프로젝트를 통해 다음을 학습할 수 있습니다:

- ✅ **Terraform**을 이용한 Infrastructure as Code
- ✅ **Multi-Cloud** 아키텍처 설계 및 구현
- ✅ **Kubernetes**(EKS, AKS) 컨테이너 오케스트레이션
- ✅ **DR(재해 복구)** 전략 수립 및 테스트
- ✅ **네트워크** 설계 (VPC, Subnet, Load Balancer)
- ✅ **데이터베이스** 백업 및 복구
- ✅ **모니터링 및 로깅**
- ✅ **문제 해결 능력** (실전 트러블슈팅)

---

---

## ✅ 배포 현황

### 현재 운영 중 (2025-12-28)

| 구분 | 상태 | 엔드포인트 |
|------|------|------------|
| **Production** | 🟢 운영 중 | https://blueisthenewblack.store |
| AWS Primary | 🟢 Active | k8s-web-webingre-5d0cf16a97-1358663516.ap-northeast-2.elb.amazonaws.com |
| Azure Secondary | 🟢 Standby | bloberry01.z12.web.core.windows.net |
| CloudFront | 🟢 Deployed | E2OX3Z0XHNDUN |

### 배포 구성
- **Container Registry**: DockerHub (cloud039)
- **WAS Image**: `cloud039/petclinic-was:v3`
- **Web Image**: `cloud039/petclinic-web:v1`
- **EKS Cluster**: blue-eks (Kubernetes 1.34)
- **AKS Cluster**: aks-dr-blue (Kubernetes 1.34)
- **Database**: RDS MySQL Multi-AZ (Primary), Azure MySQL Flexible Server (DR)
- **Auto-Scaling**: AWS Web (2 pods), WAS (1 pod) / Azure Web (1 pod), WAS (1 pod)

### 최근 변경사항
- 2026-01-13: Azure 2-emergency 배포 및 DR 테스트 완료
- 2026-01-13: MySQL username 검증 로직 추가 (mysqladmin 강제)
- 2026-01-13: Application Gateway backend IP 동적 업데이트 스크립트 추가
- 2026-01-12: DR 전략 Pilot Light → Backup & Restore로 명확화

---

**문서 버전**: v2.3
**최종 수정**: 2026-01-13
**작성자**: I2ST-blue

**프로젝트 데모**: https://blueisthenewblack.store
**애플리케이션**: Spring Boot PetClinic v3.0 (동물병원 관리 애플리케이션)
