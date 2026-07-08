# 멀티클라우드 DR 프로젝트 면접 복습 자료

## 0. 프로젝트 한 줄 요약

AWS를 운영 서비스의 기본 환경으로 두고, 장애 발생 시 Azure에 점검 페이지를 먼저 제공한 뒤, 장기 장애로 판단되면 Azure 쪽에 AKS, Application Gateway, MySQL을 올려 전체 서비스를 복구하는 멀티클라우드 DR 구조를 Terraform으로 구성했다.

면접에서 너무 길게 말하지 말고, 먼저 이렇게 시작하면 된다.

> 운영 트래픽은 Route 53, CloudFront, ALB, EKS, RDS로 처리했고, 장애 시에는 CloudFront가 Azure Blob의 점검 페이지로 먼저 전환되도록 했습니다. 이후 장기 장애로 판단되면 Terraform의 emergency 구성을 적용해 Azure AKS, Application Gateway, Azure MySQL을 생성하고 백업 DB를 복구하는 방식으로 설계했습니다.

## 1. 전체 구조를 다시 기억하기

### 평상시 흐름

사용자 요청은 `Route 53 -> CloudFront -> AWS ALB -> EKS -> RDS MySQL` 순서로 이동한다.

- `Route 53`: 도메인 DNS
- `CloudFront`: CDN이자 장애 시 원본 전환 지점
- `AWS ALB`: EKS 내부 Web 계층으로 들어가는 L7 진입점
- `EKS`: Web/WAS 애플리케이션 실행
- `RDS MySQL`: 운영 DB

### 장애 시 흐름

장애 직후에는 전체 Azure 서비스를 바로 띄우지 않고, 먼저 사용자가 실패 화면을 보지 않도록 점검 페이지를 제공한다.

- 1단계: CloudFront가 AWS 원본 장애를 감지하고 Azure Blob 점검 페이지로 전환
- 2단계: 운영자가 장기 장애라고 판단하면 Azure emergency 리소스 생성
- 3단계: Azure MySQL에 DB 백업 복구
- 4단계: AKS에 Web/WAS 배포 후 Application Gateway를 통해 서비스 제공
- 5단계: AWS 정상화 후 데이터 동기화 및 원복

면접 포인트:

> 모든 것을 즉시 자동 복구하려고 한 것이 아니라, 사용자 안내와 전체 서비스 복구를 분리했습니다. 그래서 평상시 비용을 낮추면서도 장애 직후에는 통제된 안내를 제공하고, 장기 장애일 때만 고비용 복구 리소스를 생성하도록 했습니다.

## 2. 네트워크 기초

### VPC와 Subnet

VPC는 AWS 안에서 내가 직접 설계하는 사설 네트워크다. Subnet은 VPC 안을 용도별, 가용 영역별로 나눈 구역이다.

이 프로젝트에서는 대략 다음처럼 분리했다.

- Public Subnet: ALB처럼 외부 진입이 필요한 리소스
- Web Subnet: Nginx 또는 Web Pod
- WAS Subnet: Spring 같은 비즈니스 로직 Pod
- DB Subnet: RDS

면접 질문:

> 왜 Web, WAS, DB 서브넷을 나눴나요?

답변 골격:

> 계층별 접근 제어를 분리하기 위해서입니다. 외부 요청은 ALB와 Web 계층까지만 들어오고, WAS는 Web에서만 접근하게 하며, DB는 WAS에서만 접근하게 만들면 보안 그룹과 라우팅을 계층별로 관리할 수 있습니다. 또한 장애나 확장도 계층 단위로 생각할 수 있습니다.

### Public Subnet과 Private Subnet

Public Subnet은 인터넷 게이트웨이로 직접 라우팅되는 서브넷이다. Private Subnet은 외부에서 직접 접근하지 못하게 하고, 필요한 경우 NAT Gateway 등을 통해 외부로 나가는 통신만 허용한다.

면접 질문:

> EKS 노드는 Public Subnet에 둬야 하나요, Private Subnet에 둬야 하나요?

답변 골격:

