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
- 관리자 사용자명: 기본 `mysqladmin`, Terraform 변수와 Key Vault에서 동일하게 사용
- SKU 기본값: `B_Standard_B2s`
- Storage 기본값: 20GB
- 네트워크: `snet-db` 위임 서브넷에 VNet 통합, 공개 엔드포인트 없음
- Private DNS: `${environment}.private.mysql.database.azure.com`, VNet link
- TLS: `require_secure_transport = ON`, JDBC와 복원 client 모두 TLS 사용
- Backup retention: 7일

DB module은 위임된 `snet-db`와 VNet ID를 전달받습니다. DNS link를 먼저 생성한 뒤 MySQL을 배포합니다. Private Endpoint 방식이 아니라 VNet 통합 방식입니다. 복원은 VNet 연결 작업 환경에서 수행하며 인터넷에서 직접 접속하지 않습니다.

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

`kubernetes_version` 기본값은 `null`이다. 새 클러스터는 해당 리전의 권장 버전을 사용한다. 기존 클러스터를 관리할 때는 실제 버전을 확인하고 명시한 뒤 계획을 검토한다.

## Application Gateway

코드 기준:

- Name: `appgw-${environment}`
- SKU: Standard_v2
- Capacity: 2
- Zones: 1, 2
- Listener: HTTP 80
- Backend protocol/port: HTTP, 기본 80 (Web LoadBalancer)
- Backend pool: `aks-backend-pool`
- Probe: 기본 `/`, 30초, 200–399
- SSL policy: `AppGwSslPolicy20220101`

첫 apply에서는 `backend_ip_addresses = []`로 Gateway를 생성한다. Web 배포 후 `setup-ingress.sh`가 `web-service`의 사설 LoadBalancer IP를 `backend.auto.tfvars`에 저장하고 Terraform을 다시 적용한다.

## Kubernetes Service와 Ingress

- `web-service`: internal LoadBalancer, port 80
- `was-service`: ClusterIP, port 8080
- 과거 Web Ingress 매니페스트는 참고용이며 현재 배포 스크립트는 적용하지 않음

현재 Terraform에는 AGIC 설치 리소스가 없다. Gateway backend는 Terraform이 관리하고 `setup-ingress.sh`가 Web LoadBalancer IP를 조회해 전달한다. 스크립트는 기존 AKS에 AGIC가 활성화되어 있으면 중단한다.

## 필수 입력

```hcl
subscription_id        = "<azure-subscription-id>"
tenant_id              = "<azure-tenant-id>"
storage_account_name   = "<1-always-storage-name>"
db_password            = "<secret>"
backend_ip_addresses   = []
backend_port           = 80
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

./deploy-complete.sh
```

`deploy-complete.sh`는 Web/WAS 배포 뒤 Web LoadBalancer IP를 조회하고 Gateway backend를 Terraform으로 갱신한다. Azure CLI와 Kubernetes 접근 권한이 필요하다.

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

- Gateway를 처음 생성할 때 backend pool은 비어 있다. Web LoadBalancer IP를 받은 뒤 재적용해야 한다.
- AGIC 설치가 Terraform에 포함되지 않았다.
- DB 복원 환경은 VNet 라우팅과 Private DNS 조회가 필요하다.
- Application Gateway listener는 HTTP만 구현되어 있다. 사용자 TLS는 Front Door에서 종료되는 흐름을 전제로 설명한다.
