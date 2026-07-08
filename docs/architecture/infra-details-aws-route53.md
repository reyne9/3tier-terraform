# AWS Route53 & CloudFront 인프라 상세 설명

**디렉토리**: `/codes/aws/1. route53/`

**목적**: 전역 DNS 관리 및 Multi-Cloud Failover를 위한 CDN 구성

---

## 📋 개요

이 디렉토리는 Multi-Cloud DR 솔루션의 최전선에서 트래픽을 관리하는 글로벌 엣지 인프라를 구성합니다. CloudFront와 Route53을 활용하여 AWS Primary Site 장애 시 자동으로 Azure 점검 페이지로 전환되며, DR 완료 후 수동으로 Azure 복구 사이트로 트래픽을 라우팅할 수 있습니다.

### 주요 구성 요소

- **CloudFront Distribution**: HTTPS 종단점, Origin Failover
- **Route53 Hosted Zone**: DNS 레코드 관리
- **ACM SSL Certificate**: HTTPS 통신 보안
- **Origin Groups**: Primary(AWS) + Secondary(Azure 점검 페이지)

---

## 🏗️ 아키텍처 구성

```
사용자 → CloudFront (HTTPS)
           ↓
      Origin Group
           ├─ Primary Origin: AWS EKS ALB (k8s-web-webingre-*.elb.amazonaws.com)
           └─ Secondary Origin: Azure Static Website (bloberry01.z12.web.core.windows.net)
           ↓
      Route53 (blueisthenewblack.store)
```

### 트래픽 흐름

1. **정상 상태**: CloudFront → AWS EKS ALB → Web Pod → WAS Pod → RDS MySQL
2. **AWS 장애**: CloudFront → Azure Static Website (점검 페이지)
3. **DR 완료**: CloudFront Origin 수동 업데이트 → Azure Application Gateway → AKS → MySQL

---

## 🔑 핵심 설계 결정

### 1. CloudFront Origin Failover를 선택한 이유

#### 선택: CloudFront Origin Groups with Failover
```hcl
origin_group {
  origin_id = "origin-group-blue"

  failover_criteria {
    status_codes = [500, 502, 503, 504, 404, 403]
  }

  member {
    origin_id = "primary-eks-alb"    # AWS
  }

  member {
    origin_id = "secondary-azure-web" # Azure 점검 페이지
  }
}
```

#### 장점
- **자동 Failover**: AWS 장애 시 즉시 Azure 점검 페이지로 전환 (사용자 인지 없음)
- **HTTPS 종단점**: CloudFront에서 SSL/TLS 처리, Origin은 HTTP 가능
- **글로벌 엣지 캐싱**: 300+ 엣지 로케이션에서 콘텐츠 제공 (낮은 레이턴시)
- **DDoS 보호**: AWS Shield Standard 기본 포함
- **비용 효율**: Route53 Health Check보다 저렴 (Health Check: $0.50/월, CloudFront: 무료 failover)

#### 트레이드오프
- **수동 DR 전환**: Azure 2-emergency 배포 후 CloudFront Origin을 수동으로 업데이트해야 함
  ```bash
  aws cloudfront update-distribution \
    --id E2OX3Z0XHNDUN \
    --distribution-config file://azure-dr-config.json
  ```
- **전파 시간**: CloudFront 배포 업데이트 시 5-10분 소요

#### 대안 고려 및 기각 사유

**대안 1: Route53 Health Check Failover**
```
Route53 Weighted Routing
  ├─ Primary: AWS ALB (Health Check 활성)
  └─ Secondary: Azure App Gateway (Health Check 활성)
```
- ❌ **기각 사유**:
  - Health Check 비용: $0.50/월 × 2개 = $1/월
  - DNS TTL 캐싱으로 인한 지연 (최대 60초)
  - HTTPS 종단점 없음 (ACM 인증서를 각 Origin에 설치 필요)
  - 글로벌 캐싱 없음

**대안 2: Azure Front Door**
```
Azure Front Door (Multi-Cloud)
  ├─ Backend Pool 1: AWS EKS ALB
  └─ Backend Pool 2: Azure AKS App Gateway
```
- ❌ **기각 사유**:
  - 비용 높음: $35/월 (기본) + 데이터 전송 비용
  - AWS → Azure Front Door → AWS 경로로 추가 홉 발생 (레이턴시 증가)
  - 프로젝트 목적과 맞지 않음 (AWS 중심 솔루션)

