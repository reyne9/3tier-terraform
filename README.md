# PetClinic 멀티클라우드 DR

AWS에서 Spring PetClinic을 운영하고, 장애 시 Azure에서 서비스를 복구하는 구성을 코드로 정리한 프로젝트입니다. Terraform 인프라, Kubernetes 매니페스트, Web/WAS 애플리케이션 소스, 백업·복원 스크립트를 한 저장소에서 확인할 수 있습니다.

Terraform 인프라부터 Web/WAS 이미지, GitHub Actions·Argo CD 배포, 백업·복원과 DR 전환까지의 실행 순서는 [운영 가이드](docs/runbooks/end-to-end.md)에 정리했습니다. 코드 검사와 테스트 결과는 [검증 기록](docs/runbooks/code-validation.md)에서 확인할 수 있습니다.

## 요청 경로와 DR 방식

| 상태 | 요청 경로 | 전환 방식 |
| --- | --- | --- |
| 정상 | Route 53 → CloudFront → AWS ALB → EKS Web(Nginx) → WAS(Spring Boot) → RDS MySQL | AWS가 주 서비스 |
| AWS 장애 직후 | CloudFront → Azure Front Door → Blob 점검 페이지 | CloudFront가 `GET`·`HEAD`·`OPTIONS` 요청에 대해 자동 Origin Failover |
| 전체 DR | CloudFront → Azure Front Door → Application Gateway → AKS Web/WAS → Azure MySQL | 운영자가 인프라 배포, 백업 복원, 읽기·쓰기 검증 후 수동 전환 |

정상 상태의 `POST` 등 쓰기 요청은 AWS로 전달됩니다. **CloudFront의 자동 Origin Failover는 쓰기 요청을 Azure 서비스로 복구하지 않습니다.** 전체 DR에는 최신 MySQL dump 복원과 애플리케이션 쓰기 검증이 별도로 필요합니다. 상세 구성과 TLS 경계는 [현재 구현 기준 아키텍처](docs/architecture/current-implementation.md)에 적었습니다.

Azure MySQL은 전용 DB 서브넷에 VNet 통합으로 배치하고 Private DNS Zone으로 사설 IP를 조회합니다. AKS에서 DB까지 TLS를 사용하며 복원 작업도 VNet 연결 환경에서 수행합니다.

## 저장소 구성

| 경로 | 내용 |
| --- | --- |
| [`spring-petclinic/`](spring-petclinic/README.md) | PetClinic 소스·테스트, Maven 빌드, Web/WAS Dockerfile |
| [`codes/aws/1. route53/`](codes/aws/1.%20route53/README.md) | Route 53, CloudFront, Origin Failover |
| [`codes/aws/2. service/`](codes/aws/2.%20service/) | VPC, EKS, RDS, 백업 인스턴스, Kubernetes 매니페스트 |
| [`codes/aws/3. monitoring/`](codes/aws/3.%20monitoring/) | CloudWatch 및 복구 알림 Lambda |
| [`codes/azure/1-always/`](codes/azure/1-always/README.md) | Blob 점검 페이지와 Front Door 상시 계층 |
| [`codes/azure/2-emergency/`](codes/azure/2-emergency/README.md) | Azure MySQL, AKS, Application Gateway와 복원 절차 |
| [`scripts/`](scripts/) | 승인 후 DR 전환·복귀 스크립트 |
| [`docs/`](docs/README.md) | 구현 기준, 배포 순서, 검증 기록, 포트폴리오 다이어그램 |

PetClinic 소스의 출처와 통합 내역은 [소스 통합 기록](docs/overview/source-integration.md)에 남겼습니다. 원본 Spring PetClinic의 라이선스는 [`spring-petclinic/LICENSE.txt`](spring-petclinic/LICENSE.txt)를 참고하세요. 이미지는 Git 커밋 SHA 태그로 게시하고 동일한 태그를 GitOps 매니페스트에 반영합니다.

## 로컬 검증

클라우드 자격 증명 없이 다음 검사를 실행할 수 있습니다.

```bash
python3 -m unittest discover -s tests -v
```

2026년 10월 6일 기준 오프라인 회귀 테스트 10개, Terraform 1.14.0의 `fmt -check`와 5개 루트 `validate`, mock `terraform test` 9개가 통과했습니다. 테스트는 백업 실패 처리, 특수문자 자격 증명, 복원 대상 확인, Lambda 알림 재호출 방지, 쉘 문법을 다룹니다. [검증 기록](docs/runbooks/code-validation.md)에는 실제 클라우드에서 추가로 확인할 항목을 구분해 적었습니다.

PetClinic 애플리케이션은 Java 17 이상과 Maven Wrapper가 필요합니다. Web/WAS 이미지는 Docker가 필요합니다.

```bash
cd spring-petclinic
./mvnw verify
./mvnw package -DskipTests
docker build -f Dockerfile.was -t petclinic-was:local .
docker build -f Dockerfile.web -t petclinic-web:local .
```

[검증 워크플로](.github/workflows/petclinic-verify.yml)는 테스트와 이미지 빌드를 수행합니다. [배포 워크플로](.github/workflows/petclinic-delivery.yml)는 설정을 활성화하면 Maven, Trivy, Buildx, Docker Hub, 같은 저장소의 매니페스트 갱신, Argo CD 자동 동기화, HTTP 확인 순서로 이어집니다. Azure DR 이미지는 [수동 승격 워크플로](.github/workflows/petclinic-promote-azure.yml)로 별도 관리합니다. Maven·Trivy 검사 후 이미지를 게시하고 Argo CD의 revision·rollout·이미지 태그와 HTTP 응답을 확인합니다.

## 문서

- [현재 구현 기준 아키텍처](docs/architecture/current-implementation.md): 실제 코드의 요청 경로와 DR 전환 조건
- [소스 통합 기록](docs/overview/source-integration.md): PetClinic 원본 커밋과 통합 범위
- [처음부터 운영까지](docs/runbooks/end-to-end.md): 준비, 배포, 이미지 게시, 운영, DR 순서
- [PPT 및 구현 대조표](docs/overview/portfolio-claim-check.md): 슬라이드의 주장과 실제 코드·검증 범위
- [코드 검증 기록](docs/runbooks/code-validation.md): 수정 내역, 테스트 범위, 배포 전 점검 항목
- [배포 가이드](docs/runbooks/deployment-guide.md): AWS·Azure 인프라 설정 순서
- [DR 절차서](docs/runbooks/dr-failover-procedure.md): 백업 복원과 서비스 전환 순서
- [포트폴리오 다이어그램](docs/interview-prep/architecture-slides/): 구성 설명 자료

RTO·RPO와 비용은 환경, 백업 주기, 실제 복원 결과에 따라 달라집니다. 운영 가이드에서 백업 시점, 복원 완료 시점과 읽기·쓰기 확인 시점을 기록합니다.
