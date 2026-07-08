# Azure 2-emergency 인프라 상세 설명

**디렉토리**: `/codes/azure/2-emergency/`

**목적**: AWS 장애 시 15분 내 전체 서비스 복구를 위한 Emergency DR 인프라

---

## 📋 개요

이 디렉토리는 **AWS Primary Site 장애 시에만 배포**되는 Azure DR 리소스를 구성합니다. 평상시에는 중지 상태(비용 $0)이며, 재해 발생 시 `terraform apply` 명령 한 번으로 전체 인프라를 15분 내에 배포합니다.

### DR 배포 리소스

1. **AKS (Azure Kubernetes Service)**: Web/WAS Pod 실행
2. **MySQL Flexible Server**: AWS RDS 백업에서 복원
3. **Application Gateway**: HTTP/HTTPS 로드 밸런서
4. **Public IP**: Application Gateway 외부 접근

---

## 🔑 핵심 설계 결정

### 1. DR 배포 시나리오

#### 전체 DR 플로우 (15분)

```
T+0분: AWS 장애 감지
┌──────────────────────────────────────────────────┐
│ AWS Primary Site (장애!)                          │
│ - EKS: X 응답 없음                                │
│ - RDS: X 접근 불가                                │
└──────────────────────────────────────────────────┘
           ↓ CloudFront 자동 Failover (즉시)
┌──────────────────────────────────────────────────┐
│ Azure Static Website (자동 전환)                  │
│ 점검 페이지: "서비스 점검 중입니다"                │
└──────────────────────────────────────────────────┘

T+1분: DR 배포 시작 (수동)
$ cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency
$ terraform apply -auto-approve

T+5분: MySQL 복원
┌──────────────────────────────────────────────────┐
│ MySQL Flexible Server 생성                        │
│ - Azure Blob Storage에서 최신 백업 다운로드        │
│ - mysql < backup.sql (데이터 복원)                │
└──────────────────────────────────────────────────┘

T+10분: AKS 클러스터 생성
┌──────────────────────────────────────────────────┐
│ AKS Cluster 배포                                  │
│ - 2 Node Pools (Web, WAS)                        │
│ - kubectl apply -f k8s-manifests/                │
│ - Pod 시작 (Web: 1개, WAS: 1개)                  │
└──────────────────────────────────────────────────┘

T+13분: Application Gateway 생성
┌──────────────────────────────────────────────────┐
│ Application Gateway 배포                          │
│ - Backend: WAS Service LoadBalancer IP           │
│ - Health Check: /actuator/health                 │
│ - Public IP 할당                                  │
└──────────────────────────────────────────────────┘

T+15분: CloudFront Origin 수동 전환
$ aws cloudfront update-distribution \
    --id E2OX3Z0XHNDUN \
    --origin-domain-name <appgw-public-ip>

T+20분: CloudFront 전파 완료
┌──────────────────────────────────────────────────┐
│ 서비스 복구 완료!                                  │
│ 사용자 → CloudFront → Azure AKS → MySQL          │
└──────────────────────────────────────────────────┘
```

---

### 2. AKS 구성 (Web/WAS 분리)

#### 선택: 2 Node Pools (Separate Web & WAS)

```hcl
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-dr-blue"
  location            = "koreacentral"
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-dr-blue"
  kubernetes_version  = "1.28"

  default_node_pool {
    name                = "web"
    node_count          = 1
    vm_size             = "Standard_D2s_v3"  # 2 vCPU, 8GB RAM
    vnet_subnet_id      = var.web_subnet_id
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 3

    node_labels = {
      tier = "web"
    }
  }

  # WAS Node Pool (별도 추가)
  # azurerm_kubernetes_cluster_node_pool 리소스로 생성
}

resource "azurerm_kubernetes_cluster_node_pool" "was" {
  name                  = "was"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D2s_v3"
  node_count            = 1
  vnet_subnet_id        = var.was_subnet_id
  enable_auto_scaling   = true
  min_count             = 1
  max_count             = 3

  node_labels = {
    tier = "was"
  }

  node_taints = [
    "tier=was:NoSchedule"
  ]
}
```

#### 왜 Web/WAS를 분리하는가?

**AWS EKS와 동일한 아키텍처 유지**

