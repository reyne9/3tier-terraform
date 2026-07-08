# AWS to Azure Automatic Failover Configuration

## Overview
CloudFront Origin Failover가 구성되어 AWS에 문제가 발생하면 자동으로 Azure Blob Storage로 전환됩니다.

## Architecture

### Origin Configuration
1. **Primary Origin**: AWS ALB (k8s-web-webingre-5d0cf16a97-840173904.ap-northeast-2.elb.amazonaws.com)
2. **Secondary Origin**: Azure Blob Storage (bloberry01.z12.web.core.windows.net)

### Failover Mechanism
- **Failover Group ID**: `failover-group`
- **Trigger Conditions**: HTTP 상태 코드 500, 502, 503, 504
- **Failover Path**: Primary (AWS ALB) → Secondary (Azure Blob)

## Traffic Routing

### 1. Static Content (Default Behavior)
- **Path**: `/*` (모든 경로)
- **Target**: Origin Failover Group
- **Allowed Methods**: GET, HEAD
- **Behavior**:
  - AWS ALB에서 응답
  - AWS에서 5xx 에러 발생 시 자동으로 Azure Blob Storage로 failover
  - 정적 파일 서빙에 적합

### 2. API Requests (Cache Behavior)
- **Path**: `/api/*`
- **Target**: Primary AWS ALB (단일 origin)
- **Allowed Methods**: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS
- **Behavior**:
  - POST/PUT/DELETE 등 쓰기 작업 지원
  - Failover 미지원 (API는 primary만 사용)
  - Origin Request Policy 적용으로 모든 헤더/쿼리 전달

## Health Monitoring

### Route53 Health Check
- **Health Check ID**: `ccf960e1-c878-4344-97f7-2545eae7dd28`
- **Target**: AWS ALB (k8s-web-webingre-5d0cf16a97-840173904.ap-northeast-2.elb.amazonaws.com:80)
- **Protocol**: HTTP
- **Path**: `/`
- **Interval**: 30초
- **Failure Threshold**: 3회

## Testing

### GET Request (Failover 지원)
```bash
# 정상 응답 확인
curl -I https://blueisthenewblack.store/

# Failover 테스트 (AWS 중단 시)
# AWS ALB가 5xx 에러를 반환하면 자동으로 Azure로 전환
```

### POST Request (Primary만 사용)
```bash
# API 엔드포인트 테스트
curl -X POST https://blueisthenewblack.store/api/users \
  -H "Content-Type: application/json" \
  -d '{"username":"test","email":"test@example.com"}'
```

### Health Check Status
```bash
# Health check 상태 확인
aws route53 get-health-check-status \
  --health-check-id ccf960e1-c878-4344-97f7-2545eae7dd28
```

## Failover Scenarios

### Scenario 1: AWS ALB 장애 (정적 콘텐츠)
1. 사용자가 https://blueisthenewblack.store/ 요청
2. CloudFront가 AWS ALB로 요청 전달
3. AWS ALB에서 502/503/504 응답
4. **자동으로 Azure Blob Storage로 failover**
5. Azure에서 정적 파일 제공

### Scenario 2: API 요청 (POST/PUT/DELETE)
1. 사용자가 https://blueisthenewblack.store/api/* 요청
2. CloudFront가 AWS ALB로 요청 전달 (Primary만 사용)
3. AWS 장애 시 failover 없음 (쓰기 작업의 경우 단일 origin 필요)
4. 에러 반환

## Limitations

1. **POST/PUT/DELETE는 Failover 미지원**
   - CloudFront Origin Group은 읽기 전용(GET/HEAD)만 failover 지원
   - 쓰기 작업은 primary origin으로만 라우팅

2. **Azure Blob Storage 제약**
   - 정적 웹사이트 호스팅만 지원
   - 동적 API 요청 처리 불가

## Recovery Process

### AWS 복구 후 자동 복귀
- AWS ALB가 정상화되면 자동으로 primary로 복귀
- CloudFront가 자동으로 상태를 감지하고 전환
- 수동 개입 불필요

### 수동 전환 (필요 시)
```bash
# CloudFront 배포 상태 확인
aws cloudfront get-distribution --id E2OX3Z0XHNDUN

# Cache 무효화 (필요 시)
aws cloudfront create-invalidation \
  --distribution-id E2OX3Z0XHNDUN \
  --paths "/*"
```

## Monitoring Commands

```bash
# CloudFront 배포 상태
aws cloudfront get-distribution --id E2OX3Z0XHNDUN \
  --query 'Distribution.Status'

# Health Check 상태
aws route53 get-health-check-status \
  --health-check-id ccf960e1-c878-4344-97f7-2545eae7dd28

# CloudFront 설정 확인
aws cloudfront get-distribution-config --id E2OX3Z0XHNDUN \
  --output json | jq '.DistributionConfig.OriginGroups'
```

## Configuration Files

- CloudFront Distribution ID: `E2OX3Z0XHNDUN`
- CloudFront Domain: `dar3erndlc7gv.cloudfront.net`
- Custom Domain: `blueisthenewblack.store`

## Notes

- Failover는 정적 콘텐츠에만 적용
- API 요청은 AWS 복구를 기다려야 함
- Azure Blob Storage는 백업용 정적 페이지 역할
- 완전한 DR을 위해서는 Azure AKS 배포 필요 (별도 구성)
