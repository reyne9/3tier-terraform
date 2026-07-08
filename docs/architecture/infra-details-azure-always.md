# Azure 1-always 인프라 상세 설명

**디렉토리**: `/codes/azure/1-always/`

**목적**: Backup & Restore DR 전략을 위한 최소 비용 상시 대기 리소스

---

## 📋 개요

이 디렉토리는 **평상시 항상 실행되는 Azure 리소스**를 구성합니다. Backup & Restore DR 전략의 핵심은 **대부분의 리소스는 중지 상태**로 유지하여 비용을 최소화하고, **꼭 필요한 리소스만 실행**하는 것입니다.

### 상시 실행 리소스 (월 $5)

1. **Storage Account**: AWS RDS 백업 저장 + 점검 페이지 호스팅
2. **Virtual Network**: 서브넷 미리 구성 (비용 없음)
3. **Resource Group**: Azure 리소스 논리적 그룹핑 (비용 없음)

### DR 시에만 실행 리소스 (평상시 $0)

- AKS (Azure Kubernetes Service)
- MySQL Flexible Server
- Application Gateway
- Public IP

---

## 🔑 핵심 설계 결정

### 1. Backup & Restore DR 전략 선택

#### 선택: Backup & Restore (Cold Standby)

```
평상시:
┌─────────────────────────────────────┐
│  AWS Primary (Full Running)         │
│  - EKS: $194/월                      │
│  - RDS: $72/월                       │
│  - NAT Gateway: $66/월               │
│  총: $368/월                         │
└─────────────────────────────────────┘
           ↓ 백업 (매일 자동)
┌─────────────────────────────────────┐
│  Azure Standby (Minimal)            │
│  - Storage Account: $5/월            │
│  - AKS: $0 (중지)                    │
│  - MySQL: $0 (중지)                  │
│  총: $5/월                           │
└─────────────────────────────────────┘

장애 시:
┌─────────────────────────────────────┐
│  AWS Primary (장애!)                 │
│  X 서비스 중단                        │
└─────────────────────────────────────┘
           ↓ CloudFront 자동 Failover
┌─────────────────────────────────────┐
│  Azure Static Website (점검 페이지)  │
│  "서비스 점검 중입니다"               │
└─────────────────────────────────────┘
           ↓ 수동 DR 배포 (15분)
┌─────────────────────────────────────┐
│  Azure Emergency (Full Running)      │
│  - AKS 배포                          │
│  - MySQL 복원 (백업에서)             │
│  - App Gateway 배포                  │
│  총: $250/월 (DR 기간만)             │
└─────────────────────────────────────┘
```

#### 왜 Backup & Restore인가?

**DR 전략 비교**

| 전략 | RTO | RPO | 평상시 비용 | DR 시 비용 | 선택 |
|------|-----|-----|-----------|-----------|------|
| **Backup & Restore** ✅ | 15-30분 | 1시간 | $5/월 | $250/월 (DR 시만) | ✅ |
| Pilot Light | 5-10분 | 5분 | $100/월 | $250/월 | ❌ |
| Warm Standby | 1-5분 | 실시간 | $250/월 | $250/월 | ❌ |
| Hot Standby (Active-Active) | 0분 | 0 | $500/월 | $500/월 | ❌ |

**선택 이유**:

1. **비용 효율 극대화** (98% 비용 절감)
   - Warm Standby 대비: $250/월 → $5/월 (1/50)
   - 연간 비용: $3000/월 → $60/월 + DR 비용 (거의 발생 안함)

2. **포트폴리오 프로젝트 목적 달성**
   - 실무 Multi-Cloud DR 경험 증명
   - Terraform + Kubernetes 자동화 능력 입증
   - 비용 제약 내에서 고가용성 구현

3. **허용 가능한 RTO** (15-30분)
   - 재해 상황에서 15분은 합리적 복구 시간
   - PetClinic은 Mission-Critical 서비스 아님 (금융, 의료 아님)
   - 점검 페이지로 사용자 안내 가능