> 운영 관점에서는 워커 노드를 Private Subnet에 두는 것이 일반적입니다. 외부 사용자는 ALB를 통해 들어오고, 노드는 직접 인터넷에 노출하지 않는 구조가 안전합니다. 다만 학습용이나 비용 제약이 있는 프로젝트에서는 구성 단순화를 위해 Public Subnet을 사용할 수도 있고, 그 경우 보안 그룹과 접근 CIDR 제한이 중요합니다.

## 3. EKS 면접 핵심

### EKS가 하는 일

EKS는 AWS가 관리해주는 Kubernetes Control Plane이다. 사용자는 워커 노드, 노드 그룹, Pod, Service, Ingress, 보안 그룹, IAM 연동 등을 설계한다.

구분해서 기억할 것:

- Control Plane: Kubernetes API Server, 스케줄러 등. AWS가 관리
- Worker Node: 실제 Pod가 실행되는 EC2 노드
- Pod: 컨테이너 실행 단위
- Service: Pod 앞에 붙는 내부 네트워크 추상화
- Ingress 또는 ALB Controller: HTTP 요청을 외부에서 내부 Service로 연결

### EKS 엔드포인트 설정

EKS 엔드포인트는 애플리케이션 접속 주소가 아니라, Kubernetes API Server에 접근하는 주소다. 즉 `kubectl`, 노드, 컨트롤러가 클러스터 제어 명령을 주고받는 통로다.

주요 설정:

- Public endpoint enabled: 인터넷에서 EKS API Server 엔드포인트 접근 가능
- Private endpoint enabled: VPC 내부에서 EKS API Server 접근 가능
- Public access CIDR: Public endpoint 접근을 허용할 IP 범위

면접 질문:

> EKS endpoint public access와 private access의 차이가 뭔가요?

답변 골격:

> Public access는 kubectl 같은 관리 트래픽이 인터넷을 통해 EKS API Server에 접근할 수 있게 하는 설정입니다. Private access는 VPC 내부에서 사설 네트워크로 API Server에 접근하게 하는 설정입니다. 보안이 중요한 운영 환경에서는 private access를 켜고 public access를 끄거나, public access를 특정 관리자 IP로 제한하는 방식이 안전합니다.

꼬리 질문:

> Public endpoint를 끄면 로컬 PC에서 kubectl을 어떻게 쓰나요?

답변 골격:

> 로컬에서 바로 접근할 수 없기 때문에 VPN, Direct Connect, Bastion, SSM Session Manager 같은 방식으로 VPC 내부에 들어간 뒤 kubectl을 실행해야 합니다. 또는 CI/CD runner를 VPC 내부에 두는 방식도 가능합니다.

꼬리 질문:

> EKS 엔드포인트를 private으로 하면 애플리케이션도 private이 되나요?

답변 골격:

> 아닙니다. EKS endpoint는 Kubernetes API Server 관리용 엔드포인트입니다. 애플리케이션의 외부 공개 여부는 ALB, Ingress, Service type, 보안 그룹, 서브넷 배치로 결정됩니다.

내 프로젝트에서 확인할 것:

- 실제 Terraform에서 `endpoint_public_access`가 true인지 false인지
- `endpoint_private_access`를 사용했는지
- public access CIDR를 전체 공개로 두었는지, 특정 IP로 제한했는지

면접 방어 표현:

> 프로젝트 당시에는 배포와 테스트 편의성을 우선해 public endpoint를 열어두는 구성을 사용했을 수 있습니다. 운영 기준으로는 public CIDR 제한 또는 private endpoint 중심 구성이 더 적절하다고 보고 있습니다.

## 4. ALB, Ingress, Service

### ALB의 역할

ALB는 HTTP/HTTPS 요청을 받아 Web 계층 또는 Kubernetes Service로 라우팅한다. L7 로드밸런서라서 path, host 기반 라우팅과 health check를 사용할 수 있다.

면접 질문:

> 왜 NLB가 아니라 ALB를 썼나요?

답변 골격:

> 이 프로젝트는 Web/WAS 기반 HTTP 서비스 구조라서 L7 라우팅과 상태 확인이 중요했습니다. ALB는 HTTP/HTTPS 요청을 path 또는 host 기준으로 분기할 수 있고, Kubernetes Ingress와 연동하기도 좋아서 선택했습니다. TCP 고성능이나 고정 IP가 핵심이면 NLB를 고려할 수 있습니다.

