# AWS Monitoring & Observability 인프라 상세 설명

**디렉토리**: `/codes/aws/3. monitoring/`

**목적**: 병목현상 탐지, 성능 분석, 자동 복구를 위한 Multi-Layer Observability 구성

---

## 📋 개요

이 디렉토리는 AWS Primary Site의 전체 스택(Infrastructure → Container → Application)에 대한 **통합 관측성(Observability)** 을 제공합니다. 단순한 모니터링을 넘어, **병목현상을 사전 탐지**하고 **자동으로 복구**하는 것이 핵심 목표입니다.

### Observability 3 Pillars 구현

1. **Metrics** (지표): CloudWatch Container Insights, RDS Performance Insights
2. **Logs** (로그): CloudWatch Logs, Application/Access Logs 수집
3. **Traces** (추적): X-Ray 분산 추적 (선택 사항)

### 병목현상 탐지 레이어

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1: Infrastructure (Node, Network, Disk)           │
│  - EKS Node CPU/Memory/Disk 사용률                        │
│  - NAT Gateway 대역폭, Packet Drop                        │
│  └─> 병목: Node 리소스 고갈, 네트워크 포화                │
├──────────────────────────────────────────────────────────┤
│  Layer 2: Container Orchestration (Kubernetes)           │
│  - Pod CPU/Memory 사용률                                  │
│  - Pod Restart Count, Pending Count                      │
│  └─> 병목: Pod OOMKilled, Scheduling 실패                │
├──────────────────────────────────────────────────────────┤
│  Layer 3: Load Balancer (ALB)                            │
│  - Target Response Time                                   │
│  - Surge Queue Length, Spillover Count                   │
│  └─> 병목: Backend 처리 지연, 큐 적체                     │
├──────────────────────────────────────────────────────────┤
│  Layer 4: Application (WAS)                              │
│  - HTTP 5xx Error Rate                                    │
│  - Request Latency (P50/P90/P99)                         │
│  └─> 병목: Application 로직 오류, 느린 쿼리               │
├──────────────────────────────────────────────────────────┤
│  Layer 5: Database (RDS)                                 │
│  - Disk Queue Depth, Read/Write Latency                 │
│  - Database Connections, CPU Utilization                 │
│  └─> 병목: Slow Query, Connection Pool 고갈              │
└──────────────────────────────────────────────────────────┘
```

---

## 🔑 핵심 설계 결정

### 1. CloudWatch Container Insights 선택

#### 구성: EKS Add-on 기반 자동 수집

```hcl
# EKS 모듈에서 Container Insights 활성화
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  configuration_values = jsonencode({
    agent = {
      config = {
        logs = {
          metrics_collected = {
            kubernetes = {
              enhanced_container_insights = true
            }
          }
        }
      }
    }
  })
}
```

#### 왜 Container Insights인가?

**대안 비교**

| 솔루션 | 데이터 수집 | 대시보드 | 비용 | 설정 복잡도 |
|--------|------------|----------|------|------------|
| **Container Insights** ✅ | Node + Pod + Service | CloudWatch 통합 | $3/월 (50 메트릭) | 낮음 (EKS Add-on) |
| Prometheus + Grafana | Node + Pod + Custom | Grafana (고급) | $0 (self-hosted) | 높음 (운영 부담) |
| Datadog | 전체 스택 | 강력 | $15/host/월 | 낮음 (Agent 설치) |
| New Relic APM | Application 중심 | 강력 | $99/월 | 중간 (APM Agent) |

**선택 이유: Container Insights**
- **AWS 네이티브 통합**: EKS → CloudWatch 자동 연동 (추가 설정 불필요)
- **낮은 운영 부담**: Prometheus/Grafana처럼 별도 서버 관리 불필요
- **비용 효율**: 포트폴리오 프로젝트에 적합한 가격대
- **충분한 기능**: Node/Pod/Service 메트릭 전부 수집

**트레이드오프**:
- Prometheus/Grafana 대비 커스터마이징 제한
- 고급 쿼리(PromQL 수준)는 불가능
- 메트릭 보관 기간: 15개월 (Prometheus는 무제한 설정 가능)

---

### 2. 병목현상 탐지 전략

#### Layer 1: Infrastructure 병목 (Node 리소스)

**핵심 메트릭**:

```hcl
# Node CPU 병목 탐지
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  threshold           = 80  # 80% 초과 시 알람
  evaluation_periods  = 2   # 10분 내 2번 초과
  period              = 300 # 5분 집계
  statistic           = "Average"
}
```

**병목 시나리오 및 근본 원인 분석**:

| 증상 | 근본 원인 | 해결 방법 |
|------|----------|----------|
| Node CPU > 80% | 1. WAS Pod CPU 과다 사용 (무한 루프, CPU-bound 작업) | Pod CPU Limit 확인, 프로파일링 |
| | 2. Pod 수 과다 (Overcommitment) | Node 추가, Pod 재배치 |
| | 3. Sidecar Container 리소스 소모 | 불필요한 Sidecar 제거 |
| Node Memory > 85% | 1. Memory Leak (Java Heap, Native Memory) | Heap Dump 분석, JVM 튜닝 |
| | 2. 캐시 비대화 (Redis, Caffeine) | 캐시 Eviction 정책 조정 |
| Node Disk > 80% | 1. 로그 파일 적재 | 로그 Rotation 설정 |
| | 2. 이미지 레이어 축적 | `docker image prune` 자동화 |

**Observability 포인트**:
- Node 메트릭 높으면 → Pod별 메트릭 Drill-down
- 특정 Pod가 원인이면 → Container 로그 분석

```bash
# Node CPU 병목 시 Drill-down
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=cpu

