# 멀티클라우드 DR 프로젝트 면접 준비 패키지

## 읽는 순서

1. [`basic-review.md`](./basic-review.md)

기초부터 다시 기억을 끌어올리는 자료다. VPC, EKS endpoint, ALB, CloudFront, RDS, AKS, Terraform 같은 개념을 면접 답변 형태로 정리했다.

2. [`implementation-review.md`](./implementation-review.md)

GitHub 실제 Terraform 코드 기준으로 구현 내용을 정리한 자료다. EKS endpoint 설정, 노드 그룹, CloudFront origin failover, RDS, Azure AKS, Application Gateway, MySQL 설정과 개선 포인트를 확인할 수 있다.

3. [`interview-qna.md`](./interview-qna.md)

면접 직전에 읽는 질문/답변 카드다. 실제로 소리 내서 답변 연습할 때 사용한다.

4. [`architecture-slides/`](./architecture-slides/)

포트폴리오에 넣을 아키텍처 다이어그램이다. PNG는 바로 붙여넣기용이고, SVG는 원본 벡터 파일이다.

## 다이어그램 목록

- [`01-overview-flow.png`](./architecture-slides/01-overview-flow.png): 멀티클라우드 DR 전체 구조
- [`02-aws-primary-detail.png`](./architecture-slides/02-aws-primary-detail.png): AWS 운영 환경 상세 구조
- [`03-azure-dr-detail.png`](./architecture-slides/03-azure-dr-detail.png): Azure DR 환경 상세 구조
- [`04-dr-operation-timeline.png`](./architecture-slides/04-dr-operation-timeline.png): 장애 대응 타임라인
- [`05-edge-failover-rationale.png`](./architecture-slides/05-edge-failover-rationale.png): 설계 포인트

## 면접에서 가장 먼저 말할 요약

> 이 프로젝트는 AWS 기반 3-Tier 서비스를 Azure DR 환경으로 복구할 수 있게 설계한 멀티클라우드 인프라 프로젝트입니다. 평상시에는 Route 53, CloudFront, ALB, EKS, RDS MySQL로 서비스를 운영하고, 장애가 발생하면 CloudFront가 Azure Blob 점검 페이지로 전환해 사용자에게 통제된 안내를 제공합니다. 이후 장기 장애로 판단되면 Terraform으로 Azure AKS, Application Gateway, Azure MySQL을 생성하고, 백업 DB를 복구해 서비스를 재개하는 구조입니다.

## 면접에서 조심할 표현

- 이 구조는 Active-Active가 아니라 Pilot Light/수동 DR에 가깝다.
- EKS endpoint는 사용자 접속 주소가 아니라 Kubernetes API Server 관리 주소다.
- CloudFront failover는 우선 점검 페이지 전환이며, 전체 서비스 자동 전환과는 다르다.
- 실제 코드에는 보안 개선점이 있다. 질문이 나오면 숨기지 말고 개선 방향까지 말한다.
- 포트폴리오 설명에서는 Petclinic 기반 3-Tier DR로 통일한다.
