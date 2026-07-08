#!/bin/bash

###############################################################################
# AWS 장애 시뮬레이션 스크립트
#
# Description: AWS EKS 워크로드를 중단하여 장애 상황을 시뮬레이션
# Usage: ./simulate-failure.sh
###############################################################################

set -e

echo "========================================="
echo "AWS Failure Simulation"
echo "========================================="
echo ""
echo "WARNING: This will scale down all pods in AWS EKS"
echo "This is a SIMULATED FAILURE for DR testing"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled"
  exit 0
fi

echo ""
echo "[1/3] Switching to AWS EKS context..."
kubectl config use-context arn:aws:eks:ap-northeast-2:ACCOUNT_ID:cluster/blue-eks

echo ""
echo "[2/3] Scaling down WAS deployment..."
kubectl scale deployment was-spring -n was --replicas=0

echo ""
echo "[3/3] Scaling down WEB deployment..."
kubectl scale deployment web-nginx -n web --replicas=0

echo ""
echo "Waiting for pods to terminate..."
sleep 10

echo ""
echo "========================================="
echo "Current Pod Status:"
echo "========================================="
kubectl get pods -n was
echo ""
kubectl get pods -n web

echo ""
echo "========================================="
echo "Failure Simulation Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Check website (should show errors or Azure failover):"
echo "   curl -I https://blueisthenewblack.store/"
echo ""
echo "2. Check Lambda@Edge logs:"
echo "   aws logs tail /aws/lambda/us-east-1.CloudFrontFailover --follow"
echo ""
echo "3. Check Route53 Health Check:"
echo "   aws route53 get-health-check-status --health-check-id 0499007e-e628-4a48-aa9c-a9337e320fdd"
echo ""
echo "4. To recover:"
echo "   ./recover-aws.sh"
echo ""
