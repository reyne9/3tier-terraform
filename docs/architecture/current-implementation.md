# 현재 구현 기준 아키텍처

이 문서는 `codes/`의 실제 Terraform과 Kubernetes manifest를 기준으로 한 문서 해석의 기준점이다.

## 핵심 결론

- 정상 사용자 경로는 `Route 53 → CloudFront → AWS ALB → EKS → RDS`다.
- Azure Front Door는 `codes/azure/1-always`에서 평상시에도 배포한다.
- CloudFront Origin Group의 Secondary는 Blob 직결이 아니라 Azure Front Door다.
- Front Door의 기본 backend는 HTTPS Blob 점검 페이지다.
- AWS 장애 시 `GET/HEAD` 요청은 자동으로 `CloudFront → Front Door → Blob` 경로를 사용한다.
- 전체 Azure 서비스는 운영자 승인, `2-emergency` 배포, 최신 dump 복원, 검증이 끝난 뒤 수동 전환한다.
- 수동 전환 후 경로는 `Route 53 → CloudFront → Front Door → Application Gateway → AKS → Azure MySQL`이다.

## 상태별 요청 경로

### 1. 정상 운영

```text
User
  -> Route 53 Alias
  -> CloudFront (traffic_mode=normal)
  -> AWS ALB
  -> EKS Web/WAS
  -> RDS MySQL
```

CloudFront viewer는 HTTP 요청을 HTTPS로 리다이렉트한다. 현재 ALB Ingress listener가 HTTP 80이므로 CloudFront에서 ALB까지는 `http-only`다.

### 2. AWS 장애 직후: 자동 점검 페이지

```text
User
  -> HTTPS CloudFront
  -> Origin Group
  -> AWS ALB 실패
  -> HTTPS Azure Front Door
  -> HTTPS Azure Blob Static Website
```

코드 기준:

- Origin Group: `multi-cloud-failover-group`
- Primary Origin: `primary-aws-alb`
- Secondary Origin: `azure-frontdoor-dr`
- Failover status: `500`, `502`, `503`, `504`
- Normal mode methods: `GET`, `HEAD`
- Front Door mode: `maintenance`
- Front Door forwarding protocol: `HttpsOnly`
- Storage Account: `https_traffic_only_enabled = true`

CloudFront Origin Failover는 쓰기 method를 Secondary로 장애 조치하지 않는다. 따라서 장애 순간의 `POST/PUT/PATCH/DELETE`는 실패할 수 있지만, 사용자가 새로고침하거나 다시 접속하는 일반 `GET` 요청은 자동으로 HTTPS 점검 페이지를 받는다.

### 3. 장기 장애: 승인된 전체 Azure DR

운영 순서:

1. 관리자가 장애 범위와 전체 DR 전환을 승인한다.
2. `codes/azure/2-emergency`를 배포한다.
3. 최신 MySQL dump를 Azure MySQL에 복원한다.
4. AKS workload와 Application Gateway backend를 구성한다.
5. Application Gateway에서 읽기·쓰기 및 DB 정합성을 검증한다.
6. Front Door를 `frontdoor_backend_mode = "azure_service"`로 적용한다.
7. CloudFront를 `traffic_mode = "azure_dr"`로 적용한다.

```text
User
  -> Route 53 Alias
  -> CloudFront (azure_dr, all methods)
  -> HTTPS Azure Front Door
  -> HTTP Application Gateway
  -> AKS Web/WAS
  -> Azure MySQL
```

현재 Application Gateway listener가 HTTP 80이므로 Front Door에서 App Gateway까지는 `HttpOnly`다. 사용자와 CloudFront, CloudFront와 Front Door 구간은 HTTPS다. End-to-end TLS가 필요하면 Application Gateway HTTPS listener와 인증서를 추가해야 한다.

## Front Door를 상시 유지하는 이유

Blob 기본 endpoint 자체도 HTTPS를 지원하므로 “HTTPS만을 위해 Front Door가 반드시 필요하다”는 설명은 정확하지 않다. 이 설계가 Front Door 비용을 평상시에도 부담하는 이유는 다음과 같다.

- 장애 전에 HTTPS 점검 페이지 경로를 검증해 둔다.
- CloudFront의 Azure Origin hostname을 고정한다.
- Blob 점검 페이지와 App Gateway/AKS 사이의 backend 전환점을 통일한다.
- 장애 중 Front Door 신규 배포나 DNS/Origin 주소 교체를 피한다.

## Azure 계층

### 상시 계층: `codes/azure/1-always`

- Resource Group
- VNet과 AppGW/Web/WAS/DB Subnet
- MySQL 백업 Container
- Blob Static Website 점검 페이지
- Azure Front Door

### 긴급 계층: `codes/azure/2-emergency`

- Azure MySQL Flexible Server
- AKS Web/WAS node pool
- Application Gateway

## 전환 변수

| 계층 | 평상시 | 전체 Azure DR |
|---|---|---|
| CloudFront | `traffic_mode = "normal"` | `traffic_mode = "azure_dr"` |
| Front Door | `frontdoor_backend_mode = "maintenance"` | `frontdoor_backend_mode = "azure_service"` |
| App Gateway IP | 비어 있어도 됨 | `azure_appgw_ip` 필수 |

`scripts/switch-to-azure.sh`는 `--approved --db-restored`를 요구하며 두 상태를 순서대로 적용한다. `scripts/switch-to-aws.sh`는 AWS 복구와 데이터 정합성 검증 후 `--approved`로 실행한다.

## 문서 작성 규칙

- 자동 전환과 수동 전체 DR을 구분한다.
- 자동 전환은 HTTPS 점검 페이지를 제공하는 읽기 요청 경로다.
- 전체 서비스 전환은 승인·배포·최신 dump 복원·검증 후 수행한다.
- Front Door를 CloudFront와 독립된 사용자 Edge라고 설명하지 않는다.
- RTO/RPO는 보장값으로 표현하지 않는다.
- ID, FQDN, IP는 Terraform output으로 조회하며 문서에 고정하지 않는다.
