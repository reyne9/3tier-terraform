# Multi-Cloud DR 문서 인덱스

AWS/Azure 멀티클라우드 Backup & Restore DR 솔루션의 문서를 목적별로 정리한 인덱스입니다.

## 빠른 시작

- [프로젝트 포트폴리오 보고서](overview/PORTFOLIO_REPORT.md): 프로젝트 배경, 아키텍처, 기술 선택, 성과 정리
- [면접 대비 패키지](interview-prep/README.md): 기초 복습, 구현 상세, Q&A, 포트폴리오 다이어그램
- [배포 가이드](runbooks/deployment-guide.md): AWS Primary와 Azure DR 인프라 배포 순서
- [DR 전환 절차](runbooks/dr-failover-procedure.md): AWS 장애 시 Azure로 복구하는 실행 절차
- [트러블슈팅](runbooks/troubleshooting.md): 배포와 운영 중 자주 만나는 문제 해결

## 문서 구조

```
docs/
├── README.md              # 문서 인덱스
├── overview/              # 포트폴리오와 프로젝트 개요
├── runbooks/              # 배포, DR, 테스트, 삭제, 트러블슈팅 절차
├── architecture/          # AWS/Azure/보안/Failover 상세 설계
└── interview-prep/        # 면접 복습 자료와 아키텍처 다이어그램
```

## Overview

- [PORTFOLIO_REPORT.md](overview/PORTFOLIO_REPORT.md): 전체 프로젝트 리포트
- [petclinic-web-was-separation.md](overview/petclinic-web-was-separation.md): PetClinic Web/WAS 분리 배경과 구조
- [source-integration.md](overview/source-integration.md): PetClinic 소스의 출처와 통합 범위

## Runbooks

- [deployment-guide.md](runbooks/deployment-guide.md): AWS/Azure 인프라 배포 가이드
- [dr-failover-procedure.md](runbooks/dr-failover-procedure.md): AWS 장애 시 DR 전환 절차
- [DR_TEST_GUIDE.md](runbooks/DR_TEST_GUIDE.md): DR 테스트 가이드
- [DESTROY_GUIDE.md](runbooks/DESTROY_GUIDE.md): 인프라 삭제 가이드
- [troubleshooting.md](runbooks/troubleshooting.md): 종합 트러블슈팅

## Architecture

- [current-implementation.md](architecture/current-implementation.md): 실제 코드 기준 단계형 CloudFront→Front Door DR 경로
- [FAILOVER_CONFIGURATION.md](architecture/FAILOVER_CONFIGURATION.md): CloudFront와 Front Door Failover 설정
- [route53-health-check-guide.md](architecture/route53-health-check-guide.md): Route53 헬스체크와 CloudFront 구성
- [security-architecture.md](architecture/security-architecture.md): 구현된 보안 제어와 개선 과제
- [infra-details-aws-route53.md](architecture/infra-details-aws-route53.md): AWS Route53 및 CloudFront
- [infra-details-aws-service.md](architecture/infra-details-aws-service.md): AWS VPC, EKS, RDS
- [infra-details-aws-monitoring.md](architecture/infra-details-aws-monitoring.md): AWS 모니터링과 병목 감지
- [infra-details-aws-cicd.md](architecture/infra-details-aws-cicd.md): CI/CD 파이프라인
- [infra-details-azure-always.md](architecture/infra-details-azure-always.md): Azure 상시 대기 인프라
- [infra-details-azure-emergency.md](architecture/infra-details-azure-emergency.md): Azure 재해 복구 인프라

## Interview Prep

- [basic-review.md](interview-prep/basic-review.md): 기초 개념부터 다시 보는 면접 복습 자료
- [implementation-review.md](interview-prep/implementation-review.md): 실제 Terraform 구현 기준 상세 복습
- [interview-qna.md](interview-prep/interview-qna.md): 면접 질문/답변 카드
- [architecture-slides/](interview-prep/architecture-slides/): 포트폴리오용 아키텍처 다이어그램

## 문서 관리 원칙

- 실행 절차는 `runbooks/`에 둡니다.
- 설계 설명과 서비스별 상세 내용은 `architecture/`에 둡니다.
- 자기소개서, 포트폴리오, 프로젝트 개요 성격의 문서는 `overview/`에 둡니다.
- 면접 복습용 자료와 발표용 다이어그램은 `interview-prep/`에 둡니다.
- 링크는 GitHub에서 바로 열리도록 `/docs/...` 형태의 저장소 루트 기준 경로를 사용합니다.
