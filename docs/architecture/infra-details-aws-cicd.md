# AWS CI/CD 구현 기준

## 실행 경로

- `.github/workflows/petclinic-verify.yml`: Maven 테스트와 Web/WAS 이미지 빌드
- `.github/workflows/petclinic-delivery.yml`: Maven → Trivy → Buildx → Docker Hub → 같은 저장소의 매니페스트 태그 갱신 → Argo CD 자동 동기화 → 앱 HTTP 확인
- `codes/aws/4-cicd/argocd/application.yaml`: `reyne9/3tier-terraform`의 AWS Kustomize 경로 추적
- `codes/aws/2. service/k8s-manifests/kustomization.yaml`: Namespace, Web/WAS, Service, Ingress 목록

`ENABLE_DELIVERY=true`와 Docker Hub 자격 증명, `aws-production` Environment, `AWS_APP_URL`, `AWS_ARGOCD_SERVER`, `AWS_ARGOCD_TOKEN`이 설정되지 않으면 이미지 게시 이후 단계는 실행되지 않습니다. Argo CD가 EKS에 설치되고 Application을 적용해야 Git 커밋이 실제 배포로 이어집니다. Actions는 클러스터에 직접 `kubectl apply`하지 않습니다.

배포 검사는 Argo CD API에서 매니페스트 커밋 SHA, Synced·Healthy 상태와 Web/WAS 이미지 SHA 태그를 확인한 뒤 `/vets.html`을 호출합니다. HPA가 Pod 수를 관리할 수 있도록 Argo CD는 `/spec/replicas` 차이를 무시하고 동기화 시에도 그 값을 유지합니다. 예약 POST·DB 저장 확인은 [운영 가이드](../runbooks/end-to-end.md)를 따릅니다.

Azure DR 이미지 승격은 `petclinic-promote-azure.yml`에서 별도로 승인받아 실행합니다. 자세한 설정값과 순서는 [CI/CD 안내](../../codes/aws/4-cicd/README.md)를 참고하세요.
