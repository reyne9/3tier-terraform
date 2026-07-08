# AWS CI/CD 파이프라인 상세 설명

**디렉토리**: `/codes/aws/4-cicd/`

**목적**: GitHub Actions + ArgoCD GitOps 기반 자동화된 Multi-Cloud 배포 파이프라인

---

## 📋 개요

이 디렉토리는 Spring PetClinic 애플리케이션의 **완전 자동화된 빌드, 테스트, 배포 파이프라인**을 구성합니다. 코드 변경 시 자동으로 AWS EKS와 Azure AKS에 배포되며, **GitOps 원칙**을 따라 선언적 배포를 수행합니다.

### 핵심 목표

1. **빠른 피드백 루프**: 코드 커밋 → 운영 배포까지 10분 이내
2. **무중단 배포**: Rolling Update로 서비스 중단 없이 업데이트
3. **자동 롤백**: 배포 실패 시 자동으로 이전 버전 복구
4. **Multi-Cloud 일관성**: AWS와 Azure에 동일한 방식으로 배포

---

## 🔑 핵심 설계 결정

### 1. CI 도구 선택: GitHub Actions

#### 선택: GitHub Actions

```yaml
name: PetClinic Multi-Cloud DR - CI/CD Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build with Maven
        run: ./mvnw clean package
```

#### 왜 GitHub Actions인가?

**대안 비교**

| CI/CD 도구 | 비용 | GitHub 통합 | 학습 곡선 | Self-Hosted | 선택 |
|-----------|------|-------------|----------|-------------|------|
| **GitHub Actions** ✅ | 무료 (2000분/월) | 네이티브 | 낮음 | 선택 가능 | ✅ |
| Jenkins | 무료 | Plugin 필요 | 높음 | 필수 | ❌ |
| GitLab CI/CD | 무료 (400분/월) | Migration 필요 | 중간 | 선택 가능 | ❌ |
| CircleCI | 유료 ($30/월) | Webhook | 중간 | 클라우드 | ❌ |
| AWS CodePipeline | 유료 ($1/pipeline) | GitHub App | 높음 | AWS 전용 | ❌ |

**선택 이유**:

1. **GitHub 네이티브 통합**
   - 코드 저장소와 같은 플랫폼 (추가 인증 불필요)
   - Pull Request 자동 트리거, 코멘트 연동
   - GitHub Packages와 자동 연동

2. **제로 인프라 관리**
   - Self-hosted 불필요 (Jenkins처럼 서버 관리 안 함)
   - Auto-scaling Runner (동시 빌드 자동 처리)
   - 보안 패치 자동 적용

3. **비용 효율**
   - Public 저장소: 무제한 무료
   - Private 저장소: 2000분/월 무료 (이 프로젝트: ~100분/월)
   - Self-hosted Runner 사용 시 완전 무료

4. **풍부한 Marketplace**
   - Docker Build/Push: `docker/build-push-action`
   - Trivy 보안 스캔: `aquasecurity/trivy-action`
   - AWS/Azure CLI: 공식 Action 제공

**트레이드오프**:
- Jenkins 대비 플러그인 생태계 작음
- Workflow 파일이 복잡해지면 가독성 저하 (Groovy보다 YAML이 장황)
- GitHub에 종속 (Vendor Lock-in)

**대안 기각 이유**:

**Jenkins (기각)**:
```
장점: 플러그인 생태계 강력, 완전 커스터마이징
단점:
  - EC2 인스턴스 필요 ($30/월 t3.medium)
  - 플러그인 보안 취약점 관리 부담
  - Java 11+ 요구 (메모리 소모 큼)
  - 프로젝트 목적(포트폴리오)에 과도한 복잡도
```

**AWS CodePipeline (기각)**:
```
장점: AWS 네이티브, IAM 통합
단점:
  - Azure 배포 복잡 (CodePipeline은 AWS 중심)
  - 비용 ($1/pipeline/월 + CodeBuild $0.005/분)
  - GitHub Actions 대비 느림 (평균 2배)
  - UI가 직관적이지 않음
```

---

### 2. CD 도구 선택: ArgoCD (GitOps)

#### 구성: ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: petclinic-was
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/c1oud9/3tier-terraform
    targetRevision: main
    path: codes/aws/2. service/k8s-manifests/was
  destination:
    server: https://kubernetes.default.svc
    namespace: was
  syncPolicy:
    automated:
      prune: true       # 삭제된 리소스 자동 정리
      selfHeal: true    # 수동 변경 자동 되돌림
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