4. **RPO 1시간 허용**
   - 매일 자동 백업 (mysqldump)
   - 최악의 경우 1시간 데이터 손실 (애완동물 예약 데이터)
   - Mission-Critical 서비스는 RPO 0 필요 (Warm Standby)

**트레이드오프**:
- 수동 개입 필요 (terraform apply 실행)
- 15분 복구 시간 동안 서비스 중단 (점검 페이지만 표시)
- 최근 1시간 데이터 손실 가능

**대안 비교**:

**Pilot Light (기각)**:
```
평상시:
  - RDS Read Replica: $72/월
  - EC2 t3.micro (백업 인스턴스): $7/월
  - VPC: $0
  총: $79/월

DR 시:
  - EKS 배포 (5분)
  - RDS Read Replica → Primary 승격 (5분)
  RTO: 10분

기각 이유:
  - 월 $79는 포트폴리오 프로젝트에 과도 (연간 $948)
  - RTO 10분 vs 15분 차이는 프로젝트 목표에 큰 의미 없음
  - Pilot Light 개념 학습은 Backup & Restore로도 충분히 증명
```

**Warm Standby (기각)**:
```
평상시:
  - AKS (1 Node): $100/월
  - MySQL: $70/월
  - App Gateway: $50/월
  - VNet: $0
  총: $220/월

DR 시:
  - AKS Scale-out (1분)
  - DNS 전환 (1분)
  RTO: 2분

기각 이유:
  - 연간 $2640는 개인 프로젝트에 부담
  - RTO 2분 vs 15분은 PetClinic에서 큰 차이 없음
  - Backup & Restore로도 DR 개념 충분히 증명 가능
```

**Hot Standby / Active-Active (기각)**:
```
평상시:
  - AWS Full Running: $368/월
  - Azure Full Running: $250/월
  - Global Load Balancer: $20/월
  총: $638/월

DR 시:
  - RTO: 0분 (자동 Failover)
  - RPO: 0 (실시간 복제)

기각 이유:
  - 연간 $7656는 상용 서비스 수준 (개인 프로젝트 불가능)
  - 프로젝트 목표: "비용 효율적 DR" ≠ Active-Active
  - 금융/의료 서비스가 아닌 PetClinic에 과도
```

---

### 2. Storage Account 설계 (Dual Purpose)

#### 구성: Standard LRS

```hcl
resource "azurerm_storage_account" "backups" {
  name                     = "bloberry01"  # 전역 고유 이름
  resource_group_name      = azurerm_resource_group.main.name
  location                 = "koreacentral"
  account_tier             = "Standard"
  account_replication_type = "LRS"  # Locally Redundant Storage

  static_website {
    index_document = "index.html"
  }

  blob_properties {
    versioning_enabled = true  # 실수 삭제 방지
  }
}

# Purpose 1: MySQL 백업 저장
resource "azurerm_storage_container" "mysql_backups" {
  name                  = "backups"
  storage_account_name  = azurerm_storage_account.backups.name
  container_access_type = "private"  # 외부 접근 차단
}

# Purpose 2: 점검 페이지 호스팅 ($web 컨테이너 자동 생성)
resource "azurerm_storage_blob" "maintenance_page" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.backups.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"

  source_content = <<HTML
<!DOCTYPE html>
<html lang="ko">
<head>
    <title>서비스 점검 중</title>
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
        }
        .container {
            background: white;
            border-radius: 20px;
            padding: 60px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔧 서비스 점검 중입니다</h1>
        <p>현재 시스템 유지보수 작업이 진행 중입니다.</p>
        <p>빠른 시일 내에 정상화하겠습니다.</p>
    </div>
</body>
</html>
HTML
}
```

#### 왜 Storage Account를 이중 용도로 사용하는가?

**단일 리소스, 이중 목적**

| 목적 | 컨테이너 | 용량 | 비용 |
|------|---------|------|------|
| **MySQL 백업** | `backups` | 5GB (30일 보관) | $0.10 |
| **점검 페이지** | `$web` | 1MB (HTML/CSS) | $0.00 |
| **합계** | | 5.001GB | **$0.10/월** |

