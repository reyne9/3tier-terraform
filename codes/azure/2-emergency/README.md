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

최초 배포에서는 `backend_ip_addresses = []`, `backend_port = 80`을 사용합니다. AKS 버전은 기본적으로 해당 리전의 권장 버전을 사용하며, 필요하면 `kubernetes_version`을 명시합니다. AWS와 Azure의 `db_name` 및 백업 Container 이름은 같아야 합니다. 로컬에서 복원하려면 `admin_ip`에 해당 PC의 공인 IPv4를 설정합니다.

### 2. 최신 dump 복원

```bash
# DB_PASSWORD는 터미널에서 입력하거나 환경변수로 전달합니다.
bash scripts/restore-db.sh
```

Azure CLI 로그인 계정에는 Storage Blob Data Reader 권한이 필요합니다. 기존 Storage Key를 사용하려면 `AZURE_STORAGE_KEY` 환경변수로 전달합니다.

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

DB_PASSWORD를 설정한 뒤 실제 매니페스트와 Gateway 연결을 함께 적용합니다.

```bash
bash scripts/deploy-complete.sh
```

위 스크립트는 Web/WAS rollout 성공을 확인하고 Web LoadBalancer 주소를 `backend.auto.tfvars`에 저장한 뒤 Terraform으로 Gateway를 갱신합니다. `-auto-approve`를 전달하지 않으면 apply 전에 변경 계획을 확인할 수 있습니다.

### 4. Application Gateway backend 구성

`deploy-complete.sh`가 이 단계를 수행합니다. 다시 연결할 때는 `bash scripts/setup-ingress.sh`를 실행합니다. AGIC는 함께 사용하지 않습니다. 기존 AGIC가 켜져 있으면 스크립트가 중단하므로 적용 전 아래 검증 문서의 이전 절차를 확인합니다.

```bash
WEB_LB_IP=$(kubectl get svc -n web web-service \
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

현재 Web LoadBalancer IP와 backend pool IP를 비교한다. 동적 IP를 문서나 코드에 고정하지 않는다.

### Azure MySQL 인증 실패

Terraform 변수, Kubernetes Secret, JDBC URL의 username/password/database를 맞춘다.

### 복원 후 데이터 불일치

dump 시점, 복원 로그, row count와 애플리케이션의 실제 연결 DB를 확인한다.

수정 내역, 기존 환경 이전 절차, 로컬 검증 명령은 [코드 검증 기록](../../../docs/runbooks/code-validation.md)을 참고합니다.
