# 트러블슈팅

이 문서는 현재 Terraform과 운영 시나리오를 기준으로 한다.

## 1. CloudFront에서 502가 발생한다

확인:

```bash
terraform -chdir="codes/aws/1. route53" output -json origin_failover_config
```

가능한 원인:

- ALB DNS 오류
- ALB target unhealthy
- CloudFront origin protocol과 ALB listener 불일치

현재 Ingress는 ALB HTTP 80 listener이므로 CloudFront ALB Origin도 `http-only`다.

## 2. AWS 장애인데 점검 페이지가 나오지 않는다

확인 순서:

1. CloudFront `traffic_mode`가 `normal`인지 확인
2. Origin Group Secondary가 `azure-frontdoor-dr`인지 확인
3. Front Door endpoint가 HTTPS로 응답하는지 확인
4. Front Door mode가 `maintenance`인지 확인
5. 요청 method가 GET/HEAD인지 확인

```bash
terraform -chdir="codes/aws/1. route53" output -raw traffic_mode
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
AFD_ENDPOINT=$(terraform -chdir=codes/azure/1-always output -raw frontdoor_endpoint)
curl -I "https://${AFD_ENDPOINT}/"
```

CloudFront는 연결 실패 또는 `500/502/503/504`에 대해 Secondary를 사용한다. 애플리케이션이 200 응답의 오류 화면을 반환하면 failover가 발생하지 않는다.

## 3. 장애 상태에서 POST/PUT이 실패한다

원인:

CloudFront Origin Failover는 GET, HEAD, OPTIONS에만 동작한다. 프로젝트 normal mode는 점검 페이지 용도이므로 GET/HEAD만 허용한다.

해결:

- 사용자는 GET 재접속으로 점검 페이지를 확인한다.
- 관리자는 승인, `2-emergency` 배포, 최신 dump 복원, 검증을 완료한다.
- CloudFront를 `traffic_mode = "azure_dr"`로 수동 전환한다.

## 4. Front Door 점검 페이지 HTTPS가 실패한다

Front Door는 Azure DR 경로에서 서비스 도메인의 HTTPS 접속 문제를 해결하기 위해 도입했다. `1-always`에 상시 배포해 장애 전에 관리형 TLS와 CloudFront Origin 경로를 검증한다.

확인:

- Front Door가 `1-always`에 배포됐는지
- `frontdoor_backend_mode = "maintenance"`인지
- Blob Origin이 활성인지
- Front Door route가 `HttpsOnly`인지
- Storage Account `https_traffic_only_enabled = true`인지

Blob endpoint 직접 검사:

```bash
terraform -chdir=codes/azure/1-always output -raw static_website_url
```

## 5. 전체 DR 스크립트가 실행을 거부한다

`switch-to-azure.sh`는 다음 두 확인을 모두 요구한다.

```bash
./scripts/switch-to-azure.sh --approved --db-restored
```

- `--approved`: 관리자 회의에서 전체 DR 승인
- `--db-restored`: 최신 dump 복원과 App Gateway/AKS 검증 완료

이는 점검 페이지 단계에서 검증되지 않은 Azure 서비스로 성급히 전환하는 것을 막는다.

## 6. Front Door `azure_service` apply가 실패한다

`azure_appgw_ip`가 비어 있으면 precondition이 실패한다.

```bash
terraform -chdir=codes/azure/2-emergency output -raw appgw_public_ip
```

해당 값을 `1-always`의 `azure_appgw_ip`에 반영한다.

## 7. Application Gateway 502

가능한 원인:

- `backend_ip_addresses`가 현재 WAS LoadBalancer IP와 다름
- health probe path/port 불일치
- AKS Service External IP 변경

```bash
WAS_LB_IP=$(kubectl get svc -n was was-service \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

az network application-gateway show-backend-health \
  --resource-group "<resource-group>" \
  --name "<appgw-name>"
```

Terraform 입력 또는 운영 스크립트에서 backend IP를 최신 값으로 갱신한다.

## 8. Azure MySQL 인증 실패

확인:

- Terraform `db_username`
- Kubernetes Secret username/password
- JDBC URL
- 복원 대상 database

