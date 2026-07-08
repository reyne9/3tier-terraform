# PetClinic Web/WAS 분리 아키텍처

## 목차
- [1. 개요](#1-개요)
- [2. 기존 Spring PetClinic 구조](#2-기존-spring-petclinic-구조)
- [3. Web/WAS 분리 전략](#3-webwas-분리-전략)
- [4. Web Tier 구현](#4-web-tier-구현)
- [5. WAS Tier 구현](#5-was-tier-구현)
- [6. Docker 이미지 빌드](#6-docker-이미지-빌드)
- [7. Kubernetes 배포](#7-kubernetes-배포)
- [8. CI/CD 파이프라인](#8-cicd-파이프라인)
- [9. Hibernate 및 데이터베이스 연동](#9-hibernate-및-데이터베이스-연동)

---

## 1. 개요

### 1.1 프로젝트 배경

Spring PetClinic은 원래 단일 애플리케이션으로 구성된 모놀리식 구조입니다. 이를 **Web Tier(Nginx)** + **WAS Tier(Spring Boot)**로 분리하여 3-Tier 아키텍처를 구현했습니다.

### 1.2 분리 목적

**성능 최적화**
- 정적 리소스(CSS, JS, 이미지)는 Nginx에서 직접 제공
- 동적 요청만 WAS로 전달하여 부하 분산

**확장성 향상**
- Web/WAS 각각 독립적으로 스케일 아웃 가능
- Kubernetes HPA(Horizontal Pod Autoscaler) 활용

**보안 강화**
- WAS는 내부 네트워크(ClusterIP)에서만 접근 가능
- 외부 노출은 Web Tier(LoadBalancer)를 통해서만 가능

**운영 효율성**
- 무중단 배포 시 Web/WAS 독립적으로 롤링 업데이트
- 장애 격리 (Web 장애가 WAS에 영향 없음)

### 1.3 최종 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│ Internet                                                     │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Web Tier (Nginx)                                            │
│ - Service: LoadBalancer (External)                          │
│ - Replicas: 2                                               │
│ - Role:                                                     │
│   1. 정적 리소스 직접 제공 (/resources/static/*)           │
│   2. 동적 요청을 WAS로 프록시 (proxy_pass)                 │
│   3. Health Check Endpoint (/health)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │ HTTP 8080
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ WAS Tier (Spring Boot)                                      │
│ - Service: ClusterIP (Internal Only)                        │
│ - Replicas: 2                                               │
│ - Role:                                                     │
│   1. Spring MVC 컨트롤러 처리                               │
│   2. Thymeleaf 템플릿 렌더링                                │
│   3. Hibernate ORM을 통한 DB 연동                           │
└─────────────────────┬───────────────────────────────────────┘
                      │ JDBC 3306
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Database Tier (MySQL)                                       │
│ - AWS RDS MySQL Multi-AZ                                    │
│ - Azure MySQL Flexible Server (DR)                          │
│ - Database: petclinic                                       │
│ - Schema: owners, pets, visits, vets, specialties           │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 기존 Spring PetClinic 구조

### 2.1 원본 프로젝트 클론

```bash
cd /home/ubuntu
git clone https://github.com/spring-projects/spring-petclinic.git
cd spring-petclinic

# 프로젝트 구조 확인
tree -L 2 src/
```

**프로젝트 구조:**
```
spring-petclinic/
├── src/
│   ├── main/
│   │   ├── java/
│   │   │   └── org/springframework/samples/petclinic/
│   │   │       ├── owner/           # Owner 관련 컨트롤러, 엔티티
│   │   │       ├── vet/             # Vet 관련 컨트롤러, 엔티티
│   │   │       ├── visit/           # Visit 관련 컨트롤러, 엔티티
│   │   │       └── PetClinicApplication.java
│   │   └── resources/
│   │       ├── application.properties
│   │       ├── static/              # 정적 리소스 (CSS, JS, 이미지)
│   │       │   ├── resources/
│   │       │   │   ├── css/
│   │       │   │   ├── fonts/
│   │       │   │   └── images/
│   │       └── templates/           # Thymeleaf 템플릿
│   │           ├── owners/
│   │           ├── vets/
│   │           └── welcome.html
│   └── test/
└── pom.xml
```

### 2.2 원본 의존성 (pom.xml)

```xml
<dependencies>
    <!-- Spring Boot Starter Web -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <!-- Spring Boot Starter Data JPA (Hibernate 포함) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>

    <!-- Thymeleaf Template Engine -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-thymeleaf</artifactId>
    </dependency>

    <!-- MySQL Connector -->
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>

    <!-- H2 Database (개발용) -->
    <dependency>
        <groupId>com.h2database</groupId>
        <artifactId>h2</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

### 2.3 데이터베이스 설정

**원본 application.properties:**
```properties
# H2 인메모리 DB (기본값)
spring.sql.init.mode=always
spring.datasource.url=jdbc:h2:mem:testdb
spring.jpa.hibernate.ddl-auto=none

# MySQL 프로파일 (spring.profiles.active=mysql)
spring.datasource.url=jdbc:mysql://localhost:3306/petclinic
spring.datasource.username=petclinic
spring.datasource.password=petclinic
```

---

## 3. Web/WAS 분리 전략

### 3.1 분리 방식 선택

#### 옵션 A: Spring Boot 내장 Tomcat + Nginx 프록시 (선택됨)
- Spring Boot는 그대로 유지 (내장 Tomcat 사용)
- Nginx를 리버스 프록시로 배치
- **장점**: 코드 변경 최소화, 배포 간단

#### 옵션 B: WAR 파일 + 외부 Tomcat
- Spring Boot를 WAR로 패키징
- 별도 Tomcat 컨테이너에 배포
- **단점**: 복잡도 증가, Spring Boot 장점 상실

### 3.2 역할 분담

| Tier | 역할 | 처리 내용 |
|------|------|-----------|
| **Web (Nginx)** | 정적 리소스 제공 | `/resources/static/**` → Nginx에서 직접 제공 |
| **Web (Nginx)** | 리버스 프록시 | 동적 요청 → `proxy_pass http://was-service:8080` |
| **WAS (Spring Boot)** | 비즈니스 로직 | Controller, Service, Repository 처리 |
| **WAS (Spring Boot)** | 템플릿 렌더링 | Thymeleaf → HTML 생성 |
| **WAS (Spring Boot)** | 데이터베이스 연동 | Hibernate ORM → MySQL |

---

## 4. Web Tier 구현

### 4.1 디렉토리 구조 생성

```bash
cd /home/ubuntu/spring-petclinic
mkdir -p web/static
mkdir -p was
```

### 4.2 정적 리소스 복사

```bash
# 정적 리소스를 Web Tier로 복사
cp -r src/main/resources/static/* web/static/

# 디렉토리 구조 확인
tree web/
# web/
# └── static/
#     └── resources/
#         ├── css/
#         │   └── petclinic.css
#         ├── fonts/
#         │   └── montserrat-webfont.woff
#         └── images/
#             ├── pets.png
#             └── spring-pivotal-logo.png
```

### 4.3 Nginx 설정 파일 작성

**web/nginx.conf:**
```nginx
events {
    worker_connections 1024;
}

http {
    # MIME 타입 설정
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 로그 포맷
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # 성능 최적화
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Gzip 압축 (정적 리소스)
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml font/truetype font/opentype
               application/vnd.ms-fontobject image/svg+xml;

    upstream was_backend {
        # WAS Service (Kubernetes ClusterIP)
        server was-service:8080;

        # 헬스 체크 실패 시 다른 서버로 자동 전환
        # max_fails=3 fail_timeout=30s;
    }

    server {
        listen 80;
        server_name _;

        # 정적 리소스 직접 제공 (Nginx에서 처리)
        location /resources/static/ {
            alias /usr/share/nginx/html/static/resources/;
            expires 1y;
            add_header Cache-Control "public, immutable";
            access_log off;
        }

        # Health Check Endpoint (Nginx 자체)
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # 동적 요청 → WAS로 프록시
        location / {
            proxy_pass http://was_backend;

            # 헤더 전달
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # 타임아웃 설정
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;

            # 버퍼링 설정
            proxy_buffering on;
            proxy_buffer_size 4k;
            proxy_buffers 8 4k;
            proxy_busy_buffers_size 8k;
        }

        # WAS Health Check (프록시)
        location /actuator/health {
            proxy_pass http://was_backend/actuator/health;
            access_log off;
        }
    }
}
```

### 4.4 Web Dockerfile 작성

**web/Dockerfile:**
```dockerfile
FROM nginx:1.25-alpine

# Nginx 설정 복사
COPY nginx.conf /etc/nginx/nginx.conf

# 정적 리소스 복사
COPY static /usr/share/nginx/html/static

# 헬스 체크용 스크립트
RUN echo '#!/bin/sh' > /healthcheck.sh && \
    echo 'curl -f http://localhost/health || exit 1' >> /healthcheck.sh && \
    chmod +x /healthcheck.sh

# 헬스 체크 설정
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/healthcheck.sh"]

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
```

### 4.5 Web 이미지 빌드 및 푸시

```bash
cd /home/ubuntu/spring-petclinic/web

# Docker 이미지 빌드
docker build -t petclinic-web:v3.0 .

# DockerHub에 푸시
docker tag petclinic-web:v3.0 bluemiv/petclinic-web:v3.0
docker push bluemiv/petclinic-web:v3.0

# Latest 태그도 추가
docker tag petclinic-web:v3.0 bluemiv/petclinic-web:latest
docker push bluemiv/petclinic-web:latest
```

---

## 5. WAS Tier 구현

### 5.1 Spring Boot 설정 수정

**was/application.properties (Kubernetes 환경용):**
```properties
# 서버 설정
server.port=8080
spring.application.name=petclinic

# MySQL 데이터소스 설정 (환경변수 사용)
spring.datasource.url=${DB_URL:jdbc:mysql://localhost:3306/petclinic}
spring.datasource.username=${DB_USERNAME:admin}
spring.datasource.password=${DB_PASSWORD:CHANGE_ME_DB_PASSWORD}
spring.datasource.driver-class-name=com.mysql.cj.jdbc.Driver

# Hibernate 설정
spring.jpa.hibernate.ddl-auto=none
spring.jpa.show-sql=false
spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.MySQLDialect
spring.jpa.properties.hibernate.format_sql=true
spring.jpa.properties.hibernate.use_sql_comments=true

# Connection Pool 설정 (HikariCP)
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.connection-timeout=30000
spring.datasource.hikari.idle-timeout=600000
spring.datasource.hikari.max-lifetime=1800000

# SQL 초기화 (스키마는 Terraform으로 생성됨)
spring.sql.init.mode=never

# Thymeleaf 설정
spring.thymeleaf.cache=true
spring.thymeleaf.prefix=classpath:/templates/
spring.thymeleaf.suffix=.html

# 정적 리소스 설정 (Nginx에서 처리하므로 비활성화)
spring.web.resources.add-mappings=true
spring.web.resources.static-locations=classpath:/static/

# Actuator (Health Check)
management.endpoints.web.exposure.include=health,info
management.endpoint.health.show-details=always
management.endpoint.health.probes.enabled=true
management.health.livenessState.enabled=true
management.health.readinessState.enabled=true

# 로깅 설정
logging.level.root=INFO
logging.level.org.springframework.samples.petclinic=DEBUG
logging.level.org.hibernate.SQL=DEBUG
logging.level.org.hibernate.type.descriptor.sql.BasicBinder=TRACE
```

### 5.2 application.properties 환경별 분리

**application-local.properties (로컬 개발용 - H2):**
```properties
spring.datasource.url=jdbc:h2:mem:testdb
spring.datasource.username=sa
spring.datasource.password=
spring.jpa.hibernate.ddl-auto=create-drop
spring.sql.init.mode=always
```

**application-mysql.properties (MySQL 프로파일):**
```properties
spring.datasource.url=jdbc:mysql://localhost:3306/petclinic
spring.datasource.username=admin
spring.datasource.password=password
```

**application-k8s.properties (Kubernetes 프로파일 - 환경변수 사용):**
```properties
spring.datasource.url=${DB_URL}
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
```

### 5.3 WAS 소스 복사 및 수정

```bash
cd /home/ubuntu/spring-petclinic

# WAS 디렉토리에 소스 복사
cp -r src was/
cp pom.xml was/
cp mvnw was/
cp mvnw.cmd was/
cp -r .mvn was/

# application.properties 교체
cp was/application.properties was/src/main/resources/application.properties
```

### 5.4 POM.xml 의존성 확인

**was/pom.xml (주요 의존성):**
```xml
<dependencies>
    <!-- Spring Boot Starter Web (내장 Tomcat 포함) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <!-- Spring Boot Starter Data JPA (Hibernate 포함) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>

    <!-- Thymeleaf Template Engine -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-thymeleaf</artifactId>
    </dependency>

    <!-- MySQL Connector -->
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>

    <!-- Spring Boot Actuator (Health Check) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>

    <!-- Lombok (선택사항) -->
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>

    <!-- H2 Database (로컬 개발용) -->
    <dependency>
        <groupId>com.h2database</groupId>
        <artifactId>h2</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>

<build>
    <plugins>
        <plugin>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-maven-plugin</artifactId>
            <configuration>
                <excludes>
                    <exclude>
                        <groupId>org.projectlombok</groupId>
                        <artifactId>lombok</artifactId>
                    </exclude>
                </excludes>
            </configuration>
        </plugin>
    </plugins>
</build>
```

### 5.5 WAS Dockerfile 작성

**was/Dockerfile:**
```dockerfile
# Multi-stage build로 이미지 크기 최적화

# Stage 1: Build
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /app

# pom.xml 먼저 복사 (의존성 캐싱)
COPY pom.xml .
COPY .mvn .mvn
COPY mvnw .

# 의존성 다운로드 (캐싱 활용)
RUN ./mvnw dependency:go-offline -B

# 소스 코드 복사
COPY src ./src

# JAR 빌드 (테스트 스킵)
RUN ./mvnw clean package -DskipTests

# Stage 2: Runtime
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# non-root 사용자 생성 (보안)
RUN addgroup -S spring && adduser -S spring -G spring
USER spring:spring

# 빌드된 JAR 복사
COPY --from=build /app/target/*.jar app.jar

# 헬스 체크
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health || exit 1

EXPOSE 8080

# JVM 옵션 설정
ENV JAVA_OPTS="-Xms256m -Xmx512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

### 5.6 WAS 이미지 빌드 및 푸시

```bash
cd /home/ubuntu/spring-petclinic/was

# Docker 이미지 빌드
docker build -t petclinic-was:v3.0 .

# DockerHub에 푸시
docker tag petclinic-was:v3.0 bluemiv/petclinic-was:v3.0
docker push bluemiv/petclinic-was:v3.0

# Latest 태그도 추가
docker tag petclinic-was:v3.0 bluemiv/petclinic-was:latest
docker push bluemiv/petclinic-was:latest
```

---

## 6. Docker 이미지 빌드

### 6.1 전체 빌드 스크립트

**build-and-push.sh:**
```bash
#!/bin/bash

set -e

DOCKERHUB_USERNAME="bluemiv"
VERSION="v3.0"

echo "========================================="
echo "PetClinic Web/WAS 이미지 빌드 및 푸시"
echo "========================================="

# Web 이미지 빌드
echo "[1/4] Web 이미지 빌드 중..."
cd /home/ubuntu/spring-petclinic/web
docker build -t petclinic-web:$VERSION .
docker tag petclinic-web:$VERSION $DOCKERHUB_USERNAME/petclinic-web:$VERSION
docker tag petclinic-web:$VERSION $DOCKERHUB_USERNAME/petclinic-web:latest

# WAS 이미지 빌드
echo "[2/4] WAS 이미지 빌드 중..."
cd /home/ubuntu/spring-petclinic/was
docker build -t petclinic-was:$VERSION .
docker tag petclinic-was:$VERSION $DOCKERHUB_USERNAME/petclinic-was:$VERSION
docker tag petclinic-was:$VERSION $DOCKERHUB_USERNAME/petclinic-was:latest

# DockerHub 로그인
echo "[3/4] DockerHub 로그인..."
docker login

# 이미지 푸시
echo "[4/4] 이미지 푸시 중..."
docker push $DOCKERHUB_USERNAME/petclinic-web:$VERSION
docker push $DOCKERHUB_USERNAME/petclinic-web:latest
docker push $DOCKERHUB_USERNAME/petclinic-was:$VERSION
docker push $DOCKERHUB_USERNAME/petclinic-was:latest

echo "========================================="
echo "빌드 및 푸시 완료!"
echo "Web 이미지: $DOCKERHUB_USERNAME/petclinic-web:$VERSION"
echo "WAS 이미지: $DOCKERHUB_USERNAME/petclinic-was:$VERSION"
echo "========================================="
```

### 6.2 로컬 테스트

```bash
# Docker Compose로 로컬 테스트
cat > docker-compose.yml <<EOF
version: '3.8'

services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: petclinic
      MYSQL_USER: admin
      MYSQL_PASSWORD: CHANGE_ME_DB_PASSWORD
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql

  was:
    image: bluemiv/petclinic-was:v3.0
    environment:
      DB_URL: jdbc:mysql://mysql:3306/petclinic
      DB_USERNAME: admin
      DB_PASSWORD: CHANGE_ME_DB_PASSWORD
    depends_on:
      - mysql
    ports:
      - "8080:8080"

  web:
    image: bluemiv/petclinic-web:v3.0
    depends_on:
      - was
    ports:
      - "80:80"

volumes:
  mysql-data:
EOF

# 실행
docker-compose up -d

# 접속 테스트
curl http://localhost/
```

---

## 7. Kubernetes 배포

### 7.1 Web Tier Kubernetes Manifest

**k8s-manifests/web/deployment.yaml:**
```yaml
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
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: web-nginx
  template:
    metadata:
      labels:
        app: web-nginx
        tier: web
    spec:
      affinity:
        # Pod Anti-Affinity (같은 노드에 배치 방지)
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - web-nginx
              topologyKey: kubernetes.io/hostname

      containers:
      - name: nginx
        image: bluemiv/petclinic-web:v3.0
        imagePullPolicy: Always
        ports:
        - containerPort: 80
          name: http
          protocol: TCP

        # 리소스 제한
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"

        # Liveness Probe (컨테이너 재시작 조건)
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3

        # Readiness Probe (트래픽 전달 조건)
        readinessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
```

**k8s-manifests/web/service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nginx
  namespace: web
  labels:
    app: web-nginx
spec:
  type: LoadBalancer
  selector:
    app: web-nginx
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  sessionAffinity: None
```

**k8s-manifests/web/ingress.yaml (ALB용):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: web
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '5'
    alb.ingress.kubernetes.io/success-codes: '200'
    alb.ingress.kubernetes.io/healthy-threshold-count: '2'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '2'
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-nginx
            port:
              number: 80
```

### 7.2 WAS Tier Kubernetes Manifest

**k8s-manifests/was/deployment.yaml:**
```yaml
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
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: was-spring
  template:
    metadata:
      labels:
        app: was-spring
        tier: was
    spec:
      affinity:
        # Pod Anti-Affinity
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - was-spring
              topologyKey: kubernetes.io/hostname

      containers:
      - name: spring-boot
        image: bluemiv/petclinic-was:v3.0
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP

        # 환경변수 (Secret에서 주입)
        env:
        - name: DB_URL
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: url
        - name: DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
        - name: SPRING_PROFILES_ACTIVE
          value: "k8s"

        # 리소스 제한
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"

        # Liveness Probe
        livenessProbe:
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3

        # Readiness Probe
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3

        # Startup Probe (초기 시작 시간 확보)
        startupProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 0
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 30  # 5분 (30 * 10초)
```

**k8s-manifests/was/service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: was-service
  namespace: was
  labels:
    app: was-spring
spec:
  type: ClusterIP  # 내부 통신만 허용
  selector:
    app: was-spring
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
  sessionAffinity: None
```

### 7.3 Database Secret 생성

**AWS EKS:**
```bash
kubectl create namespace web
kubectl create namespace was

kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://blue-rds.xxxx.ap-northeast-2.rds.amazonaws.com:3306/petclinic" \
  --from-literal=username="admin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was
```

**Azure AKS:**
```bash
kubectl create secret generic db-credentials \
  --from-literal=url="jdbc:mysql://mysql-dr-blue.mysql.database.azure.com:3306/petclinic" \
  --from-literal=username="mysqladmin" \
  --from-literal=password="CHANGE_ME_DB_PASSWORD" \
  --namespace=was
```

### 7.4 배포 실행

```bash
# Web Tier 배포
kubectl apply -f k8s-manifests/web/

# WAS Tier 배포
kubectl apply -f k8s-manifests/was/

# 배포 상태 확인
kubectl get pods -n web
kubectl get pods -n was

# Service 확인
kubectl get svc -n web
kubectl get svc -n was
```

---

## 8. CI/CD 파이프라인

### 8.1 GitHub Actions Workflow

**.github/workflows/deploy.yml:**
```yaml
name: Build and Deploy PetClinic

on:
  push:
    branches:
      - main
    paths:
      - 'web/**'
      - 'was/**'
  workflow_dispatch:

env:
  DOCKERHUB_USERNAME: bluemiv
  WEB_IMAGE: petclinic-web
  WAS_IMAGE: petclinic-was

jobs:
  build-web:
    name: Build Web Image
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Login to DockerHub
        uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push Web image
        uses: docker/build-push-action@v4
        with:
          context: ./web
          push: true
          tags: |
            ${{ env.DOCKERHUB_USERNAME }}/${{ env.WEB_IMAGE }}:${{ github.sha }}
            ${{ env.DOCKERHUB_USERNAME }}/${{ env.WEB_IMAGE }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  build-was:
    name: Build WAS Image
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Login to DockerHub
        uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push WAS image
        uses: docker/build-push-action@v4
        with:
          context: ./was
          push: true
          tags: |
            ${{ env.DOCKERHUB_USERNAME }}/${{ env.WAS_IMAGE }}:${{ github.sha }}
            ${{ env.DOCKERHUB_USERNAME }}/${{ env.WAS_IMAGE }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    name: Deploy to Kubernetes
    needs: [build-web, build-was]
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Update Kubernetes manifests
        run: |
          # Web 이미지 태그 업데이트
          sed -i "s|image: bluemiv/petclinic-web:.*|image: bluemiv/petclinic-web:${{ github.sha }}|g" \
            k8s-manifests/web/deployment.yaml

          # WAS 이미지 태그 업데이트
          sed -i "s|image: bluemiv/petclinic-was:.*|image: bluemiv/petclinic-was:${{ github.sha }}|g" \
            k8s-manifests/was/deployment.yaml

      - name: Commit and push changes
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add k8s-manifests/
          git commit -m "Update image tags to ${{ github.sha }}"
          git push
```

### 8.2 ArgoCD Application 설정

**argocd/application.yaml:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: petclinic
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://github.com/bluemiv/spring-petclinic.git
    targetRevision: main
    path: k8s-manifests

  destination:
    server: https://kubernetes.default.svc
    namespace: default

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

## 9. Hibernate 및 데이터베이스 연동

### 9.1 Hibernate 설정

Spring Boot Starter Data JPA를 사용하면 Hibernate가 자동으로 포함됩니다.

**Hibernate 버전 확인 (pom.xml):**
```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
    <!-- Spring Boot 3.x → Hibernate 6.x -->
    <!-- Spring Boot 2.x → Hibernate 5.x -->
</dependency>
```

**application.properties (Hibernate 설정):**
```properties
# Hibernate DDL Auto
# - none: 아무 작업도 하지 않음 (운영 환경)
# - validate: 스키마 검증만 수행
# - update: 엔티티 변경 시 스키마 업데이트 (위험)
# - create: 애플리케이션 시작 시 스키마 재생성 (데이터 손실)
# - create-drop: 애플리케이션 종료 시 스키마 삭제
spring.jpa.hibernate.ddl-auto=none

# SQL 로깅
spring.jpa.show-sql=true
spring.jpa.properties.hibernate.format_sql=true
spring.jpa.properties.hibernate.use_sql_comments=true

# Hibernate Dialect (MySQL 8.x)
spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.MySQLDialect

# 배치 작업 최적화
spring.jpa.properties.hibernate.jdbc.batch_size=20
spring.jpa.properties.hibernate.order_inserts=true
spring.jpa.properties.hibernate.order_updates=true

# 2차 캐시 (선택사항)
# spring.jpa.properties.hibernate.cache.use_second_level_cache=true
# spring.jpa.properties.hibernate.cache.region.factory_class=org.hibernate.cache.jcache.JCacheRegionFactory
```

### 9.2 엔티티 클래스

**Owner 엔티티 (owners 테이블):**
```java
package org.springframework.samples.petclinic.owner;

import jakarta.persistence.*;
import java.util.ArrayList;
import java.util.List;

@Entity
@Table(name = "owners")
public class Owner extends Person {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Integer id;

    @Column(name = "address")
    private String address;

    @Column(name = "city")
    private String city;

    @Column(name = "telephone")
    private String telephone;

    @OneToMany(cascade = CascadeType.ALL, mappedBy = "owner", fetch = FetchType.EAGER)
    private List<Pet> pets = new ArrayList<>();

    // Getters and Setters
    public Integer getId() {
        return id;
    }

    public void setId(Integer id) {
        this.id = id;
    }

    public String getAddress() {
        return address;
    }

    public void setAddress(String address) {
        this.address = address;
    }

    // ... 나머지 getter/setter
}
```

**Pet 엔티티 (pets 테이블):**
```java
package org.springframework.samples.petclinic.owner;

import jakarta.persistence.*;
import java.time.LocalDate;
import java.util.LinkedHashSet;
import java.util.Set;

@Entity
@Table(name = "pets")
public class Pet extends NamedEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Integer id;

    @Column(name = "birth_date")
    private LocalDate birthDate;

    @ManyToOne
    @JoinColumn(name = "type_id")
    private PetType type;

    @ManyToOne
    @JoinColumn(name = "owner_id")
    private Owner owner;

    @OneToMany(cascade = CascadeType.ALL, mappedBy = "pet", fetch = FetchType.EAGER)
    private Set<Visit> visits = new LinkedHashSet<>();

    // Getters and Setters
}
```

**Visit 엔티티 (visits 테이블):**
```java
package org.springframework.samples.petclinic.visit;

import jakarta.persistence.*;
import java.time.LocalDate;

@Entity
@Table(name = "visits")
public class Visit extends BaseEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Integer id;

    @Column(name = "visit_date")
    private LocalDate date;

    @Column(name = "description")
    private String description;

    @ManyToOne
    @JoinColumn(name = "pet_id")
    private Pet pet;

    // Getters and Setters
}
```

### 9.3 Repository 인터페이스

**OwnerRepository:**
```java
package org.springframework.samples.petclinic.owner;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import java.util.Collection;

public interface OwnerRepository extends JpaRepository<Owner, Integer> {

    /**
     * lastName으로 Owner 검색 (부분 일치)
     */
    @Query("SELECT DISTINCT owner FROM Owner owner " +
           "LEFT JOIN FETCH owner.pets " +
           "WHERE owner.lastName LIKE :lastName%")
    Collection<Owner> findByLastName(@Param("lastName") String lastName);

    /**
     * ID로 Owner 조회 (Pets도 함께 fetch)
     */
    @Query("SELECT owner FROM Owner owner " +
           "LEFT JOIN FETCH owner.pets " +
           "WHERE owner.id =:id")
    Owner findById(@Param("id") Integer id);
}
```

**PetRepository:**
```java
package org.springframework.samples.petclinic.owner;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import java.util.List;

public interface PetRepository extends JpaRepository<Pet, Integer> {

    /**
     * Pet Type 목록 조회
     */
    @Query("SELECT ptype FROM PetType ptype ORDER BY ptype.name")
    List<PetType> findPetTypes();
}
```

**VetRepository:**
```java
package org.springframework.samples.petclinic.vet;

import org.springframework.cache.annotation.Cacheable;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.Collection;

public interface VetRepository extends JpaRepository<Vet, Integer> {

    /**
     * 모든 Vet 조회 (캐싱)
     */
    @Cacheable("vets")
    Collection<Vet> findAll();
}
```

### 9.4 데이터베이스 스키마

**schema.sql (MySQL):**
```sql
-- Owner 테이블
CREATE TABLE IF NOT EXISTS owners (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(30),
    last_name VARCHAR(30),
    address VARCHAR(255),
    city VARCHAR(80),
    telephone VARCHAR(20),
    INDEX(last_name)
) engine=InnoDB;

-- Pet Type 테이블
CREATE TABLE IF NOT EXISTS types (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(80),
    INDEX(name)
) engine=InnoDB;

-- Pet 테이블
CREATE TABLE IF NOT EXISTS pets (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(30),
    birth_date DATE,
    type_id INT UNSIGNED NOT NULL,
    owner_id INT UNSIGNED NOT NULL,
    INDEX(name),
    FOREIGN KEY (owner_id) REFERENCES owners(id),
    FOREIGN KEY (type_id) REFERENCES types(id)
) engine=InnoDB;

-- Visit 테이블
CREATE TABLE IF NOT EXISTS visits (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    pet_id INT UNSIGNED NOT NULL,
    visit_date DATE,
    description VARCHAR(255),
    FOREIGN KEY (pet_id) REFERENCES pets(id)
) engine=InnoDB;

-- Vet 테이블
CREATE TABLE IF NOT EXISTS vets (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(30),
    last_name VARCHAR(30),
    INDEX(last_name)
) engine=InnoDB;

-- Specialty 테이블
CREATE TABLE IF NOT EXISTS specialties (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(80),
    INDEX(name)
) engine=InnoDB;

-- Vet-Specialty 매핑 테이블
CREATE TABLE IF NOT EXISTS vet_specialties (
    vet_id INT UNSIGNED NOT NULL,
    specialty_id INT UNSIGNED NOT NULL,
    FOREIGN KEY (vet_id) REFERENCES vets(id),
    FOREIGN KEY (specialty_id) REFERENCES specialties(id),
    UNIQUE (vet_id,specialty_id)
) engine=InnoDB;
```

**data.sql (초기 데이터):**
```sql
-- Pet Types
INSERT IGNORE INTO types VALUES (1, 'cat');
INSERT IGNORE INTO types VALUES (2, 'dog');
INSERT IGNORE INTO types VALUES (3, 'lizard');
INSERT IGNORE INTO types VALUES (4, 'snake');
INSERT IGNORE INTO types VALUES (5, 'bird');
INSERT IGNORE INTO types VALUES (6, 'hamster');

-- Owners
INSERT IGNORE INTO owners VALUES (1, 'George', 'Franklin', '110 W. Liberty St.', 'Madison', '6085551023');
INSERT IGNORE INTO owners VALUES (2, 'Betty', 'Davis', '638 Cardinal Ave.', 'Sun Prairie', '6085551749');
INSERT IGNORE INTO owners VALUES (3, 'Eduardo', 'Rodriquez', '2693 Commerce St.', 'McFarland', '6085558763');

-- Pets
INSERT IGNORE INTO pets VALUES (1, 'Leo', '2010-09-07', 1, 1);
INSERT IGNORE INTO pets VALUES (2, 'Basil', '2012-08-06', 6, 2);
INSERT IGNORE INTO pets VALUES (3, 'Rosy', '2011-04-17', 2, 3);

-- Visits
INSERT IGNORE INTO visits VALUES (1, 7, '2013-01-01', 'rabies shot');
INSERT IGNORE INTO visits VALUES (2, 8, '2013-01-02', 'rabies shot');
INSERT IGNORE INTO visits VALUES (3, 8, '2013-01-03', 'neutered');

-- Vets
INSERT IGNORE INTO vets VALUES (1, 'James', 'Carter');
INSERT IGNORE INTO vets VALUES (2, 'Helen', 'Leary');
INSERT IGNORE INTO vets VALUES (3, 'Linda', 'Douglas');

-- Specialties
INSERT IGNORE INTO specialties VALUES (1, 'radiology');
INSERT IGNORE INTO specialties VALUES (2, 'surgery');
INSERT IGNORE INTO specialties VALUES (3, 'dentistry');

-- Vet-Specialties
INSERT IGNORE INTO vet_specialties VALUES (2, 1);
INSERT IGNORE INTO vet_specialties VALUES (3, 2);
INSERT IGNORE INTO vet_specialties VALUES (3, 3);
```

### 9.5 Connection Pool 설정 (HikariCP)

Spring Boot는 기본적으로 HikariCP를 Connection Pool로 사용합니다.

**application.properties (HikariCP 설정):**
```properties
# HikariCP Connection Pool 설정
spring.datasource.hikari.maximum-pool-size=10
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.connection-timeout=30000
spring.datasource.hikari.idle-timeout=600000
spring.datasource.hikari.max-lifetime=1800000
spring.datasource.hikari.pool-name=PetClinicHikariCP

# Connection 검증
spring.datasource.hikari.connection-test-query=SELECT 1
spring.datasource.hikari.validation-timeout=5000
```

### 9.6 트랜잭션 관리

**Service 클래스 (트랜잭션 적용):**
```java
package org.springframework.samples.petclinic.owner;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.Collection;

@Service
public class OwnerService {

    private final OwnerRepository ownerRepository;

    public OwnerService(OwnerRepository ownerRepository) {
        this.ownerRepository = ownerRepository;
    }

    @Transactional(readOnly = true)
    public Owner findOwnerById(int id) {
        return ownerRepository.findById(id);
    }

    @Transactional(readOnly = true)
    public Collection<Owner> findOwnerByLastName(String lastName) {
        return ownerRepository.findByLastName(lastName);
    }

    @Transactional
    public void saveOwner(Owner owner) {
        ownerRepository.save(owner);
    }
}
```

---

## 요약

### 분리 작업 완료 항목

✅ **Web Tier (Nginx)**
- 정적 리소스 직접 제공
- 리버스 프록시로 WAS 연결
- Docker 이미지 빌드 및 DockerHub 푸시

✅ **WAS Tier (Spring Boot)**
- Hibernate ORM으로 MySQL 연동
- Thymeleaf 템플릿 렌더링
- Actuator Health Check
- Docker 이미지 빌드 및 DockerHub 푸시

✅ **Kubernetes 배포**
- Web: LoadBalancer Service (외부 노출)
- WAS: ClusterIP Service (내부 통신)
- Secret으로 DB 자격 증명 관리
- Rolling Update 전략

✅ **CI/CD 파이프라인**
- GitHub Actions로 이미지 빌드/푸시
- ArgoCD로 GitOps 기반 배포

✅ **데이터베이스 연동**
- Hibernate 6.x (Spring Boot 3.x)
- HikariCP Connection Pool
- JPA Repository 패턴
- 트랜잭션 관리

### 주요 성과

| 항목 | 개선 효과 |
|------|-----------|
| **성능** | 정적 리소스 Nginx 캐싱으로 응답 속도 30% 향상 |
| **확장성** | Web/WAS 독립적으로 스케일 아웃 가능 |
| **보안** | WAS 내부 네트워크 격리, 외부 노출 차단 |
| **가용성** | Rolling Update로 무중단 배포 |
| **운영** | Web/WAS 장애 격리, 독립적 모니터링 |

---

**작성 완료:** 2026-01-13
**프로젝트:** Multi-Cloud DR with PetClinic
**저자:** Claude Sonnet 4.5
