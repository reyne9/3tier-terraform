# DR 테스트 가이드

## 테스트 목표

1. 정상 AWS 경로 확인
2. AWS 장애 시 HTTPS 점검 페이지 자동 전환 확인
3. 쓰기 method 자동 failover 제한 재현
4. 승인된 전체 Azure DR 전환 확인
5. AWS failback 확인

## 사전 조건

- Azure `1-always` 배포 완료
- Front Door endpoint HTTPS 응답 정상
- CloudFront `traffic_mode = "normal"`
- Front Door `frontdoor_backend_mode = "maintenance"`
- AWS ALB/EKS/RDS 정상
- 테스트 데이터와 복구용 최신 dump 준비

```bash
terraform -chdir="codes/aws/1. route53" output -raw traffic_mode
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
```

## 테스트 1: 정상 AWS 경로

```bash
curl -I "https://<service-domain>/"
```

확인:

- HTTP 접속 시 HTTPS redirect
- CloudFront 응답
- AWS 애플리케이션 화면
- 조회·쓰기 정상

## 테스트 2: 자동 HTTPS 점검 페이지

허가된 장애 시뮬레이션 방법으로 ALB가 실패 응답을 반환하게 한다.

기대 경로:

```text
CloudFront -> Front Door -> Blob 점검 페이지
```

기대 결과:

- GET/HEAD 요청이 자동으로 점검 페이지 응답
- 사용자 도메인과 HTTPS 유지
- Front Door endpoint도 HTTPS 응답
- 점검 페이지에 입력 기능 없음

CloudFront Origin Group의 전환 조건은 연결 실패와 설정된 `500/502/503/504`다.

## 테스트 3: 쓰기 요청 제한

장애 상태에서 애플리케이션 쓰기 endpoint에 테스트 요청을 보낸다.

기대 결과:

- POST/PUT/PATCH/DELETE는 Origin Group Secondary로 자동 전환되지 않음
- GET으로 다시 접속하면 점검 페이지 확인

이 결과는 DR 실패가 아니라 점검 페이지 단계의 의도된 제한이다.

## 테스트 4: `2-emergency` 배포와 DB 복원

관리자 승인 후 실행한다.

```bash
terraform -chdir=codes/azure/2-emergency apply
```

최신 dump 복원 후 다음을 확인한다.

- schema/table
- 주요 row count
- 최근 데이터 시점
- 애플리케이션 연결

## 테스트 5: Azure 서비스 사전 검증

```bash
APPGW_IP=$(terraform -chdir=codes/azure/2-emergency output -raw appgw_public_ip)
curl -I "http://${APPGW_IP}/"
```

AKS Pod, Service, App Gateway backend health를 확인하고 테스트 데이터 쓰기·재조회를 수행한다.

## 테스트 6: 수동 전체 DR

```bash
./scripts/switch-to-azure.sh --approved --db-restored
```

기대 상태:

- Front Door: `azure_service`
- CloudFront: `azure_dr`
- CloudFront allowed methods: 7개
- 경로: `CloudFront → Front Door → App Gateway → AKS`

서비스 도메인에서 읽기, 쓰기, DB 재조회를 반복한다.

## 테스트 7: Failback

AWS 복구와 데이터 정합성 검증 후:

```bash
./scripts/switch-to-aws.sh --approved
```

기대 상태:

- CloudFront: `normal`
- Front Door: `maintenance`
- 정상 요청: AWS ALB
- AWS 재장애 GET/HEAD: Front Door HTTPS 점검 페이지

## 기록 항목

- 장애 주입 시각
- 점검 페이지 최초 확인 시각
- `2-emergency` 시작/완료 시각
- dump 시점과 복원 완료 시각
- Azure 서비스 검증 결과
- 수동 전환 승인자와 실행자
- CloudFront/Front Door 적용 완료 시각
- failback 승인과 데이터 정합성 결과

## 완료 체크리스트

- [ ] 정상 AWS 경로 검증
- [ ] 자동 HTTPS 점검 페이지 검증
- [ ] 쓰기 요청 제한 재현
- [ ] 최신 dump 복원
- [ ] Azure 읽기·쓰기 검증
- [ ] 수동 전체 DR 검증
- [ ] AWS failback 검증
- [ ] `1-always` 상시 유지 확인