### Health Check

Health Check는 대상 서버나 Pod가 정상 응답하는지 주기적으로 확인하는 기능이다. 장애 감지와 트래픽 제외의 기준이 된다.

면접 질문:

> Health Check 경로는 어떻게 정하는 게 좋나요?

답변 골격:

> 단순히 포트가 열려 있는지만 보는 것보다, 애플리케이션이 실제로 정상 동작하는지 확인할 수 있는 `/health` 같은 경로를 두는 것이 좋습니다. 다만 DB까지 강하게 물고 들어가면 일시적인 DB 지연이 전체 장애로 판단될 수 있어서, readiness와 liveness의 목적을 나눠 설계하는 것이 좋습니다.

## 5. CloudFront와 장애 전환

### CloudFront의 역할

CloudFront는 CDN이지만, 이 프로젝트에서는 단순 캐시보다 장애 시 사용자에게 점검 페이지를 제공하는 진입점 역할이 중요했다.

면접 질문:

> 왜 장애 시 바로 Azure AKS로 보내지 않고 점검 페이지로 보냈나요?

답변 골격:

> 장기 장애인지 일시 장애인지 판단하기 전에 전체 복구 리소스를 자동으로 띄우면 비용과 운영 리스크가 커집니다. 그래서 장애 직후에는 점검 페이지로 사용자에게 통제된 안내를 제공하고, 운영자가 장기 장애라고 판단했을 때 Azure 전체 복구를 진행하도록 단계화했습니다.

꼬리 질문:

> 그러면 RTO가 길어지는 것 아닌가요?

답변 골격:

> 맞습니다. 이 구조는 무중단 Active-Active 구조가 아니라 비용을 고려한 Pilot Light 또는 Warm Standby에 가까운 구조입니다. 목표는 즉시 전체 서비스 복구가 아니라, 장애 직후 사용자 경험을 통제하고 장기 장애 시 복구 가능한 경로를 확보하는 것이었습니다.

## 6. RDS와 DB 복구

### RDS Multi-AZ

RDS Multi-AZ는 동일 리전 안의 다른 가용 영역에 대기 DB를 두고 장애 시 자동 장애 조치를 제공하는 구조다.

면접 질문:

> RDS Multi-AZ와 Read Replica의 차이는?

답변 골격:

> Multi-AZ는 고가용성을 위한 대기 DB 구성이고, 일반적으로 애플리케이션이 직접 읽기 트래픽을 보내는 용도가 아닙니다. Read Replica는 읽기 부하 분산이나 리전 간 복제에 사용할 수 있지만, 장애 조치나 데이터 정합성 특성이 Multi-AZ와 다릅니다.

### Azure로 DB 백업을 옮긴 이유

AWS 리전 장애를 가정하면 AWS 안에만 백업이 있으면 복구 경로가 막힐 수 있다. 그래서 Azure Blob에 DB 백업을 보관하고, 장기 장애 시 Azure MySQL로 복구하는 흐름을 설계했다.

면접 질문:

> 실시간 복제가 아니라 백업 복구 방식을 쓴 이유는?

답변 골격:

> 실시간 복제는 RPO를 줄일 수 있지만 구성 복잡도와 비용이 올라갑니다. 이 프로젝트는 비용을 낮춘 DR 실습이 목적이었기 때문에, 주기적 백업과 수동 복구를 통해 복구 경로를 검증하는 데 초점을 맞췄습니다. 운영 수준이라면 DMS, CDC, 이중화 DB 전략을 더 검토해야 합니다.

## 7. Azure DR 구성

### 1-always와 2-emergency

이 프로젝트의 중요한 설계는 Azure 리소스를 두 단계로 나눈 것이다.

- `1-always`: 평상시에도 유지하는 저비용 리소스
- `2-emergency`: 장기 장애 시에만 생성하는 고비용 복구 리소스

`1-always` 예시:

- Resource Group
- VNet/Subnet
- Storage Account 또는 Blob
- Alert
- 점검 페이지
- 백업 저장소

`2-emergency` 예시:

- AKS
- Application Gateway
- Azure MySQL
- 복구용 Web/WAS 배포

면접 질문:

