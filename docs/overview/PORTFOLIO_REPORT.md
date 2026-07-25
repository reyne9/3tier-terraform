# 멀티클라우드 3-Tier DR 프로젝트

## 프로젝트 개요

AWS EKS 기반 3-Tier 서비스를 주 운영 환경으로 두고, 장애 직후에는 Azure HTTPS 점검 페이지를 자동 제공하며, 관리자 승인 후 AKS와 Azure MySQL로 전체 서비스를 복구하는 단계형 DR 프로젝트다.

## 정상 아키텍처

```text
Route 53
  -> CloudFront
  -> AWS ALB
  -> EKS Web
  -> EKS WAS
  -> RDS MySQL
```

CloudFront는 사용자 HTTPS 진입점이고, AWS Load Balancer Controller가 ALB를 관리한다.

## 장애 직후: 자동 안내

```text
CloudFront Origin Group
  -> AWS ALB 실패
  -> Azure Front Door
  -> Azure Blob Static Website
```

Front Door는 Azure `1-always`에서 상시 배포된다. maintenance mode에서는 HTTPS Blob Origin만 활성화한다. CloudFront의 `GET/HEAD`는 연결 실패나 `500/502/503/504`에 따라 자동 전환된다.

점검 페이지는 입력 기능이 없는 정적 페이지다. CloudFront Origin Failover가 POST/PUT 같은 쓰기 요청을 secondary로 보내지 않는다는 제약과 일치한다.

## 장기 장애: 승인된 전체 서비스 복구

운영자가 전체 DR을 승인하면:

1. Azure `2-emergency` 배포
2. 최신 MySQL dump 복원
3. AKS workload 배포
4. Application Gateway backend 구성
5. 읽기·쓰기와 데이터 정합성 검증
6. Front Door를 `azure_service`로 전환
7. CloudFront를 `azure_dr`로 전환

```text
Route 53
  -> CloudFront
  -> Azure Front Door
  -> Application Gateway
  -> AKS Web/WAS
  -> Azure MySQL
```

## Front Door 상시 유지의 판단

Front Door는 Azure DR Origin의 HTTPS 접속 문제를 해결하기 위해 도입했다. 현재 Application Gateway의 IP 기반 HTTP listener 앞에서 CloudFront용 관리형 TLS hostname과 고정 HTTPS endpoint를 제공한다. 개인 도메인의 사용자 TLS는 CloudFront의 `us-east-1` ACM 인증서가 계속 처리한다.

- 장애 전에 인증서와 HTTPS 점검 경로를 검증
- CloudFront의 Azure HTTPS Origin hostname 고정
- Blob과 Application Gateway backend 전환점 통일
- 장애 중 신규 Edge 배포와 DNS 변경 회피

Blob endpoint 자체도 HTTPS를 제공하지만, 점검 페이지와 전체 Azure 서비스가 동일한 Front Door HTTPS Origin을 사용하게 만드는 것이 핵심이다.

## Terraform 구성

### AWS

- `codes/aws/1. network`
- `codes/aws/2. service`
- `codes/aws/1. route53`
- `codes/aws/3. monitoring`

### Azure

- `codes/azure/1-always`: 네트워크, Storage, 점검 페이지, Front Door
- `codes/azure/2-emergency`: MySQL, AKS, Application Gateway

## 전환 상태

| 상태 | CloudFront | Front Door | 사용자 결과 |
|---|---|---|---|
| 정상 | `normal` | `maintenance` | AWS 서비스 |
| AWS 장애 | `normal` | `maintenance` | HTTPS 점검 페이지 |
| 전체 Azure DR | `azure_dr` | `azure_service` | Azure 전체 서비스 |

## 주요 트러블슈팅

### CloudFront 전환 후 쓰기 실패

화면이 보인다는 사실만으로 DR 성공을 판단했지만 POST 요청은 실패했다. CloudFront Origin Failover가 GET/HEAD/OPTIONS만 secondary로 장애 조치한다는 점이 원인이었다.

개선:

- 자동 점검 페이지와 전체 서비스 DR 분리
- 전체 DR 전환 전 최신 dump 복원과 쓰기 검증
- CloudFront direct Front Door mode에서 7개 method 허용

### Application Gateway 502

AKS WAS LoadBalancer IP가 바뀌었지만 Application Gateway backend가 이전 IP를 가리켰다. 최신 External IP를 다시 조회하고 backend pool과 health probe를 갱신했다.

### Azure MySQL 인증 실패

Terraform 관리자 계정과 Kubernetes Secret이 달랐다. username validation과 Secret/JDBC 설정을 일치시켰다.

### Terraform destroy dependency

Kubernetes가 생성한 Load Balancer, ENI, Security Group 의존성이 남아 삭제가 실패했다. 외부 생성 리소스의 삭제 순서를 runbook으로 정리했다.

## 보안과 접근 제어

- Web/WAS/DB 계층을 subnet, node pool, namespace로 분리
- 필요한 다음 계층 방향으로 접근 범위 제한
- CloudFront viewer HTTPS
- CloudFront에서 Front Door HTTPS
- maintenance mode Front Door에서 Blob HTTPS

현재 Application Gateway listener는 HTTP 80이고 Azure MySQL public access/SSL 설정도 개선 여지가 있다. 구현된 보안과 향후 개선을 구분해 설명한다.

## 운영 명령

전체 Azure DR:

```bash
./scripts/switch-to-azure.sh --approved --db-restored
```

AWS failback:

```bash
./scripts/switch-to-aws.sh --approved
```

Azure `2-emergency` 삭제는 별도 승인 작업이다.

## 핵심 학습

인프라 리소스를 생성하는 것보다 중요한 것은 상태 전환과 데이터 책임을 명시하는 일이었다. 장애 직후의 사용자 안내는 자동화할 수 있지만, 쓰기 가능한 서비스 복구는 DB 복원과 검증 없이 자동화해서는 안 된다. 이 프로젝트는 그 경계를 Terraform 변수와 운영 승인 절차로 표현했다.