# 가장 많이 사용하는 Pod 로그 확인
kubectl logs -n was <pod-name> --tail=100
```

---

#### Layer 2: Container 병목 (Pod 리소스)

**핵심 메트릭**:

```hcl
# Pod CPU 병목 탐지
resource "aws_cloudwatch_metric_alarm" "pod_cpu_high" {
  metric_name         = "pod_cpu_utilization"
  namespace           = "ContainerInsights"
  threshold           = 80  # Pod CPU Request 대비 80%
  evaluation_periods  = 2
  period              = 300
  statistic           = "Average"

  dimensions = {
    ClusterName = var.eks_cluster_name
    Namespace   = "was"  # WAS Tier 집중 모니터링
  }
}

# Pod Memory 병목 탐지
resource "aws_cloudwatch_metric_alarm" "pod_memory_high" {
  metric_name         = "pod_memory_utilization"
  threshold           = 85
  # OOMKilled 직전 수준 (90% 이상 위험)
}

# Pod Restart 급증 (Crash Loop)
resource "aws_cloudwatch_metric_alarm" "pod_restart_high" {
  metric_name         = "pod_number_of_container_restarts"
  threshold           = 5   # 5분 내 3회 재시작 → 문제
  evaluation_periods  = 1
  period              = 300
}
```

**병목 시나리오**:

| 증상 | 근본 원인 | Observability 접근 |
|------|----------|-------------------|
| Pod CPU 80% 초과 | WAS가 CPU-bound 작업 수행 (대량 JSON 파싱, 암호화) | **1. Profiling**: Java Flight Recorder 활성화<br>**2. Code**: CPU 집약 로직 비동기 처리 |
| Pod Memory 85% 초과 | Java Heap 부족, Off-Heap 메모리 누수 | **1. Heap Dump**: `kubectl exec` → jmap<br>**2. JVM Flag**: `-XX:+HeapDumpOnOutOfMemoryError` |
| Pod Restart 급증 | OOMKilled, Liveness Probe 실패 | **1. Event 확인**: `kubectl describe pod`<br>**2. Exit Code**: 137 (OOMKilled), 1 (App Crash) |
| Pod Pending 상태 | Node 리소스 부족, Taints/Tolerations 미매치 | **1. Scheduler Event**: `kubectl describe pod`<br>**2. Node 여유 리소스**: `kubectl describe nodes` |

**Kubernetes Metrics 예시**:
```
pod_cpu_utilization: 85%
pod_memory_utilization: 78%
pod_number_of_container_restarts: 3 (5분 내)
pod_status_ready: 0 (Ready 상태 아님)
```

**자동 스케일링 연동**:
```yaml
# HPA (Horizontal Pod Autoscaler)
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: was-hpa
spec:
  scaleTargetRef:
    kind: Deployment
    name: was-deployment
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70  # 70% 초과 시 스케일 아웃
```

---

#### Layer 3: Load Balancer 병목 (ALB)

**핵심 메트릭**:

```hcl
# ALB Target Response Time (Backend 처리 시간)
resource "aws_cloudwatch_metric_alarm" "alb_target_response_time_high" {
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  threshold           = 2.0  # 2초 초과 시 병목
  statistic           = "Average"

  dimensions = {
    LoadBalancer = data.aws_lb.alb[0].arn_suffix
  }
}

