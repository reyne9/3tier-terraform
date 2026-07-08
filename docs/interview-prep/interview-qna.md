# 멀티클라우드 DR 프로젝트 면접 질문 답변 카드

## 1. 프로젝트 설명

### Q. 이 프로젝트를 한 문장으로 설명해보세요.

AWS 기반 3-Tier 서비스를 기본 운영 환경으로 두고, 장애 발생 시 Azure의 점검 페이지와 AKS 기반 복구 환경으로 전환할 수 있도록 Terraform으로 구성한 멀티클라우드 DR 프로젝트입니다.

### Q. 왜 멀티클라우드 DR을 구성했나요?

단일 클라우드 또는 단일 리전에 장애가 발생했을 때도 사용자에게 최소한의 안내와 복구 경로를 제공하기 위해서입니다. 특히 모든 리소스를 상시 이중화하면 비용이 크기 때문에, 평상시에는 저비용 리소스만 유지하고 장기 장애 시 복구 리소스를 생성하는 구조로 설계했습니다.

### Q. 이 구조는 Active-Active인가요?

아닙니다. Active-Active가 아니라 Pilot Light 또는 수동 DR에 가까운 구조입니다. AWS가 기본 운영 환경이고 Azure는 점검 페이지와 백업 저장소를 유지하다가, 장기 장애 시 AKS/App Gateway/MySQL을 생성해 복구합니다.

## 2. 장애 대응

### Q. 장애가 나면 어떤 순서로 동작하나요?

먼저 CloudFront가 AWS ALB 원본의 5xx 장애를 감지하면 Azure Blob의 점검 페이지로 전환합니다. 이후 운영자가 장기 장애라고 판단하면 Terraform `2-emergency` 구성을 적용해 Azure AKS, Application Gateway, Azure MySQL을 생성하고, DB 백업을 복구한 뒤 트래픽을 Azure 쪽으로 전환합니다.

### Q. 왜 바로 Azure AKS로 넘기지 않았나요?

장애가 일시적인지 장기적인지 판단하기 전에 전체 복구 리소스를 자동으로 띄우면 비용과 운영 리스크가 큽니다. 그래서 장애 직후에는 점검 페이지로 사용자 안내를 먼저 제공하고, 장기 장애로 판단될 때만 고비용 리소스를 생성하도록 단계를 나눴습니다.

### Q. RTO/RPO는 어떻게 설명할 수 있나요?

점검 페이지 전환 RTO는 CloudFront 장애 감지와 origin failover 시간에 가깝고, 전체 서비스 복구 RTO는 Terraform 배포, DB 복구, 애플리케이션 배포 시간에 영향을 받습니다. RPO는 실시간 복제가 아니라 백업 기반이기 때문에 백업 주기에 의존합니다.

## 3. EKS

### Q. EKS endpoint public/private access 차이를 설명해보세요.

EKS endpoint는 Kubernetes API Server에 접근하는 관리용 주소입니다. Public access는 인터넷에서 API Server에 접근할 수 있게 하는 설정이고, private access는 VPC 내부에서 사설망으로 접근하는 설정입니다. 운영 환경에서는 public access를 끄거나 관리자 IP로 제한하고 private access 중심으로 구성하는 것이 안전합니다.

### Q. 이 프로젝트의 EKS endpoint 설정은 어땠나요?

실제 코드에서는 `endpoint_private_access = true`, `endpoint_public_access = true`, `public_access_cidrs = ["0.0.0.0/0"]`였습니다. 테스트와 로컬 관리 편의성을 우선한 설정이고, 운영 기준으로는 public CIDR를 제한하거나 private endpoint 접근 방식으로 개선해야 합니다.

### Q. EKS endpoint를 private으로 하면 서비스도 외부에서 접근이 안 되나요?

아닙니다. EKS endpoint는 Kubernetes API Server 관리용입니다. 사용자 트래픽은 ALB, Ingress, Service, 보안 그룹, 서브넷 설정으로 결정됩니다.

### Q. EKS 노드 그룹은 어떻게 나눴나요?

Web 노드 그룹과 WAS 노드 그룹을 분리했습니다. Web 노드는 Web Subnet에, WAS 노드는 WAS Subnet에 배치했고 각각 `tier=web`, `tier=was` label을 붙였습니다. 다만 실제 Pod 스케줄링을 nodeSelector로 강제했는지는 별도 확인이 필요합니다.

### Q. EKS add-on은 무엇을 썼나요?

VPC CNI, kube-proxy, CoreDNS를 기본으로 구성했고, CloudWatch Observability add-on을 추가해 EKS 로그와 컨테이너 관측성을 확보하려 했습니다.

## 4. Kubernetes

### Q. Web/WAS는 Kubernetes에서 어떻게 분리했나요?

`web` namespace와 `was` namespace를 나눴고, Web은 Nginx Pod, WAS는 Spring Boot Pod로 구성했습니다. Web Nginx는 Kubernetes DNS인 `was-service.was.svc.cluster.local:8080`으로 WAS에 프록시합니다.

