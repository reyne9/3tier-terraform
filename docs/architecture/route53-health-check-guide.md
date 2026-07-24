# Route 53 Health Check 가이드

Route 53 health check는 장애 관측용이다. 현재 사용자 도메인은 CloudFront Alias이며 DNS failover record가 아니다.

## 코드 기준 Health Check

`codes/aws/1. route53/main.tf`는 다음 대상을 확인한다.

| 대상 | 방식 | 목적 |
|---|---|---|
| AWS ALB | HTTP:80 | AWS Origin 직접 상태 |
| CloudFront 사용자 도메인 | HTTPS_STR_MATCH:443 | End-to-end 상태 |
| Azure Blob Static Website | HTTPS:443 | 점검 페이지 상태 |

실제 ID는 Terraform output으로 조회한다.

```bash
cd "codes/aws/1. route53"
terraform output -json health_check_ids
terraform output -json health_check_config
terraform output -json health_check_commands
```

개별 상태 확인:

```bash
AWS_CHECK_ID=$(terraform output -json health_check_ids | jq -r '.aws_alb_health_check_id')

aws route53 get-health-check-status \
  --health-check-id "$AWS_CHECK_ID"
```

## 장애 전환과의 관계

- Route 53 health check: 관측
- CloudFront Origin Group: AWS ALB 장애 시 Azure Front Door의 HTTPS 점검 페이지로 GET/HEAD 전환
- Azure Front Door health probe: 별도 Front Door endpoint의 priority Origin 선택

Route 53 health check 결과가 Front Door의 Origin 상태를 직접 제어하지 않는다.

## 진단 순서

1. `dig`로 사용자 도메인이 CloudFront Alias를 가리키는지 확인한다.
2. AWS ALB health check 상태를 확인한다.
3. CloudFront end-to-end health check를 확인한다.
4. Azure Blob health check를 확인한다.
5. Front Door 문제라면 Azure CLI에서 `failover-group` Origin 상태를 별도로 확인한다.

```bash
dig "<custom-domain>"
curl -I "https://<custom-domain>/"

az afd origin list \
  --resource-group "<resource-group>" \
  --profile-name "afd-multicloud-<environment>" \
  --origin-group-name failover-group \
  --output table
```

## 주의사항

- 문서에 health check ID나 endpoint를 고정하지 않는다.
- `health_check_search_string` 기본값은 `PetClinic`이다. 실제 응답 본문에 문자열이 없으면 end-to-end check가 실패한다.
- CloudFront 정상 여부와 AWS ALB 정상 여부를 구분한다.
- 사용자 도메인은 CloudFront를 가리키고, Front Door endpoint는 CloudFront의 Azure Origin으로 사용한다.