#### 왜 ArgoCD인가?

**GitOps 도구 비교**

| 도구 | GitOps 지원 | UI | Multi-Cluster | RBAC | 선택 |
|------|------------|----|--------------|----- |------|
| **ArgoCD** ✅ | Native | 강력 | 지원 | 강력 | ✅ |
| Flux CD | Native | CLI 중심 | 지원 | 중간 | ❌ |
| Jenkins X | 부분 | 약함 | 지원 | 약함 | ❌ |
| Spinnaker | 부분 | 강력 | 지원 | 강력 | ❌ |
| Helm + kubectl | 수동 | 없음 | 수동 | 없음 | ❌ |

**선택 이유**:

1. **GitOps 원칙 완벽 구현**
   - **Single Source of Truth**: Git = 운영 환경 상태
   - **선언적 배포**: Desired State를 Git에 선언
   - **자동 동기화**: Git 변경 → 3분 이내 클러스터 반영

2. **강력한 UI**
   ```
   ArgoCD UI 기능:
   - 실시간 리소스 Tree View
   - Sync 상태 시각화 (OutOfSync, Synced, Progressing)
   - 로그 통합 확인 (Pod Events, Logs)
   - 원클릭 롤백 (이전 커밋으로 Sync)
   ```
   vs. Flux CD: CLI 중심, UI 별도 설치 필요

3. **Multi-Cluster 지원**
   - 단일 ArgoCD로 AWS EKS + Azure AKS 관리
   - Cluster별 RBAC 세밀 제어

4. **Self-Healing (자동 복구)**
   ```
   시나리오:
   1. 운영자가 kubectl로 Deployment 수정
      (replicas: 2 → 5로 수동 변경)
   2. ArgoCD가 Git과 차이 감지 (OutOfSync)
   3. 자동으로 Git 상태로 되돌림 (replicas: 2)
   결과: Git이 항상 진실의 원천 (Drift 방지)
   ```

**트레이드오프**:
- 추가 컴포넌트 운영 (ArgoCD Server, Repo Server, Dex)
- 러닝 커브 (GitOps 개념 이해 필요)
- Git Push 후 최대 3분 지연 (Polling 주기)

**대안 비교**:

**Flux CD (기각)**:
```
장점:
  - 더 경량 (CRD 기반, UI 불필요)
  - Helm 네이티브 지원 강력
단점:
  - UI 없음 (CLI로만 상태 확인)
  - 학습 곡선 높음 (Kustomize 필수)
  - 디버깅 어려움 (로그 분산)
```

**Spinnaker (기각)**:
```
장점:
  - Netflix 검증, Canary 배포 강력
단점:
  - 복잡도 극심 (10+ 마이크로서비스)
  - 리소스 소모 큼 (최소 16GB 메모리)
  - 학습 곡선 매우 높음
  - 포트폴리오 프로젝트에 과도
```

**수동 배포 (Helm + kubectl) (기각)**:
```
장점:
  - 간단, 추가 도구 불필요
단점:
  - 수동 작업 필요 (CI에서 kubectl 직접 실행)
  - Drift Detection 없음 (Git ≠ Cluster)
  - 롤백 복잡 (수동으로 이전 Helm revision)
  - Multi-Cluster 관리 어려움
```

---

### 3. 배포 전략 선택: Rolling Update

#### 구성: Kubernetes Deployment Strategy

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: was-deployment
  namespace: was
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 최대 1개 추가 Pod 생성 가능
      maxUnavailable: 0  # 항상 최소 2개 Pod 유지
  template:
    spec:
      containers:
        - name: was
          image: cloud039/petclinic-was:v3
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
```

#### 왜 Rolling Update인가?

**배포 전략 비교**

| 전략 | 다운타임 | 리소스 오버헤드 | 롤백 속도 | 복잡도 | 선택 |
|------|---------|---------------|----------|--------|------|
| **Rolling Update** ✅ | 없음 | 낮음 (+50%) | 빠름 | 낮음 | ✅ |
| Blue-Green | 없음 | 높음 (+100%) | 즉시 | 중간 | ❌ |
| Canary | 없음 | 중간 (+10-20%) | 중간 | 높음 | ❌ |
| Recreate | 있음 (30초~1분) | 없음 | 빠름 | 매우 낮음 | ❌ |

**Rolling Update 동작 방식**:

```
초기 상태: 2개 Pod (v2)
┌─────────┐  ┌─────────┐
│ Pod-1   │  │ Pod-2   │
│  v2     │  │  v2     │
└─────────┘  └─────────┘
     ↓            ↓
   트래픽 100%