# ALB Surge Queue Length (요청 대기 큐)
resource "aws_cloudwatch_metric_alarm" "alb_surge_queue_high" {
  metric_name         = "SurgeQueueLength"
  namespace           = "AWS/ApplicationELB"
  threshold           = 1024  # 큐가 쌓이기 시작 → Backend 처리 지연
  statistic           = "Maximum"
}

# ALB Spillover Count (큐 오버플로)
resource "aws_cloudwatch_metric_alarm" "alb_spillover" {
  metric_name         = "SpilloverCount"
  threshold           = 1  # 1건이라도 발생 → 심각한 병목
}

# ALB Unhealthy Host Count
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host" {
  metric_name         = "UnHealthyHostCount"
  threshold           = 1  # 1개 Pod라도 Unhealthy → 트래픽 몰림
}
```

**병목 시나리오**:

| 메트릭 | 정상 범위 | 병목 수준 | 근본 원인 분석 |
|--------|----------|----------|---------------|
| **TargetResponseTime** | < 500ms | > 2초 | **Backend 느림**: WAS 로직 지연, DB Slow Query<br>**확인**: CloudWatch Logs Insights → 느린 요청 추출 |
| **SurgeQueueLength** | 0 | > 1024 | **Backend 처리 속도 < 요청 유입 속도**<br>**해결**: Pod 수 증가, HPA 임계값 낮춤 |
| **SpilloverCount** | 0 | > 0 | **심각한 병목**: 큐 최대치(1024) 초과<br>**즉시 조치**: Manual Scale-out, Circuit Breaker 발동 |
| **UnHealthyHostCount** | 0 | ≥ 1 | **Pod 장애**: Readiness Probe 실패<br>**확인**: `kubectl get pods`, `kubectl logs` |

**Observability 시나리오**:

```
증상: TargetResponseTime 3초
   ↓
1. ALB Access Logs 확인 (S3)
   → 어떤 엔드포인트가 느린가? /api/owners/search
   ↓
2. WAS Pod 로그 확인 (CloudWatch Logs Insights)
   → SQL 쿼리 로그: "SELECT * FROM owners WHERE name LIKE '%kim%'" (Full Table Scan)
   ↓
3. RDS Performance Insights 확인
   → Top SQL: 해당 쿼리가 3초 소요, 1000번 실행
   ↓
근본 원인: Index 누락
해결: CREATE INDEX idx_owner_name ON owners(name);
```

---

#### Layer 4: Application 병목 (WAS)

**핵심 메트릭**:

```hcl
# HTTP 5xx Error Rate (Application 오류)
resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  threshold           = 10  # 5분 내 10건 이상 → 문제
  statistic           = "Sum"

  # Target 그룹별로 분리 (Web vs WAS)
  dimensions = {
    LoadBalancer = data.aws_lb.alb[0].arn_suffix
    TargetGroup  = "was-target-group"
  }
}

