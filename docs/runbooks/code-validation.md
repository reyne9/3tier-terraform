# Terraform 수정 및 검증 기록

> 2026-10-07 추가: PPT 설명에 맞춰 Karpenter, AWS/Azure Secrets Store CSI, CloudFront origin-facing 보안 그룹과 Web egress 정책을 코드에 연결했다. 변경된 AWS service·Route 53·Azure emergency의 Terraform `validate`, 쉘 구문, AWS/Azure Kustomize 빌드가 통과했다. [앱 빌드 CI](https://github.com/reyne9/3tier-terraform/actions/runs/37557974495)와 [Maven·Trivy CI](https://github.com/reyne9/3tier-terraform/actions/runs/37557974481)도 통과했다. 이미지 게시 단계는 설정되지 않아 실행되지 않았고, 신규 리소스의 실제 `apply` 및 장애 테스트도 수행하지 않았다. 아래 2026-10-06 기록은 그 날짜의 구성과 결과다.

> 2026-10-06 재검증: Terraform 1.14.0에서 5개 root의 `fmt -check`와 `validate`, mock `terraform test` 9건이 통과했다. Python 오프라인 회귀 테스트 10건도 통과했다. [GitHub Actions 실행](https://github.com/reyne9/3tier-terraform/actions/runs/37476071052)에서는 Maven 테스트와 Web/WAS 이미지 빌드가 통과했다. 실제 AWS/Azure `apply`, 이미지 레지스트리 푸시와 클라우드 배포는 이번 검증에 포함하지 않았다.

2026-09-22에 기존 AWS Primary / Azure Backup & Restore 구성을 기준으로 수정했습니다. 기능 확장 대신 최초 배포, 정상 요청, 백업·복원, 모니터링을 막는 코드 문제를 처리했습니다. 실제 AWS/Azure apply는 실행하지 않았습니다.

## 수정한 동작

- CloudFront 정상 모드도 7개 HTTP method를 허용합니다. POST는 AWS로 전달되며 자동 failover하지 않습니다. DR 모드는 Front Door를 직접 선택합니다. 조건부 output의 타입 오류와 리소스 생성 후에만 알 수 있는 값에 의존하던 count를 수정했습니다.
- Blob의 실제 `primary_web_host`를 사용합니다. Storage endpoint의 `z12` 고정값을 제거했습니다.
- Azure 최초 apply는 Gateway backend 없이 가능합니다. `deploy-complete.sh`가 기존 매니페스트로 Web/WAS를 배포하고 Web LoadBalancer IP를 `backend.auto.tfvars`에 저장합니다. Gateway는 Terraform만 관리하며 Web 80 → WAS 8080 경로를 사용합니다.
- Azure DB 방화벽은 임의의 `/16` 공인 IP 대역 대신 AKS의 실제 관리형 outbound IP 하나를 허용합니다. 사용자 VNet에 대한 AKS Network Contributor 권한도 구성합니다.
- AKS 1.28 고정을 제거했습니다. 새 클러스터는 해당 리전의 권장 버전을 사용하며, 기존 클러스터는 적용 전에 사용할 지원 버전을 명시하는 편이 좋습니다.
- 복원 대상과 DB Secret은 Terraform output을 사용합니다. 복원 전에 dump의 DB 이름을 확인하고, 복원 뒤 대상 DB의 테이블 존재를 확인합니다. 행 수·최근 데이터·애플리케이션 쓰기 검증은 운영자가 별도로 수행해야 합니다.
- 백업 스크립트는 매번 Secrets Manager에서 자격증명을 읽습니다. 특수문자를 shell 코드에 삽입하지 않습니다. dump 실패 시 업로드를 중단하고, 겹친 cron 실행을 막으며, user data 변경 시 EC2를 교체해 실제 초기화가 다시 실행되도록 했습니다.
- `enable_backup_instance = false`는 EC2와 해당 상태 알람을 생성하지 않습니다. 백업용 IAM·보안 그룹·Secret은 유지합니다. SSH 공개 키는 선택사항이며 비어 있으면 SSM으로 접속합니다. RDS 보관 기간 변수도 실제 리소스에 연결했습니다.
- RDS ingress를 별도 rule 리소스로 통일했습니다. LB Controller 설치는 chart와 같은 버전의 IAM policy를 사용하며 재실행 시 같은 role을 사용합니다.
- EKS 삭제 훅은 노드 삭제 전에 Kubernetes Ingress/LoadBalancer Service를 삭제하고 controller 정리를 기다립니다. VPC의 ENI를 강제로 분리하지 않습니다. 삭제 시 `aws`, `kubectl`, `jq`와 해당 클러스터 접근 권한이 필요하며, 기본 리전 외에서는 `AWS_REGION`을 지정합니다.
- 모니터링은 실제 EKS ASG 이름을 조회합니다. ALB에는 지원되지 않는 `SurgeQueueLength` 대신 `RejectedConnectionCount`를 사용합니다. 기존 Terraform 주소와 임계값 변수명은 유지했습니다. Observability add-on이 먼저 생성한 로그 그룹은 import block으로 인계합니다.
- Lambda에 빠진 EC2 상태 조회 권한을 추가했습니다. 자신이 발행한 일반 텍스트 알림을 다시 JSON 알람으로 처리하지 않으며 초기화 중인 노드를 비정상 노드로 종료하지 않습니다.

## 기존 state에 적용하기 전

먼저 각 root의 `terraform plan`을 검토합니다. AWS 서비스의 EC2/key/알람 주소 변경은 `moved` block으로 처리합니다. user data 변경으로 **백업 EC2 교체가 계획될 수 있습니다**. 로컬 백업 파일은 교체 시 사라지므로 Azure 업로드 상태를 확인하세요.

기존 RDS ingress가 inline rule로 생성되어 있다면 아래 rule을 먼저 import해야 중복 규칙 오류를 피할 수 있습니다. AWS 서비스 디렉터리에서 실행합니다. 새 환경에는 필요하지 않습니다.

```bash
RDS_SG=$(printf '%s\n' 'module.rds.db_security_group_id' | terraform console | tr -d '"')
EKS_SG=$(terraform output -raw eks_cluster_security_group_id)
terraform import 'module.rds.aws_security_group_rule.rds_from_eks' \
  "${RDS_SG}_ingress_tcp_3306_3306_${EKS_SG}"
```

기존 AKS identity에 같은 VNet Network Contributor 역할이 이미 있다면 해당 role assignment를 `module.aks.azurerm_role_assignment.vnet`으로 import합니다. 실제 assignment ID는 해당 구독에서 확인해야 하므로 임의 ID를 문서에 넣지 않았습니다.

기존 `setup-ingress.sh`로 AGIC를 활성화했다면 Gateway를 동시에 관리하지 않도록 먼저 AGIC를 비활성화하고 기존 `web-ingress`를 제거한 뒤 새 배포 절차를 사용합니다. 해당 단계는 기존 서비스에 영향을 줄 수 있으므로 변경 시간에 수행합니다. 이전 `web/ingress.yaml`은 참조용으로 남아 있지만 새 배포 스크립트는 적용하지 않습니다.

AWS와 Azure의 `db_name`은 기존 데이터베이스 이름으로 맞추세요. 기본값은 양쪽 `petclinic`으로 통일했으며 기존 AWS DB가 다른 이름이면 `terraform.tfvars`에 그 이름을 명시해야 의도하지 않은 DB 교체를 피할 수 있습니다. `backup_container_name`도 AWS의 `azure_backup_container_name` 및 상시 계층과 같아야 합니다.

## 배포 순서

1. Azure `1-always`: tfvars 입력 → init → plan → apply.
2. AWS `2. service`: Azure Storage 정보와 DB 비밀번호 입력 → init → plan → apply. LB Controller·Secrets Store CSI·Karpenter·metrics-server를 설치하고 Web/WAS 매니페스트를 배포합니다. DB Secret은 CSI 마운트 시 동기화됩니다.
3. AWS `1. route53`: 기존 Hosted Zone, **us-east-1의 ISSUED ACM 인증서**, 실제 ALB DNS 또는 EKS 이름, Azure Front Door output을 입력하고 적용합니다.
4. AWS `3. monitoring`: EKS/ALB/RDS/Health Check 정보를 입력하고 적용합니다. Slack 연결은 기존과 같이 사용자가 먼저 완료해야 합니다.
5. DR 시 Azure `2-emergency`: backend `[]`, port `80`으로 적용합니다. 로컬 복원 PC의 공인 IP는 `admin_ip`에 입력합니다. `restore-db.sh` → `deploy-complete.sh` → 읽기·쓰기·데이터 검증 → 기존 전환 스크립트 순서로 진행합니다.

`restore-db.sh`는 Azure CLI 로그인과 Storage Blob Data Reader 권한 또는 환경변수로 전달한 Storage key/SAS가 필요합니다. Terraform에 비밀번호를 입력하는 방법은 기존과 같으며 저장소에 실제 tfvars/state를 커밋하지 않습니다.

## 로컬 검증

최종 결과: Terraform 5개 root의 validate 통과, mock plan 테스트 9건 통과, Python 회귀 테스트 10건 통과, 전체 쉘 스크립트 문법 검사와 Terraform fmt 검사 통과.

Terraform 1.14.0으로 검사했습니다. 검증 프로바이더는 AWS edge 6.56.0, AWS service/monitoring 6.66.0, AzureRM 3.117.1입니다. `terraform init`은 provider 다운로드가 필요합니다. test 파일은 mock provider와 `command = plan`만 사용하므로 클라우드 리소스를 생성하지 않습니다.

```bash
terraform fmt -check -recursive codes
python3 -m unittest discover -s tests -v
for dir in 'codes/aws/1. route53' 'codes/aws/2. service' \
  'codes/aws/3. monitoring' 'codes/azure/1-always' 'codes/azure/2-emergency'; do
  terraform -chdir="$dir" init -backend=false
  terraform -chdir="$dir" validate
  terraform -chdir="$dir" test
done
```

검증 범위는 Terraform 문법·스키마·모의 plan, 백업 실패 처리, 특수문자 자격증명 처리, Lambda 재호출 처리 및 쉘 문법입니다. 실제 계정의 IAM, 리전별 AKS/VM 지원, 이미지 pull, 실제 DB dump 복원, ALB/App Gateway 연결, 쓰기 요청과 failover는 배포 후 검증해야 합니다. 과거 README의 배포 성공 기록은 이번 검증 결과에 포함하지 않았습니다.

## 확인한 공식 자료

- [CloudFront Origin Failover의 HTTP method 범위](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/high_availability_origin_failover.html)
- [EC2 CloudWatch metrics와 ASG dimension](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/viewing_metrics_with_cloudwatch.html)
- [AzureRM 3.117.1 AKS 속성](https://github.com/hashicorp/terraform-provider-azurerm/blob/v3.117.1/website/docs/r/kubernetes_cluster.html.markdown)
- [AzureRM 3.117.1 Storage Account 속성](https://github.com/hashicorp/terraform-provider-azurerm/blob/v3.117.1/website/docs/r/storage_account.html.markdown)
