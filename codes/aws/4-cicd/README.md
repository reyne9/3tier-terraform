# PetClinic CI/CD와 GitOps

이 저장소의 실행 워크플로는 루트 `.github/workflows/`에 있습니다. `petclinic-verify.yml`은 Maven 검증과 Web/WAS 이미지 빌드를 수행합니다. `petclinic-delivery.yml`은 앱 변경 시 Maven 검증, Trivy 파일 검사, Buildx 이미지 게시, 이 저장소의 AWS 이미지 태그 갱신, 애플리케이션 HTTP 확인 순서로 진행하도록 구성했습니다. 테스트나 검사 실패 시 뒤 단계는 실행되지 않습니다.

게시 단계는 저장소 변수 `ENABLE_DELIVERY=true`를 설정해야 실행됩니다. 또한 `aws-production` GitHub Environment, `DOCKERHUB_USERNAME` 저장소 변수, `DOCKERHUB_TOKEN` Environment secret, `AWS_APP_URL` Environment 변수가 필요합니다. Environment에 승인 규칙을 설정하면 이미지 게시 전 운영자 검토를 받을 수 있습니다. 모든 이미지는 Git 커밋 SHA로 태그합니다. 태그 갱신 커밋은 `[skip ci]`로 반복 실행을 막습니다.

Argo CD의 `argocd/application.yaml`은 이 저장소의 `codes/aws/2. service/k8s-manifests`를 추적합니다. 이 디렉터리의 `kustomization.yaml`은 Web/WAS, Service, Ingress, Namespace를 명시합니다. Argo CD를 클러스터에 설치하고 이 Application을 적용해야 자동 동기화가 작동합니다. GitHub Actions만 설정한 상태에서는 클러스터에 배포되지 않습니다.

Azure DR은 `.github/workflows/petclinic-promote-azure.yml`의 수동 실행으로 현재 AWS에서 사용하는 이미지 태그를 Azure 매니페스트에 반영합니다. `azure-dr` Environment 승인, Azure DB 복원과 확인, AKS/Argo CD 준비가 선행되어야 합니다. 이후 `AZURE_APP_URL`로 앱 응답을 확인하고 운영자가 CloudFront 전체 DR 전환을 수행합니다. 자동 점검 페이지 전환과 전체 쓰기 서비스 복구는 별개입니다.

[처음부터 운영까지의 순서](../../../docs/runbooks/end-to-end.md)와 [PPT 대조표](../../../docs/overview/portfolio-claim-check.md)를 함께 참고하세요. 클라우드와 배포 파이프라인의 실제 실행 결과는 별도로 검증해야 합니다.
