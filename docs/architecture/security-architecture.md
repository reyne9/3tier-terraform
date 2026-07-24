# 현재 코드 기준 보안 아키텍처

이 문서는 구현된 보안 제어와 개선 항목을 구분한다. WAF, private endpoint, Key Vault처럼 코드에 없는 기능을 구현 완료로 표현하지 않는다.

## AWS 네트워크

### 계층 분리

- Public Subnet: ALB, NAT Gateway
- Web Subnet: EKS Web node
- WAS Subnet: EKS WAS node
- RDS Subnet: RDS MySQL

ALB는 internet-facing이고 80/443을 `0.0.0.0/0`에서 허용한다.

RDS:

- Private subnet group
- `publicly_accessible = false`
- 3306 ingress를 EKS cluster security group에서만 허용
- Storage encryption 활성
- CloudWatch error/general/slow query log export

### EKS 관리 endpoint

현재 구현:

```hcl
endpoint_private_access = true
endpoint_public_access  = true
public_access_cidrs     = ["0.0.0.0/0"]
```

이는 관리 편의를 위한 설정이며 운영 기준 개선 대상이다. 사용자 서비스의 외부 공개 여부와 EKS API endpoint 공개 여부는 별개다.

### IAM/OIDC

- EKS OIDC provider가 생성된다.
- AWS Load Balancer Controller 설치 스크립트는 IAM role과 ServiceAccount를 사용한다.
- RDS Enhanced Monitoring용 IAM role이 있다.

IRSA/OIDC는 특정 ServiceAccount에 최소 권한을 연결하는 용도로 설명한다. 모든 workload 권한이 최소화됐다고 단정하지 않는다.

## Edge와 TLS

### CloudFront

- Viewer protocol: HTTPS redirect
- TLS 최소 버전: `TLSv1.2_2021`
- ACM 인증서는 `us-east-1`에서 조회
- Origin protocol: HTTPS only

### Azure Front Door

- HTTP/HTTPS route
- HTTPS redirect 활성
- Custom domain 사용 시 managed certificate, TLS 1.2
- AWS ALB/Blob Origin은 certificate name check 활성
- Application Gateway Origin은 IP를 사용하므로 certificate name check 비활성

Front Door는 CloudFront의 상시 Azure Origin이다. maintenance mode에서는 Blob까지 HTTPS를 사용하고, azure_service mode에서는 현재 App Gateway HTTP listener에 맞춰 Front Door 이후 구간이 HTTP다.

## 데이터 보호

### AWS RDS

- gp3 encrypted storage
- 7일 backup retention
- Multi-AZ는 변수로 제어
- Public access 비활성

### Azure Storage

- Blob versioning 활성
- Backup lifecycle 적용
- 현재 `https_traffic_only_enabled = false`

### Azure MySQL

현재 구현:

- Public network 경로 사용
- `require_secure_transport = OFF`
- `4.230.0.0/16` firewall rule
- 관리자 IP 선택 허용
- 7일 backup retention

따라서 Azure MySQL private endpoint, private DNS, SSL 강제는 개선안이지 구현 완료 항목이 아니다.

## Secret 관리

Terraform variable에는 `sensitive = true`가 적용된 값이 있지만 값은 Terraform state에 남을 수 있다. Kubernetes Secret도 base64 encoding이지 암호화 저장을 자동 보장하지 않는다.

운영 개선:

- AWS Secrets Manager 또는 SSM Parameter Store
- Azure Key Vault
- Terraform remote backend encryption/locking
- CI/CD secret
- Kubernetes secret encryption at rest

## 구현되지 않은 보안 기능

다음 기능은 현재 `codes/`에서 확인되지 않으므로 구현 완료로 설명하지 않는다.

- AWS WAF Web ACL 연결
- Azure Front Door WAF policy
- Azure Application Gateway WAF_v2
- Azure MySQL private endpoint/private DNS
- Azure Front Door diagnostic setting
- CloudTrail/Activity Log를 프로젝트 코드에서 별도 생성하는 구성

## 우선 개선 순서

1. EKS public endpoint CIDR 제한
2. Azure MySQL SSL 강제와 허용 대역 축소
3. Storage HTTPS-only
4. Secret Manager/Key Vault 연동
5. Terraform remote state
6. Front Door/CloudFront WAF와 diagnostic log
7. Application Gateway backend 연결 자동화
