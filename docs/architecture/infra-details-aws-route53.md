# AWS Route 53와 CloudFront 상세

**코드 위치**: `codes/aws/1. route53/`

이 계층은 사용자 도메인을 CloudFront에 연결하고 두 가지 명시적 트래픽 모드를 관리한다.

## 입력

```hcl
domain_name                 = "<domain>"
alb_dns_name                = "<aws-alb-dns>"
azure_frontdoor_domain_name = "<1-always frontdoor_endpoint>"
traffic_mode                = "normal"
```

`azure_frontdoor_domain_name`은 protocol과 `/`를 제외한 hostname이다.

## Normal mode

```text
Route 53 -> CloudFront -> AWS ALB
                         \ 5xx GET/HEAD
                          -> Azure Front Door -> HTTPS Blob 점검 페이지
```

| 항목 | 값 |
|---|---|
| Origin Group | `multi-cloud-failover-group` |
| Primary | `primary-aws-alb` |
| Secondary | `azure-frontdoor-dr` |
| Failover code | 500, 502, 503, 504 |
| Allowed methods | GET, HEAD |
| Cached methods | GET, HEAD |
| TTL | 0 |
| ALB origin protocol | HTTP only |
| Front Door origin protocol | HTTPS only |
| Viewer protocol | HTTPS redirect |

현재 EKS Ingress는 ALB HTTP 80 listener만 생성하므로 CloudFront의 ALB origin도 `http-only`다.

## Azure DR mode

`traffic_mode = "azure_dr"`이면 Default Cache Behavior가 Front Door Origin을 직접 선택하고 `GET/HEAD/OPTIONS/PUT/PATCH/POST/DELETE`를 허용한다. 캐시는 계속 비활성이다.

## Route 53

- 기존 public Hosted Zone을 data source로 조회한다.
- 사용자 도메인은 CloudFront distribution에 A Alias로 연결된다.
- DNS failover record를 사용하지 않는다.
- AWS ALB, CloudFront end-to-end, Front Door health check를 만든다.

## 배포와 검증

```bash
cd "codes/aws/1. route53"
terraform init
terraform validate
terraform plan
terraform apply
```

```bash
terraform output -raw active_traffic_path
terraform output -json origin_failover_config
terraform output -json health_check_config
```

## 제한

- Origin Group의 자동 장애 조치는 쓰기 method에 적용되지 않는다.
- ALB origin 구간은 현재 HTTP다.
- 전체 Azure DR은 Front Door backend 전환과 CloudFront direct-origin 전환을 모두 완료해야 한다.
