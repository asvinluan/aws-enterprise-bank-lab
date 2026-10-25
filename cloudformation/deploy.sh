#!/usr/bin/env bash
# =============================================================================
# deploy.sh - deploy ONE CloudFormation stack from this folder.
#
#   ./deploy.sh network    [Param=Value ...]     stack 1: VPC, subnets, NAT, endpoints
#   ./deploy.sh data       [Param=Value ...]     stack 2: KMS, DynamoDB, S3, Kinesis, Athena
#   ./deploy.sh compute    [Param=Value ...]     stack 3: Lambda, API Gateway, WAF, alarms
#   ./deploy.sh containers [Param=Value ...]     stack 4: ECR and (optionally) EKS
#
# Each stack is its own deployment. Order matters once, on the way up:
#   data -> network -> compute -> containers   (network and data are independent)
# and the reverse on the way down (see destroy.sh).
#
# Examples:
#   ./deploy.sh network
#   ./deploy.sh network EnableNat=true EnableInterfaceEndpoints=true     # costs money
#   ./deploy.sh compute ConnectInstanceId=<uuid> WireConnect=true
#
# Everything defaults to the cheap setting. Run from AWS CloudShell or any shell
# with credentials for the lab account.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
PREFIX="${PREFIX:-mb}"
cd "$(dirname "$0")"

which="${1:-}"; shift || true
case "$which" in
  network)    template="01-network.yaml";       stack="${PREFIX}-network" ;;
  data)       template="02-data.yaml";          stack="${PREFIX}-data" ;;
  compute)    template="03-compute-edge.yaml";  stack="${PREFIX}-compute" ;;
  containers) template="04-containers.yaml";    stack="${PREFIX}-containers" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
params=("Prefix=${PREFIX}")
# Stack names other stacks import from. Keep them aligned with PREFIX.
case "$which" in
  compute|containers) params+=("NetworkStackName=${PREFIX}-network" "DataStackName=${PREFIX}-data") ;;
esac

if [ "$which" = "network" ]; then
  # A gateway endpoint is reached through a managed PREFIX LIST of the service's addresses.
  # The Lambda security group needs those to reach S3 and DynamoDB, so look them up.
  s3pl="$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
          --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.s3" \
          --query 'PrefixLists[0].PrefixListId' --output text)"
  ddbpl="$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
          --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.dynamodb" \
          --query 'PrefixLists[0].PrefixListId' --output text)"
  params+=("S3PrefixListId=${s3pl}" "DynamoDbPrefixListId=${ddbpl}")
fi

# Anything the caller passed overrides the defaults above.
params+=("$@")

if [ "$which" = "compute" ]; then
  # `aws cloudformation package` zips ../app/lambdas/<name>, uploads the zips, and rewrites
  # the template to point at them.
  artifacts="${PREFIX}-cfn-artifacts-${ACCOUNT}-${REGION}"
  if ! aws s3api head-bucket --bucket "$artifacts" 2>/dev/null; then
    echo "Creating artifact bucket $artifacts"
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$artifacts" --region "$REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$artifacts" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    aws s3api put-public-access-block --bucket "$artifacts" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
  aws cloudformation package --region "$REGION" --template-file "$template" \
    --s3-bucket "$artifacts" --output-template-file ".packaged-${template}" >/dev/null
  template=".packaged-${template}"
fi

echo "Deploying $stack from $template in $REGION"
aws cloudformation deploy --region "$REGION" \
  --stack-name "$stack" --template-file "$template" \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
  --parameter-overrides "${params[@]}"

if [ "$which" = "compute" ]; then
  # Attach the S3 -> RecordingRouter trigger. Prefix connect/ is NOT optional: without it
  # the function fires on the objects it writes itself and recurses forever.
  fn_arn="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
            --query "Stacks[0].Outputs[?OutputKey=='RecordingRouterArn'].OutputValue" --output text)"
  bucket="${PREFIX}-recordings-${ACCOUNT}"
  aws s3api put-bucket-notification-configuration --region "$REGION" --bucket "$bucket" \
    --notification-configuration "{\"LambdaFunctionConfigurations\":[{\"LambdaFunctionArn\":\"${fn_arn}\",\"Events\":[\"s3:ObjectCreated:*\"],\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"connect/\"}]}}}]}"
  echo "S3 trigger attached: s3://${bucket}/connect/ -> RecordingRouter"
fi

aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
  --query 'Stacks[0].Outputs' --output table || true
