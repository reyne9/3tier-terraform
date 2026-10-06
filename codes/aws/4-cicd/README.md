# CI/CD 구성 상태

## 현재 실행되는 경로

저장소 루트의 [PetClinic 검증 워크플로](../../../.github/workflows/petclinic-verify.yml)가 GitHub Actions에서 실행됩니다. `spring-petclinic/` 변경 또는 수동 실행 시 Java 21에서 Maven `verify`를 수행하고 Web/WAS Docker 이미지를 로컬로 빌드합니다. [2026-10-06 실행 결과](https://github.com/reyne9/3tier-terraform/actions/runs/37476071052)는 성공했습니다.

이 워크플로는 Docker Hub 푸시, Kubernetes 매니페스트 갱신, Argo CD 동기화, AWS/Azure 배포, 스모크 테스트를 수행하지 않습니다. 이미지를 빌드했다는 사실만으로 클러스터에 배포되었다고 볼 수 없습니다.

## 보관된 배포 예시

`github-actions/petclinic-cicd.yaml`과 `argocd/`는 과거 CI/CD 설계를 참고하기 위한 파일입니다. `github-actions/`의 YAML은 `.github/workflows/` 밖에 있으므로 자동 실행되지 않습니다. 이 예시는 외부 이미지 레지스트리, GitOps 저장소, 클라우드 자격 증명, 이미 배포된 EKS/AKS와 Argo CD를 전제로 하며, 현재 상태로는 이 저장소만으로 배포를 재현할 수 없습니다. 특히 Azure 예시는 `c1oud9/petclinic-gitops`를 참조합니다.

과거 이미지 태그와 리소스 주소는 현재 배포 상태의 증거가 아닙니다. 이 예시를 실제 파이프라인으로 사용하려면 저장소와 이미지 참조를 통합하고, 비밀정보 관리·승인 절차를 결정한 뒤, 테스트 실패 시 중단되도록 수정해야 합니다. 그 후 새 환경에서 빌드·푸시·동기화·롤아웃·HTTP 응답과 쓰기 요청까지 검증해야 합니다.

전체 프로젝트의 재현 범위와 PPT 문구는 [대조표](../../../docs/overview/portfolio-claim-check.md)를 참고하세요.
