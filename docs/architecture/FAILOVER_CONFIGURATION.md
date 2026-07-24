# CloudFront와 Azure Front Door Failover 구성

전체 기준은 [현재 구현 기준 아키텍처](./current-implementation.md)를 따른다.

## 정상 모드

`codes/aws/1. route53`:

```hcl
traffic_mode                 = "normal"
azure_frontdoor_domain_name = "<1-always frontdoor_endpoint>"
```

| 항목 | 코드 값 |
|---|---|
| CloudFront Primary | `primary-aws-alb` |
| CloudFront Secondary | `azure-frontdoor-dr` |
| Origin Group | `multi-cloud-failover-group` |
| Failover 응답 | 500, 502, 503, 504 |
| Allowed methods | GET, HEAD |
| Viewer protocol | HTTPS redirect |
| Cache TTL | 0 |

`codes/azure/1-always`:

```hcl
frontdoor_backend_mode = "maintenance"
azure_appgw_ip          = ""
```

Front Door는 상시 배포되고 Blob Origin만 활성화한다. Route는 외부 HTTP를 HTTPS로 리다이렉트하고, Blob에는 `HttpsOnly`로 전달한다.

## 자동 점검 페이지 전환

```text
CloudFront
  -> AWS ALB 실패
  -> Azure Front Door (HTTPS)
  -> Azure Blob Static Website (HTTPS)
```

Route 53 레코드는 CloudFront Alias로 유지된다. DNS failover가 아니라 CloudFront Origin Group이 읽기 요청을 전환한다.

CloudFront Origin Failover는 `GET`, `HEAD`, `OPTIONS` 요청에만 동작한다. 이 프로젝트 normal mode는 점검 페이지 용도에 맞춰 `GET/HEAD`만 허용한다. 쓰기 요청의 자동 장애 조치를 주장하면 안 된다.

## 승인된 전체 Azure DR

전제:

- 장애대응 회의에서 전체 DR 전환 승인
- `2-emergency` 배포 완료
- 최신 dump 복원 완료
- AKS, Application Gateway, Azure MySQL 검증 완료

전환:

```hcl
# codes/azure/1-always
azure_appgw_ip          = "<2-emergency appgw_public_ip>"
frontdoor_backend_mode = "azure_service"
```

```hcl
# codes/aws/1. route53
azure_frontdoor_domain_name = "<1-always frontdoor_endpoint>"
traffic_mode                 = "azure_dr"
```

CloudFront는 Origin Group이 아닌 `azure-frontdoor-dr` Origin을 직접 대상으로 삼고 7개 HTTP method를 허용한다. Front Door는 Blob을 비활성화하고 Application Gateway를 활성화한다.

```text
Route 53
  -> CloudFront
  -> Azure Front Door
  -> Application Gateway
  -> AKS
  -> Azure MySQL
```

명령:

```bash
./scripts/switch-to-azure.sh --approved --db-restored
```

Terraform 승인 프롬프트를 생략하려는 경우에만 `--auto-approve`를 추가한다.

## Failback

전제:

- AWS ALB/EKS/RDS 정상
- 최신 데이터 반영과 정합성 검증 완료
- 운영자 승인 완료

```bash
./scripts/switch-to-aws.sh --approved
```

스크립트는 먼저 CloudFront를 normal mode로 복귀시키고, 그다음 Front Door를 maintenance mode로 되돌린다. Azure `2-emergency` 삭제는 별도 승인 작업이며 자동 수행하지 않는다.

## 검증 명령

```bash
terraform -chdir="codes/aws/1. route53" output -json origin_failover_config
terraform -chdir="codes/aws/1. route53" output -raw active_traffic_path
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
terraform -chdir=codes/azure/1-always output -raw frontdoor_endpoint
```

```bash
curl -I "https://$(terraform -chdir=codes/azure/1-always output -raw frontdoor_endpoint)/"
```

Distribution ID, Front Door endpoint, Application Gateway IP는 Terraform output에서 조회한다.