| 이유 | 설명 |
|------|------|
| **일관성** | AWS EKS도 Web/WAS 분리 → Azure도 동일하게 설계 |
| **리소스 격리** | WAS (CPU 높음) vs Web (CPU 낮음) 분리 |
| **독립 스케일링** | 트래픽 급증 시 Web만 증설 가능 |
| **보안 경계** | Web (DMZ) vs WAS (Internal) 네트워크 분리 |

**VM 크기: Standard_D2s_v3 선택 이유**

| VM 크기 | vCPU | RAM | 디스크 | 가격/시간 | 선택 |
|---------|------|-----|--------|----------|------|
| Standard_B2s | 2 | 4GB | 30GB | $0.042 | ❌ |
| **Standard_D2s_v3** ✅ | 2 | 8GB | 50GB | $0.104 | ✅ |
| Standard_D4s_v3 | 4 | 16GB | 100GB | $0.208 | ❌ |

**D2s_v3 선택 이유**:
- **8GB RAM**: Spring Boot WAS는 최소 4GB 필요 (JVM Heap 2GB + OS 1GB)
- **B 시리즈 부적합**: CPU Burst 크레딧 제한 (Production 부적합)
- **비용 효율**: D4s_v3는 과도 (DR 환경은 최소 리소스)

---

### 3. MySQL Flexible Server 구성

#### 선택: Burstable B1ms (Zone-Redundant HA)

```hcl
resource "azurerm_mysql_flexible_server" "main" {
  name                = "mysql-dr-blue"
  location            = "koreacentral"
  resource_group_name = var.resource_group_name

  sku_name = "B_Standard_B1ms"  # Burstable: 1 vCore, 2GB RAM
  version  = "8.0.21"

  storage {
    size_gb = 20
    iops    = 360  # Burstable: 기본 IOPS
  }

  high_availability {
    mode                      = "ZoneRedundant"  # HA 활성화
    standby_availability_zone = "2"              # 다른 AZ에 Standby
  }

  backup_retention_days = 7
  geo_redundant_backup_enabled = false  # GRS 불필요 (AWS에 원본)

  delegated_subnet_id = var.db_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id
}
```

#### 왜 Zone-Redundant HA인가?

**HA 옵션 비교**

| 모드 | Primary AZ | Standby AZ | Failover 시간 | 비용 | 선택 |
|------|-----------|-----------|--------------|------|------|
| **None** | 1개 | 없음 | 5-10분 (재생성) | $17/월 | ❌ |
| **Same Zone** | 1개 | 같은 AZ | 60-120초 | $34/월 | ❌ |
| **Zone-Redundant** ✅ | 1개 | 다른 AZ | 60-120초 | $34/월 | ✅ |

**Zone-Redundant 선택 이유**:

1. **데이터센터 장애 대응**
   ```
   Zone 1 (Primary) 장애 → Zone 2 (Standby) 자동 승격
   RTO: 60-120초 (자동 Failover)
   ```
   - Same Zone HA: Zone 전체 장애 시 모두 중단
   - None: 5-10분 재생성 시간 (DR 목표 위배)

2. **AWS RDS Multi-AZ와 일관성**
   - AWS: Multi-AZ (AZ-2a + AZ-2c)
   - Azure: Zone-Redundant (Zone 1 + Zone 2)
   - 동일한 HA 전략 유지

3. **비용 2배 vs 가용성**
   - HA 없음: $17/월
   - HA 활성화: $34/월 (2배)
   - **DR 환경은 장애 시에만 실행**: 월 평균 1일 실행 → 실제 비용 $1.13/일 × 1일 = $1.13

**B_Standard_B1ms (Burstable) 선택 이유**

| SKU Tier | vCore | RAM | 가격/시간 | 월 비용 (730h) | 선택 |
|----------|-------|-----|----------|---------------|------|
| **Burstable B1ms** ✅ | 1 | 2GB | $0.023 | $17 | ✅ |
| General Purpose D2ds_v4 | 2 | 8GB | $0.127 | $93 | ❌ |
| Memory Optimized E2ds_v4 | 2 | 16GB | $0.186 | $136 | ❌ |

**Burstable 선택 이유**:
- **DR 환경**: 트래픽 적음 (복구 직후 검증만)
- **CPU Burst**: 평균 20% 사용, Burst 시 100% 가능
- **비용 1/5**: General Purpose 대비 매우 저렴

---

### 4. Application Gateway 구성

#### 선택: Standard_v2 (Auto-scaling)