# Application Custom Metrics (선택 사항)
# Spring Boot Actuator + CloudWatch Agent
resource "aws_cloudwatch_metric_alarm" "jvm_heap_high" {
  metric_name         = "jvm.memory.used"
  namespace           = "SpringBoot"
  threshold           = 800000000  # 800MB (Heap 1GB 중 80%)
  statistic           = "Average"
}
```

**병목 시나리오**:

| 증상 | 근본 원인 | 로그 기반 분석 |
|------|----------|---------------|
| 5xx 급증 | 1. Unhandled Exception (NullPointerException)<br>2. DB Connection Pool 고갈<br>3. 외부 API 타임아웃 | **CloudWatch Logs Insights**:<br>`fields @timestamp, @message`<br>`| filter @message like /ERROR/`<br>`| stats count() by bin(5m)` |
| Latency P99 > 5s | 1. N+1 Query 문제<br>2. 동기 I/O 블로킹<br>3. GC Pause (Full GC) | **X-Ray Trace**:<br>각 메서드 실행 시간 분석<br>DB 쿼리 수 카운트 |
| JVM Heap 90% | 1. Memory Leak (ThreadLocal 미정리)<br>2. 캐시 비대화 (HashMap 무한 증가) | **Heap Dump 분석**:<br>`kubectl exec` → `jmap -dump`<br>Eclipse MAT로 Leak Suspect 확인 |

**Custom Metrics 수집 (Spring Boot 예시)**:

```java
// Spring Boot Actuator + Micrometer
@Configuration
public class MetricsConfig {
    @Bean
    public MeterRegistry meterRegistry() {
        return new CloudWatchMeterRegistry(
            CloudWatchConfig.DEFAULT,
            Clock.SYSTEM,
            cloudWatchAsyncClient()
        );
    }
}

// Controller에서 Custom Metric
@GetMapping("/api/owners")
public List<Owner> getOwners() {
    Timer.Sample sample = Timer.start(registry);
    List<Owner> owners = ownerService.findAll();
    sample.stop(Timer.builder("api.owners.duration")
        .tag("endpoint", "/api/owners")
        .register(registry));
    return owners;
}
```

---

#### Layer 5: Database 병목 (RDS)

**핵심 메트릭**:

```hcl
# RDS Disk Queue Depth (가장 중요한 병목 지표)
resource "aws_cloudwatch_metric_alarm" "rds_disk_queue_high" {
  metric_name         = "DiskQueueDepth"
  namespace           = "AWS/RDS"
  threshold           = 10  # 10 이상 → I/O 병목
  statistic           = "Average"

  dimensions = {
    DBInstanceIdentifier = "petclinic-db"
  }
}

# RDS Read Latency (읽기 지연)
resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  threshold           = 0.010  # 10ms 초과
  statistic           = "Average"
}

# RDS Write Latency (쓰기 지연)
resource "aws_cloudwatch_metric_alarm" "rds_write_latency_high" {
  metric_name         = "WriteLatency"
  threshold           = 0.020  # 20ms 초과
}

# RDS Database Connections (Connection Pool 고갈)
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  metric_name         = "DatabaseConnections"
  threshold           = 80  # db.t3.medium 최대 연결: 100개
}

# RDS CPU Utilization
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  metric_name         = "CPUUtilization"
  threshold           = 80  # 80% 초과 시 스케일업 고려
}

# RDS Freeable Memory Low
resource "aws_cloudwatch_metric_alarm" "rds_memory_low" {
  metric_name         = "FreeableMemory"
  threshold           = 500000000  # 500MB 미만
  comparison_operator = "LessThanThreshold"
}
```

**병목 시나리오 및 근본 원인**:

| 메트릭 | 정상 | 병목 | 근본 원인 | 해결 방법 |
|--------|------|------|----------|----------|
| **DiskQueueDepth** | < 5 | > 10 | **I/O Bottleneck**: Slow Query, Full Table Scan | **1. Performance Insights**: Top SQL 확인<br>**2. Index 추가**: 자주 조회되는 컬럼<br>**3. Query 최적화**: SELECT * 제거 |
| **ReadLatency** | < 5ms | > 10ms | Disk I/O 지연, Buffer Pool 부족 | **1. IOPS 증가**: gp3 → io1<br>**2. Read Replica**: 읽기 부하 분산 |
| **WriteLatency** | < 10ms | > 20ms | Multi-AZ 동기 복제 지연, 트랜잭션 과다 | **1. Batch Insert**: 개별 INSERT → Bulk<br>**2. Transaction 최적화**: 불필요한 트랜잭션 제거 |
| **DatabaseConnections** | < 50 | > 80 | Connection Pool 설정 오류, Connection Leak | **1. HikariCP 설정**:<br>`maximum-pool-size: 20` (WAS Pod당)<br>**2. Connection Leak 확인**: `SHOW PROCESSLIST` |
| **CPUUtilization** | < 50% | > 80% | CPU-bound Query (정렬, 집계, 정규표현식) | **1. Query Refactoring**: 복잡한 Join 단순화<br>**2. Stored Procedure**: 반복 쿼리 프로시저화 |
| **FreeableMemory** | > 2GB | < 500MB | Buffer Pool 부족, 메모리 파편화 | **1. Instance Class 업그레이드**: db.t3.medium → db.t3.large<br>**2. 불필요한 커넥션 정리** |

**RDS Performance Insights 활용**:

```sql
-- Performance Insights Top SQL 예시
SELECT
  digest_text,
  count_star AS exec_count,
  avg_timer_wait / 1000000000 AS avg_latency_ms
