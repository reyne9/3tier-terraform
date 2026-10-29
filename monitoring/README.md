# Prometheus & Grafana 인프라 모니터링 스택

이 디렉터리는 3-Tier PetClinic 인프라(Web/WAS/DB 호스트)의 상태를 실시간으로 수집하고 시각화하며, 시스템 이상 징후를 감지해 알림을 발송하는 모니터링 시스템을 포함합니다.

`ansible/roles/node_exporter`를 통해 각 인스턴스에 설치된 `node_exporter`의 지표(Metrics)를 Scrape하여 중앙 관제 센터 역할을 수행합니다.

---

## 🏗️ 모니터링 아키텍처

```text
+-----------------------+     +-----------------------+
|   Web Server (Nginx)  |     |   WAS Server (Spring) |
|  node_exporter (:9100)|     |  node_exporter (:9100)|
+-----------+-----------+     +-----------+-----------+
            |                             |
            +--------------+--------------+
                           | Pull (Scrape every 10s)
                           v
              +-------------------------+
              |       Prometheus        | <---> Alertmanager (:9093)
              |         (:9090)         |        (Email / Slack 임계치 알림)
              +------------+------------+
                           |
                           v Data Source
              +-------------------------+
              |         Grafana         |
              |         (:3000)         |
              | (자동 프로비저닝 대시보드)  |
              +-------------------------+
```

---

## 📁 디렉터리 구조

```text
monitoring/
├── docker-compose.yml                     # Prometheus, Grafana, Alertmanager 컨테이너 스택
├── .env.example                           # 포트 및 관리자 계정 환경 변수 템플릿
├── .gitignore                             # 시크릿 파일(.env) 및 영구 데이터 볼륨 제외
├── prometheus/
│   ├── prometheus.yml                     # Scrape 대상 호스트 및 주기 설정
│   └── rules/
│       └── host_alerts.yml                # CPU, 디스크, 메모리, 인스턴스 다운 경보 규칙
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── datasource.yml             # Prometheus 데이터소스 자동 연동
    │   └── dashboards/
    │       └── dashboard_provider.yml     # 대시보드 프로비저닝 설정
    └── dashboards/
        └── node_exporter_dashboard.json   # 호스트 메트릭 실시간 관제 대시보드 JSON
```

---

## 🚨 Prometheus 핵심 Alert Rules (`host_alerts.yml`)

가비아의 IaaS/시스템 엔지니어링 관점에서 서버 가용성과 자원 고갈을 선제적으로 예방하기 위해 설계되었습니다.

| 경보명 (Alert Name) | 임계 조건 (Expression) | 심각도 | 설명 |
| :--- | :--- | :---: | :--- |
| **`InstanceDown`** | `up == 0 for 1m` | **Critical** | 호스트 인스턴스가 1분 이상 응답하지 않는 장애 감지 |
| **`HostHighCpuLoadWarning`** | CPU 사용률 > 80% for 5m | Warning | CPU 지속 점유로 인한 프로세스 병목 위험 감지 |
| **`HostHighCpuLoadCritical`**| CPU 사용률 > 90% for 3m | **Critical** | 즉각적인 스케일아웃 또는 프로세스 확인이 필요한 고갈 상태 |
| **`HostDiskSpaceWarning`**   | 루트 디스크 잔여량 < 20% for 5m | Warning | 로그 폭증이나 임시 파일 축적으로 인한 디스크 경고 |
| **`HostDiskSpaceCritical`**  | 루트 디스크 잔여량 < 10% for 2m | **Critical** | I/O 장애 및 DB 락다운을 유발할 수 있는 디스크 고갈 임박 |
| **`HostMemoryUnderPressure`**| 메모리 사용률 > 90% for 5m | Warning | OOM(Out of Memory) Killer 작동 위험 예방 |

---

## 📊 Grafana 대시보드 주요 관제 지표

`grafana/dashboards/node_exporter_dashboard.json`은 Grafana 기동 시 별도 수동 설정 없이 자동 로드됩니다.

1. **인스턴스 Health 상태**: 각 계층(Web, WAS, DB)의 살아있는 인스턴스 UP/DOWN 상태 표시
2. **CPU & 메모리 사용률 (Gauge & Timeseries)**: 유휴 시간(idle)을 제외한 실제 시스템 리소스 사용량 추이
3. **루트 디스크 사용률 (Gauge)**: `/` 파티션의 실시간 잔여 공간
4. **네트워크 I/O 추이 (TX / RX)**: 가상 인터페이스를 제외한 물리 인터페이스 기준 초당 송수신 바이트 추적
5. **Load Average 추이**: 1분, 5분, 15분 단위의 커널 런큐(Run queue) 부하 추이
6. **시스템 Uptime**: 마지막 리부팅 이후 가동 시간

---

## 🚀 실행 방법

### 1. 환경 변수 파일 생성
```bash
cd monitoring
cp .env.example .env
# 필요에 따라 .env 파일의 패스워드 수정
```

### 2. Scrape 대상 IP 확인 (`prometheus/prometheus.yml`)
Ansible 프로비저닝 결과로 할당된 Web(`10.0.1.10`), WAS(`10.0.2.10`) IP가 올바른지 확인합니다.

### 3. Docker Compose 스택 기동
```bash
docker compose up -d
```

### 4. 웹 콘솔 접속
* **Grafana**: `http://<호스트IP>:3000` (ID: `admin` / PW: `.env`에 설정한 암호)
  * 로그인 시 "PetClinic Infrastructure" 폴더 내에 "PetClinic 호스트 인프라 관제 대시보드"가 자동으로 마운트되어 있습니다.
* **Prometheus**: `http://<호스트IP>:9090`
  * `Status` → `Targets`: 각 인스턴스 node_exporter 수집 상태 확인
  * `Alerts`: 정의된 Alert Rules 상태(Inactive, Pending, Firing) 확인
