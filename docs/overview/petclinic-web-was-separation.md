# PetClinic Web/WAS 분리 구현

이 문서는 현재 Kubernetes manifest를 기준으로 Web/WAS 분리를 설명한다.

## 구성

```text
External Edge
  -> ALB 또는 Application Gateway
  -> Web Service
  -> Nginx Pod
  -> was-service.was.svc.cluster.local:8080
  -> Spring Boot Pod
  -> MySQL
```

## Namespace

- `web`: Nginx
- `was`: Spring Boot

Namespace 분리는 리소스 이름과 정책 적용 범위를 분리하지만 그 자체로 network isolation을 강제하지 않는다. 현재 manifest에는 NetworkPolicy가 없다.

## AWS

### Web

- Deployment: `web-nginx`
- Service: `web-service`
- Service type: ClusterIP
- Service port: 80
- Ingress class: `alb`
- 외부 진입: AWS Load Balancer Controller가 Ingress에서 생성한 ALB

### WAS

- Deployment: `was-spring`
- Service: `was-service`
- Service type: ClusterIP
- Service port: 8080
- 외부 직접 노출 없음
- DB credential: `db-credentials` Secret

### 요청 흐름

```text
CloudFront
  -> AWS ALB
  -> web-service:80
  -> Nginx
  -> was-service.was.svc.cluster.local:8080
  -> Spring Boot
  -> RDS MySQL
```

## Azure DR

### Web

- Deployment: `web-nginx`
- Service: `web-service`
- Service type: ClusterIP
- Ingress class: `azure-application-gateway`

### WAS

- Deployment: `was-spring`
- Service: `was-service`
- Service type: LoadBalancer
- Service port: 8080

Application Gateway backend는 현재 WAS LoadBalancer IP를 사용한다. Web Ingress manifest도 존재하지만 Terraform에 AGIC 설치가 없으므로 Ingress만으로 Application Gateway가 자동 구성된다고 단정하지 않는다.

### 요청 흐름

현재 실행 절차 기준:

```text
Azure Front Door
  -> Application Gateway
  -> WAS LoadBalancer backend
  -> Spring Boot
  -> Azure MySQL
```

Web Nginx를 반드시 거치는 구조로 설명하려면 AGIC 또는 Application Gateway backend가 Web Service/Ingress를 가리키도록 코드가 정리되어야 한다.

## Web/WAS 분리 방식

### 논리 분리

- Namespace 분리
- Deployment/Service 분리
- Image 분리
- Nginx reverse proxy와 Spring Boot 역할 분리

### 노드 계층 분리

EKS와 AKS Terraform은 Web/WAS node pool과 `tier=web`, `tier=was` label을 만든다.

현재 Web/WAS Deployment manifest에는 `nodeSelector`, node affinity, taint/toleration이 없다. 따라서 Pod가 해당 node pool에 강제로 배치된다고 설명하면 안 된다.

강제하려면 예를 들어 다음 설정이 필요하다.

```yaml
spec:
  template:
    spec:
      nodeSelector:
        tier: web
```

WAS는 `tier: was`를 사용한다.

## Probe

Web과 WAS Deployment에는 liveness/readiness probe가 있고 WAS에는 startup probe도 있다. Probe 경로가 실제 image와 애플리케이션 endpoint에서 200을 반환하는지 배포 전에 확인한다.

```bash
kubectl describe pod -n web <pod-name>
kubectl describe pod -n was <pod-name>
```

## Service discovery

Nginx는 Kubernetes DNS를 사용한다.

```text
was-service.was.svc.cluster.local:8080
```

확인:

```bash
kubectl get svc -n was was-service
kubectl get endpoints -n was was-service

kubectl exec -n web deploy/web-nginx -- \
  getent hosts was-service.was.svc.cluster.local
```

## DB 연결

WAS는 Secrets Store CSI가 AWS Secrets Manager에서 동기화한 `db-credentials` Secret을 사용한다. Azure DR에서는 AKS Key Vault CSI가 동일한 이름으로 동기화한다.

검증:

```bash
kubectl get secret -n was db-credentials
kubectl logs -n was -l app=was-spring --tail=100
```

Secret 값을 문서나 로그에 평문으로 남기지 않는다.

## 현재 구현의 핵심 차이

| 항목 | AWS | Azure |
|---|---|---|
| Web Service | ClusterIP | ClusterIP |
| WAS Service | ClusterIP | LoadBalancer |
| 외부 L7 | ALB Ingress | Application Gateway |
| Edge | CloudFront | CloudFront → Front Door |
| Database | RDS MySQL | Azure MySQL |

## 개선점

- Web/WAS Deployment에 nodeSelector 또는 affinity 추가
- Namespace 간 NetworkPolicy 추가
- Azure 진입 경로를 Web Ingress 또는 WAS LoadBalancer 중 하나로 통일
- AGIC를 사용할 경우 설치와 identity를 Terraform으로 관리
- Secret Manager/Key Vault 연동
- Probe 경로와 애플리케이션 health endpoint 통일