FROM performance_schema.events_statements_summary_by_digest
ORDER BY sum_timer_wait DESC
LIMIT 10;

-- 결과 예시:
-- SELECT * FROM visits WHERE owner_id = ? | 5000 | 250ms (병목!)
-- Index 필요: CREATE INDEX idx_visits_owner ON visits(owner_id);
```

**Connection Pool 설정 최적화**:

```yaml
# application.yml (Spring Boot)
spring:
  datasource:
    hikari:
      maximum-pool-size: 20     # Pod당 20개
      minimum-idle: 5
      connection-timeout: 30000  # 30초
      idle-timeout: 600000       # 10분
      max-lifetime: 1800000      # 30분

# 전체 연결 계산:
# WAS Pod 4개 × 20 = 80개 연결
# RDS db.t3.medium 최대: 100개
# 여유: 20개 (다른 서비스용)
```

---

### 3. CloudWatch Dashboard 구성

#### 설계: Single Pane of Glass (통합 대시보드)

```hcl
resource "aws_cloudwatch_dashboard" "eks_monitoring" {
  dashboard_name = "${var.environment}-eks-monitoring-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: 클러스터 전체 상태
      {
        type   = "metric"
        properties = {
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name],
            [".", "node_memory_utilization", ".", "."],
            [".", "pod_cpu_utilization", ".", "."],
            [".", "pod_memory_utilization", ".", "."]
          ]
          title  = "📊 Cluster Resource Utilization"
          period = 300
          stat   = "Average"
          region = var.aws_region
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      },

      # Row 2: ALB Performance (병목 탐지)
      {
        type   = "metric"
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix],
            [".", "RequestCount", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "SurgeQueueLength", ".", "."]
          ]
          title  = "🌐 ALB Performance & Bottleneck Detection"
          annotations = {
            horizontal = [
              {
                value = 2.0
                label = "Response Time Threshold (2s)"
                color = "#d13212"
              },
              {
                value = 1024
                label = "Surge Queue Threshold"
                color = "#ff9900"
              }
            ]
          }
        }
      },

      # Row 3: RDS Performance (Database Bottleneck)
      {
        type   = "metric"
        properties = {
          metrics = [
            ["AWS/RDS", "DiskQueueDepth", "DBInstanceIdentifier", "petclinic-db"],
            [".", "ReadLatency", ".", "."],
            [".", "WriteLatency", ".", "."],
            [".", "DatabaseConnections", ".", "."]
          ]
          title  = "💾 RDS Bottleneck Indicators"
          annotations = {
            horizontal = [
              {
                value = 10
                label = "Disk Queue Depth Threshold"
                color = "#d13212"
              },
              {
                value = 0.010
                label = "Read Latency Threshold (10ms)"
                color = "#ff9900"
              }
            ]
          }
        }
      },

      # Row 4: Pod-level Details (Drill-down)
      {
        type   = "log"
        properties = {
          query = <<-EOQ
            SOURCE '/aws/containerinsights/${var.eks_cluster_name}/application'
            | fields @timestamp, kubernetes.namespace_name, kubernetes.pod_name, log
            | filter kubernetes.namespace_name = 'was'
            | filter log like /ERROR/
            | stats count() by bin(5m)
          EOQ
          title  = "🔍 Application Error Logs (WAS)"
          region = var.aws_region
        }
      }
    ]
  })
}
```

**Dashboard 설계 원칙**:

1. **Top-Down 접근**: 전체 클러스터 → 개별 Pod → 로그 (Drill-down 가능)
2. **병목 우선**: 가장 자주 발생하는 병목 지표를 상단 배치
3. **Threshold 시각화**: Annotation으로 임계값 표시 (색상 코딩)
4. **시간 범위**: 기본 1시간, 최대 7일 (Zoom 가능)

---

### 4. CloudWatch Logs Insights (로그 기반 분석)

#### 병목 분석 쿼리 예시

**1. 느린 API 엔드포인트 탐지**:
```
fields @timestamp, @message
| filter @message like /duration/
| parse @message /duration=(?<duration>\d+)ms/
| filter duration > 1000
| stats count(), avg(duration), max(duration) by @message
| sort avg(duration) desc
```

**2. 5xx 오류 패턴 분석**:
```
fields @timestamp, @message
| filter @message like /ERROR/ or @message like /Exception/
| parse @message /(?<exception>[A-Z]\w+Exception)/
| stats count() by exception, bin(5m)
| sort count() desc
```

**3. Database Connection Pool 상태**:
```
fields @timestamp, @message
| filter @message like /HikariPool/ or @message like /Connection/
| parse @message /active=(?<active>\d+), idle=(?<idle>\d+), waiting=(?<waiting>\d+)/
| display @timestamp, active, idle, waiting
| sort @timestamp desc
```

**4. GC Pause 시간 분석** (JVM 로그):
```
fields @timestamp, @message
| filter @message like /Full GC/ or @message like /G1 Young/
| parse @message /\[GC pause.*?(?<pause_ms>\d+\.\d+) secs\]/
| stats avg(pause_ms), max(pause_ms), count() by bin(1h)
```

---

### 5. Lambda 기반 자동 복구

#### 구성: EventBridge → Lambda → Auto Scaling

```hcl
# Lambda 함수: Node CPU 높을 때 자동 스케일 아웃
resource "aws_lambda_function" "auto_scale_on_high_cpu" {
  filename      = "${path.module}/lambda/auto_scale.zip"
  function_name = "${var.environment}-eks-auto-scale"
  role          = aws_iam_role.lambda_auto_scale.arn
  handler       = "index.handler"
  runtime       = "python3.11"
  timeout       = 60

  environment {
    variables = {
      CLUSTER_NAME      = var.eks_cluster_name
      NODE_GROUP_NAME   = "was-nodes"
      MAX_SIZE          = 10
    }
  }
}