> 왜 모든 Azure 리소스를 평상시에 계속 켜두지 않았나요?

답변 골격:

> 비용 대비 효과를 고려했습니다. 점검 페이지와 백업 저장소처럼 장애 직후 바로 필요한 구성은 유지하고, AKS나 Application Gateway, DB처럼 비용이 큰 리소스는 장기 장애 판단 이후 생성하도록 분리했습니다.

### Azure AKS와 AWS EKS 비교

EKS와 AKS 모두 관리형 Kubernetes다. 기본 개념은 같지만, 네트워크와 IAM 연동 방식, 로드밸런서 연동 방식이 다르다.

면접 질문:

> EKS에서 AKS로 옮길 때 가장 신경 쓸 점은?

답변 골격:

> Kubernetes manifest 자체는 재사용할 수 있는 부분이 있지만, LoadBalancer, Ingress, IAM/Managed Identity, StorageClass, Network Plugin, 이미지 레지스트리 인증 같은 클라우드 의존 요소는 다시 맞춰야 합니다. 특히 DB endpoint, Secret, ConfigMap, 보안 그룹 또는 NSG에 해당하는 네트워크 정책을 확인해야 합니다.

## 8. Terraform 복습

### Terraform이 하는 일

Terraform은 클라우드 리소스를 코드로 정의하고 생성, 수정, 삭제하는 IaC 도구다.

핵심 개념:

- Provider: AWS, Azure 같은 클라우드 연결 플러그인
- Resource: 실제 생성할 리소스
- Variable: 환경별로 바뀌는 값
- Output: 생성 후 확인할 값
- State: 현재 인프라 상태 기록
- Module: 반복 가능한 구성 묶음

면접 질문:

> Terraform state가 왜 중요한가요?

답변 골격:

> Terraform은 state를 기준으로 실제 인프라와 코드의 차이를 계산합니다. state가 깨지거나 유출되면 리소스 관리와 보안에 문제가 생길 수 있습니다. 그래서 운영 환경에서는 로컬 state보다 S3, Azure Storage 같은 원격 backend와 lock을 사용하는 것이 좋습니다.

꼬리 질문:

> `terraform plan`과 `apply`의 차이는?

답변 골격:

> plan은 변경 예정 사항을 미리 보여주는 단계이고, apply는 실제 리소스를 변경하는 단계입니다. 특히 DR 리소스처럼 비용과 영향이 큰 리소스는 plan으로 생성/삭제 범위를 확인한 뒤 apply해야 합니다.

## 9. Kubernetes 기초 질문

### Pod와 Deployment

Pod는 컨테이너가 실행되는 최소 단위다. Deployment는 원하는 Pod 개수를 유지하고 롤링 업데이트를 관리한다.

면접 질문:

> Pod가 죽으면 어떻게 복구되나요?

답변 골격:

> Deployment나 ReplicaSet이 원하는 replica 수를 유지하려고 하기 때문에 Pod가 죽으면 새로운 Pod를 생성합니다. 단, 노드 장애나 이미지 pull 실패, readiness probe 실패 등 원인에 따라 복구 방식과 시간이 달라질 수 있습니다.

### Liveness Probe와 Readiness Probe

- Liveness Probe: 컨테이너가 살아 있는지 확인. 실패하면 재시작 대상
- Readiness Probe: 트래픽을 받을 준비가 됐는지 확인. 실패하면 Service endpoint에서 제외

면접 질문:

> liveness와 readiness를 왜 나누나요?

답변 골격:

> 살아는 있지만 아직 트래픽을 받으면 안 되는 상태가 있기 때문입니다. 예를 들어 애플리케이션 시작 중이거나 DB 연결 준비가 안 된 경우 readiness는 실패시켜 트래픽을 막고, liveness는 불필요한 재시작을 피하도록 별도로 설계합니다.

## 10. 보안 질문

### 보안 그룹

보안 그룹은 인스턴스나 로드밸런서 단위의 가상 방화벽이다. 인바운드와 아웃바운드 규칙으로 접근을 제한한다.

면접 질문:

> 3-Tier에서 보안 그룹을 어떻게 나눠야 하나요?

답변 골격:

