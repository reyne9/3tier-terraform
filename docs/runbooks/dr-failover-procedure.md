# DR Failover 절차

이 절차는 자동 점검 페이지와 승인된 전체 Azure DR을 분리한다.

## 1. 정상 상태

```text
Route 53 -> CloudFront -> AWS ALB -> EKS -> RDS
```

확인:

```bash
terraform -chdir="codes/aws/1. route53" output -raw traffic_mode
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
```

기대값:

- CloudFront: `normal`
- Front Door: `maintenance`

## 2. AWS 장애 직후

CloudFront Origin Group이 AWS ALB 연결 실패 또는 `500/502/503/504` 응답을 감지하면 `GET/HEAD` 요청을 Front Door로 보낸다.

```text
User -> HTTPS CloudFront -> HTTPS Front Door -> HTTPS Blob 점검 페이지
```

Route 53와 CloudFront 설정을 수동으로 바꾸지 않는다. 점검 페이지는 입력 기능이 없는 읽기 전용이다.

검증:

```bash
AFD_ENDPOINT=$(terraform -chdir=codes/azure/1-always output -raw frontdoor_endpoint)
curl -I "https://${AFD_ENDPOINT}/"
curl -I "https://<service-domain>/"
```

주의:

- 일반 페이지 재접속은 GET이므로 자동 전환된다.
- 장애 순간 처리 중인 POST/PUT/PATCH/DELETE는 자동 failover하지 않는다.

## 3. 전체 DR 전환 결정

관리자는 다음을 검토하고 회의에서 전환을 승인한다.

- AWS 장애 범위와 예상 복구 시간
- 최신 dump 생성 시점과 예상 RPO
- Azure 리소스 배포 비용
- 데이터 복원 및 정합성 검증 책임자
- failback 조건

승인 전에는 `traffic_mode = "azure_dr"`로 변경하지 않는다.

## 4. Azure `2-emergency` 배포

```bash
cd codes/azure/2-emergency
terraform init
terraform validate
terraform plan
terraform apply
```

생성 대상:

- Azure MySQL
- AKS Web/WAS node pool
- Application Gateway

## 5. 최신 dump 복원

Storage Container에서 최신 dump를 선택하고 Azure MySQL에 복원한다. 파일명만 보고 선택하지 말고 생성 시각, 크기, 압축 무결성을 확인한다.

복원 후 확인:

- schema와 table 존재
- 주요 row count
- 최근 데이터 시점
- 애플리케이션 계정 연결
- 문자셋과 timezone

## 6. AKS와 Application Gateway 검증

```bash
az aks get-credentials \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw aks_cluster_name)"

kubectl get nodes
kubectl get pods -A
kubectl get svc -A
```

WAS LoadBalancer IP를 Application Gateway backend에 반영한 뒤 backend health를 확인한다.

```bash
APPGW_IP=$(terraform output -raw appgw_public_ip)
curl -I "http://${APPGW_IP}/"
```

점검 항목:

- 읽기 화면
- 로그인 또는 세션 기능
- 쓰기 요청
- DB 반영
- 재조회 정합성

## 7. 수동 전체 Azure DR 전환

승인과 DB 복원·검증을 명시적으로 확인하는 스크립트를 사용한다.

```bash
cd <repository-root>
./scripts/switch-to-azure.sh --approved --db-restored
```

스크립트 순서:

1. Application Gateway 응답 확인
2. Front Door를 `azure_service`로 적용
3. Front Door HTTPS 응답 확인
4. CloudFront를 `azure_dr`로 적용

최종 경로:

```text
Route 53
  -> CloudFront
  -> Azure Front Door
  -> Application Gateway
  -> AKS
  -> Azure MySQL
```

## 8. 전체 DR 검증

```bash
terraform -chdir="codes/aws/1. route53" output -raw active_traffic_path
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
curl -I "https://<service-domain>/"
```

GET뿐 아니라 실제 쓰기 요청과 DB 재조회를 검증한다.

## 9. Failback

전제:

- AWS ALB/EKS/RDS 정상
- Azure에서 발생한 데이터 반영 계획 완료
- 데이터 정합성 검증 완료
- 운영자 승인 완료

```bash
./scripts/switch-to-aws.sh --approved
```

스크립트는 CloudFront를 먼저 normal mode로 되돌리고 Front Door를 maintenance mode로 복귀시킨다.

## 10. Azure 긴급 계층 정리

`2-emergency` 삭제는 별도 승인 후 수행한다.

```bash
terraform -chdir=codes/azure/2-emergency destroy
```

`1-always`의 Storage, 네트워크, 점검 페이지, Front Door는 유지한다.

## 체크리스트

- [ ] Front Door 점검 페이지를 장애 전에 HTTPS로 검증했다.
- [ ] AWS 장애 시 GET/HEAD가 자동으로 점검 페이지로 전환됐다.
- [ ] 쓰기 요청 자동 failover 제한을 기록했다.
- [ ] 전체 DR 전환을 회의에서 승인했다.
- [ ] `2-emergency` 배포 후 최신 dump를 복원했다.
- [ ] App Gateway/AKS 읽기·쓰기를 검증했다.
- [ ] Front Door와 CloudFront를 순서대로 수동 전환했다.
- [ ] Failback 전에 데이터 정합성을 검증했다.
- [ ] `1-always`를 삭제하지 않았다.
