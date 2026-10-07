# AWS Route 53 + CloudFront

사용자 도메인의 공통 진입점과 단계형 DR 트래픽 모드를 관리한다.

## 사전 조건

1. AWS ALB 배포 완료
2. Azure `1-always` 배포 완료
3. `frontdoor_endpoint` output 확인
4. CloudFront용 ACM 인증서가 `us-east-1`에 존재

## 입력 예시

```hcl
enable_custom_domain         = true
domain_name                 = "example.com"
alb_dns_name                = "<alb-dns>"
azure_frontdoor_domain_name = "<frontdoor-endpoint>.azurefd.net"
traffic_mode                = "normal"
```

## Normal mode

```text
개인 도메인 -> Route 53 A Alias -> HTTPS CloudFront(ACM) -> AWS ALB
                                                       \ 장애 GET/HEAD
                                                        -> Azure Front Door -> HTTPS Blob 점검 페이지
```

- Primary: `primary-aws-alb`
- Secondary: `azure-frontdoor-dr`
- Origin Group: `multi-cloud-failover-group`
- Failover responses: 500, 502, 503, 504
- Allowed methods: GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE
- 자동 Origin Failover 대상: GET, HEAD, OPTIONS. POST 등 쓰기는 정상 시 AWS로 전달하며 자동 failover하지 않습니다.

## Azure DR mode

`traffic_mode = "azure_dr"`:

```text
개인 도메인 -> Route 53 A Alias -> HTTPS CloudFront(ACM) -> Azure Front Door -> Application Gateway -> AKS
```

CloudFront가 Front Door Origin을 직접 선택하고 7개 HTTP method를 허용한다. 전체 DR은 `2-emergency` 배포, 최신 dump 복원과 검증 후 적용한다.

## 도메인과 인증서는 DR 중 변경하지 않음

- Route 53 A Alias는 평상시와 DR 모두 CloudFront Distribution을 가리킨다.
- CloudFront용 ACM 인증서는 `us-east-1`에 있으며 개인 도메인의 Viewer HTTPS를 처리한다.
- 자동 점검 페이지 전환과 전체 Azure DR은 DNS 전환이 아니라 CloudFront Origin 전환이다.
- Azure로 전환해도 사용자는 같은 개인 도메인으로 접속하며 ACM 인증서를 Azure로 이동하지 않는다.
- Route 53 Health Check는 관측용이고 DNS Failover Record는 사용하지 않는다.
- AWS ALB에는 CloudFront origin-facing prefix list만 들어올 수 있어 Route 53의 ALB 직접 HTTP health check는 생성하지 않는다. CloudFront 경로 health check와 ALB target health를 사용한다.

## 배포

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

## 확인

```bash
terraform output -raw cloudfront_url
terraform output -raw active_traffic_path
terraform output -json origin_failover_config
terraform output -json health_check_ids
```

## HTTPS 범위

- Viewer → CloudFront: HTTPS
- CloudFront → Front Door: HTTPS
- Normal mode Front Door → Blob: HTTPS
- CloudFront → AWS ALB: HTTP
- Azure service mode Front Door → Application Gateway: HTTP

현재 ALB와 Application Gateway listener가 HTTP이므로 end-to-end TLS는 별도 개선 항목이다.

## 운영 스크립트

```bash
./scripts/switch-to-azure.sh --approved --db-restored
./scripts/switch-to-aws.sh --approved
```

스크립트는 hard-coded Distribution ID를 사용하지 않고 Terraform state/output과 `dr-mode.auto.tfvars`를 사용한다.

## 주의

- Origin Failover는 쓰기 method를 secondary로 보내지 않는다.
- Route 53은 CloudFront Alias이며 DNS failover record가 아니다.
- ACM 인증서는 CloudFront 요구사항에 따라 `us-east-1`에서 조회한다.
- Front Door hostname에는 protocol을 넣지 않는다.