> ALB는 80/443을 외부에서 받고, Web 계층은 ALB에서만 접근 허용합니다. WAS 계층은 Web 계층에서만 접근 허용하고, DB는 WAS 보안 그룹에서 오는 DB 포트만 허용합니다. 이렇게 계층별로 최소 권한 원칙을 적용합니다.

### Secret 관리

면접 질문:

> DB 비밀번호를 Terraform 코드에 직접 넣으면 어떤 문제가 있나요?

답변 골격:

> Git 이력, Terraform state, plan 로그 등에 비밀번호가 남을 수 있습니다. 이 레포에서는 하드코딩 값을 변수/환경변수 기반으로 정리했지만, 운영 환경에서는 Secrets Manager, SSM Parameter Store, Azure Key Vault, Kubernetes Secret 암호화, CI/CD secret 변수 등을 사용해야 합니다.

## 11. 자주 나올 꼬리 질문 모음

### 이 구조는 Active-Active인가요?

아니다. 이 프로젝트는 Active-Active보다는 Pilot Light 또는 수동 DR에 가깝다. AWS가 기본 운영 환경이고, Azure는 점검 페이지와 백업을 유지하다가 장기 장애 시 확장한다.

### RTO와 RPO를 어떻게 설명할까요?

- RTO: 장애 후 서비스를 복구하는 데 걸리는 목표 시간
- RPO: 장애 시점 기준으로 허용 가능한 데이터 손실량

이 프로젝트 답변:

> 점검 페이지 제공의 RTO는 짧게 가져가고, 전체 서비스 복구 RTO는 Terraform 배포와 DB 복구 시간에 영향을 받습니다. RPO는 백업 주기에 의존합니다.

### 가장 아쉬운 점은?

답변 골격:

> 실제 운영 수준의 자동 복제나 완전 자동 failover까지는 구현하지 못했습니다. 특히 DB 실시간 동기화, Secret 관리, private endpoint 중심의 접근 제어, 복구 리허설 자동화가 개선 포인트라고 생각합니다.

### 가장 많이 배운 점은?

답변 골격:

> 단순히 리소스를 많이 붙이는 것보다 장애 단계별로 무엇을 자동화하고 무엇을 운영 판단으로 남길지 정하는 것이 중요하다는 점을 배웠습니다. 또한 EKS/AKS 같은 Kubernetes 서비스는 비슷해 보여도 네트워크, 인증, 로드밸런서 연동에서 클라우드별 차이가 크다는 것을 경험했습니다.

## 12. 면접 전 확인 체크리스트

아래는 면접 전 실제 코드나 다이어그램을 보며 확인할 항목이다.

- EKS endpoint 설정: public/private, CIDR 제한 여부
- EKS 노드 그룹이 어느 서브넷에 배치됐는지
- ALB가 Public Subnet에 있는지
- Web/WAS Pod가 어떤 namespace와 Service로 나뉘었는지
- RDS가 Multi-AZ인지, subnet group은 어떻게 구성됐는지
- CloudFront 원본이 AWS ALB와 Azure Blob으로 어떻게 나뉘었는지
- Azure `1-always`에 어떤 리소스가 있고, `2-emergency`에 어떤 리소스가 있는지
- DB 백업 방식과 복구 절차
- Terraform state/backend 구성
- Secret이 코드에 노출된 부분이 있었는지, 개선 답변을 준비했는지

## 13. 1분 답변 템플릿

> 이 프로젝트는 AWS 기반 3-Tier 서비스를 Azure DR 환경으로 복구할 수 있게 설계한 멀티클라우드 인프라 프로젝트입니다. 평상시에는 Route 53, CloudFront, ALB, EKS, RDS MySQL로 서비스를 운영하고, 장애가 발생하면 CloudFront가 Azure Blob의 점검 페이지로 전환해 사용자에게 통제된 안내를 제공합니다. 이후 장기 장애로 판단되면 Terraform으로 Azure의 emergency 구성을 적용해 AKS, Application Gateway, Azure MySQL을 생성하고, 백업 DB를 복구해 전체 서비스를 재개하는 구조입니다. 핵심은 모든 복구를 즉시 자동화한 것이 아니라, 장애 직후 사용자 안내와 장기 장애 시 전체 복구를 분리해 비용과 운영 리스크를 조절했다는 점입니다.
