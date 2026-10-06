# 멀티클라우드 DR 프로젝트 실제 구현 상세 복습

기준 레포:

- `reynecat/3tier-terraform`
- 기준 커밋: `a705272` (`summary3`, 2026-01-13)
- 참고 커밋: `c259227` (`12fix3`, 2025-12-30) - Azure emergency 구성이 모듈화된 시점

이 문서는 면접에서 “실제로 어떻게 구성했나요?”라고 물었을 때 코드 기준으로 답하기 위한 자료다.

## 1. 전체 구조

운영 환경은 AWS, DR 환경은 Azure다.

AWS 운영 흐름:

`Route 53 -> CloudFront -> AWS ALB -> EKS Web Pod -> EKS WAS Pod -> RDS MySQL`

Azure DR 흐름:

`CloudFront 5xx GET/HEAD -> Front Door -> HTTPS Blob 점검 페이지 -> 운영자 승인 -> Terraform 2-emergency -> 최신 dump 복원·검증 -> Front Door AppGW backend 전환 -> CloudFront direct Front Door 전환`

핵심 설계:

- AWS는 실제 운영 서비스 담당
- Azure `1-always`는 네트워크, Storage, 점검 페이지와 Azure Front Door 담당
- Azure `2-emergency`는 장기 장애 시 생성하는 복구 리소스 담당
- 장애 직후 사용자 안내와 장기 장애 복구를 분리

## 2. AWS VPC와 Subnet

파일:

- `codes/aws/2. service/modules/vpc/main.tf`

구성:

- VPC: `var.vpc_cidr`
- Public Subnet: ALB/인터넷 진입용
- Web Subnet: EKS Web 노드 그룹
- WAS Subnet: EKS WAS 노드 그룹
- RDS Subnet: RDS MySQL
- Internet Gateway: Public Subnet 외부 통신
- NAT Gateway: Private Subnet의 아웃바운드 통신

중요 코드 포인트:

- Public Subnet은 `map_public_ip_on_launch = true`
- Web/WAS/RDS Subnet은 private 성격
- Web/WAS Subnet에는 Kubernetes용 태그가 들어감
- Private Route Table은 `0.0.0.0/0`을 NAT Gateway로 보냄

면접 답변:

> VPC 안에서 Public, Web, WAS, RDS 서브넷을 분리했습니다. 외부 진입점은 Public Subnet에 두고, 애플리케이션 계층과 DB 계층은 Private Subnet에 배치해 계층별 접근 제어가 가능하도록 구성했습니다. Private Subnet의 외부 패키지 다운로드나 이미지 pull 같은 아웃바운드 통신은 NAT Gateway를 통해 처리하는 구조입니다.

주의할 점:

- 다이어그램에서 ALB는 Public Subnet 진입점으로 설명하면 된다.
- Web/WAS는 논리적으로 노드 그룹과 namespace가 분리되어 있다.
- 실제 Ingress annotation은 `internet-facing` ALB를 생성하도록 되어 있다.

## 3. EKS 실제 설정

파일:

- `codes/aws/2. service/modules/eks/main.tf`

### 3.1 Cluster endpoint

실제 설정:

```hcl
vpc_config {
  subnet_ids              = concat(var.web_subnet_ids, var.was_subnet_ids)
  endpoint_private_access = true
  endpoint_public_access  = true
  public_access_cidrs     = ["0.0.0.0/0"]
}
```

해석:

- Private endpoint: 켜짐
- Public endpoint: 켜짐
- Public 접근 CIDR: 전체 공개

면접에서 솔직하게 말할 포인트:

> 프로젝트 당시에는 테스트와 로컬 `kubectl` 접근 편의 때문에 public endpoint를 열어두고 CIDR도 전체 허용으로 구성했습니다. 다만 운영 기준으로는 public access CIDR를 관리자 IP로 제한하거나, public endpoint를 끄고 VPN/SSM/Bastion/내부 CI runner를 통해 private endpoint로 접근하는 구성이 더 안전합니다.

자주 나오는 꼬리 질문:

> EKS endpoint는 서비스 접속 주소인가요?

답변:

