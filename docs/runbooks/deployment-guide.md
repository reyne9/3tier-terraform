# AWS 서비스 배포

`codes/aws/2. service`의 배포 순서입니다. 전체 의존 관계는 [처음부터 운영까지](end-to-end.md)를 참고하세요.

## 준비

Terraform 1.14+, AWS CLI, `kubectl`, Helm, `jq`, `curl`, `shasum`이 필요합니다. `codes/azure/1-always`의 Storage Account와 백업 컨테이너를 먼저 준비합니다. `terraform.tfvars.example`을 복사하고 계정·리전·DB 입력을 채우되 실제 비밀번호와 Storage key는 Git에 올리지 않습니다.

```bash
cd 'codes/aws/2. service'
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Terraform은 VPC, EKS 관리형 기본 노드, RDS, 백업 EC2, CloudFront 출발지 전용 ALB 보안 그룹, DB용 Secrets Manager secret과 WAS IRSA 역할을 만듭니다. `terraform.tfstate`에는 DB 비밀번호가 남으므로 암호화된 원격 state와 제한된 접근 권한을 사용하세요.

## 클러스터 구성

아래 스크립트는 Terraform output에서 클러스터·리전·역할을 읽습니다. AWS CLI 주체에는 EKS, IAM, CloudFormation, EC2, Helm 설치에 필요한 권한이 있어야 합니다.

```bash
bash scripts/install-lb-controller.sh
bash scripts/install-secrets-store.sh
bash scripts/install-karpenter.sh
bash scripts/install-metrics-server.sh
```

`install-secrets-store.sh`는 AWS Secrets Manager CSI provider 및 동기화 기능을 설치하고 `was/petclinic-was` ServiceAccount에 IRSA 역할을 연결합니다. `SecretProviderClass`가 DB JSON 값을 읽어 Pod 볼륨에 마운트하고 `db-credentials` Kubernetes Secret으로 동기화합니다. Pod가 마운트되지 않으면 동기화된 Secret도 생성되지 않습니다. 비밀번호를 수동으로 `kubectl create secret` 할 필요는 없습니다. 비밀번호를 교체한 뒤에는 WAS Pod를 재시작해야 환경 변수에 새 값이 반영됩니다.

`install-karpenter.sh`는 고정 버전의 공식 IAM/이벤트 CloudFormation 템플릿을 SHA-256으로 확인한 뒤 적용하고, 노드 IAM 역할·IRSA·Helm controller·NodePool/EC2NodeClass를 설정합니다. 기존 Web/WAS 관리형 노드는 Karpenter controller를 유지하는 기본 용량이고, HPA로 생긴 Pod가 스케줄되지 못할 때 Karpenter가 추가 노드를 생성합니다. HPA용 metrics-server도 설치해야 합니다.

## 앱과 트래픽

```bash
kubectl apply -k k8s-manifests
kubectl rollout status deployment/was-spring -n was --timeout=600s
kubectl rollout status deployment/web-nginx -n web --timeout=300s
kubectl get ingress web-ingress -n web
```

Ingress는 Terraform이 만든 `portfolio-cloudfront-origin` 보안 그룹을 ALB에 붙입니다. 인바운드 80은 AWS 관리형 CloudFront origin-facing prefix list만 허용합니다. 이 제어는 **CloudFront 서비스 전체의 출발지**를 허용하며, 이 저장소의 특정 distribution만 식별하지는 않습니다. 별도 distribution 차단이 필요하면 CloudFront custom origin header와 ALB listener 조건을 추가해야 합니다. Route 53의 직접 ALB health check는 이 제한과 양립하지 않아 사용하지 않습니다. ALB target health와 CloudFront 경로를 관측하세요.

ALB DNS가 준비되면 `codes/aws/1. route53`의 CloudFront Terraform을 적용합니다. Route 53은 CloudFront Alias이고 정상 경로는 `CloudFront → ALB → Web → WAS → RDS`입니다. Azure Front Door는 읽기 요청의 장애 시 점검 페이지 Origin입니다.

## 확인할 항목

새 환경에 배포했다면 ALB의 SG가 CloudFront prefix list만 허용하는지, CSI와 IRSA가 Secret을 읽는지, `kubectl top pods`가 동작하는지, 예약 POST가 DB에 저장되는지 확인합니다. Karpenter는 일부러 Pod 용량을 초과시키는 별도 시나리오에서 NodePool/NodeClaim을 확인해야 합니다. 이 저장소에는 새 통합본의 실제 클라우드 검증 기록이 없습니다.

설계 기준은 [Karpenter 설치 안내](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/), [AWS Secrets Manager CSI와 IRSA](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_ascp_irsa.html), [AWS Load Balancer Controller 보안 그룹](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/security_groups/)입니다.