### Q. Service type은 어떻게 사용했나요?

AWS의 Web/WAS Service는 기본적으로 ClusterIP를 사용하고, 외부 진입은 Ingress와 ALB가 담당합니다. Azure DR 쪽은 App Gateway와 Ingress/Service 연결을 실험한 구조이며, 일부 WAS Service가 LoadBalancer인 흔적이 있어 backend IP를 보정하는 과정이 필요했습니다.

### Q. liveness/readiness/startup probe 차이는?

startup probe는 애플리케이션이 처음 뜨는 시간을 기다려주는 용도입니다. liveness probe는 컨테이너가 살아 있는지 확인해 재시작 여부를 판단합니다. readiness probe는 트래픽을 받을 준비가 되었는지 확인해 Service endpoint 포함 여부를 결정합니다.

## 5. ALB와 CloudFront

### Q. 왜 ALB를 사용했나요?

HTTP 기반 Web/WAS 서비스라 L7 라우팅과 health check가 중요했기 때문입니다. ALB는 Kubernetes Ingress와 연동하기 쉽고 path/host 기반 라우팅과 상태 확인을 지원합니다.

### Q. ALB Ingress에서 중요한 annotation은?

`alb.ingress.kubernetes.io/scheme: internet-facing`, `target-type: ip`, `listen-ports: HTTP 80`, `healthcheck-path: /health`, `ingressClassName: alb`가 핵심입니다. 이 설정으로 AWS Load Balancer Controller가 외부 ALB를 만들고 Pod IP를 target으로 등록합니다.

### Q. CloudFront origin failover는 어떻게 구성했나요?

CloudFront Origin Group을 사용했습니다. Primary origin은 AWS ALB, Secondary origin은 Azure Blob static website입니다. AWS origin에서 500, 502, 503, 504가 발생하면 secondary origin으로 전환해 점검 페이지를 제공합니다.

### Q. CloudFront allowed method가 GET/HEAD/OPTIONS면 어떤 한계가 있나요?

정적 점검 페이지 제공에는 적합하지만, 장기 장애 시 전체 애플리케이션의 POST/PUT/DELETE 같은 쓰기 요청까지 처리하기에는 부족합니다. Azure App Gateway로 전체 서비스 전환을 하려면 cache behavior와 allowed method를 재검토해야 합니다.

## 6. Database

### Q. RDS는 어떻게 구성했나요?

RDS MySQL 8.0을 private subnet에 두고 public access를 비활성화했습니다. 보안 그룹은 EKS 쪽에서 오는 3306 접근만 허용했습니다. Multi-AZ, 7일 백업, Enhanced Monitoring, CloudWatch log export를 통해 가용성과 관측성을 고려했습니다.

### Q. RDS Multi-AZ와 Read Replica 차이는?

Multi-AZ는 고가용성을 위한 대기 DB 구성이고 장애 조치 목적입니다. Read Replica는 읽기 부하 분산이나 복제 용도이며, 읽기 트래픽을 보낼 수 있지만 장애 조치와 정합성 특성은 Multi-AZ와 다릅니다.

### Q. 왜 실시간 복제가 아니라 백업 복구를 썼나요?

비용과 구현 복잡도를 낮추기 위해 주기적 논리 백업과 수동 복구 방식을 사용했습니다. 이 방식은 RPO가 백업 주기에 의존한다는 한계가 있고, 운영 수준에서는 DMS/CDC/리전 간 복제 등을 검토해야 합니다.

## 7. Azure DR

### Q. `1-always`와 `2-emergency`를 왜 나눴나요?

평상시에 꼭 필요한 저비용 리소스와 장애 시에만 필요한 고비용 리소스를 분리하기 위해서입니다. `1-always`는 VNet, Subnet, Storage, 점검 페이지, 백업 저장소를 유지하고, `2-emergency`는 AKS, Application Gateway, Azure MySQL을 장기 장애 시 생성합니다.

### Q. Azure AKS 네트워크 설정은?

Azure CNI와 Azure Network Policy를 사용했고, Service CIDR는 `10.240.0.0/16`, DNS service IP는 `10.240.0.10`으로 설정했습니다. Web/WAS 노드풀은 각각 다른 subnet에 배치했습니다.

### Q. Azure Application Gateway는 어떤 역할인가요?

Azure DR 환경의 L7 진입점입니다. Public IP와 HTTP listener를 두고 backend pool에 AKS 쪽 backend IP를 연결해 health probe 기반으로 라우팅합니다.

### Q. Azure Application Gateway 구성의 한계는?

Terraform에서 `backend_ip_addresses`를 변수로 받기 때문에 AKS Service LoadBalancer IP가 생성된 뒤 backend pool을 보정해야 합니다. 완전 자동화하려면 AGIC, Kubernetes provider, data source, 또는 배포 스크립트 개선이 필요합니다.

## 8. Terraform