> 아닙니다. EKS endpoint는 Kubernetes API Server 관리용 주소입니다. 사용자가 접속하는 애플리케이션 주소는 ALB/Ingress/Service로 결정됩니다.

### 3.2 EKS 노드 그룹

실제 설정:

- Web 노드 그룹: `aws_eks_node_group.web`
- WAS 노드 그룹: `aws_eks_node_group.was`
- Web 노드 그룹 subnet: `var.web_subnet_ids`
- WAS 노드 그룹 subnet: `var.was_subnet_ids`
- 노드 label:
  - Web: `tier = "web"`
  - WAS: `tier = "was"`

면접 답변:

> EKS 안에서 Web과 WAS를 namespace뿐 아니라 노드 그룹 단위로도 분리했습니다. Web 노드는 Web Subnet에, WAS 노드는 WAS Subnet에 배치하고 각각 `tier` label을 붙여 계층별 확장과 운영을 분리할 수 있게 했습니다.

주의할 점:

- 실제 manifest에는 `nodeSelector`가 보이지 않는다. 따라서 label은 있지만 Pod가 반드시 해당 노드 그룹에 스케줄링되도록 강제한 구성인지는 추가 확인이 필요하다.
- 면접에서는 “노드 그룹을 분리했다”는 표현은 가능하지만, “Pod 스케줄링을 nodeSelector로 강제했다”고 말하면 안 된다.

### 3.3 EKS Add-on

구성:

- `vpc-cni`
- `kube-proxy`
- `coredns`
- `amazon-cloudwatch-observability`

면접 답변:

> 기본 네트워킹과 DNS를 위한 VPC CNI, kube-proxy, CoreDNS add-on을 구성했고, 관측성을 위해 CloudWatch Observability add-on을 추가했습니다. 이를 통해 EKS 로그와 컨테이너 메트릭을 CloudWatch로 수집할 수 있게 했습니다.

## 4. Kubernetes Web/WAS 구성

파일:

- `codes/aws/2. service/k8s-manifests/`
- `codes/azure/2-emergency/k8s-manifests/`

### 4.1 Namespace

구성:

- `web`
- `was`

면접 답변:

> Kubernetes namespace를 Web과 WAS로 분리해 리소스와 서비스 경계를 나눴습니다. 운영 수준에서는 여기에 NetworkPolicy, ResourceQuota, RBAC까지 붙이면 더 명확한 격리가 가능합니다.

### 4.2 Web 계층

AWS/Azure 공통 Web 구성:

- Deployment: `web-nginx`
- Service: `web-service`
- Service type: `ClusterIP`
- Container port: 80
- Health path: `/health`
- Nginx가 WAS Service로 proxy:
  - `http://was-service.was.svc.cluster.local:8080`

면접 답변:

> Web 계층은 Nginx Pod로 구성했고, 외부 요청을 받아 WAS namespace의 `was-service`로 프록시하도록 했습니다. Kubernetes DNS를 사용해 `was-service.was.svc.cluster.local`로 WAS에 접근합니다.

### 4.3 WAS 계층

AWS WAS 구성:

- Deployment: `was-spring`
- Service: `was-service`
- Service type: `ClusterIP`
- Container port: 8080
- DB 접속 정보는 `db-credentials` Secret에서 주입
- startup/liveness/readiness probe 구성

Azure WAS 구성:

- Deployment 구조는 AWS와 유사
- `web-service`는 `LoadBalancer`(80), `was-service`는 `ClusterIP`(8080)
- App Gateway backend pool에는 Web LoadBalancer IP를 연결한다. 배포 스크립트가 IP를 조회해 Terraform에 전달한다.

면접 주의:

> Azure DR은 Application Gateway → Web LoadBalancer → WAS ClusterIP 경로로 설명합니다. 최초 Terraform apply에서 Gateway backend는 비어 있고, Web 배포 후 스크립트가 IP를 조회해 다시 적용합니다. 실제 클라우드 연결과 쓰기 검증은 별도로 확인해야 합니다.

## 5. AWS ALB와 Ingress

파일:

- `codes/aws/2. service/k8s-manifests/ingress/ingress.yaml`

