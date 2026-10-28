# Ansible 자동화 가이드 (3-Tier PetClinic Provisioning)

이 디렉터리는 Terraform으로 프로비저닝된 인스턴스(AWS EC2, OpenStack VM 등)를 대상으로 운영체제 설정, 보안 하드닝, 미들웨어(Web/WAS) 구성, 모니터링 에이전트 설치를 자동화하는 Ansible 코드를 포함합니다.

---

## 📁 디렉터리 구조

```text
ansible/
├── ansible.cfg                    # Ansible 기본 설정 (ssh_args, roles_path, timeout 등)
├── inventory/
│   ├── hosts.ini.example          # 인벤토리 예시 (Web, WAS, DB 서버 그룹 정의)
│   └── group_vars/
│       ├── all.yml.example        # 공통 환경 변수 (SSH 하드닝, node_exporter 버전 등)
│       ├── webservers.yml.example # Web(Nginx) 전용 변수 (WAS 프록시 주소, 포트)
│       └── wasservers.yml.example # WAS(Spring/Tomcat) 전용 변수 (DB 연결, JVM 옵션)
├── playbooks/
│   ├── common.yml                 # 필수 유틸리티 설치 및 보안 하드닝
│   ├── web.yml                    # Nginx 리버스 프록시 구성
│   ├── was.yml                    # Spring Boot(Tomcat) systemd 서비스 배포
│   └── monitoring.yml             # Prometheus node_exporter 배포
├── roles/
│   ├── common/                    # OS 기본 패키지, 배포자 계정 관리, SSH 하드닝
│   ├── nginx/                     # Nginx 설치, 리버스 프록시 및 정적 캐싱, 방화벽(80)
│   ├── tomcat/                    # OpenJDK 17, 전용 계정/디렉터리, systemd 데몬 등록
│   └── node_exporter/             # 공식 바이너리 다운로드, systemd 데몬 등록, 포트(9100)
└── site.yml                       # 전체 프로비저닝 메인 플레이북
```

---

## 🔒 보안 및 멱등성 (Idempotency) 설계 원칙

1. **SSH 보안 하드닝 (`roles/common`)**:
   * Root 원격 로그인 차단 (`PermitRootLogin no`)
   * 패스워드 인증 비활성화 및 SSH 키 기반 인증 강제 (`PasswordAuthentication no`, `PubkeyAuthentication yes`)
   * 패스워드 없는 sudo 권한을 갖는 전용 배포 사용자(`deployer`) 격리
   * fail2ban 활성화로 무차별 대입 공격(Brute Force) 방어
2. **최소 권한의 원칙 (`roles/tomcat`)**:
   * root가 아닌 시스템 계정(`petclinic:petclinic`)으로 애플리케이션 데몬 실행
   * systemd 리소스 제한(`LimitNOFILE=65535`)으로 대용량 트래픽 대비
3. **멱등성 보장**:
   * 패키지, 설정 파일 템플릿, 사용자/디렉터리 생성 및 서비스 데몬 등록 시 반복 실행해도 동일한 결과를 보장하도록 Ansible core 모듈 위주로 구성되었습니다.

---

## 🚀 빠른 시작

### 1. 인벤토리 및 변수 설정
```bash
cd ansible
cp inventory/hosts.ini.example inventory/hosts.ini
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
cp inventory/group_vars/webservers.yml.example inventory/group_vars/webservers.yml
cp inventory/group_vars/wasservers.yml.example inventory/group_vars/wasservers.yml

# inventory/hosts.ini 및 group_vars 파일들을 환경에 맞게 편집
vi inventory/hosts.ini
```

### 2. 접속 연결 테스트 (Ping)
```bash
ansible -i inventory/hosts.ini all -m ping
```

### 3. 문법 및 Dry-run 검사
```bash
# 구문 검사
ansible-playbook -i inventory/hosts.ini site.yml --syntax-check

# Dry-run (Check 모드)
ansible-playbook -i inventory/hosts.ini site.yml --check
```

### 4. 전체 프로비저닝 실행
```bash
ansible-playbook -i inventory/hosts.ini site.yml
```

### 5. 개별 역할별 실행 (필요 시)
```bash
# Web 서버만 재설정
ansible-playbook -i inventory/hosts.ini playbooks/web.yml

# 모니터링 에이전트만 재배포
ansible-playbook -i inventory/hosts.ini playbooks/monitoring.yml
```