**선택 근거**: CloudFront Origin Failover는 비용 대비 성능이 가장 우수하며, AWS 기반 프로젝트에 적합

---

### 2. Route53 Public Hosted Zone

#### 설정
```hcl
resource "aws_route53_zone" "main" {
  name = "blueisthenewblack.store"

  tags = {
    Environment = "Production"
    Purpose     = "Multi-Cloud-DR"
  }
}

resource "aws_route53_record" "cloudfront_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "blueisthenewblack.store"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
```

#### 왜 Public Hosted Zone인가?
- **요구사항**: 외부 사용자가 접근 가능한 Public 웹 애플리케이션
- **대안**: Private Hosted Zone은 VPC 내부 DNS 전용
- **장점**:
  - 전 세계 어디서나 DNS 해석 가능
  - CloudFront Alias 레코드 지원
  - 자동 Route53 네임서버 할당

#### Route53 Alias vs CNAME
- **선택**: Alias 레코드
- **이유**:
  - Zone Apex(루트 도메인)에서 CNAME 사용 불가 (RFC 표준)
  - Alias는 AWS 리소스 직접 참조 (무료, 빠름)
  - `blueisthenewblack.store` 직접 사용 가능 (www 서브도메인 불필요)

---

### 3. ACM SSL/TLS 인증서

#### 설정
```hcl
resource "aws_acm_certificate" "main" {
  domain_name       = "blueisthenewblack.store"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}
```