중요 설정:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
alb.ingress.kubernetes.io/healthcheck-path: /health
alb.ingress.kubernetes.io/healthcheck-interval-seconds: '30'
alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '5'
ingressClassName: alb
```

해석:

- AWS Load Balancer Controller가 Ingress를 보고 ALB를 생성
- `internet-facing`이므로 외부 공개 ALB
- `target-type: ip`라서 Pod IP를 target으로 등록하는 방식
- Health Check는 `/health`

면접 답변:

> Ingress에 ALB annotation을 붙여 AWS Load Balancer Controller가 외부 ALB를 생성하게 했습니다. `target-type: ip`를 사용해 Pod IP를 직접 target으로 등록하고, `/health` 경로로 상태 확인을 수행하게 했습니다.

주의할 점:

- 인증서 ARN이 코드에 직접 들어가 있다. 면접에서는 운영 개선점으로 “변수화 또는 ACM data source/Secret 관리”를 말하면 좋다.
- listen port는 HTTP 80으로 되어 있다. CloudFront viewer 쪽은 HTTPS로 받고 origin에는 설정에 따라 HTTP/HTTPS가 섞일 수 있으므로 설명을 단순화해야 한다.

## 6. CloudFront, Route 53, Azure Front Door

파일:

- `codes/aws/1. route53/main.tf`

### 6.1 CloudFront Origin Group

실제 구성:

- Primary origin: AWS ALB
- Secondary origin: Azure Storage static website
- Failover status code: `500`, `502`, `503`, `504`
- Default cache behavior target: `multi-cloud-failover-group`
- Allowed methods: `GET`, `HEAD`, `OPTIONS`
- TTL: 0

면접 답변:

> CloudFront Origin Group에서 AWS ALB를 primary, 상시 배포된 Azure Front Door를 secondary로 두었습니다. ALB의 연결 실패 또는 5xx가 발생하면 GET/HEAD 요청이 Front Door를 거쳐 HTTPS Blob 점검 페이지로 전환됩니다.

중요한 한계:

> CloudFront의 allowed method가 `GET`, `HEAD`, `OPTIONS`라 정적 점검 페이지 전환에는 맞지만 전체 애플리케이션의 쓰기 요청 failover에는 제한이 있습니다. 전체 서비스 DR은 별도 Azure Front Door에서 Application Gateway Origin을 활성화하는 경로로 분리했습니다.

### 6.2 Route 53 Health Check

실제 구성:

- AWS ALB 직접 Health Check
- CloudFront end-to-end Health Check
- Azure Blob Health Check

면접 답변:

> Route 53 Health Check는 DNS failover의 직접 수단이라기보다 관측과 검증 목적으로 두었습니다. 실제 사용자 트래픽의 장애 전환은 CloudFront Origin Group이 담당하고, Route 53은 도메인을 CloudFront alias로 연결합니다.

### 6.3 Azure Front Door Origin Group

파일:

- `codes/azure/1-always/modules/frontdoor/main.tf`

실제 구성:

- maintenance mode: Azure Blob 활성, HTTPS 전달
- azure_service mode: Application Gateway 활성, HTTP 전달
- `azure_service`는 `azure_appgw_ip`가 필수
- Health probe: HTTP GET `/`, 30초
- Route: `/*`, HTTP/HTTPS, HTTPS redirect

면접 답변:

> Front Door는 CloudFront의 상시 Azure Origin입니다. 평상시에는 Blob 점검 페이지를 제공하고, 승인된 전체 DR에서는 Application Gateway backend로 바뀝니다. CloudFront는 normal mode에서 ALB/Front Door Origin Group을 사용하고, azure_dr mode에서는 쓰기 요청을 위해 Front Door를 직접 선택합니다.

## 7. RDS MySQL

파일:

- `codes/aws/2. service/modules/rds/main.tf`
- `codes/aws/2. service/main.tf`

실제 구성:

- Engine: MySQL 8.0
- Storage: gp3, encrypted
- Publicly accessible: false
- Multi-AZ: variable `var.rds_multi_az`
- Backup retention: 7 days
- Enhanced Monitoring: enabled
- CloudWatch logs: error/general/slowquery
- Security Group: EKS cluster security group에서 3306 허용

면접 답변:

> RDS는 private subnet에 두고 public access를 막았습니다. 보안 그룹은 EKS 쪽에서 오는 3306만 허용하도록 구성했습니다. Multi-AZ, 백업 보존, Enhanced Monitoring, slow query log export를 통해 운영 DB 가용성과 관측성을 확보하려 했습니다.

개선한 점:

- RDS master password는 하드코딩하지 않고 `var.db_password` sensitive 변수로 주입하도록 정리했다.
- 실제 운영 환경에서는 여기에 Secrets Manager, SSM Parameter Store, CI/CD secret, Terraform remote state 암호화까지 함께 적용하는 것이 좋다.

## 8. Azure 1-always

파일:

- `codes/azure/1-always/main.tf`

구성:

- Resource Group
- VNet
- Subnet:
  - `snet-appgw`
  - `snet-web`
  - `snet-was`
  - `snet-db`
- Storage Account
- MySQL backup container
- Static Website 점검 페이지
- Blob lifecycle policy
- Azure Front Door와 Origin Group

면접 답변:

> Azure에는 VNet, Subnet, Storage, 점검 페이지와 Front Door를 상시 유지했습니다. Front Door가 CloudFront의 고정 Azure Origin이 되어 장애 직후 HTTPS 점검 페이지를 제공하고, 전체 DR에서는 Application Gateway backend로 전환됩니다. 오래된 백업은 lifecycle policy로 삭제됩니다.

주의할 점:

- Storage Account의 `https_traffic_only_enabled = false`는 운영 보안 기준으로는 약점이다.
- 면접에서는 “테스트/정적 웹사이트 접근 편의 설정이었고 운영이면 HTTPS-only를 켜야 한다”고 답하면 좋다.

## 9. Azure 2-emergency

파일:

- `codes/azure/2-emergency/main.tf`
- `codes/azure/2-emergency/modules/aks/main.tf`
- `codes/azure/2-emergency/modules/db/main.tf`
- `codes/azure/2-emergency/modules/appgw/main.tf`

### 9.1 AKS

실제 구성:

- Cluster name: `aks-dr-${environment}`
- Kubernetes version: variable
- Web default node pool:
  - subnet: `snet-web`
  - zones: `1`, `2`
  - autoscaling enabled
  - label: `tier=web`
- WAS node pool:
  - subnet: `snet-was`
  - zones: `1`, `2`
  - autoscaling enabled
  - label: `tier=was`
- Network plugin: `azure`
- Network policy: `azure`
- Service CIDR: `10.240.0.0/16`
- DNS service IP: `10.240.0.10`
- Load balancer SKU: `standard`
- Identity: SystemAssigned
- OIDC issuer enabled

면접 답변:

> Azure DR 쪽 AKS도 Web/WAS 노드풀을 분리했습니다. Azure CNI와 Azure Network Policy를 사용하고, Service CIDR와 DNS IP를 명시해 클러스터 내부 네트워크 대역을 분리했습니다. 노드풀은 zone 1, 2에 분산하고 autoscaling을 켰습니다.

### 9.2 Azure MySQL

실제 구성:

- MySQL Flexible Server
- Version: 8.0.21
- Backup retention: 7 days
- Geo-redundant backup: false
- Zone: 1
- Database charset: utf8mb4
- `require_secure_transport = OFF`
- Firewall:
  - AKS outbound IP 대역으로 보이는 `4.230.0.0 ~ 4.230.255.255`
  - admin IP 선택 허용

면접 답변:

> Azure MySQL은 emergency 시 백업을 복구할 대상 DB로 만들었습니다. 비용을 고려해 HA나 geo-redundant backup은 끄고, 백업 보존과 기본 DB 생성 위주로 구성했습니다.

주의할 점:

- `require_secure_transport = OFF`는 운영 보안 기준으로 약점이다.
- AKS outbound IP 대역을 넓게 허용한 방화벽도 개선 필요.

방어 답변:

> DR 실습에서는 연결성 검증을 우선해 SSL 강제와 방화벽을 완화했습니다. 운영 수준이라면 private endpoint/private DNS, SSL required, 최소 IP 허용, Key Vault 연동으로 개선해야 합니다.

### 9.3 Application Gateway

실제 구성:

- Public IP: Standard, Static, zones 1/2
- SKU: Standard_v2, capacity 2
- Frontend port: 80
- Backend pool: `var.backend_ip_addresses`
- Backend setting: HTTP, `var.backend_port`
- Probe path: `var.health_probe_path`
- Unhealthy threshold: 3

면접 답변:

> Application Gateway는 Azure DR 서비스의 L7 진입점으로 구성했습니다. Public IP와 HTTP listener를 두고, backend pool에는 AKS 쪽 backend IP를 넣어 health probe를 통해 정상 backend로 라우팅하도록 했습니다.

중요한 한계:

> 현재 Terraform은 `backend_ip_addresses`를 변수로 요구합니다. AKS Service의 LoadBalancer IP가 생성된 뒤 App Gateway backend pool에 넣어야 하므로, 완전한 원샷 자동화보다는 apply, 서비스 배포, backend IP 확인, App Gateway 보정 흐름이 필요합니다. 면접에서는 이 부분을 “개선 포인트”로 설명하면 좋습니다.

## 10. DB 백업과 복구

관련 파일:

- `codes/aws/2. service/backup-instance.tf`
- `codes/aws/2. service/scripts/backup-init.sh`
- `codes/azure/2-emergency/scripts/restore-db.sh`

설명:

- AWS RDS의 데이터를 `mysqldump` 형태로 백업
- Azure Blob backup container에 보관
- 장애 시 Azure MySQL로 복구

면접 답변:

> 이 프로젝트에서는 실시간 DB 복제가 아니라 주기적 논리 백업과 수동 복구 방식을 사용했습니다. 비용과 구현 복잡도를 낮추는 대신 RPO는 백업 주기에 의존합니다. 운영 수준에서는 DMS/CDC 또는 DB 복제 전략을 추가로 고려해야 합니다.

## 11. 이 프로젝트에서 말하면 좋은 개선점

면접에서 단점을 묻는다면 아래 순서로 답하면 좋다.

1. Secret 관리

> 일부 비밀번호나 인증서 ARN이 코드에 직접 남은 부분이 있습니다. 운영에서는 Secrets Manager, SSM Parameter Store, Azure Key Vault, Terraform sensitive variable, remote backend 암호화를 사용해야 합니다.

2. EKS API endpoint 보안

> EKS public endpoint가 전체 CIDR에 열려 있습니다. 운영에서는 관리자 IP로 제한하거나 private endpoint 중심으로 구성해야 합니다.

3. Azure MySQL 보안

> SSL 강제 비활성화와 넓은 firewall rule은 운영 기준으로 개선해야 합니다. Private Endpoint, Private DNS, SSL required, 최소 IP 허용이 필요합니다.

4. App Gateway backend 자동화

> backend IP를 변수로 넣는 구조라 AKS Service IP 생성 이후 수동 보정이 필요합니다. Terraform data source, Kubernetes provider, AGIC, 또는 배포 스크립트 정교화로 자동화할 수 있습니다.

5. DR 리허설 자동화

> 실제 장애 시나리오별 runbook과 자동 검증 스크립트를 더 강화하면 RTO를 더 예측 가능하게 만들 수 있습니다.

## 12. 면접에서 절대 헷갈리면 안 되는 말

- “EKS endpoint”는 사용자 접속 주소가 아니다. Kubernetes API Server 관리 주소다.
- “CloudFront 장애 전환”은 전체 서비스 무중단 복구가 아니다. 우선 점검 페이지 전환이다.
- CloudFront Secondary/DR Origin은 Front Door다.
- Front Door는 maintenance mode에서 Blob, azure_service mode에서 Application Gateway를 활성화한다.
- 이 구조는 Active-Active가 아니다. Pilot Light/수동 DR에 가깝다.
- Web/WAS 노드 그룹 label은 있지만, 실제 Pod 스케줄링 강제 여부는 별도 확인이 필요하다.
- 포트폴리오/면접 설명은 Petclinic 기반 3-Tier DR로 통일한다.