Step 1: 새 버전 Pod 1개 추가 (maxSurge=1)
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Pod-1   │  │ Pod-2   │  │ Pod-3   │
│  v2     │  │  v2     │  │  v3     │
└─────────┘  └─────────┘  └─────────┘
     ↓            ↓            ↓
   트래픽 66%              (readiness 대기)

Step 2: Pod-3 Ready 확인 후 Pod-1 종료
                ┌─────────┐  ┌─────────┐
                │ Pod-2   │  │ Pod-3   │
                │  v2     │  │  v3     │
                └─────────┘  └─────────┘
                     ↓            ↓
                   트래픽 50%

Step 3: 새 버전 Pod 1개 추가
                ┌─────────┐  ┌─────────┐  ┌─────────┐
                │ Pod-2   │  │ Pod-3   │  │ Pod-4   │
                │  v2     │  │  v3     │  │  v3     │
                └─────────┘  └─────────┘  └─────────┘
                     ↓            ↓            ↓
                   트래픽 33%              (readiness 대기)

Step 4: Pod-4 Ready 확인 후 Pod-2 종료
                             ┌─────────┐  ┌─────────┐
                             │ Pod-3   │  │ Pod-4   │
                             │  v3     │  │  v3     │
                             └─────────┘  └─────────┘
                                  ↓            ↓
                                트래픽 100%

완료: 2개 Pod (v3)
```

**선택 이유**:

1. **무중단 배포**
   - `maxUnavailable: 0` 설정으로 항상 2개 이상 Pod 유지
   - ALB Health Check 통과한 Pod만 트래픽 수신

2. **빠른 롤백**
   ```bash
   # 롤백 명령 (30초 이내 완료)
   kubectl rollout undo deployment was-deployment -n was

   # 또는 ArgoCD에서 이전 커밋으로 Sync
   ```

3. **낮은 리소스 오버헤드**
   - 최대 3개 Pod (2 + maxSurge 1)
   - Blue-Green처럼 2배 리소스 불필요

4. **Readiness Probe 활용**
   ```yaml
   readinessProbe:
     httpGet:
       path: /actuator/health
       port: 8080
     initialDelaySeconds: 30  # 30초 후 체크 시작
     periodSeconds: 10         # 10초마다 체크
     failureThreshold: 3       # 3번 실패 시 Unready
   ```
   - Spring Boot Actuator Health Endpoint 사용
   - DB 연결, 디스크 상태 자동 체크
   - Unready Pod는 트래픽 미수신 (자동 제외)

**트레이드오프**:
- Canary 대비 점진적 트래픽 전환 불가 (한번에 전환)
- Blue-Green 대비 즉시 롤백 불가 (Rolling으로 되돌려야 함)

**대안 비교**:

**Blue-Green 배포 (기각)**:
```yaml
# Blue (현재 버전)
apiVersion: v1
kind: Service
metadata:
  name: was-service
spec:
  selector:
    app: was
    version: blue  # Blue 환경 선택

---
# Green (새 버전) 배포 후 Service selector 변경
spec:
  selector:
    app: was
    version: green  # Green으로 즉시 전환
```

**장점**:
- 즉시 롤백 (Service selector만 변경)
- 트래픽 전환 순간적 (DNS 레벨)

**기각 이유**:
- **리소스 2배 필요**: Blue 2개 + Green 2개 = 4개 Pod
- **비용 2배**: 배포 중 t3.medium Node 4개 필요 ($120/월)
- **포트폴리오 프로젝트에 과도**: 실무는 유용하나 학습용으로는 Rolling으로 충분

**Canary 배포 (기각)**:
```yaml
# Canary 10%
apiVersion: v1
kind: Service
metadata:
  name: was-service
spec:
  selector:
    app: was  # v2, v3 모두 선택 (10% vs 90% 비율)

# Istio VirtualService로 트래픽 제어
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
spec:
  http:
    - match:
        - headers:
            user-type:
              exact: beta-tester
      route:
        - destination:
            subset: v3  # Beta 사용자 → v3
    - route:
        - destination:
            subset: v2
          weight: 90
        - destination:
            subset: v3
          weight: 10  # 10% 트래픽 → v3
