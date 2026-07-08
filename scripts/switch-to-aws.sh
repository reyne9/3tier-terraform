#!/bin/bash

###############################################################################
# CloudFront Traffic Failback to AWS
#
# Description: 장애 복구 후 CloudFront를 AWS ALB로 복귀
# Usage: ./switch-to-aws.sh
###############################################################################

set -e

CLOUDFRONT_ID="E2OX3Z0XHNDUN"
LAMBDA_ARN="arn:aws:lambda:us-east-1:ACCOUNT_ID:function:CloudFrontFailover:1"

echo "========================================="
echo "CloudFront Failback to AWS"
echo "========================================="
echo ""

# Step 1: AWS 상태 확인
echo "[1/6] Checking AWS infrastructure status..."

# EKS 컨텍스트로 전환
kubectl config use-context arn:aws:eks:ap-northeast-2:ACCOUNT_ID:cluster/blue-eks > /dev/null 2>&1

# Pod 상태 확인
WAS_PODS=$(kubectl get pods -n was --no-headers 2>/dev/null | wc -l)
WEB_PODS=$(kubectl get pods -n web --no-headers 2>/dev/null | wc -l)

if [ "$WAS_PODS" -eq 0 ] || [ "$WEB_PODS" -eq 0 ]; then
  echo "WARNING: AWS pods are not running!"
  echo "WAS Pods: $WAS_PODS"
  echo "WEB Pods: $WEB_PODS"
  echo ""
  read -p "Do you want to continue failback anyway? (yes/no): " CONTINUE

  if [ "$CONTINUE" != "yes" ]; then
    echo "Failback cancelled"
    exit 1
  fi
fi

echo "✓ AWS infrastructure check complete"
echo "  WAS Pods: $WAS_PODS"
echo "  WEB Pods: $WEB_PODS"
echo ""

# Step 2: Health Check 확인
echo "[2/6] Checking Route53 Health Check..."
HEALTH_STATUS=$(aws route53 get-health-check-status \
  --health-check-id 0499007e-e628-4a48-aa9c-a9337e320fdd \
  --query 'HealthCheckObservations[0].StatusReport.Status' \
  --output text 2>/dev/null || echo "Unknown")

echo "  Health Check Status: $HEALTH_STATUS"

if [[ ! "$HEALTH_STATUS" =~ "Success" ]]; then
  echo "WARNING: Health check is not healthy"
  echo ""
  read -p "Do you want to continue failback anyway? (yes/no): " CONTINUE

  if [ "$CONTINUE" != "yes" ]; then
    echo "Failback cancelled"
    exit 1
  fi
fi

echo ""

# Step 3: 현재 CloudFront 설정 백업
echo "[3/6] Backing up current CloudFront configuration..."
BACKUP_FILE="/tmp/cloudfront-config-failback-$(date +%Y%m%d-%H%M%S).json"
aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --output json > "$BACKUP_FILE"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: Failed to backup CloudFront configuration"
  exit 1
fi

echo "✓ Backup saved to: $BACKUP_FILE"
echo ""

# Step 4: 설정 수정
echo "[4/6] Preparing CloudFront configuration for AWS..."
ETAG=$(cat "$BACKUP_FILE" | jq -r '.ETag')

cat "$BACKUP_FILE" | jq '.DistributionConfig' | jq '
# Default Behavior를 AWS ALB로 복귀하고 Lambda@Edge 재활성화
.DefaultCacheBehavior.TargetOriginId = "primary-aws-alb" |
.DefaultCacheBehavior.LambdaFunctionAssociations = {
  "Quantity": 1,
  "Items": [
    {
      "LambdaFunctionARN": "arn:aws:lambda:us-east-1:ACCOUNT_ID:function:CloudFrontFailover:1",
      "EventType": "origin-response",
      "IncludeBody": false
    }
  ]
} |
.Comment = "Multi-Cloud DR with Origin Failover (Restored to AWS at '"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"')"
' > /tmp/cf-aws-config.json

echo "✓ Configuration prepared"
echo ""

# Step 5: CloudFront 업데이트
echo "[5/6] Updating CloudFront distribution..."
echo "This may take 5-10 minutes..."

aws cloudfront update-distribution \
  --id "$CLOUDFRONT_ID" \
  --distribution-config file:///tmp/cf-aws-config.json \
  --if-match "$ETAG" \
  --output json > /tmp/cf-failback-result.json

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to update CloudFront"
  echo "Backup file: $BACKUP_FILE"
  exit 1
fi

echo "✓ CloudFront update initiated"
echo ""

# Step 6: 배포 완료 대기
echo "[6/6] Waiting for CloudFront deployment..."

for i in {1..40}; do
  STATUS=$(aws cloudfront get-distribution --id "$CLOUDFRONT_ID" --query 'Distribution.Status' --output text)

  if [ "$STATUS" = "Deployed" ]; then
    echo ""
    echo "✓ CloudFront deployment complete!"
    break
  fi

  echo -n "."
  sleep 15

  if [ $i -eq 40 ]; then
    echo ""
    echo "WARNING: Deployment is taking longer than expected"
    echo "Check status manually: aws cloudfront get-distribution --id $CLOUDFRONT_ID"
  fi
done

echo ""
echo "========================================="
echo "Failback Complete!"
echo "========================================="
echo ""
echo "Traffic is now routed to AWS ALB with Lambda@Edge failover enabled"
echo ""
echo "Next steps:"
echo "1. Invalidate CloudFront cache (optional, for immediate effect):"
echo "   aws cloudfront create-invalidation --distribution-id $CLOUDFRONT_ID --paths '/*'"
echo ""
echo "2. Test the website:"
echo "   curl -I https://blueisthenewblack.store/"
echo ""
echo "3. Monitor AWS resources:"
echo "   kubectl get pods -n was -n web"
echo ""
echo "4. Clean up Azure resources (optional, to save costs):"
echo "   cd codes/azure/2-emergency"
echo "   terraform destroy"
echo ""
echo "Backup file location: $BACKUP_FILE"
echo ""
