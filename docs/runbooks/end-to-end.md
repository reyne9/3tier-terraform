# 처음부터 운영까지: 재현 순서

이 문서는 이 저장소의 코드가 담당하는 범위와 운영자가 준비할 입력을 연결합니다. 새 계정의 AWS/Azure 실제 배포나 장애 전환을 완료했다는 기록은 아닙니다. 배포 전에 비용 한도와 삭제 계획을 정하고 각 `terraform plan`을 검토하세요.

## 1. 준비

AWS와 Azure 계정, Terraform 1.14 이상, AWS CLI, Azure CLI, `kubectl`, Helm, Docker Hub 계정, GitHub Actions 사용 권한이 필요합니다. 사용자 도메인의 Route 53 Hosted Zone과 CloudFront용 `us-east-1` ACM 인증서도 준비합니다. 비밀번호, Storage key, Terraform state와 실제 `tfvars`는 Git에 올리지 않습니다.

애플리케이션은 `spring-petclinic/`에 있고, AWS와 Azure의 Web/WAS 이미지는 같은 Docker Hub 태그를 사용합니다. 예약 시간은 평일 09:00~17:00의 1시간 단위이며, 기준 시간대는 `Asia/Seoul`입니다. 진료 가능 시간은 영업시간에서 이미 예약된 수의사 시간을 제외해 계산합니다. 실제 병원별 근무표나 휴무일 연동은 포함하지 않습니다.

## 2. 인프라 생성

1. `codes/azure/1-always/README.md`의 입력값을 채워 Blob 점검 페이지와 Front Door 상시 계층을 `init → plan → apply` 순서로 생성합니다.
2. `codes/aws/2. service/`의 예제 tfvars에 Azure Storage 정보와 DB 설정을 반영하고 `init → plan → apply`합니다. [AWS 배포 가이드](deployment-guide.md)에 따라 Load Balancer Controller, Secrets Store CSI, Karpenter, metrics-server를 설치하고 Web/WAS 매니페스트를 준비합니다. DB 값은 Terraform이 Secrets Manager에 기록하며 WAS Pod는 IRSA로 읽습니다.
3. ALB DNS와 Front Door 주소를 확인한 다음 `codes/aws/1. route53/README.md`에 따라 Route 53과 CloudFront를 적용합니다.
4. `codes/aws/3. monitoring/`의 알람 대상과 알림 채널을 설정하고 적용합니다.

이 순서는 [코드 검증 기록](code-validation.md)의 의존 관계를 따릅니다. 각 root의 실제 리소스와 권한, 가용 리전은 대상 계정에서 `plan`으로 확인해야 합니다.

## 3. 앱 이미지와 GitOps

1. GitHub 저장소에 `DOCKERHUB_USERNAME` 변수와 `aws-production` Environment의 `DOCKERHUB_TOKEN`, `AWS_APP_URL`을 설정합니다. 운영 승인 규칙을 사용할 경우 Environment에 등록합니다.
2. EKS에 Argo CD를 설치하고 `codes/aws/4-cicd/argocd/application.yaml`을 적용합니다. Application은 이 저장소의 AWS Kustomize 매니페스트를 추적합니다. CSI가 Pod 마운트 시 `db-credentials`를 동기화하며 HPA는 metrics-server의 CPU 메트릭을 사용합니다.
3. 준비가 끝나면 저장소 변수 `ENABLE_DELIVERY=true`를 설정하고 `petclinic-delivery.yml`을 수동 실행하거나 앱 변경을 `main`에 푸시합니다. 테스트와 Trivy 검사가 통과해야 두 이미지를 커밋 SHA 태그로 게시합니다.
4. 워크플로가 AWS 매니페스트의 이미지 태그를 같은 저장소에 커밋하면 Argo CD가 동기화합니다. HTTP 확인이 통과한 뒤 `kubectl rollout status`와 Pod 이미지 SHA, `/vets.html` 응답, 예약 POST와 DB 저장을 직접 확인합니다.

`petclinic-verify.yml` [실행](https://github.com/reyne9/3tier-terraform/actions/runs/37557974495)에서 Maven 테스트와 이미지 빌드가, `petclinic-delivery.yml` [실행](https://github.com/reyne9/3tier-terraform/actions/runs/37557974481)에서 Maven·Trivy가 통과했습니다. `ENABLE_DELIVERY`가 설정되지 않아 이미지 게시·GitOps·운영 검사는 실행되지 않았습니다.

## 4. 백업과 장애 대응

정상 운영에서는 백업 EC2가 RDS dump를 Azure Blob에 주기적으로 업로드합니다. 업로드 성공, 최신 파일 시각, 복원 가능성을 운영자가 확인합니다. AWS 장애 시 CloudFront는 읽기 요청에 대해 점검 페이지로 자동 전환할 수 있으나 POST 쓰기는 복구되지 않습니다.

장기 장애라면 `codes/azure/2-emergency/README.md`와 [DR 절차서](dr-failover-procedure.md)에 따라 AKS·Azure MySQL·Application Gateway를 준비하고 dump를 복원합니다. AKS Key Vault CSI add-on은 DB 연결값을 Key Vault에서 읽습니다. DB 내용을 확인한 뒤 `petclinic-promote-azure.yml`을 수동 실행해 AWS에서 사용 중인 이미지 태그를 Azure 매니페스트로 승격합니다. AKS Argo CD에는 `codes/azure/4-cicd/argocd/application.yaml`을 적용합니다. 앱의 조회와 신규 예약 저장을 확인한 후 운영자가 CloudFront를 전체 Azure DR 모드로 변경합니다.

5분 내 점검 페이지와 24시간 RPO는 PPT의 목표입니다. 실측 결과로 적으려면 전환 시간, 백업 시각, 복원 데이터와 쓰기 테스트 결과를 실행 기록으로 남겨야 합니다.
