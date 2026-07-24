# AWS 모니터링 구현 상세

**코드 위치**: `codes/aws/3. monitoring/`

## 구성 요소

- CloudWatch Log Group
  - Container Insights
  - Application log
  - Lambda log
- CloudWatch Dashboard
- CloudWatch Metric Alarm
- Route 53 health check alarm
- SNS topic
- Email subscription
- AWS Chatbot Slack channel
- Lambda auto recovery

## Alarm 범위

### EKS node

- CPU
- Memory
- Disk
- Status check
- Node count

### Pod/container

- Pod CPU/Memory
- Restart
- Network RX/TX
- Container CPU/Memory
- Service count

### ALB

- Surge queue
- ALB 5xx
- Target 5xx
- Latency
- Unhealthy host

ALB 관련 alarm은 ALB 이름/ARN suffix 입력 여부에 따라 조건부 생성된다.

### RDS

- Free storage
- Connection
- Disk queue
- CPU
- Read/Write latency
- Freeable memory

RDS identifier가 없으면 관련 alarm은 조건부로 생성되지 않는다.

### Route 53

- Primary/secondary health
- Health percentage
- AWS ALB health
- All sites down composite alarm

`enable_route53_monitoring`과 health check ID 입력값에 따라 조건부 생성된다.

Route 53 alarm은 CloudFront 경로의 관측이다. Azure Front Door health probe나 diagnostic log를 이 module이 수집하지 않는다.

## 알림

- 기본 SNS topic
- Route 53 전용 SNS topic
- Email subscription
- AWS Chatbot Slack configuration

Slack workspace/channel ID가 비어 있으면 Chatbot resource가 조건부로 생성되는지 Terraform expression을 확인하고 plan 결과를 기준으로 판단한다.

## Lambda auto recovery

`archive_file` data source가 `lambda/index.py`를 zip으로 만들고 Lambda를 배포한다. SNS topic이 Lambda를 호출한다.

문서에서 “자동 복구”라고 표현할 때는 Lambda code가 처리하는 alarm 종류와 action을 함께 확인해야 한다. 모든 장애를 자동 복구한다고 설명하지 않는다.

## 배포

```bash
cd "codes/aws/3. monitoring"
terraform init
terraform validate
terraform plan
terraform apply
```

필수 data source 대상:

- EKS cluster
- Node group
- ALB
- RDS

대상이 먼저 생성되어 있어야 한다.

## Output

```bash
terraform output -raw dashboard_url
terraform output -raw sns_topic_arn
terraform output -raw auto_recovery_lambda_name
terraform output -json alarm_arns
terraform output -json route53_alarms
```

알람 개수는 조건부 resource와 입력값에 따라 달라지므로 고정 숫자로 설명하지 않는다.

## 구현 범위 밖

- Azure Front Door diagnostic setting
- Azure Monitor/Log Analytics
- Application Gateway diagnostic log
- AKS Container Insights

이 항목은 현재 AWS monitoring module에 구현되지 않았다.
