# 포트폴리오 PPT와 저장소 대조

대조 대상은 `포트폴리오_김창주_2.pptx`와 이 저장소입니다. 코드를 구성했다는 사실과 실제 클라우드에서 실행했다는 증거를 구분합니다. 이전 별도 환경의 작업을 부정하는 기록은 아닙니다.

| PPT 내용 | 저장소 구현·설계 | 증거 수준 |
| --- | --- | --- |
| 3, 9, 15쪽: 진료 가능 시간 확인과 예약 저장 | `spring-petclinic`에 수의사·날짜별 빈 시간 조회, 예약 POST, 날짜·시간·설명 검증, 같은 수의사 시간 중복 방지 DB 제약을 추가 | 코드 구성. 평일 09:00~17:00 고정 시간대이며 수의사별 근무표·휴무일은 없음. 예약 조회·저장 테스트는 앱 CI로 검사 |
| 4~7, 10쪽: AWS Web/WAS/RDS와 Azure DR | Terraform, Web/WAS 매니페스트, 백업·복원·전환 스크립트 포함 | Terraform validate·mock plan, 백업·복원 회귀 테스트로 검사 |
| 3, 8쪽: 5분 내 점검 페이지와 24시간 RPO | CloudFront 읽기 요청 Origin Failover, 일일 dump와 Azure Blob 보관 설계 | 목표 수치. 전환 시간과 최종 복구 시각 실측 없음 |
| 16쪽: HPA와 Karpenter | Web/WAS CPU HPA, metrics-server 설치 스크립트, Karpenter 1.14.1 설치 스크립트와 NodePool/EC2NodeClass 구성 | 코드 구성. 노드 증설 실측 없음 |
| 18쪽: Maven → Trivy → Buildx → Docker Hub → Git 매니페스트 → Argo CD → 스모크 테스트 | `petclinic-delivery.yml`과 같은 저장소를 추적하는 Argo CD Application 구성. Docker Hub·GitHub Environment·앱 URL을 설정해야 게시 단계 실행 | [CI](https://github.com/reyne9/3tier-terraform/actions/runs/37557974481)에서 Maven·Trivy 통과. 게시·배포 단계는 Environment 설정에 따라 실행하며 Argo CD revision·health·image를 확인 |
| 20~21쪽: NetworkPolicy, CloudFront만 ALB 접근, CSI | Web egress·WAS ingress 정책, CloudFront origin-facing prefix list 전용 ALB 보안 그룹, AWS Secrets Manager·IRSA·CSI와 Azure Key Vault CSI 구성 | CloudFront 서비스 출발지 제한까지 코드 구성. 특정 distribution만 허용하는 인증은 없음. 정책과 매니페스트는 Kustomize로 생성 |
| 19쪽: Azure MySQL 복원 후 조회·신규 저장 | 복원 절차, Azure 승격 워크플로, 앱 경로 확인이 있음 | 복원 후 데이터 조회·신규 예약 저장과 전환 시간을 운영 절차에서 확인 |

[처음부터 운영까지의 순서](../runbooks/end-to-end.md)는 제3자가 각 계정에 맞게 준비할 입력과 작업 순서를 설명합니다. 실제 배포 전에는 Terraform plan, 이미지 게시, Argo CD 동기화, 앱 조회·쓰기와 복원 결과를 확인해야 합니다.
