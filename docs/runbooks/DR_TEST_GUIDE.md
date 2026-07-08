# DR (Disaster Recovery) 테스트 가이드

## 테스트 시나리오

**Azure Front Door 기반 자동 Failover**

1. **장애 발생 (즉시)**: Azure Front Door가 자동으로 Azure Blob Storage로 failover (정적 유지보수 페이지)
2. **장애 장기화 (30분+)**: Azure AKS 배포 → Front Door Origin을 AKS로 전환 (전체 기능 복구)
3. **장애 복구**: AWS 복구 → Front Door Origin을 AWS로 failback

**소요 시간**:
- 자동 Failover: 즉시 (30초 이내)
- 완전 복구: 30-40분 (AKS 배포 포함)

---

## Phase 1: 모의 장애 발생

```bash
./scripts/simulate-failure.sh
```

**예상 결과**: Azure Blob Storage 유지보수 페이지 표시 (30초 이내)

---

## Phase 2: Azure AKS 배포 (장애 장기화 시)

```bash
# 1. Azure 인프라 배포
cd codes/azure/2-emergency
terraform init
terraform apply -auto-approve

# 2. AKS 자격증명
az aks get-credentials --resource-group rg-dr-blue --name aks-dr-blue --overwrite-existing

# 3. DB 복원
cd scripts
./restore-db.sh

# 4. 애플리케이션 배포
./deploy-petclinic.sh
```

**소요 시간**: 약 15-20분

---

## Phase 3: Front Door Origin 전환 (완전 복구)

```bash
# Azure AKS Origin 추가
APPGW_IP=$(az network public-ip show -g rg-dr-blue --name pip-appgw-dr-blue --query ipAddress -o tsv)

az afd origin create \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name azure-aks-appgw \
  --host-name $APPGW_IP \
  --origin-host-header $APPGW_IP \
  --priority 2 \
  --weight 1000 \
  --enabled-state Enabled \
  --http-port 80

# Azure Blob Origin 비활성화
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name azure-blob-secondary \
  --enabled-state Disabled
```

**예상 결과**: GET/POST 모두 정상 작동

---

## Phase 4: AWS 복구

```bash
# AWS Pod 재시작
kubectl config use-context arn:aws:eks:ap-northeast-2:ACCOUNT_ID:cluster/blue-eks
kubectl scale deployment petclinic-was -n was --replicas=2
kubectl scale deployment web-nginx -n web --replicas=2
```

**대기 시간**: 2-3분 (Pod 시작)

---

## Phase 5: Failback (AWS로 복귀)

**중요**: Azure Front Door는 Priority 기반 라우팅을 사용하지만, 한번 failover된 후 자동으로 failback하지 않습니다. **수동 전환**이 필요합니다.

### 방법 1: Azure Blob Origin 비활성화 (권장)

```bash
# 1. Azure Blob Origin 비활성화하여 강제로 AWS로 전환
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name azure-blob-secondary \
  --enabled-state Disabled

# 2. 30초 대기 후 테스트
sleep 30
curl -s https://blueisthenewblack.store/ | grep -i petclinic

# 3. 확인 후 Azure Blob Origin 재활성화 (백업용)
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name azure-blob-secondary \
  --enabled-state Enabled
```

### 방법 2: AWS Origin 토글

```bash
# 1. AWS Origin 일시 비활성화
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name aws-alb-primary \
  --enabled-state Disabled

# 2. 5초 대기
sleep 5

# 3. AWS Origin 재활성화
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name aws-alb-primary \
  --enabled-state Enabled

# 4. 30초 대기 후 테스트
sleep 30
curl -s https://blueisthenewblack.store/ | grep -i petclinic
```

### Azure AKS가 배포된 경우

```bash
# Azure AKS Origin 비활성화
az afd origin update \
  -g rg-dr-blue \
  --profile-name afd-multicloud-dr \
  --origin-group-name failover-group \
  --origin-name azure-aks-appgw \
  --enabled-state Disabled
```

**예상 결과**: 트래픽이 AWS ALB로 복귀 (Priority 1)

---

## Phase 6: Azure 리소스 정리 (선택사항)

```bash
cd codes/azure/2-emergency
terraform destroy -auto-approve
```

---

## 주요 스크립트

- **장애 시뮬레이션**: `./scripts/simulate-failure.sh`
- **DB 복원**: `./codes/azure/2-emergency/scripts/restore-db.sh`
- **애플리케이션 배포**: `./codes/azure/2-emergency/scripts/deploy-petclinic.sh`

---

## 아키텍처

```
Azure Front Door (Global)
├─ Origin Group: failover-group
│  ├─ Priority 1: AWS ALB (primary)
│  ├─ Priority 2: Azure AKS App Gateway (장애 장기화 시)
│  └─ Priority 3: Azure Blob Storage (정적 페이지, 기본 failover)
└─ Custom Domain: blueisthenewblack.store

Health Probe: HTTP / (30초 간격)
Failover 조건: 3회 연속 실패
```

---

## 테스트 체크리스트

- [ ] Phase 1: AWS 장애 시 Azure Blob으로 자동 failover (30초 이내)
- [ ] Phase 2: Azure AKS 배포 완료 (15-20분)
- [ ] Phase 3: Azure AKS Origin 전환 후 GET/POST 정상
- [ ] Phase 4: AWS 복구 완료
- [ ] Phase 5: AWS로 Failback 완료
- [ ] Phase 6: Azure 리소스 정리

---

## 참고사항

**Azure Front Door vs CloudFront**:
- ✅ POST/PUT/DELETE 완전 지원
- ✅ Multi-cloud failover (AWS + Azure)
- ✅ 자동 health check 및 failover
- ✅ Custom domain 및 SSL

**현재 구성**:
- Front Door Profile: `afd-multicloud-dr`
- Endpoint: `multicloud-endpoint-d8cah5e8ergrckg4.a03.azurefd.net`
- Custom Domain: `blueisthenewblack.store` (설정 진행 중)
