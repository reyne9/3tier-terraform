# 포트폴리오 PPT와 저장소 대조

대조 대상은 `포트폴리오_김창주_2.pptx`와 이 저장소입니다. 코드를 구성했다는 사실과 실제 클라우드에서 실행했다는 증거를 구분합니다. 이전 별도 환경의 작업을 부정하는 기록은 아닙니다.

| PPT 내용 | 저장소 구현·설계 | 증거 수준 |
| --- | --- | --- |
| 3, 9, 15쪽: 진료 가능 시간 확인과 예약 저장 | `spring-petclinic`에 수의사·날짜별 빈 시간 조회, 예약 POST, 날짜·시간·설명 검증, 같은 수의사 시간 중복 방지 DB 제약을 추가 | 코드 구성. 평일 09:00~17:00 고정 시간대이며 수의사별 근무표·휴무일은 없음. 새 통합본의 클라우드 실행은 미확인 |
| 4~7, 10쪽: AWS Web/WAS/RDS와 Azure DR | Terraform, Web/WAS 매니페스트, 백업·복원·전환 스크립트 포함 | Terraform 오프라인 검사 기록 있음. 새 통합본의 AWS/Azure 실제 배포는 미확인 |
| 3, 8쪽: 5분 내 점검 페이지와 24시간 RPO | CloudFront 읽기 요청 Origin Failover, 일일 dump와 Azure Blob 보관 설계 | 목표 수치. 전환 시간과 최종 복구 시각 실측 없음 |
| 16쪽: HPA와 Karpenter | Web/WAS CPU HPA 매니페스트를 추가. EKS는 관리형 노드 그룹의 최소·최대 크기를 설정하지만 Karpenter는 설치하지 않음 | HPA는 metrics-server와 클러스터 실행이 필요. Karpenter 표기는 PPT에서 수정 필요 |
| 18쪽: Maven → Trivy → Buildx → Docker Hub → Git 매니페스트 → Argo CD → 스모크 테스트 | `petclinic-delivery.yml`과 같은 저장소를 추적하는 Argo CD Application을 추가. Docker Hub·GitHub Environment·앱 URL을 설정해야 게시 단계 실행 | 이전 성공 CI는 Maven 테스트·이미지 빌드까지. 새 전달 흐름의 실제 실행은 미확인 |
| 20~21쪽: NetworkPolicy, CloudFront만 ALB 접근, CSI | WAS ingress NetworkPolicy와 EKS VPC CNI 정책 설정을 추가. CloudFront 전용 ALB 접근 제어와 Secrets Store CSI는 구현되지 않음. DB 자격 증명은 별도 Kubernetes Secret, 백업 EC2 자격 증명은 Secrets Manager 사용 | PPT의 CloudFront 전용 접근 및 CSI 표기는 수정 필요 |
| 19쪽: Azure MySQL 복원 후 조회·신규 저장 | 복원 절차, Azure 승격 워크플로, 앱 경로 확인이 있음 | 실제 데이터 조회·신규 예약 저장 및 RTO/RPO 측정은 실행 기록 필요 |

[처음부터 운영까지의 순서](../runbooks/end-to-end.md)는 제3자가 각 계정에 맞게 준비할 입력과 작업 순서를 설명합니다. 실제 배포 전에는 Terraform plan, 이미지 게시, Argo CD 동기화, 앱 조회·쓰기와 복원 결과를 확인해야 합니다.
