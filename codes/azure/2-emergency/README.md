# Azure `2-emergency`

관리자가 장기 장애로 판단하고 전체 DR을 승인한 뒤 배포하는 긴급 계층이다.

## 포함 리소스

- Azure MySQL Flexible Server
- AKS Web/WAS node pool
- Application Gateway와 Public IP
- Key Vault, AKS Key Vault CSI add-on, DB 연결값 secret

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

최초 배포에서는 `backend_ip_addresses = []`, `backend_port = 80`을 사용합니다. AKS 버전은 기본적으로 해당 리전의 권장 버전을 사용하며, 필요하면 `kubernetes_version`을 명시합니다. AWS와 Azure의 `db_name` 및 백업 Container 이름은 같아야 합니다. MySQL은 `snet-db`에 VNet 통합으로 배치하며 Private DNS Zone을 VNet에 연결합니다. 공개 엔드포인트와 공인 IP 방화벽 규칙은 사용하지 않습니다.

### 2. 사설망에서 최신 dump 복원

복원 명령은 VPN으로 Azure VNet에 연결된 PC 또는 VNet 내부 작업 runner에서 실행합니다. 이 환경에는 Terraform state 접근, Azure CLI, MySQL 8 client, Private DNS 조회와 DB 사설 IP까지의 3306 연결이 필요합니다. Azure Cloud Shell은 기본 상태에서 이 VNet에 연결되지 않습니다. 운영자가 먼저 `nslookup "$(terraform output -raw mysql_fqdn)"`으로 사설 IP 조회를 확인합니다.

```bash
# DB_PASSWORD는 터미널에서 입력하거나 환경변수로 전달합니다.
bash scripts/restore-db.sh
```

Azure CLI 로그인 계정에는 Storage Blob Data Reader 권한이 필요합니다. 기존 Storage Key를 사용하려면 `AZURE_STORAGE_KEY` 환경변수로 전달합니다.

백업 Container에서 최신 유효 dump를 선택해 Azure MySQL에 복원한다. 이미 실행 중인 DR WAS가 있다면 쓰기 트래픽을 차단하고 WAS를 중지한 뒤 복원합니다. Argo CD selfHeal과 HPA가 다시 실행하지 않도록 함께 조정한 뒤, 복원 완료 후 원래 상태로 복귀합니다.

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

Terraform의 DB username과 Key Vault secret은 같은 입력값에서 생성됩니다. `deploy-petclinic.sh`가 AKS CSI identity를 사용하는 SecretProviderClass를 만들고 Pod 마운트 시 Kubernetes Secret을 동기화합니다. 비밀번호를 터미널에서 다시 입력할 필요는 없습니다.

AKS add-on identity에 Key Vault Secrets User 역할을 부여하는 방식은 [Azure 공식 CSI identity 안내](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-identity-access)를 따릅니다. Secret이 바뀌면 마운트 파일과 동기화된 Kubernetes Secret은 갱신될 수 있지만 Spring의 환경 변수는 Pod를 재시작해야 새 값을 읽습니다.

실제 매니페스트와 Gateway 연결을 함께 적용합니다.

```bash
bash scripts/deploy-complete.sh
```

위 스크립트는 HPA·NetworkPolicy를 포함한 Kustomize 구성을 적용하고 Web/WAS rollout 성공을 확인합니다. Web Service는 internal LoadBalancer를 사용합니다. 이후 Web LoadBalancer 주소를 `backend.auto.tfvars`에 저장한 뒤 Terraform으로 Gateway를 갱신합니다. `-auto-approve`를 전달하지 않으면 apply 전에 변경 계획을 확인할 수 있습니다.

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

## 기존 공개 DB에서 이전

기존 공개 MySQL을 VNet 통합으로 변경하면 Terraform에서 서버 교체가 계획될 수 있습니다. dump와 복원 절차를 먼저 확보하고 `terraform plan`의 DB 삭제·생성 항목을 확인하세요. `admin_ip` 입력과 공개 DB 방화벽 규칙은 더 이상 사용하지 않습니다. 새 사설 DB로 복원한 뒤 Key Vault의 FQDN, 주요 행 수와 읽기·쓰기를 확인합니다.

기존 공개 Web LoadBalancer를 internal로 변경하면 Service 주소가 바뀔 수 있습니다. 변경 시간에 `scripts/setup-ingress.sh`를 다시 실행해 새 사설 IP를 Application Gateway backend에 반영하고 Gateway 응답을 확인합니다.