**설계 이유**:

1. **비용 최소화**
   - 별도 VM/App Service 불필요 ($10~50/월 절감)
   - Storage Account 기본 비용 없음 (사용량만 과금)
   - 5GB × $0.02/GB = $0.10/월

2. **Static Website 기능**
   ```
   Azure Storage Static Website:
   - $web 컨테이너 자동 생성
   - index.html, error.html 자동 라우팅
   - CDN 연동 가능 (선택 사항)
   - HTTPS 자동 지원
   ```
   vs. Azure App Service: $10/월 (B1 Basic)

3. **고가용성**
   - LRS: 3개 복제본 (같은 데이터센터 내)
   - 99.9% SLA
   - 점검 페이지는 항상 접근 가능

4. **Versioning으로 실수 방지**
   ```hcl
   blob_properties {
     versioning_enabled = true
   }
   ```
   - 백업 파일 실수 삭제 시 복구 가능
   - 최대 30일 이전 버전 복원

**Storage Replication 옵션 비교**

| 옵션 | 복제본 | 가용성 | 비용 (GB당) | 선택 |
|------|--------|--------|-----------|------|
| **LRS** ✅ | 3개 (단일 DC) | 99.9% | $0.02 | ✅ |
| ZRS | 3개 (3 AZ) | 99.99% | $0.025 | ❌ |
| GRS | 6개 (Primary + Secondary 리전) | 99.99999999% | $0.04 | ❌ |
| RA-GRS | GRS + Read Access | 99.99999999% | $0.05 | ❌ |

**LRS 선택 이유**:
- **백업 파일**: 이미 AWS에 원본 있음 (다중화 불필요)
- **점검 페이지**: 단순 HTML (복잡한 HA 불필요)
- **비용 최소화**: GRS는 2배 비용 ($0.02 → $0.04)

**대안 기각**:

**Azure App Service (기각)**:
```
장점:
  - 동적 콘텐츠 지원 (PHP, Node.js)
  - Custom Domain 쉬움
단점:
  - 최소 $10/월 (B1 Basic)
  - 정적 HTML만 필요한데 과도
  - 추가 설정 복잡 (Deployment Slot 등)
```

**Azure Static Web Apps (기각)**:
```
장점:
  - GitHub Actions 통합 강력
  - Global CDN 무료 포함
  - 무료 플랜 존재
단점:
  - GitHub Repo 필수 (점검 페이지는 Terraform으로 충분)
  - Storage Account보다 복잡
  - Blob Storage와 별도 관리 필요
```

---

### 3. Lifecycle Management (백업 자동 삭제)

#### 구성: 30일 후 자동 삭제

```hcl
resource "azurerm_storage_management_policy" "backup_lifecycle" {
  storage_account_id = azurerm_storage_account.backups.id

  rule {
    name    = "deleteOldBackups"
    enabled = true

    filters {
      prefix_match = ["backups/petclinic-*.sql.gz"]  # 백업 파일만
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 30
      }
    }
  }
}
```

#### 왜 30일인가?

**백업 보관 정책**

```
Day 1~7:   일별 백업 (7개)
Day 8~30:  주간 백업 (3-4개)
Day 31+:   자동 삭제

총 백업 파일: 약 10-12개
파일 크기: 500MB (압축)
스토리지 사용량: 5-6GB
월 비용: 5GB × $0.02 = $0.10
```

**30일 선택 이유**:

1. **규제 요구사항 충족**
   - 대부분의 산업: 최소 7일~1개월 백업 보관
   - PII (개인정보): 최소 30일 (GDPR, CCPA)

2. **비용 vs 안전성 균형**
   - 7일: 주말 포함 최소 보관, 장기 복구 불가능
   - 30일: 월간 패턴 분석 가능 (월초 데이터 vs 월말)
   - 90일: 3배 비용, PetClinic에는 과도