# EventBridge Rule: CloudWatch Alarm → Lambda 트리거
resource "aws_cloudwatch_event_rule" "high_cpu_trigger" {
  name        = "${var.environment}-high-cpu-auto-scale"
  description = "Node CPU 80% 초과 시 자동 스케일 아웃"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.node_cpu_high.alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "invoke_lambda" {
  rule      = aws_cloudwatch_event_rule.high_cpu_trigger.name
  target_id = "AutoScaleLambda"
  arn       = aws_lambda_function.auto_scale_on_high_cpu.arn
}
```

**Lambda 코드 예시** (`lambda/auto_scale.py`):
```python
import boto3
import os

eks = boto3.client('eks')

def handler(event, context):
    cluster_name = os.environ['CLUSTER_NAME']
    node_group_name = os.environ['NODE_GROUP_NAME']
    max_size = int(os.environ['MAX_SIZE'])

    # 현재 Node Group 설정 가져오기
    response = eks.describe_nodegroup(
        clusterName=cluster_name,
        nodegroupName=node_group_name
    )

    current_desired = response['nodegroup']['scalingConfig']['desiredSize']
    new_desired = min(current_desired + 2, max_size)  # 2개씩 증가

    # Node Group 스케일 아웃
    eks.update_nodegroup_config(
        clusterName=cluster_name,
        nodegroupName=node_group_name,
        scalingConfig={
            'desiredSize': new_desired,
            'minSize': 2,
            'maxSize': max_size
        }
    )

    print(f"Scaled {node_group_name} from {current_desired} to {new_desired}")

    return {
        'statusCode': 200,
        'body': f'Auto-scaled to {new_desired} nodes'
    }
```

**자동 복구 시나리오**:

```
1. Node CPU > 80% (10분 내 2번)
   ↓
2. CloudWatch Alarm: ALARM 상태 전환
   ↓
3. EventBridge: Alarm 이벤트 감지
   ↓
4. Lambda: auto_scale_on_high_cpu 실행
   ↓
5. EKS API: Node Group desired_size: 2 → 4
   ↓
6. 새로운 Node 2개 시작 (5분 소요)
   ↓
7. Pod 자동 재배치 (Pending → Running)
   ↓
8. Node CPU 정상화 (< 80%)
```

---

## 💰 비용 분석

### CloudWatch 비용 구조

| 항목 | 수량 | 단가 | 월 비용 |
|------|------|------|---------|
| **Container Insights 메트릭** | 50개 메트릭 | $0.30/메트릭 | $15 |
| **Custom Metrics** | 10개 (Application) | $0.30/메트릭 | $3 |
| **Log Ingestion** | 10GB/월 | $0.50/GB | $5 |
| **Log Storage** | 10GB × 30일 | $0.03/GB | $0.30 |
| **Dashboard** | 1개 | $3/월 | $3 |
| **Alarms** | 20개 | $0.10/알람 | $2 |
| **Lambda 실행** | 100회/월 | $0.20/100만 요청 | $0.02 |
| **총 합계** | | | **$28.32** |

### 비용 최적화 팁

1. **Log Retention 단축**: 30일 → 7일 (개발 환경)
2. **Metric Filter 사용**: 필요한 메트릭만 수집
3. **Aggregation**: Pod별 → Namespace별 집계로 메트릭 수 감소

---

## 🚀 배포 절차

```bash
cd /home/ubuntu/3tier-terraform/codes/aws/3.\ monitoring/

# 변수 파일 편집
cp terraform.tfvars.example terraform.tfvars
# Slack Webhook, Email 등 알림 채널 설정

# 배포
terraform init
terraform plan
terraform apply

# 배포 후 확인
aws cloudwatch list-dashboards
aws cloudwatch describe-alarms --alarm-names blue-eks-node-cpu-high
```

---

## 🔧 운영 가이드

### 병목 발생 시 대응 절차

#### 시나리오 1: Node CPU 병목

```bash
# 1. 현재 상태 확인
kubectl top nodes

# 2. Pod별 CPU 사용률
kubectl top pods --all-namespaces --sort-by=cpu

# 3. 가장 많이 사용하는 Pod 상세 확인
kubectl describe pod <pod-name> -n was

# 4. 프로파일링 (Java Flight Recorder)
kubectl exec -it <pod-name> -n was -- jcmd 1 JFR.start duration=60s filename=/tmp/profile.jfr
kubectl cp was/<pod-name>:/tmp/profile.jfr ./profile.jfr

# 5. 스케일 아웃 (임시 조치)
kubectl scale deployment was-deployment -n was --replicas=6
```

#### 시나리오 2: RDS DiskQueueDepth 병목

```bash
# 1. Performance Insights 확인
aws rds describe-db-instances --db-instance-identifier petclinic-db

# 2. Top SQL 쿼리 확인 (AWS Console)
# Performance Insights → Top SQL

# 3. Slow Query Log 활성화
aws rds modify-db-parameter-group \
  --db-parameter-group-name petclinic-params \
  --parameters "ParameterName=slow_query_log,ParameterValue=1,ApplyMethod=immediate"

# 4. Slow Query 확인
mysql -h <rds-endpoint> -u admin -p
mysql> SELECT * FROM mysql.slow_log ORDER BY query_time DESC LIMIT 10;

# 5. Index 추가 (근본 해결)
mysql> CREATE INDEX idx_owner_name ON owners(name);
```

---

## 📝 관련 문서

- **[Observability Best Practices (AWS)](https://aws.amazon.com/blogs/containers/observability-best-practices-for-amazon-eks/)**: AWS 공식 가이드
- **[CloudWatch Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html)**: 메트릭 상세
- **[RDS Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html)**: Database 병목 분석

---

**작성일**: 2026-01-13
**작성자**: I2ST-blue
**문서 버전**: 1.0
**관련 디렉토리**: `/codes/aws/3. monitoring/`
