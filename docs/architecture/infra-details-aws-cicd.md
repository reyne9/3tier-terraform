# AWS CI/CD 구현 기준

## 실행 경로

- `.github/workflows/petclinic-verify.yml`: Maven 테스트와 Web/WAS 이미지 빌드
- `.github/workflows/petclinic-delivery.yml`: Maven → Trivy → Buildx → Docker Hub → 같은 저장소의 매니페스트 태그 갱신 → Argo CD 자동 동기화 → 앱 HTTP 확인
- `codes/aws/4-cicd/argocd/application.yaml`: `reyne9/3tier-terraform`의 AWS Kustomize 경로 추적
- `codes/aws/2. service/k8s-manifests/kustomization.yaml`: Namespace, Web/WAS, Service, Ingress 목록

`ENABLE_DELIVERY=true`와 Docker Hub 자격 증명, `aws-production` Environment, `AWS_APP_URL`이 설정되지 않으면 이미지 게시 이후 단계는 실행되지 않습니다. Argo CD가 EKS에 설치되고 Application을 적용해야 Git 커밋이 실제 배포로 이어집니다. Actions는 클러스터에 직접 `kubectl apply`하지 않습니다.

GitOps 커밋과 Argo CD 동기화 사이에는 시간이 걸릴 수 있습니다. 현재 HTTP 확인은 `/vets.html`의 응답을 확인하며, 이미지 SHA가 Pod에 실제 반영되었는지와 예약 POST·DB 저장까지 확인하는 절차는 [운영 가이드](../runbooks/end-to-end.md)의 클러스터 검사로 보완해야 합니다.

Azure DR 이미지 승격은 `petclinic-promote-azure.yml`에서 별도로 승인받아 실행합니다. 자세한 설정값과 순서는 [CI/CD 안내](../../codes/aws/4-cicd/README.md)를 참고하세요.
