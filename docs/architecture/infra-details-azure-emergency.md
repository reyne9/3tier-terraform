# Azure `2-emergency` 인프라 상세

**코드 위치**: `codes/azure/2-emergency/`

`2-emergency`는 장기 장애 시 생성하는 Azure 전체 서비스 복구 계층이다.

## 생성 리소스

- Azure MySQL Flexible Server와 `petclinic` database
- AKS cluster
- Web node pool
- WAS node pool
- Application Gateway Standard_v2
- Application Gateway Public IP

Resource Group, VNet, Subnet, Storage Account는 `1-always`가 만든 기존 리소스를 data source로 참조한다.

## Azure MySQL

코드 기준:

- Server: `mysql-dr-${environment}`
- Database: 기본 `petclinic`
- 관리자 사용자명: `mysqladmin`으로 validation
- SKU 기본값: `B_Standard_B2s`
- Storage 기본값: 20GB
- Public network access: 활성
- SSL enforcement: 비활성
- Backup retention: 7일

현재 DB module은 `1-always`의 위임된 DB Subnet을 전달받지 않는다. 따라서 문서에서 Azure MySQL이 private subnet/private endpoint로 구성됐다고 설명하면 안 된다. Public access와 SSL 설정은 운영 보안 개선 대상이다.

## AKS

코드 기준:

- Cluster: `aks-dr-${environment}`
- Network plugin/policy: Azure CNI / Azure
- Service CIDR: `10.240.0.0/16`
- DNS Service IP: `10.240.0.10`
- Web/WAS node pool 분리
- Web node label: `tier=web`
- WAS node label: `tier=was`
- Auto Scaling 활성

Kubernetes version 기본값은 `1.28`이다. 실제 Azure 지원 버전과 다를 수 있으므로 배포 전에 `az aks get-versions`로 확인한다.

## Application Gateway

코드 기준:

- Name: `appgw-${environment}`
- SKU: Standard_v2
- Capacity: 2
- Zones: 1, 2
- Listener: HTTP 80
- Backend protocol/port: HTTP, 기본 8080
- Backend pool: `aks-backend-pool`
- Probe: 기본 `/`, 30초, 200–399
- SSL policy: `AppGwSslPolicy20220101`

`backend_ip_addresses`는 필수 변수다. Kubernetes의 `was-service`가 `LoadBalancer`이므로, 배포 후 External IP를 확인해 Application Gateway backend pool에 반영한다.

## Kubernetes Service와 Ingress

- `web-service`: ClusterIP, port 80
- `was-service`: LoadBalancer, port 8080
- Web Ingress class: `azure-application-gateway`

현재 Terraform에는 AGIC 설치 리소스가 없다. 따라서 Ingress manifest만으로 Application Gateway 설정이 자동 동기화된다고 설명하면 안 된다. 실제 연결은 `backend_ip_addresses`와 `deploy-complete.sh`의 Azure CLI 갱신 흐름을 기준으로 한다.

## 필수 입력

```hcl
subscription_id        = "<azure-subscription-id>"
tenant_id              = "<azure-tenant-id>"
storage_account_name   = "<1-always-storage-name>"
db_password            = "<secret>"
backend_ip_addresses   = ["<initial-backend-ip>"]
```

기본 참조 이름:

```hcl
resource_group_name = "rg-dr-prod"
vnet_name           = "vnet-dr-prod"
```

`environment` 기본값도 `prod`다. `blue`를 사용하려면 관련 이름을 모두 같은 environment로 전달한다.

## 배포

```bash
cd codes/azure/2-emergency
terraform init
terraform validate
terraform plan
terraform apply
```

## DB 복원과 workload 배포

```bash
az aks get-credentials \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw aks_cluster_name)" \
  --overwrite-existing

cd scripts
./restore-db.sh

export DB_PASSWORD='<Azure MySQL password>'
./deploy-complete.sh
```

`deploy-complete.sh`에는 `appgw-blue`, `pip-appgw-blue` fallback이 남아 있다. environment가 `prod`라면 실제 Terraform output과 리소스명으로 치환해야 한다.

## 주요 Output

```bash
terraform output -raw mysql_fqdn
terraform output -raw aks_cluster_name
terraform output -raw appgw_public_ip
terraform output -raw appgw_name
terraform output -raw resource_group_name
```

## Front Door 연결

Application Gateway 배포와 backend 검증이 끝난 뒤:

1. `appgw_public_ip`를 `1-always`의 `azure_appgw_ip`에 전달한다.
2. `1-always`를 다시 apply한다.
3. `azure-aks-appgw` Origin을 활성화한다.
4. Front Door endpoint에서 GET과 쓰기 요청을 확인한다.

전체 DR은 자동 절차가 아니다. 최신 dump 복원과 검증 후 Front Door backend를 Application Gateway로 바꾸고, CloudFront를 Front Door 직접 Origin으로 수동 전환한다.

## 알려진 한계

- Application Gateway backend IP를 apply 전에 입력해야 한다.
- `deploy-complete.sh`에 일부 `blue` 고정 이름이 있다.
- AGIC 설치가 Terraform에 포함되지 않았다.
- Azure MySQL public access와 SSL 비활성 설정은 운영 기준에 미달한다.
- Application Gateway listener는 HTTP만 구현되어 있다. 사용자 TLS는 Front Door에서 종료되는 흐름을 전제로 설명한다.