```

**장점**:
- 점진적 트래픽 전환 (10% → 50% → 100%)
- A/B 테스트 가능
- 문제 발생 시 일부만 영향

**기각 이유**:
- **Service Mesh 필요**: Istio/Linkerd 설치 (복잡도 증가)
- **추가 리소스**: Istio Control Plane (1GB+ 메모리)
- **학습 곡선 높음**: Istio CRD 이해 필요
- **프로젝트 목적과 맞지 않음**: Multi-Cloud DR에 집중, Canary는 부가 기능

**Recreate 배포 (기각)**:
```yaml
spec:
  strategy:
    type: Recreate  # 모든 Pod 삭제 후 재생성
```

**장점**:
- 가장 간단, 추가 리소스 불필요

**기각 이유**:
- **다운타임 발생**: 30초~1분 서비스 중단
- **프로젝트 목표 위배**: "무중단 배포" 요구사항
- **실무 적용 불가**: Production 환경 부적합

---

### 4. 컨테이너 레지스트리 선택: Docker Hub

#### 구성

```yaml
# GitHub Actions에서 이미지 빌드 및 푸시
- name: Build and Push Docker Image
  uses: docker/build-push-action@v5
  with:
    context: ./spring-petclinic
    file: ./Dockerfile
    push: true
    tags: |
      cloud039/petclinic-was:latest
      cloud039/petclinic-was:${{ github.sha }}
      cloud039/petclinic-was:v${{ github.run_number }}
    cache-from: type=registry,ref=cloud039/petclinic-was:buildcache
    cache-to: type=registry,ref=cloud039/petclinic-was:buildcache,mode=max
```

#### 왜 Docker Hub인가?

**컨테이너 레지스트리 비교**

| 레지스트리 | 비용 | Public 이미지 | Private 이미지 | 대역폭 | 선택 |
|----------|------|--------------|---------------|--------|------|
| **Docker Hub** ✅ | 무료 | 무제한 | 1개 | 무제한 | ✅ |
| AWS ECR | 유료 ($0.10/GB) | 지원 안함 | 무제한 | 유료 | ❌ |
| Azure ACR | 유료 ($5/월) | 지원 안함 | 무제한 | 100GB 포함 | ❌ |
| GitHub Container Registry | 무료 | 무제한 | 무제한 | 1GB/월 | △ |
| Harbor (Self-hosted) | 무료 | 무제한 | 무제한 | 무제한 | ❌ |

**선택 이유**:

1. **완전 무료 (Public 이미지)**
   - 포트폴리오 프로젝트는 Public 이미지로 충분
   - Pull 무제한 (익명 사용자: 100회/6시간, 로그인: 200회/6시간)

2. **Multi-Cloud 지원**
   - AWS EKS와 Azure AKS 모두 Docker Hub에서 Pull 가능
   - AWS ECR은 Azure에서 Pull 복잡 (IAM 인증 필요)

3. **GitHub Actions 네이티브 통합**
   ```yaml
   - name: Login to DockerHub
     uses: docker/login-action@v3
     with:
       username: ${{ secrets.DOCKER_USERNAME }}
       password: ${{ secrets.DOCKER_PASSWORD }}
   ```
   - 별도 인증 서버 불필요

4. **이미지 캐싱**
   - BuildKit Cache 지원으로 빌드 속도 3배 향상
   - Layer 재사용으로 Push 시간 단축

**트레이드오프**:
- Private 이미지 제한 (무료 플랜: 1개)
- Rate Limit (Pull 제한 있음, 실무는 ECR 권장)
- 지리적 분산 약함 (ECR은 리전별 배치)

**대안 비교**:

**AWS ECR (기각)**:
```
장점:
  - IAM 통합 인증 (Access Key 불필요)
  - VPC Endpoint 지원 (Private Link)
  - 리전별 배치 (낮은 레이턴시)
단점:
  - 비용 발생 ($0.10/GB 저장, $0.09/GB 전송)
  - Azure AKS에서 Pull 복잡 (Cross-Cloud 인증)
  - Public 이미지 지원 안함 (ECR Public은 별도)

예상 비용:
  - 이미지 크기: 500MB × 10개 버전 = 5GB
  - 저장 비용: 5GB × $0.10 = $0.50/월
  - 전송 비용: 100 Pull × 500MB × $0.09 = $4.5/월
  합계: ~$5/월 (Docker Hub 무료 대비 불필요)
