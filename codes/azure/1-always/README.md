# Azure `1-always`

평상시에도 유지하는 DR 기반 계층이다.

## 포함 리소스

- Resource Group
- VNet과 AppGW/Web/WAS/DB Subnet
- Storage Account와 MySQL backup Container
- HTTPS Blob Static Website 점검 페이지
- Azure Front Door Standard

Front Door는 조건 없이 배포된다.

## 기본 모드

```hcl
frontdoor_backend_mode = "maintenance"
azure_appgw_ip          = ""
```

```text
CloudFront -> HTTPS Front Door -> HTTPS Blob 점검 페이지
```

Storage Account는 `https_traffic_only_enabled = true`다.

## 전체 Azure 서비스 모드

`2-emergency` 배포, 최신 dump 복원, Application Gateway/AKS 검증 후:

```hcl
frontdoor_backend_mode = "azure_service"
azure_appgw_ip          = "<appgw-public-ip>"
```

```text
CloudFront -> HTTPS Front Door -> HTTP Application Gateway -> AKS
```

`azure_service`인데 App Gateway IP가 없으면 Terraform apply가 실패한다.

## Front Door를 상시 유지하는 이유

Blob endpoint도 HTTPS를 제공하므로 HTTPS만이 유일한 이유는 아니다.

- 장애 전에 검증된 HTTPS 점검 경로 확보
- CloudFront Azure Origin hostname 고정
- Blob과 App Gateway backend 전환점 통일
- 장애 중 Front Door 신규 배포와 DNS 변경 방지

## 배포

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform plan
terraform apply
```

## 확인

```bash
terraform output -raw frontdoor_endpoint
terraform output -raw frontdoor_backend_mode
terraform output -raw static_website_url

AFD_ENDPOINT=$(terraform output -raw frontdoor_endpoint)
curl -I "https://${AFD_ENDPOINT}/"
```

Route 53 레코드는 이 계층에서 생성하지 않는다. 사용자 도메인은 AWS `1. route53`의 CloudFront Alias다.