3. **RPO 1시간과 일관성**
   - 매일 백업 → 최대 24시간 손실 (실제는 1시간)
   - 30일 보관 → 1개월 전 데이터도 복구 가능

**대안 비교**:

**7일 보관 (기각)**:
```
비용: 2GB × $0.02 = $0.04/월 (60% 절감)
단점:
  - 주말 장애 발생 시 복구 옵션 제한
  - 월간 데이터 분석 불가능
  - 법적 요구사항 미충족 가능
```

**90일 보관 (기각)**:
```
비용: 15GB × $0.02 = $0.30/월 (3배)
장점:
  - 분기별 복구 가능
단점:
  - PetClinic은 Mission-Critical 아님
  - 비용 대비 효과 낮음
```

---

### 4. Virtual Network 미리 구성 (비용 $0)

#### 구성: 4-Tier Subnet

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-dr-blue"
  resource_group_name = azurerm_resource_group.main.name
  location            = "koreacentral"
  address_space       = ["10.1.0.0/16"]  # AWS와 겹치지 않는 CIDR
}

# Subnet 1: Application Gateway (Public)
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.1.0/24"]
}

# Subnet 2: Web Pod (Private)
resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  address_prefixes     = ["10.1.10.0/24"]
}

# Subnet 3: WAS Pod (Private)
resource "azurerm_subnet" "was" {
  name                 = "snet-was"
  address_prefixes     = ["10.1.20.0/24"]
}

# Subnet 4: MySQL (Private, Delegated)
resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  address_prefixes     = ["10.1.30.0/24"]

  delegation {
    name = "mysql-delegation"
    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}
```

#### 왜 미리 구성하는가?

**VNet 사전 구성 이점**

1. **DR 배포 시간 단축** (5분 절약)
   ```
   Without VNet:
   1. VNet 생성 (3분)
   2. Subnet 생성 (2분)
   3. AKS 배포 (10분)
   총: 15분

   With VNet:
   1. AKS 배포 (10분)
   총: 10분
   ```

2. **비용 $0**
   - VNet 자체는 무료 (리소스 사용 시에만 과금)
   - Subnet도 무료
   - NAT Gateway, Public IP 없으면 비용 없음

3. **IP 대역 충돌 방지**
   ```
   AWS VPC:   10.0.0.0/16
   Azure VNet: 10.1.0.0/16
   → VPN/Peering 시 충돌 없음
   ```

4. **Subnet Delegation 미리 설정**
   ```hcl
   delegation {
     name = "mysql-delegation"
     service_delegation {
       name = "Microsoft.DBforMySQL/flexibleServers"
     }
   }
   ```
   - MySQL Flexible Server는 Delegated Subnet 필수
   - 사전 구성 없으면 DR 시 추가 단계 필요

**트레이드오프**:
- 없음 (VNet은 완전 무료)

---

### 5. CloudFront Origin Failover 연동

#### 점검 페이지 URL

```bash
# Storage Account Static Website Endpoint
https://bloberry01.z12.web.core.windows.net/

# CloudFront Secondary Origin 설정
aws cloudfront get-distribution --id E2OX3Z0XHNDUN
{
  "OriginGroups": {
    "Items": [
      {
        "Members": {
          "Items": [
            {
              "OriginId": "primary-eks-alb",  # AWS EKS ALB
            },
            {
              "OriginId": "secondary-azure-web",  # Azure Static Website
              "DomainName": "bloberry01.z12.web.core.windows.net"
            }
          ]
        },
        "FailoverCriteria": {
          "StatusCodes": [500, 502, 503, 504, 404, 403]
        }
      }
    ]
  }
}
```

#### Failover 동작 방식

```
정상 상태:
사용자 → CloudFront → AWS EKS ALB → PetClinic
                                      (200 OK)

AWS 장애 발생:
사용자 → CloudFront → AWS EKS ALB (X 503 Service Unavailable)
                  ↓ Failover (자동, 즉시)
              Azure Static Website → 점검 페이지 (200 OK)
                                      "서비스 점검 중입니다"

