#!/bin/bash
# Azure/2-emergency/scripts/deploy-petclinic.sh
# AKS에 Petclinic 3-tier 배포 (AWS와 동일한 구조)

set -e

echo "=========================================="
echo "Petclinic 3-Tier 배포 (AKS - DR Site)"
echo "시작 시간: $(date)"
echo "=========================================="

# Terraform outputs에서 정보 가져오기
cd ..
AKS_NAME=$(terraform output -raw aks_cluster_name)
RESOURCE_GROUP=$(terraform output -raw resource_group_name 2>/dev/null || echo "rg-dr-blue")
MYSQL_FQDN=$(terraform output -raw mysql_fqdn)

cd scripts

echo ""
echo "[1/7] kubectl 설정 확인..."
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

kubectl cluster-info

echo ""
echo "[2/7] Namespace 생성 (web, was)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    name: web
---
apiVersion: v1
kind: Namespace
metadata:
  name: was
  labels:
    name: was
EOF

echo ""
echo "[3/7] MySQL Secret 생성 (was namespace)..."
if [ -z "${DB_PASSWORD:-}" ]; then
  echo "Error: DB_PASSWORD 환경변수를 먼저 설정하세요."
  echo "예: export DB_PASSWORD='<azure-mysql-password>'"
  exit 1
fi

kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://${MYSQL_FQDN}:3306/petclinic?useSSL=true&requireSSL=false&serverTimezone=UTC" \
  --from-literal=username="mysqladmin" \
  --from-literal=password="${DB_PASSWORD}" \
  --namespace=was \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "[4/7] WAS Tier 배포 (Spring Boot Petclinic)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: was-config
  namespace: was
data:
  SPRING_PROFILES_ACTIVE: "mysql"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-spring
  namespace: was
  labels:
    app: was-spring
    tier: was
spec:
  replicas: 2
  selector:
    matchLabels:
      app: was-spring
      tier: was
  template:
    metadata:
      labels:
        app: was-spring
        tier: was
    spec:
      containers:
      - name: spring-boot
        image: springio/petclinic
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        env:
        - name: SPRING_PROFILES_ACTIVE
          valueFrom:
            configMapKeyRef:
              name: was-config
              key: SPRING_PROFILES_ACTIVE
        - name: SPRING_DATASOURCE_URL
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: url
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
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        startupProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 12
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 0
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 0
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
      terminationGracePeriodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: was-service
  namespace: was
  labels:
    app: was-spring
    tier: was
spec:
  type: ClusterIP
  selector:
    app: was-spring
    tier: was
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
  sessionAffinity: None
EOF

echo ""
echo "[5/7] WEB Tier 배포 (Nginx)..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: web
data:
  default.conf: |
    server {
        listen 80;
        server_name _;

        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass http://was-service.was.svc.cluster.local:8080;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-nginx
  namespace: web
  labels:
    app: web-nginx
    tier: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-nginx
      tier: web
  template:
    metadata:
      labels:
        app: web-nginx
        tier: web
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        imagePullPolicy: Always
        ports:
        - containerPort: 80
          name: http
          protocol: TCP
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
      terminationGracePeriodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: web
  labels:
    app: web-nginx
    tier: web
spec:
  type: ClusterIP
  selector:
    app: web-nginx
    tier: web
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  sessionAffinity: None
EOF

echo ""
echo "[6/7] Pod 시작 대기..."
echo "WAS Pod 대기 중..."
kubectl wait --for=condition=ready pod \
  -l app=was-spring \
  -n was \
  --timeout=300s

echo ""
echo "WEB Pod 대기 중..."
kubectl wait --for=condition=ready pod \
  -l app=web-nginx \
  -n web \
  --timeout=120s

echo ""
echo "[7/7] 배포 상태 확인..."
echo ""
echo "=== WAS Namespace ==="
kubectl get pods -n was
echo ""
kubectl get svc -n was
echo ""
echo "=== WEB Namespace ==="
kubectl get pods -n web
echo ""
kubectl get svc -n web

echo ""
echo "=========================================="
echo "Petclinic 3-Tier 배포 완료!"
echo "=========================================="
echo ""
echo "다음 단계:"
echo "  Application Gateway Ingress를 설정하려면:"
echo "     cd /home/ubuntu/3tier-terraform/codes/azure/2-emergency/scripts"
echo "     ./setup-ingress.sh"
echo ""
echo "  또는 빠른 테스트를 위해 LoadBalancer로 변경:"
echo "     kubectl patch svc web-service -n web -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"
echo ""
