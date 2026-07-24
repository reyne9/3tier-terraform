# AWS CI/CD 구현 상세

**코드 위치**: `codes/aws/4-cicd/`

## GitHub Actions

Workflow: `github-actions/petclinic-cicd.yaml`

### 구현된 Job

1. Maven build
2. Maven test
3. SonarQube placeholder
4. Trivy filesystem scan
5. DockerHub Web/WAS image build와 push
6. Kubernetes manifest image tag 갱신과 Git push
7. AWS EKS 직접 배포
8. 수동 실행 시 Azure AKS 배포
9. ALB health/smoke test
10. 알림 placeholder
11. 수동 rollback job

### Trigger

- `main`, `develop` push
- `main`, `develop` pull request
- `workflow_dispatch`
- 문서 변경은 push trigger에서 제외

### 실제 동작상 주의점

- Maven test는 `continue-on-error: true`라 테스트 실패가 pipeline을 차단하지 않는다.
- SonarQube command는 주석 처리된 placeholder다.
- Trivy scan과 SARIF upload도 `continue-on-error: true`다.
- Slack webhook 호출은 주석 처리된 placeholder다.
- AWS 자격증명은 access key secret을 사용한다. OIDC federation은 구현되지 않았다.
- Docker image metadata step은 하나의 문자열 output을 여러 image tag 위치에 사용하므로 실제 tag 형식을 workflow 실행으로 검증해야 한다.
- Azure AKS job은 `workflow_dispatch`에서만 실행된다.
- Azure job의 `codes/azure/2-emergency/k8s-manifests/ingress.yaml` 경로는 실제 repository에 없다. 실제 Ingress는 `k8s-manifests/web/ingress.yaml`이다.
- 환경 변수는 `blue` 리소스명을 고정 사용하지만 Azure Terraform 기본 environment는 `prod`다.
- `workflow_dispatch` input에 `action` 정의가 없어 rollback 조건은 현재 trigger 정의만으로는 충족되지 않는다.

따라서 문서에서 이 pipeline을 품질 gate가 모두 강제되는 완전 자동화 pipeline으로 표현하지 않는다.

## Argo CD

파일:

- `argocd/application.yaml`
- `argocd/argocd-values.yaml`

Application:

- Project: `petclinic`
- App: `petclinic-aws`
- Source: `codes/aws/2. service/k8s-manifests`
- Revision: `main`
- Automated sync, prune, self-heal

Values:

- Argo CD controller/server/repo server replica와 autoscaling 설정
- ALB Ingress annotation
- Redis HA
- Slack/GitHub OAuth secret reference
- 기본 RBAC readonly, 특정 GitHub group admin

### Template 값

다음 값은 실제 배포값이 아니라 교체가 필요한 template다.

- `ACCOUNT_ID`
- `CERT_ID`
- `argocd.example.com`
- `$slack-token`
- `$dex-github-client-id`
- `$dex-github-client-secret`
- `github-secret`

## 권장 검증

```bash
git diff --check

kubectl apply --dry-run=client \
  -f codes/aws/4-cicd/argocd/application.yaml
```

GitHub Actions는 실제 runner와 secret이 필요하므로 local static 검증만으로 성공을 보장하지 않는다.

## 개선 우선순위

1. Test/Trivy 실패를 quality gate로 전환
2. GitHub OIDC로 AWS/Azure 인증
3. Azure manifest 경로와 environment 통일
4. `workflow_dispatch.inputs.action` 추가
5. SonarQube와 Slack placeholder 제거 또는 실제 연동
6. GitOps 방식과 직접 `kubectl apply` 방식 중 책임 경계 정리
