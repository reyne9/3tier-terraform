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

## 개인 도메인, Route 53, ACM, CloudFront의 역할

DR 전환 중에도 사용자가 접속하는 개인 도메인은 바뀌지 않는다.

1. Route 53 Hosted Zone이 개인 도메인의 DNS를 관리한다.
2. 개인 도메인의 A Alias 레코드는 항상 CloudFront Distribution을 가리킨다.
3. CloudFront용 ACM 인증서는 `us-east-1`에 발급되어 개인 도메인의 HTTPS를 종료한다.
4. 사용자의 HTTP 요청은 CloudFront에서 HTTPS로 리다이렉트된다.
5. AWS 장애가 발생해도 Route 53 Alias와 ACM 인증서는 그대로 유지되고, CloudFront 내부 Origin 경로만 AWS ALB에서 Azure Front Door 쪽으로 바뀐다.

따라서 자동 점검 페이지와 전체 Azure DR 모두 사용자는 같은 개인 도메인과 같은 CloudFront HTTPS 인증서를 사용한다. ACM 인증서를 Azure로 옮기거나 Route 53 레코드를 Front Door로 바꾸는 절차는 없다. Route 53 Health Check는 관측용이며 DNS Failover를 수행하지 않는다.

### 2. AWS 장애 직후: 자동 점검 페이지

```text
User
  -> 개인 도메인
  -> Route 53 A Alias
  -> HTTPS CloudFront (ACM, us-east-1)
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
- Normal mode methods: `GET`, `HEAD`, `OPTIONS`, `PUT`, `PATCH`, `POST`, `DELETE`
- 자동 Origin Failover 대상: `GET`, `HEAD`, `OPTIONS`
- Front Door mode: `maintenance`
- Front Door forwarding protocol: `HttpsOnly`
- Storage Account: `https_traffic_only_enabled = true`

정상 운영에서는 POST 등 쓰기를 AWS로 전달한다. CloudFront Origin Failover는 쓰기 method를 Secondary로 장애 조치하지 않는다. 따라서 장애 순간의 `POST/PUT/PATCH/DELETE`는 실패할 수 있지만, 사용자가 새로고침하거나 다시 접속하는 일반 `GET` 요청은 자동으로 HTTPS 점검 페이지를 받는다.

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
  -> 개인 도메인
  -> Route 53 A Alias
  -> HTTPS CloudFront (ACM, us-east-1, azure_dr, all methods)
  -> HTTPS Azure Front Door
  -> HTTP Application Gateway
  -> AKS Web/WAS
  -> Azure MySQL
```

현재 Application Gateway listener가 HTTP 80이므로 Front Door에서 App Gateway까지는 `HttpOnly`다. 사용자와 CloudFront, CloudFront와 Front Door 구간은 HTTPS다. End-to-end TLS가 필요하면 Application Gateway HTTPS listener와 인증서를 추가해야 한다.

## Front Door를 상시 유지하는 이유

Front Door를 도입한 직접적인 계기는 Azure DR Origin의 HTTPS 접속 문제를 해결하기 위해서다. 현재 Application Gateway는 IP 기반 HTTP listener를 사용하므로 CloudFront가 Azure Origin으로 연결할 TLS hostname과 HTTPS endpoint가 없다. Front Door가 `azurefd.net` 관리형 TLS endpoint를 제공하며, 개인 도메인의 사용자 HTTPS는 계속 CloudFront의 `us-east-1` ACM 인증서가 처리한다. 장애 중 새 인증서나 Edge 리소스를 구성하지 않도록 Front Door는 평상시에도 유지한다.

- CloudFront에서 Azure로 이어지는 HTTPS Origin hostname을 고정한다.
- 장애 전에 HTTPS 점검 페이지 경로를 검증해 둔다.
- Blob 점검 페이지와 Application Gateway/AKS 사이의 backend 전환점을 통일한다.
- 장애 중 인증서, Front Door 또는 DNS/Origin 주소를 새로 구성하지 않는다.

Blob 기본 endpoint도 HTTPS를 제공하지만, Front Door 도입 목적은 Blob 한 개의 HTTPS 지원 여부가 아니라 점검 페이지와 전체 Azure 서비스가 동일한 HTTPS 진입점을 사용하도록 만드는 것이다.

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