#### 왜 ACM을 사용하는가?
- **무료**: AWS Certificate Manager는 추가 비용 없음
- **자동 갱신**: 만료 전 자동 갱신 (Let's Encrypt 대비 운영 부담 없음)
- **CloudFront 통합**: us-east-1 리전 인증서 자동 인식
- **DNS 검증**: Route53과 자동 연동 (이메일 검증 대비 편리)

#### us-east-1 리전 제약
```hcl
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

resource "aws_acm_certificate" "main" {
  provider = aws.us-east-1  # CloudFront는 us-east-1 인증서만 사용
  # ...
}
```
- **CloudFront 요구사항**: 글로벌 서비스이므로 us-east-1 리전 인증서 필수
- **트레이드오프**: 별도 provider 블록 필요 (복잡도 증가)

---

### 4. CloudFront 캐싱 전략

#### Cache Behavior 설정
```hcl
default_cache_behavior {
  target_origin_id       = "origin-group-blue"
  viewer_protocol_policy = "redirect-to-https"
  allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
  cached_methods         = ["GET", "HEAD"]
  compress               = true

  min_ttl     = 0
  default_ttl = 86400   # 1일
  max_ttl     = 31536000 # 1년

  forwarded_values {
    query_string = true
    cookies {
      forward = "all"
    }
  }
}
```

#### 설계 이유

**1. 모든 HTTP 메서드 허용**
- **선택**: `allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]`
- **이유**: Spring PetClinic은 RESTful API 사용 (POST, PUT, DELETE 필요)
- **대안**: `["GET", "HEAD"]`만 허용하면 정적 사이트 전용

**2. GET/HEAD만 캐싱**
- **선택**: `cached_methods = ["GET", "HEAD"]`
- **이유**:
  - POST/PUT/DELETE는 상태 변경 작업이므로 캐싱 불가
  - GET 요청만 캐싱하여 Origin 부하 감소

**3. Query String 및 Cookie 전달**
- **선택**: `query_string = true`, `cookies.forward = "all"`
- **이유**:
  - PetClinic은 동적 웹 애플리케이션 (사용자별 세션 필요)
  - Query String: 검색, 필터링 기능
  - Cookie: Spring Session 관리
- **트레이드오프**: 캐싱 효율 감소 (각 Query String/Cookie 조합별로 캐시)

**4. Gzip 압축**
- **선택**: `compress = true`
- **이유**: HTML/CSS/JS 파일 크기 60-80% 감소, 전송 비용 절감

---

### 5. Origin Failover 기준

#### Failover Trigger 설정
```hcl
failover_criteria {
  status_codes = [500, 502, 503, 504, 404, 403]
}
```

#### 각 상태 코드의 의미

| 상태 코드 | 의미 | Failover 필요 시나리오 |
|----------|------|----------------------|
| 500 | Internal Server Error | WAS Pod 크래시 |
| 502 | Bad Gateway | ALB → Pod 연결 실패 (Pod 부재) |
| 503 | Service Unavailable | EKS 노드 그룹 스케일 다운, Pod 0개 |
| 504 | Gateway Timeout | Pod 응답 지연 (30초 초과) |
| 404 | Not Found | Ingress 삭제, ALB 경로 미설정 |
| 403 | Forbidden | Security Group 차단, WAF 규칙 |

#### 왜 200 OK는 제외되는가?
- **200**: 정상 응답 (Failover 불필요)
- **301/302**: 리다이렉트 (정상 동작)
- **401**: 인증 필요 (애플리케이션 정상, 사용자 문제)

#### Failover 판단 로직
```
1. CloudFront가 Primary Origin(AWS ALB)에 요청
2. AWS ALB 응답 시간 초과 또는 위 상태 코드 반환
3. CloudFront가 Secondary Origin(Azure Static Website)로 즉시 재시도
4. 사용자는 점검 페이지 확인 (서비스 중단 인지)
```

---

## 📊 Origin 구성 상세

### Primary Origin: AWS EKS ALB

```hcl
origin {
  domain_name = "k8s-web-webingre-5d0cf16a97-1358663516.ap-northeast-2.elb.amazonaws.com"
  origin_id   = "primary-eks-alb"

  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols   = ["TLSv1.2"]
  }
}
```

#### 왜 HTTP-Only인가?
- **CloudFront ↔ Origin 통신은 AWS 내부망 (PrivateLink 가능)**
- **SSL 오프로딩**: CloudFront에서 HTTPS 처리, Origin은 HTTP로 성능 향상
- **비용 절감**: ALB에서 SSL 인증서 불필요
- **트레이드오프**: 완전한 E2E 암호화는 아님 (AWS 내부 구간 평문)

#### ALB DNS 이름 하드코딩 이슈
- **현재 방식**: 수동으로 ALB DNS 이름 입력
- **문제점**:
  - EKS Ingress 재생성 시 ALB DNS 변경 가능
  - Terraform 재실행 필요
- **개선 방안**:
  ```hcl
  data "kubernetes_ingress_v1" "web_ingress" {
    metadata {
      name      = "web-ingress"
      namespace = "web"
    }
  }

  domain_name = data.kubernetes_ingress_v1.web_ingress.status[0].load_balancer[0].ingress[0].hostname
  ```

### Secondary Origin: Azure Static Website

```hcl
origin {
  domain_name = "bloberry01.z12.web.core.windows.net"
  origin_id   = "secondary-azure-web"

  custom_origin_config {
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols   = ["TLSv1.2"]
  }
}
```

#### Azure Blob Static Website 선택 이유
- **항상 실행 중**: $5/월의 저비용 상시 대기 (VM 불필요)
- **고가용성**: Azure Storage는 99.9% SLA (LRS 기준)
- **간단한 점검 페이지**: HTML/CSS만 있으면 충분
- **대안 고려**: Azure App Service ($10/월) - 불필요하게 비쌈

#### 점검 페이지 내용
```html
<!DOCTYPE html>
<html>
<head>
    <title>시스템 점검 중</title>
</head>
<body>
    <h1>🔧 시스템 점검 중입니다</h1>
    <p>현재 시스템 유지보수 작업이 진행 중입니다.</p>
    <p>빠른 시일 내에 정상화하겠습니다.</p>
</body>
</html>
```

---

## 🔐 보안 설정

### 1. Viewer Protocol Policy
```hcl
viewer_protocol_policy = "redirect-to-https"
```
- **강제 HTTPS**: HTTP 요청 자동 301 리다이렉트
- **중간자 공격 방지**: 전송 중 데이터 암호화

### 2. CloudFront Security Headers
```hcl
# 향후 개선 계획: Lambda@Edge로 보안 헤더 추가
response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "security-headers-policy"

  security_headers_config {
    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 31536000  # 1년
      include_subdomains         = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      override     = true
      frame_option = "DENY"
    }
  }
}
```

### 3. Geo Restriction (선택 사항)
```hcl
restrictions {
  geo_restriction {
    restriction_type = "none"  # 전 세계 허용
    # 특정 국가만 허용하려면:
    # restriction_type = "whitelist"
    # locations = ["KR", "US", "JP"]
  }
}
```

---

## 💰 비용 분석

### CloudFront 요금 구조

| 항목 | 가격 | 예상 사용량 (월) | 비용 |
|------|------|----------------|------|
| 데이터 전송 (첫 10TB) | $0.085/GB | 100GB | $8.50 |
| HTTP/HTTPS 요청 | $0.0075/10,000개 | 100만 건 | $0.75 |
| 무효화 요청 | 처음 1,000개 무료 | - | $0 |
| **월 합계** | | | **$9.25** |

### Route53 요금

| 항목 | 가격 | 비용 |
|------|------|------|
| Hosted Zone | $0.50/월 | $0.50 |
| DNS 쿼리 (첫 1억 건) | $0.40/100만 건 | $0.40 |
| **월 합계** | | **$0.90** |

### ACM 인증서
- **무료** (AWS ACM 사용 시)

### 총 예상 비용
- **CloudFront + Route53 + ACM**: 약 $10/월

---

## 🚀 배포 절차

### 1. 초기 배포

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/1.\ route53/

# Terraform 초기화
terraform init

# 실행 계획 확인
terraform plan

# 배포
terraform apply
```

### 2. 배포 후 확인

```bash
# CloudFront Distribution ID 확인
terraform output cloudfront_distribution_id

# Route53 Hosted Zone ID 확인
terraform output route53_zone_id

# ACM 인증서 ARN 확인
terraform output acm_certificate_arn

# DNS 전파 확인 (5-10분 소요)
dig blueisthenewblack.store

# HTTPS 접속 테스트
curl -I https://blueisthenewblack.store/
```

### 3. Failover 테스트

```bash
# AWS EKS 노드 그룹 스케일 다운 (장애 시뮬레이션)
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name web-nodes \
  --scaling-config minSize=0,maxSize=0,desiredSize=0

# CloudFront 응답 확인 (Azure 점검 페이지로 전환됨)
curl -I https://blueisthenewblack.store/
# HTTP/2 200
# x-cache: Miss from cloudfront
# (Azure Static Website 콘텐츠)

# 원복
aws eks update-nodegroup-config \
  --cluster-name blue-eks \
  --nodegroup-name web-nodes \
  --scaling-config minSize=2,maxSize=5,desiredSize=2
```

---

## 🔧 운영 가이드

### CloudFront 캐시 무효화

```bash
# 전체 캐시 무효화
aws cloudfront create-invalidation \
  --distribution-id E2OX3Z0XHNDUN \
  --paths "/*"

# 특정 경로만 무효화
aws cloudfront create-invalidation \
  --distribution-id E2OX3Z0XHNDUN \
  --paths "/index.html" "/css/*"
```

### DR 시 Origin 전환

```bash
# 1. Azure 2-emergency 배포 완료 후 App Gateway IP 확인
APPGW_IP=$(az network public-ip show \
  --resource-group rg-dr-blue \
  --name pip-appgw-blue \
  --query ipAddress -o tsv)

# 2. CloudFront Distribution Config 백업
aws cloudfront get-distribution-config \
  --id E2OX3Z0XHNDUN \
  > original-config.json

# 3. Origin을 Azure App Gateway로 변경
# (수동으로 JSON 파일 편집 필요)
# origins[0].domainName을 $APPGW_IP로 변경

# 4. CloudFront 배포 업데이트
aws cloudfront update-distribution \
  --id E2OX3Z0XHNDUN \
  --distribution-config file://azure-dr-config.json \
  --if-match <ETag from get-distribution-config>

# 5. 전파 완료 대기 (5-10분)
aws cloudfront wait distribution-deployed \
  --id E2OX3Z0XHNDUN
```

---

## 📝 관련 문서

- **[배포 가이드](/docs/runbooks/deployment-guide.md)**: 전체 인프라 배포 순서
- **[DR 절차서](/docs/runbooks/dr-failover-procedure.md)**: 재해 복구 체크리스트
- **[트러블슈팅](/docs/runbooks/troubleshooting.md)**: CloudFront/Route53 문제 해결

---

## ✅ 체크리스트

### 배포 전 확인
- [ ] AWS CLI 인증 설정 완료
- [ ] 도메인 등록 완료 (blueisthenewblack.store)
- [ ] Terraform 1.14.0+ 설치
- [ ] AWS Provider 6.0+ 설정

### 배포 후 확인
- [ ] ACM 인증서 발급 완료 (ISSUED 상태)
- [ ] CloudFront Distribution 배포 완료 (Deployed 상태)
- [ ] Route53 DNS 전파 완료 (dig 명령으로 확인)
- [ ] HTTPS 접속 가능 (curl -I https://blueisthenewblack.store/)
- [ ] Origin Failover 테스트 완료

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/aws/1. route53/`