```hcl
resource "azurerm_application_gateway" "main" {
  name                = "appgw-blue"
  location            = "koreacentral"
  resource_group_name = var.resource_group_name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1  # 최소 인스턴스
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 3
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.appgw_subnet_id
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  backend_address_pool {
    name         = "was-backend-pool"
    ip_addresses = var.backend_ip_addresses  # WAS Service LoadBalancer IP
  }

  backend_http_settings {
    name                  = "http-settings"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "health-probe"
    pick_host_name_from_backend_address = false
  }

  probe {
    name                = "health-probe"
    protocol            = "Http"
    path                = "/actuator/health"  # Spring Boot Actuator
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    pick_host_name_from_backend_address = false
    host                = "127.0.0.1"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "was-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }
}
```

#### 왜 Application Gateway인가?

**Azure Load Balancer 옵션 비교**

| 옵션 | 계층 | 기능 | 가격/시간 | 선택 |
|------|------|------|----------|------|
| **Application Gateway** ✅ | L7 | HTTP/HTTPS, WAF, Auto-scaling | $0.07 | ✅ |
| Azure Load Balancer (Standard) | L4 | TCP/UDP, HA Ports | $0.025 | ❌ |
| Azure Front Door | L7 | Global LB, CDN | $0.06 (+ 데이터 비용) | ❌ |

**Application Gateway 선택 이유**:

1. **AWS ALB와 기능 동일**
   - AWS: Application Load Balancer (ALB)
   - Azure: Application Gateway
   - 둘 다 Layer 7 (HTTP/HTTPS) 로드 밸런서

2. **Health Check 기능**
   ```hcl
   probe {
     path = "/actuator/health"
     interval = 30
     unhealthy_threshold = 3
   }
   ```
   - Spring Boot Actuator 연동
   - Unhealthy Pod 자동 제외

3. **Auto-scaling**
   ```
   최소 1 인스턴스 (평상시)
   최대 3 인스턴스 (트래픽 급증 시)
   ```
   - Azure Load Balancer: Auto-scaling 없음

4. **WAF 추후 추가 가능**
   ```hcl
   sku {
     name = "WAF_v2"  # 업그레이드 가능
     tier = "WAF_v2"
   }
   ```
   - Standard_v2 → WAF_v2 전환 가능
   - SQL Injection, XSS 방어

**트레이드오프**:
- Azure Load Balancer 대비 3배 비용 ($0.025 vs $0.07)
- 하지만 L7 기능 (HTTP Health Check, Path Routing) 필수

---

### 5. Backend IP 동적 업데이트 문제

#### 문제: WAS LoadBalancer IP는 배포 후에만 알 수 있음

```
문제 상황:
1. terraform apply 실행
2. AKS 클러스터 생성 (10분)
3. kubectl apply -f was-deployment.yaml
4. WAS Service (LoadBalancer) 생성
5. Azure가 Public IP 할당 (1-2분)
6. 이 시점에 IP를 알 수 있음!

그런데...
Application Gateway는 AKS 배포 중에 생성됨
→ Backend IP를 모르는 상태에서 생성?
```

#### 해결 방법: 2단계 배포 + 자동화 스크립트

**방법 1: Terraform 2단계 배포**
```bash
# Step 1: AKS + MySQL 배포
terraform apply -target=module.aks -target=module.db

# WAS Service IP 확인 (kubectl 수동)
kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# 출력: 20.200.100.50

# Step 2: terraform.tfvars에 IP 입력
echo 'backend_ip_addresses = ["20.200.100.50"]' >> terraform.tfvars

# Step 3: Application Gateway 배포
terraform apply -target=module.appgw
```

**방법 2: 자동화 스크립트 (권장)**
```bash
#!/bin/bash
# scripts/deploy-complete.sh

set -e

echo "Step 1: Deploying AKS + MySQL..."
terraform apply -target=module.aks -target=module.db -auto-approve

echo "Step 2: Applying Kubernetes manifests..."
kubectl apply -f k8s-manifests/web/
kubectl apply -f k8s-manifests/was/

echo "Step 3: Waiting for WAS LoadBalancer IP..."
for i in {1..30}; do
  WAS_IP=$(kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$WAS_IP" ]; then
    echo "WAS LoadBalancer IP: $WAS_IP"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 10
done

if [ -z "$WAS_IP" ]; then
  echo "ERROR: WAS LoadBalancer IP not assigned after 5 minutes"
  exit 1
fi

echo "Step 4: Updating terraform.tfvars with Backend IP..."
sed -i "s/backend_ip_addresses = .*/backend_ip_addresses = [\"$WAS_IP\"]/" terraform.tfvars

echo "Step 5: Deploying Application Gateway..."
terraform apply -target=module.appgw -auto-approve

echo "Step 6: Getting Application Gateway Public IP..."
APPGW_IP=$(terraform output -raw appgw_public_ip)
echo "Application Gateway Public IP: $APPGW_IP"

echo ""
echo "========================================="
echo "DR Deployment Complete!"
echo "========================================="
echo "Application Gateway: http://$APPGW_IP"
echo ""
echo "Next Step: Update CloudFront Origin to $APPGW_IP"
```

