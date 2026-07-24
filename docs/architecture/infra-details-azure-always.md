# Azure `1-always` 인프라 상세

**코드 위치**: `codes/azure/1-always/`

`1-always`는 장애 전에 유지하는 Azure 기반 계층이다. Azure Front Door도 조건 없이 이 계층에서 생성한다.

## 생성 리소스

- Resource Group `rg-dr-${environment}`
- VNet과 AppGW/Web/WAS/DB Subnet
- Storage Account
- MySQL 백업 Container
- Blob Static Website 점검 페이지
- Azure Front Door Standard

Storage Account는 다음을 적용한다.

- `https_traffic_only_enabled = true`
- Static Website `$web/index.html`
- Blob versioning
- 기본 30일 lifecycle

## Front Door

| 항목 | 값 |
|---|---|
| Profile | `afd-multicloud-${environment}` |
| Endpoint | `multicloud-endpoint` |
| Origin Group | `failover-group` |
| Route | `/*` |
| Viewer | HTTP/HTTPS, HTTPS redirect |
| Cache | 비활성 |

### Maintenance mode

```hcl
frontdoor_backend_mode = "maintenance"
azure_appgw_ip          = ""
```

- Blob Origin 활성
- App Gateway Origin 미생성 또는 비활성
- Health probe: HTTPS GET `/`
- Forwarding protocol: `HttpsOnly`

```text
CloudFront -> HTTPS Front Door -> HTTPS Blob 점검 페이지
```

### Azure service mode

```hcl
frontdoor_backend_mode = "azure_service"
azure_appgw_ip          = "<2-emergency appgw_public_ip>"
```

- Blob Origin 비활성
- App Gateway Origin 활성
- Health probe: HTTP GET `/`
- Forwarding protocol: `HttpOnly`

```text
CloudFront -> HTTPS Front Door -> HTTP Application Gateway -> AKS
```

`azure_service`인데 `azure_appgw_ip`가 비어 있으면 Terraform precondition이 실패한다.

## Front Door를 평상시에도 유지하는 이유

Blob 기본 endpoint도 HTTPS를 지원하므로 HTTPS 하나만으로 Front Door 비용을 설명하지 않는다.

- 검증된 HTTPS 점검 경로를 장애 전에 확보
- CloudFront Secondary/DR Origin hostname 고정
- Blob과 App Gateway backend 전환점 통일
- 장애 중 Front Door 신규 배포와 DNS 변경 회피

## 입력

```hcl
subscription_id             = "<azure-subscription-id>"
tenant_id                   = "<azure-tenant-id>"
storage_account_name        = "<globally-unique-name>"
frontdoor_backend_mode      = "maintenance"
azure_appgw_ip               = ""
custom_domain               = ""
```

Route 53 레코드는 이 계층에서 만들지 않는다. 사용자 도메인은 AWS `1. route53`에서 CloudFront Alias로 관리한다.

## 주요 Output

```bash
terraform output -raw resource_group_name
terraform output -raw static_website_url
terraform output -raw frontdoor_endpoint
terraform output -raw frontdoor_backend_mode
terraform output -raw appgw_subnet_id
```

## 검증

```bash
AFD_ENDPOINT=$(terraform output -raw frontdoor_endpoint)
curl -I "https://${AFD_ENDPOINT}/"
```

maintenance mode에서는 점검 페이지가 반환되어야 한다. azure_service mode 전환은 `2-emergency` 배포, 최신 dump 복원, Application Gateway/AKS 검증 후에만 수행한다.
