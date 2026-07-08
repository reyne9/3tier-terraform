# Terraform Destroy 가이드

> **중요**: 이 가이드는 Terraform destroy 시 발생하는 Security Group 의존성 에러를 해결한 최신 버전입니다.

## 🎯 빠른 가이드

### 안전한 Destroy (권장)

```bash
# 1. Kubernetes 리소스 먼저 삭제
kubectl delete ingress --all --all-namespaces
kubectl delete svc --type=LoadBalancer --all --all-namespaces

# 2. AWS 리소스 정리 대기 (3분)
sleep 180

# 3. Terraform destroy
cd /home/ubuntu/3tier-terraform/codes/aws/2.\ service
terraform destroy
```

### 빠른 Destroy

```bash
# cleanup provisioner가 자동으로 정리
cd /home/ubuntu/3tier-terraform/codes/aws/2.\ service
terraform destroy
```

---

## 🔧 무엇이 수정되었나?

### ✅ 자동 정리 기능 추가

Terraform destroy 실행 시 다음 리소스들이 **자동으로 정리**됩니다:

1. **ALB/NLB (Load Balancer)** - Kubernetes Ingress가 생성한 로드밸런서
2. **Target Groups** - ALB/NLB의 타겟 그룹
3. **ENI (Elastic Network Interfaces)** - 로드밸런서의 네트워크 인터페이스
4. **적절한 대기 시간** - 리소스 완전 삭제 보장

### 🛡️ 에러 방지

이제 다음 에러들이 **발생하지 않습니다**:

```
❌ Error: deleting Security Group: DependencyViolation
❌ Error: /bin/sh: Syntax error
❌ Error: Missing map element "region"
```

---

## 📋 Destroy 프로세스

```
terraform destroy 실행
    ↓
EKS 클러스터 삭제 시작
    ↓
[자동] Load Balancer 조회 및 삭제
    ↓
[대기] 30초 (ALB/NLB 완전 삭제)
    ↓
[자동] Target Group 삭제
    ↓
[자동] ENI 삭제 ⭐ Security Group 의존성 해결
    ↓
[대기] 20초 (의존성 완전 해제)
    ↓
Security Group 삭제
    ↓
✅ 완료!
```

---

## 🚨 트러블슈팅

### 그래도 Security Group 에러가 발생한다면?

```bash
# VPC ID 확인
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "vpc-xxxxxx")

# 수동으로 모든 리소스 정리
bash <<EOF
# Load Balancer 삭제
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
  --output text | xargs -n1 -I {} aws elbv2 delete-load-balancer --load-balancer-arn {}

sleep 30

# Target Group 삭제
aws elbv2 describe-target-groups \
  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
  --output text | xargs -n1 -I {} aws elbv2 delete-target-group --target-group-arn {}

# ENI 삭제
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
  --output text | xargs -n1 -I {} aws ec2 delete-network-interface --network-interface-id {}

sleep 20
EOF

# 다시 destroy 실행
terraform destroy
```

### Region 관련 에러가 발생한다면?

```bash
# 환경 변수로 region 명시
export AWS_DEFAULT_REGION=ap-northeast-2
terraform destroy
```

---

## 📖 상세 문서

- **[troubleshooting.md](/docs/runbooks/troubleshooting.md)** - 주요 오류 원인과 해결 방법
- **[deployment-guide.md](/docs/runbooks/deployment-guide.md)** - 배포와 삭제 전후 점검 흐름

---

## ✅ 체크리스트

### Destroy 실행 전

- [ ] 중요 데이터 백업 완료
- [ ] RDS 스냅샷 확인 (`terraform.tfvars`에서 `rds_skip_final_snapshot = false` 설정)
- [ ] Kubernetes 리소스 정리 (선택사항, 자동 정리됨)

### Destroy 실행 중

- [ ] Cleanup provisioner 로그 확인
- [ ] Load Balancer 삭제 메시지 확인
- [ ] ENI 삭제 메시지 확인

### Destroy 완료 후

- [ ] AWS Console에서 모든 리소스 삭제 확인
- [ ] `terraform.tfstate` 파일 확인 (리소스 0개)
- [ ] 예상치 못한 비용 발생 여부 확인

---

## 💰 비용 최적화

Destroy 전 확인:
- RDS 스냅샷 보관 비용
- EBS 볼륨 스냅샷
- Elastic IP (미사용 시 과금)
- CloudWatch Logs 보관

---

## 🆘 도움이 필요한가요?

1. **검증 먼저**: `terraform validate`
2. **계획 확인**: `terraform plan -destroy`
3. **로그 확인**: destroy 중 cleanup 메시지 확인
4. **문서 참조**: [troubleshooting.md](/docs/runbooks/troubleshooting.md)