**방법 3: Null Resource + Local Provisioner (고급)**
```hcl
resource "null_resource" "update_appgw_backend" {
  depends_on = [
    module.aks,
    kubernetes_service.was_service
  ]

  provisioner "local-exec" {
    command = <<-EOT
      WAS_IP=$(kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
      az network application-gateway address-pool update \
        --gateway-name appgw-blue \
        --resource-group rg-dr-blue \
        --name was-backend-pool \
        --servers $WAS_IP
    EOT
  }
}
```

---

### 6. Kubernetes Manifest 구성

#### Web Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-nginx
  namespace: web
spec:
  replicas: 1  # DR 환경: 최소 리소스
  selector:
    matchLabels:
      app: web
      tier: web
  template:
    metadata:
      labels:
        app: web
        tier: web
    spec:
      nodeSelector:
        tier: web  # Web Node Pool에만 배포
      containers:
        - name: nginx
          image: cloud039/petclinic-web:v1
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: web
spec:
  type: ClusterIP  # 내부용 (App Gateway → Web)
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
```

#### WAS Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-spring
  namespace: was
spec:
  replicas: 1  # DR 환경: 최소 리소스
  selector:
    matchLabels:
      app: was
      tier: was
  template:
    metadata:
      labels:
        app: was
        tier: was
    spec:
      nodeSelector:
        tier: was  # WAS Node Pool에만 배포
      tolerations:
        - key: tier
          operator: Equal
          value: was
          effect: NoSchedule
      containers:
        - name: spring-boot
          image: cloud039/petclinic-was:v3
          ports:
            - containerPort: 8080
          env:
            - name: SPRING_DATASOURCE_URL
              value: "jdbc:mysql://mysql-dr-blue.mysql.database.azure.com:3306/petclinic"
            - name: SPRING_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
          readinessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 20
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 1000m
              memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: was-service
  namespace: was
spec:
  type: LoadBalancer  # ⚠️ Azure Public IP 할당 (App Gateway Backend용)
  selector:
    app: was
  ports:
    - port: 8080
      targetPort: 8080
```

#### 왜 WAS Service는 LoadBalancer인가?

**Service Type 비교**

| Type | 외부 접근 | 비용 | App Gateway 연동 | 선택 |
|------|----------|------|-----------------|------|
| ClusterIP | 불가 | $0 | 불가능 | ❌ |
| **LoadBalancer** ✅ | 가능 | $0.005/시간 | 가능 (Public IP 사용) | ✅ |
| Ingress Controller | 가능 | $0 (App Gateway 사용) | 권장 방법 | △ |

**LoadBalancer 선택 이유**:
- **빠른 배포**: Ingress Controller 설치 불필요 (5분 절약)
- **간단한 구조**: WAS Service → App Gateway 직접 연결
- **DR 목적 달성**: 복잡한 Ingress 설정 불필요

**Ingress Controller (AGIC) 미사용 이유**:
```
Application Gateway Ingress Controller (AGIC):
- App Gateway를 Kubernetes Ingress로 관리
- Ingress 리소스 → App Gateway 자동 구성
- 장점: GitOps 방식 (Kubernetes Native)
- 단점:
  1. AGIC Pod 설치 필요 (2-3분)
  2. AAD Pod Identity 설정 (복잡)
  3. Ingress Class 설정
  4. DR 배포 시간 증가 (15분 → 20분)

결론: DR 긴급 상황에서는 단순함이 우선
```

---

## 💰 비용 분석

### DR 배포 시 시간당 비용