DR 완료 (수동 전환):
사용자 → CloudFront → Azure App Gateway → AKS → PetClinic
                                            (DR 사이트)
```

---

## 💰 비용 분석

### Azure 1-always 월 비용

| 항목 | 스펙 | 사용량 | 단가 | 월 비용 |
|------|------|--------|------|---------|
| **Storage Account** | Standard LRS | 5GB | $0.02/GB | $0.10 |
| **Blob 트랜잭션** | - | 1000회 | $0.05/10000회 | $0.01 |
| **Outbound 데이터** | - | 1GB (점검 페이지) | $0.09/GB | $0.09 |
| **Virtual Network** | 4 Subnets | - | 무료 | $0 |
| **Resource Group** | - | - | 무료 | $0 |
| **총 합계** | | | | **$0.20/월** |

### 연간 비용

- **Azure 1-always**: $0.20/월 × 12개월 = **$2.4/년**
- **AWS 백업 전송 비용**: $5/월 × 12개월 = **$60/년**
- **총 DR 대기 비용**: **$62.4/년**

### DR 발동 시 추가 비용 (시간당)

| 항목 | 비용/시간 | 8시간 DR | 24시간 DR |
|------|----------|---------|----------|
| AKS (2 Nodes) | $0.14 | $1.12 | $3.36 |
| MySQL Flexible Server | $0.10 | $0.80 | $2.40 |
| Application Gateway | $0.07 | $0.56 | $1.68 |
| **합계** | $0.31/시간 | **$2.48** | **$7.44** |

**DR 시나리오 예시**:
- AWS 리전 장애 복구: 8시간 → DR 비용 $2.48
- 장기 DR (1주일): 168시간 → DR 비용 $52
- **연간 2회 DR 발생 가정**: $5 (충분히 저렴)

---

## 🚀 배포 절차

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/1-always/

# 변수 파일 편집
cp terraform.tfvars.example terraform.tfvars
# Azure Subscription ID, Tenant ID 입력

# Azure CLI 로그인
az login

# Terraform 배포
terraform init
terraform plan
terraform apply

# 배포 완료 확인
terraform output storage_account_primary_web_endpoint
# https://bloberry01.z12.web.core.windows.net/

# 점검 페이지 접속 테스트
curl https://bloberry01.z12.web.core.windows.net/
```

---

## 🔧 운영 가이드

### 점검 페이지 내용 수정

```bash
# HTML 파일 수정 후 Terraform 재적용
vim /home/ubuntu/3tier-terraform/codes/azure/1-always/main.tf
# source_content 부분 편집

terraform apply -target=azurerm_storage_blob.maintenance_page

# 또는 Azure CLI로 직접 업로드
az storage blob upload \
  --account-name bloberry01 \
  --container-name '$web' \
  --name index.html \
  --file ./maintenance.html \
  --content-type 'text/html'
```

### 백업 파일 수동 업로드 (테스트)

```bash
# AWS에서 백업 생성
mysqldump -h <rds-endpoint> -u admin -p petclinic | gzip > backup.sql.gz

# Azure Blob Storage 업로드
az storage blob upload \
  --account-name bloberry01 \
  --container-name backups \
  --name "petclinic-$(date +%Y%m%d).sql.gz" \
  --file backup.sql.gz
```

### Lifecycle Policy 확인

```bash
# 30일 이상 파일 확인
az storage blob list \
  --account-name bloberry01 \
  --container-name backups \
  --query "[?properties.lastModified < '2025-12-01'].name"

# Lifecycle Management Rule 확인
az storage account management-policy show \
  --account-name bloberry01 \
  --resource-group rg-dr-blue
```

---

## 📝 관련 문서

- **[Azure Storage Account 가격](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/)**
- **[Static Website Hosting](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-static-website)**
- **[Blob Lifecycle Management](https://learn.microsoft.com/en-us/azure/storage/blobs/lifecycle-management-overview)**

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/azure/1-always/`