현재 변수 validation은 Azure 관리자 계정을 `mysqladmin`으로 제한한다. Secret도 동일해야 한다.

## 9. 최신 dump 복원 후 데이터가 다르다

확인:

- 선택한 Blob의 생성 시각
- dump 압축 무결성
- schema와 table row count
- timezone/character set
- 복원 중 오류 로그
- 애플리케이션이 실제 Azure MySQL을 가리키는지

복원 성공 메시지만으로 전환하지 말고 쓰기·재조회까지 수행한다.

## 10. Terraform destroy가 dependency 오류로 실패한다

Security Group, ENI, Load Balancer 등 외부 생성 리소스의 의존성을 확인한다. Kubernetes LoadBalancer/Ingress가 만든 리소스를 먼저 정리하고 Terraform plan을 다시 확인한다.

`1-always`는 Front Door, Storage, 네트워크를 포함하므로 전체 DR 종료 시 삭제 대상이 아니다.

## 11. AWS Load Balancer Controller가 실행되지 않는다

증상:

- Controller Deployment가 `0/2` 상태다.
- Ingress를 생성해도 Controller가 처리하지 않는다.

확인:

- EKS OIDC Provider가 연결됐는지
- 전용 IAM Role의 trust policy가 OIDC와 일치하는지
- ServiceAccount annotation의 Role ARN이 올바른지
- Controller Pod 로그에 권한 오류가 있는지

해결:

OIDC, IAM Role, ServiceAccount를 IRSA로 연결하고 Controller Deployment를 재시작한다. 정상 기준은 Controller Pod 2개 Ready와 Ingress 이벤트 처리다.

## 12. Ingress를 생성했지만 ALB가 만들어지지 않는다

증상:

- `kubectl get ingress`의 `ADDRESS`가 계속 비어 있다.
- Controller 로그에 `no matching subnets`가 나타난다.

원인:

ALB가 사용할 두 개 이상의 Public Subnet에 `kubernetes.io/role/elb` 또는 cluster 식별 태그가 누락됐다.

해결:

Network Terraform에서 EKS용 Public Subnet 태그를 코드로 고정하고 Ingress를 다시 적용한다. `ADDRESS` 할당, ALB와 Target Group 생성, HTTP 200을 확인한다.

## 13. Failback 후 Azure로 계속 간다

확인:

```bash
terraform -chdir="codes/aws/1. route53" output -raw traffic_mode
terraform -chdir=codes/azure/1-always output -raw frontdoor_backend_mode
```

기대값:

- CloudFront `normal`
- Front Door `maintenance`

AWS가 아직 비정상이면 normal mode의 GET/HEAD는 다시 Front Door 점검 페이지로 갈 수 있다. ALB/EKS/RDS 상태를 먼저 복구한다.

## 주요 트러블슈팅 사례 요약

| 사례 | 원인 | 개선 |
|---|---|---|
| Azure 서비스 전환 후 정보 입력 실패 | Origin Failover method 제한 | 점검 페이지와 전체 DR 상태 분리 |
| Azure DR 서비스 HTTPS 접속 실패 | AppGW가 IP 기반 HTTP listener만 제공 | Front Door 관리형 TLS와 고정 HTTPS Edge 상시 배포 |
| CloudFront에서 ALB 연결 시 502 | Origin protocol과 ALB listener 불일치 | ALB HTTP 80에 맞춰 `http-only` 적용 |
| AWS Load Balancer Controller 설치 실패 | OIDC/IAM/ServiceAccount 연결 불일치 | IRSA 구성 순서와 의존성 명시 |
| Ingress ALB 미생성 | Public Subnet 태그 누락 | EKS용 Subnet 태그를 Terraform에 고정 |
| App Gateway 502 | stale WAS LoadBalancer IP | backend IP 재조회·health 검증 |
| Azure MySQL 인증 실패 | Secret과 관리자 계정 불일치 | `mysqladmin` validation과 Secret 정렬 |
| Terraform destroy 실패 | 외부 생성 네트워크 의존성 | 삭제 순서와 종속 리소스 점검 |