### Q. Terraform state가 왜 중요한가요?

Terraform은 state를 기준으로 코드와 실제 인프라의 차이를 계산합니다. state가 손상되면 리소스 추적이 어렵고, 민감정보가 들어갈 수 있어 보안상 중요합니다. 운영에서는 원격 backend와 locking, 암호화를 사용해야 합니다.

### Q. `plan`과 `apply` 차이는?

`plan`은 변경 예정 사항을 확인하는 단계이고, `apply`는 실제 인프라를 변경하는 단계입니다. DR 리소스처럼 비용과 영향이 큰 리소스는 `plan`으로 범위를 확인한 뒤 적용해야 합니다.

### Q. Terraform으로 DR을 구성할 때 조심할 점은?

리소스 생성 순서와 의존성, state 관리, 민감정보 관리, 수동으로 바뀐 리소스와 코드의 drift를 조심해야 합니다. 특히 App Gateway backend IP처럼 실행 중 생성되는 값을 다시 참조해야 하는 경우 자동화 설계를 신중히 해야 합니다.

## 9. 보안과 개선점

### Q. 이 프로젝트에서 보안상 아쉬운 점은?

EKS public endpoint가 전체 CIDR에 열려 있고, Azure MySQL의 SSL 강제와 방화벽 설정이 운영 기준으로는 약합니다. DB 비밀번호는 코드 하드코딩 대신 변수/환경변수로 정리했지만, 운영 환경이라면 private endpoint, 최소 권한, secret manager, remote state 암호화, public CIDR 제한을 함께 적용해야 합니다.

### Q. DB 비밀번호를 코드에 넣으면 왜 문제인가요?

Git 이력, Terraform state, plan 출력, 로그에 비밀번호가 남을 수 있습니다. 운영에서는 Secrets Manager, SSM Parameter Store, Azure Key Vault, CI/CD secret, Kubernetes Secret 암호화 등을 사용해야 합니다.

### Q. 가장 크게 개선하고 싶은 부분은?

DB 실시간 복제 또는 CDC 기반 동기화, EKS endpoint 보안 강화, Azure MySQL private endpoint 구성, App Gateway backend 자동화, DR 리허설 자동화입니다. 이렇게 개선하면 RTO/RPO를 더 예측 가능하게 만들 수 있습니다.

## 10. 1분 답변

이 프로젝트는 AWS 기반 3-Tier 서비스를 Azure DR 환경으로 복구할 수 있게 설계한 멀티클라우드 인프라 프로젝트입니다. 평상시에는 Route 53, CloudFront, ALB, EKS, RDS MySQL로 서비스를 운영하고, 장애가 발생하면 CloudFront가 Azure Blob 점검 페이지로 전환해 사용자에게 통제된 안내를 제공합니다. 이후 장기 장애로 판단되면 Terraform `2-emergency` 구성을 적용해 Azure AKS, Application Gateway, Azure MySQL을 생성하고, 백업 DB를 복구해 서비스를 재개하는 구조입니다. 핵심은 모든 것을 상시 이중화한 것이 아니라, 장애 직후 안내와 장기 장애 복구를 분리해 비용과 운영 리스크를 조절했다는 점입니다.

## 11. 3분 답변

이 프로젝트는 AWS 운영 환경과 Azure DR 환경을 Terraform으로 구성한 멀티클라우드 재해복구 프로젝트입니다.

AWS 쪽은 VPC를 Public, Web, WAS, RDS subnet으로 나누고, EKS에는 Web/WAS 노드 그룹을 분리했습니다. 사용자는 Route 53과 CloudFront를 거쳐 AWS ALB로 들어오고, ALB Ingress가 Web namespace의 Nginx Service로 요청을 전달합니다. Nginx는 WAS namespace의 Spring Boot Service로 프록시하고, WAS는 RDS MySQL에 연결합니다.

장애 대응은 두 단계로 나눴습니다. 먼저 CloudFront Origin Group에서 AWS ALB를 primary origin, Azure Blob static website를 secondary origin으로 두어 5xx 장애 시 점검 페이지를 제공합니다. 이 단계는 사용자에게 실패 화면 대신 통제된 안내를 주기 위한 것입니다. 이후 운영자가 장기 장애라고 판단하면 Azure `2-emergency` Terraform을 적용해 AKS, Application Gateway, Azure MySQL을 만들고, Azure Blob에 보관된 DB 백업을 복구한 뒤 서비스를 Azure 쪽으로 전환합니다.

이 구조는 Active-Active가 아니라 비용을 고려한 Pilot Light/수동 DR에 가깝습니다. 그래서 RTO는 점검 페이지 전환과 전체 서비스 복구를 분리해서 봐야 하고, RPO는 백업 주기에 의존합니다. 개선점으로는 EKS public endpoint CIDR 제한, Secret 관리, Azure MySQL private endpoint/SSL 강화, App Gateway backend 자동화, DB 실시간 복제 또는 CDC 기반 동기화가 있습니다.