| 항목 | 스펙 | 가격/시간 | 8시간 DR | 24시간 DR |
|------|------|----------|---------|----------|
| **AKS Nodes** | D2s_v3 × 2 | $0.208 | $1.66 | $4.99 |
| **MySQL HA** | B1ms Zone-Redundant | $0.046 | $0.37 | $1.10 |
| **Application Gateway** | Standard_v2 (1 인스턴스) | $0.07 | $0.56 | $1.68 |
| **Public IP** | Standard | $0.005 | $0.04 | $0.12 |
| **Outbound 데이터** | 10GB | $0.09/GB | $0.90 | $0.90 |
| **합계** | | $0.33/시간 | **$3.53** | **$8.79** |

### 연간 DR 비용 시나리오

| 시나리오 | 발생 횟수 | 평균 시간 | 총 비용/년 |
|---------|----------|----------|-----------|
| **테스트 DR** | 월 1회 | 2시간 | $0.66 × 12 = $7.92 |
| **실제 장애** | 년 2회 | 8시간 | $3.53 × 2 = $7.06 |
| **장기 DR** | 년 1회 | 24시간 | $8.79 × 1 = $8.79 |
| **총 합계** | | | **$23.77/년** |

**총 DR 비용 (연간)**:
- Azure 1-always (상시): $2.4/년
- Azure 2-emergency (DR 시): $23.77/년
- **총 Azure 비용**: **$26.17/년**

vs. Warm Standby (상시 실행): $2640/년 (100배 차이!)

---

## 🚀 배포 절차

### 1. 수동 배포 (단계별)

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency/

# Step 1: AKS + MySQL 배포
terraform apply -target=module.aks -target=module.db

# Step 2: Kubernetes 설정
az aks get-credentials --resource-group rg-dr-blue --name aks-dr-blue

# Step 3: K8s Manifest 적용
kubectl apply -f k8s-manifests/

# Step 4: WAS Service IP 확인
kubectl get svc -n was was-service
# EXTERNAL-IP: 20.200.100.50

# Step 5: terraform.tfvars 업데이트
echo 'backend_ip_addresses = ["20.200.100.50"]' >> terraform.tfvars

# Step 6: Application Gateway 배포
terraform apply -target=module.appgw

# Step 7: CloudFront Origin 전환
APPGW_IP=$(terraform output -raw appgw_public_ip)
# CloudFront Console에서 Origin을 $APPGW_IP로 변경
```

### 2. 자동화 스크립트 (권장)

```bash
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency/
./scripts/deploy-complete.sh

# 스크립트가 자동으로:
# 1. AKS + MySQL 배포
# 2. Kubernetes Manifest 적용
# 3. WAS LoadBalancer IP 대기 및 확인
# 4. terraform.tfvars 자동 업데이트
# 5. Application Gateway 배포
# 6. 최종 Public IP 출력
```

---

## 🔧 운영 가이드

### MySQL 백업 복원

```bash
# 1. Azure Blob Storage에서 최신 백업 다운로드
az storage blob download \
  --account-name bloberry01 \
  --container-name backups \
  --name "petclinic-$(date +%Y%m%d).sql.gz" \
  --file backup.sql.gz

# 2. 압축 해제
gunzip backup.sql.gz

# 3. MySQL 복원
mysql -h mysql-dr-blue.mysql.database.azure.com \
      -u mysqladmin \
      -p \
      petclinic < backup.sql
```

### Application Gateway Backend 업데이트

```bash
# WAS Service IP 재확인
WAS_LB_IP=$(kubectl get svc -n was was-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Application Gateway Backend Pool 업데이트
az network application-gateway address-pool update \
  --gateway-name appgw-blue \
  --resource-group rg-dr-blue \
  --name was-backend-pool \
  --servers $WAS_LB_IP
```

### DR 종료 (비용 절감)

```bash
# 전체 인프라 삭제
cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency/
terraform destroy

# Kubernetes 리소스 먼저 삭제 (권장)
kubectl delete all --all -n web
kubectl delete all --all -n was
sleep 60

# Terraform Destroy
terraform destroy -auto-approve
```

---

## 📝 관련 문서

- **[AKS 가격 계산기](https://azure.microsoft.com/en-us/pricing/calculator/)**
- **[MySQL Flexible Server HA](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-high-availability)**
- **[Application Gateway 가격](https://azure.microsoft.com/en-us/pricing/details/application-gateway/)**
- **[DR 절차서](/docs/runbooks/dr-failover-procedure.md)**

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/azure/2-emergency/`