```

**GitHub Container Registry (GHCR) (고려 대상)**:
```
장점:
  - GitHub 네이티브 (추가 계정 불필요)
  - Private 이미지 무제한 (무료)
  - GitHub Actions에서 자동 인증
단점:
  - 대역폭 제한 (1GB/월, 초과 시 과금)
  - 이미지당 500MB라면 2번 Pull로 제한 초과
  - EKS/AKS에서 Pull 시 GITHUB_TOKEN 관리 필요

결론: Public 이미지라면 Docker Hub가 더 나음
```

**Harbor Self-hosted (기각)**:
```
장점:
  - 완전 무료, 무제한
  - Vulnerability Scanning 내장
  - RBAC 강력
단점:
  - EC2 인스턴스 필요 ($30/월 t3.medium)
  - PostgreSQL, Redis 추가 설치
  - SSL 인증서 관리
  - 백업/복구 운영 부담
  - 포트폴리오 프로젝트에 과도
```

---

## 🔄 CI/CD 파이프라인 상세 플로우

### 전체 파이프라인 (10분)

```
┌─────────────────────────────────────────────────────────────┐
│  1. Code Push (GitHub)                                   0분 │
├─────────────────────────────────────────────────────────────┤
│  2. Build & Test (Maven)                                 3분 │
│     - mvn clean package                                      │
│     - mvn test                                               │
├─────────────────────────────────────────────────────────────┤
│  3. Security Scan (Trivy)                                1분 │
│     - 의존성 취약점 스캔                                      │
│     - Dockerfile 보안 검사                                    │
├─────────────────────────────────────────────────────────────┤
│  4. Docker Build & Push (BuildKit Cache)                 2분 │
│     - Build: cloud039/petclinic-was:v3                       │
│     - Push to Docker Hub                                     │
├─────────────────────────────────────────────────────────────┤
│  5. Update GitOps Repo (Kustomize)                       1분 │
│     - image: cloud039/petclinic-was:v3                       │
│     - Git Commit & Push                                      │
├─────────────────────────────────────────────────────────────┤
│  6. ArgoCD Auto-Sync                                     3분 │
│     - Detect Git change (30초 polling)                       │
│     - Apply to EKS (Rolling Update 2분)                      │
│     - Health Check (30초)                                    │
├─────────────────────────────────────────────────────────────┤
│  7. Smoke Test                                           1분 │
│     - ALB Health Check                                       │
│     - HTTP GET / (200 OK 확인)                               │
└─────────────────────────────────────────────────────────────┘
Total: ~10분
```

### GitHub Actions Job 상세

```yaml
jobs:
  # Job 1: Build & Test (병렬 실행 가능)
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup JDK 21
        uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          cache: maven  # ~/.m2 캐싱으로 30초 단축

      - name: Build with Maven
        run: |
          cd spring-petclinic
          ./mvnw clean package -DskipTests
        # 빌드 시간: 2분 (의존성 다운로드 포함)

      - name: Run Unit Tests
        run: ./mvnw test
        # 테스트 시간: 1분 (30개 테스트)

      - name: Upload JAR
        uses: actions/upload-artifact@v4
        with:
          name: petclinic-jar
          path: target/*.jar
          retention-days: 1  # 1일 후 자동 삭제

  # Job 2: Security Scan (build와 병렬 실행)
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'fs'
          severity: 'CRITICAL,HIGH'
          exit-code: '1'  # CRITICAL 발견 시 실패
        # Trivy 스캔: 1분

  # Job 3: Docker Build (build, security 완료 후)
  docker:
    needs: [build, security]
    runs-on: ubuntu-latest
    steps:
      - name: Download JAR Artifact
        uses: actions/download-artifact@v4

      - name: Set Image Tag
        id: tag
        run: |
          echo "tag=v$(date +%Y%m%d)-${GITHUB_SHA:0:7}" >> $GITHUB_OUTPUT

      - name: Build and Push
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: cloud039/petclinic-was:${{ steps.tag.outputs.tag }}
          cache-from: type=registry,ref=cloud039/petclinic-was:buildcache
          # BuildKit Cache로 빌드 시간 50% 단축
        # 빌드: 1분, Push: 1분 (캐시 활용 시)

  # Job 4: Update GitOps Repo
  gitops:
    needs: docker
    runs-on: ubuntu-latest
    steps:
      - name: Checkout GitOps Repo
        uses: actions/checkout@v4
        with:
          repository: c1oud9/3tier-terraform
          token: ${{ secrets.GH_PAT }}

      - name: Update Kustomization
        run: |
          cd codes/aws/2. service/k8s-manifests/was
          kustomize edit set image \
            cloud039/petclinic-was:${{ needs.docker.outputs.tag }}

      - name: Commit and Push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git commit -m "chore: update WAS image to ${{ needs.docker.outputs.tag }}"
          git push
        # GitOps 업데이트: 30초
```

---

## 💰 비용 분석

### GitHub Actions 비용

| 항목 | 사용량 (월) | 단가 | 비용 |
|------|-----------|------|------|
| **Public Repo** | 무제한 | 무료 | $0 |
| Private Repo (무료 플랜) | 2000분 | 무료 | $0 |
| 예상 사용량 (월 20회 배포) | 200분 | - | $0 |
| **총 합계** | | | **$0** |

### Docker Hub 비용

| 항목 | 수량 | 단가 | 비용 |
|------|------|------|------|
| **Public Repository** | 2개 (web, was) | 무료 | $0 |
| **Private Repository** | 0개 | $5/월 | $0 |
| **이미지 Pull** | 무제한 | 무료 | $0 |
| **총 합계** | | | **$0** |

### ArgoCD 비용

| 항목 | 리소스 | 월 비용 |
|------|--------|---------|
| **ArgoCD Server** | EKS 내부 (리소스 공유) | $0 |
| **추가 리소스 없음** | | $0 |

**총 CI/CD 비용: $0/월** (완전 무료)

---

## 🚀 배포 절차

### 1. ArgoCD 설치

```bash
# ArgoCD 네임스페이스 생성
kubectl create namespace argocd

# ArgoCD 설치
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Admin 비밀번호 확인
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# ArgoCD UI 접속 (포트 포워딩)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080 접속
```

### 2. ArgoCD Application 배포

```bash
# WAS Application 등록
kubectl apply -f /home/ubuntu/3tier-terraform/codes/aws/4-cicd/argocd/application.yaml

# 동기화 상태 확인
kubectl get applications -n argocd
# NAME              SYNC STATUS   HEALTH STATUS
# petclinic-was     Synced        Healthy
```

### 3. GitHub Actions 설정

```bash
# GitHub Repository Secrets 설정 (GitHub UI)
# Settings → Secrets and variables → Actions

# 필요한 Secrets:
DOCKER_USERNAME=cloud039
DOCKER_PASSWORD=<dockerhub-token>
AWS_ACCESS_KEY_ID=<aws-key>
AWS_SECRET_ACCESS_KEY=<aws-secret>
GH_PAT=<github-personal-access-token>  # GitOps Repo Push용
```

---

## 🔧 운영 가이드

### 배포 트리거

**자동 배포 (main 브랜치 Push)**:
```bash
cd /home/ubuntu/spring-petclinic
# 코드 수정
git add .
git commit -m "feat: add new feature"
git push origin main
# → GitHub Actions 자동 실행 → 10분 후 EKS 배포 완료
```

**수동 배포 (GitHub UI)**:
```
1. GitHub → Actions 탭
2. "PetClinic Multi-Cloud DR - CI/CD Pipeline" 선택
3. "Run workflow" 클릭
4. Branch 선택 (main/develop)
5. "Run workflow" 실행
```

### 롤백 절차

**ArgoCD UI 롤백**:
```
1. ArgoCD UI 접속
2. petclinic-was Application 선택
3. "History and Rollback" 클릭
4. 이전 Revision 선택
5. "Rollback" 클릭
→ 2분 이내 롤백 완료
```

**kubectl 롤백**:
```bash
# 이전 버전으로 롤백
kubectl rollout undo deployment was-deployment -n was

# 특정 Revision으로 롤백
kubectl rollout history deployment was-deployment -n was
kubectl rollout undo deployment was-deployment -n was --to-revision=3
```

---

## 📝 관련 문서

- **[GitHub Actions 공식 문서](https://docs.github.com/en/actions)**
- **[ArgoCD 공식 문서](https://argo-cd.readthedocs.io/)**
- **[GitOps 원칙](https://www.gitops.tech/)**
- **[Kubernetes Deployment Strategies](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)**

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/aws/4-cicd/`
