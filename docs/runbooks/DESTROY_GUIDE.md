# Terraform Destroy 가이드

AWS Load Balancer Controller가 만든 ALB, Target Group, ENI가 남아 있으면 VPC와 Security Group 삭제가 실패할 수 있다. 현재 EKS module에는 destroy-time cleanup provisioner가 있지만, 자동 정리만 믿지 말고 삭제 대상을 먼저 확인한다.

## AWS Service 안전 삭제

```bash
cd "codes/aws/2. service"

# 1. 데이터 보존 설정 확인
terraform plan -destroy

# 2. Controller가 만든 외부 리소스 제거
kubectl delete ingress -n web web-ingress
kubectl get ingress -A
kubectl get svc -A

# 3. ALB/Target Group/ENI 상태 확인
VPC_ID=$(terraform output -raw vpc_id)

aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${VPC_ID}'].[LoadBalancerName,State.Code]" \
  --output table

aws elbv2 describe-target-groups \
  --query "TargetGroups[?VpcId=='${VPC_ID}'].[TargetGroupName,TargetGroupArn]" \
  --output table

aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[*].[NetworkInterfaceId,Status,Description]' \
  --output table

# 4. 삭제
terraform destroy
```

## Cleanup provisioner

`codes/aws/2. service/modules/eks/main.tf`의 `null_resource.cleanup_k8s_resources`는 destroy 시 다음 정리를 시도한다.

- VPC의 Load Balancer 삭제
- Target Group 삭제
- 사용 가능한 ENI 삭제
- retry와 대기

AWS API 지연이나 다른 resource 소유권 때문에 실패할 수 있으므로 성공을 보장하는 기능으로 표현하지 않는다.

## Security Group DependencyViolation

먼저 어떤 ENI가 Security Group을 참조하는지 확인한다.

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=<security-group-id>" \
  --query 'NetworkInterfaces[*].[NetworkInterfaceId,Status,Description,Attachment.InstanceId]' \
  --output table
```

연결된 Load Balancer, NAT Gateway, EKS, RDS 리소스를 소유 서비스에서 먼저 삭제한다. 소유권을 확인하지 않고 ENI를 강제 삭제하지 않는다.

## Azure 긴급 계층 삭제

AWS 복구와 데이터 보존을 확인한 뒤:

```bash
cd codes/azure/2-emergency
terraform plan -destroy
terraform destroy
```

`codes/azure/1-always`는 다음 상시 리소스를 포함하므로 함께 삭제하지 않는다.

- Front Door
- Storage Account와 backup
- Static Website
- VNet/Subnet

## 삭제 전 체크리스트

- [ ] 마지막 정상 DB backup 확인
- [ ] RDS final snapshot/skip setting 확인
- [ ] CloudFront와 Front Door endpoint 영향 확인
- [ ] Kubernetes Ingress/LoadBalancer Service 삭제
- [ ] ALB/Target Group/ENI 상태 확인
- [ ] `terraform plan -destroy` 검토

## 삭제 후 체크리스트

- [ ] Terraform state에 예상치 못한 resource가 남지 않음
- [ ] AWS ALB, EIP, NAT Gateway, ENI 확인
- [ ] Azure `2-emergency` 리소스만 삭제됨
- [ ] Azure `1-always` backup과 Front Door 유지
- [ ] CloudWatch log와 snapshot 보존 비용 확인
