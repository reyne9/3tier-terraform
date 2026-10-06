#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
for tool in terraform aws kubectl helm curl jq; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool 설치가 필요합니다." >&2; exit 1; }
done
CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)
VPC_ID=$(terraform -chdir="$TF_DIR" output -raw vpc_id)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
OIDC_PROVIDER=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" \
  --query cluster.identity.oidc.issuer --output text)
OIDC_PROVIDER=${OIDC_PROVIDER#https://}
# Terraform already owns this OIDC provider.
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC_PROVIDER" >/dev/null
ROLE_NAME="AWSLoadBalancerControllerRole-$CLUSTER_NAME"
POLICY_NAME="AWSLoadBalancerController-$CLUSTER_NAME"
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update eks
helm show chart eks/aws-load-balancer-controller > "$WORK_DIR/chart.yaml"
CHART_VERSION=$(awk '/^version:/ {gsub(/"/, "", $2); print $2}' "$WORK_DIR/chart.yaml")
APP_VERSION=$(awk '/^appVersion:/ {gsub(/"/, "", $2); print $2}' "$WORK_DIR/chart.yaml")
[[ -n "$CHART_VERSION" && -n "$APP_VERSION" ]] || { echo 'ERROR: Helm 버전 조회 실패' >&2; exit 1; }
APP_VERSION="v${APP_VERSION#v}"
# IAM policy must match the controller release, not the old hardcoded v2.7 policy.
curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${APP_VERSION}/docs/install/iam_policy.json" -o "$WORK_DIR/policy.json"
jq -e '.Statement | length > 0' "$WORK_DIR/policy.json" >/dev/null
if aws iam get-policy --policy-arn "$POLICY_ARN" > "$WORK_DIR/existing.json" 2>/dev/null; then
  CURRENT_VERSION=$(jq -r '.Policy.DefaultVersionId' "$WORK_DIR/existing.json")
  aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$CURRENT_VERSION" \
    --query PolicyVersion.Document --output json | jq -S . > "$WORK_DIR/current.json"
  jq -S . "$WORK_DIR/policy.json" > "$WORK_DIR/new.json"
  if ! cmp -s "$WORK_DIR/current.json" "$WORK_DIR/new.json"; then
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --output json)
    if [[ $(printf '%s' "$VERSIONS" | jq '.Versions | length') -ge 5 ]]; then
      OLDEST=$(printf '%s' "$VERSIONS" | jq -r '[.Versions[] | select(.IsDefaultVersion == false)] | sort_by(.CreateDate)[0].VersionId')
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" \
      --policy-document "file://$WORK_DIR/policy.json" --set-as-default >/dev/null
  fi
else
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$WORK_DIR/policy.json" >/dev/null
fi
jq -n --arg oidc "$OIDC_PROVIDER" --arg account "$ACCOUNT_ID" '{
  Version: "2012-10-17", Statement: [{Effect: "Allow",
  Principal: {Federated: ("arn:aws:iam::" + $account + ":oidc-provider/" + $oidc)},
  Action: "sts:AssumeRoleWithWebIdentity", Condition: {StringEquals: {
    ($oidc + ":aud"): "sts.amazonaws.com",
    ($oidc + ":sub"): "system:serviceaccount:kube-system:aws-load-balancer-controller"
  }}}]}' > "$WORK_DIR/trust.json"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$WORK_DIR/trust.json"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$WORK_DIR/trust.json" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
kubectl create serviceaccount aws-load-balancer-controller -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  "eks.amazonaws.com/role-arn=arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" --overwrite
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$CHART_VERSION" -n kube-system --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" --set vpcId="$VPC_ID" --wait --timeout 5m
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=300s
