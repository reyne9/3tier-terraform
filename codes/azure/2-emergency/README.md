# Azure `2-emergency`

관리자가 장기 장애로 판단하고 전체 DR을 승인한 뒤 배포하는 긴급 계층이다.

## 포함 리소스

- Azure MySQL Flexible Server
- AKS Web/WAS node pool
- Application Gateway와 Public IP

Resource Group, VNet, Subnet, Storage는 `1-always`를 참조한다.

## 배포 순서

### 1. Terraform 배포

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform plan
terraform apply
```

### 2. 최신 dump 복원

백업 Container에서 최신 유효 dump를 선택해 Azure MySQL에 복원한다.

검증:

- schema/table
- 주요 row count
- 최근 데이터 시점
- 애플리케이션 계정 연결
- 문자셋/timezone

### 3. AKS workload 배포

```bash
az aks get-credentials \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw aks_cluster_name)"

kubectl get nodes
kubectl get pods -A
```

Terraform의 DB username과 Kubernetes Secret은 동일해야 한다. 현재 validation 값은 `mysqladmin`이다.

### 4. Application Gateway backend 구성

WAS LoadBalancer의 최신 External IP를 확인해 backend pool과 health probe에 반영한다.

```bash
WAS_LB_IP=$(kubectl get svc -n was was-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

```bash
APPGW_IP=$(terraform output -raw appgw_public_ip)
curl -I "http://${APPGW_IP}/"
```

읽기, 쓰기, DB 재조회를 모두 검증한다.

### 5. 전체 DR 수동 전환

repository root에서:

```bash
./scripts/switch-to-azure.sh --approved --db-restored
```

최종 경로:

```text
Route 53 -> CloudFront -> Azure Front Door -> Application Gateway -> AKS -> Azure MySQL
```

CloudFront나 Route 53를 App Gateway IP로 직접 바꾸지 않는다.

## Failback

AWS 복구와 데이터 정합성 검증 후:

```bash
./scripts/switch-to-aws.sh --approved
```

`2-emergency` 삭제는 별도 승인 후 수행한다. `1-always`는 유지한다.

## 주요 문제

### Application Gateway 502

현재 WAS LoadBalancer IP와 backend pool IP를 비교한다. 동적 IP를 문서나 코드에 고정하지 않는다.

### Azure MySQL 인증 실패

Terraform 변수, Kubernetes Secret, JDBC URL의 username/password/database를 맞춘다.

### 복원 후 데이터 불일치

dump 시점, 복원 로그, row count와 애플리케이션의 실제 연결 DB를 확인한다.
