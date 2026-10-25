#!/usr/bin/env bash
# =============================================================================
# stop-the-meter.sh  -  find and remove the lab resources that cost money.
#
# Run it in AWS CloudShell (same account, any Region). It needs the AWS CLI v2
# and jq, both of which CloudShell already has.
#
#   ./stop-the-meter.sh scan                  read-only: list what is billing
#   ./stop-the-meter.sh delete <stage>        DRY RUN: print what would go
#   ./stop-the-meter.sh delete <stage> --yes  really delete it
#   ./stop-the-meter.sh delete all  --yes     every stage, in the safe order
#
# Safety rules built into this script:
#   * Dry run is the default. Nothing is deleted without --yes.
#   * It only touches things named MB-* / mb-* / meridian-lab*, or that live
#     inside the VPC tagged Name=mb-vpc. Everything else is listed and skipped.
#   * Connect phone numbers, the Connect instance and KMS keys need their own
#     extra flags, because they are hard or slow to get back.
#   * The KMS key used by the Q in Connect knowledge base is never scheduled
#     for deletion by this script.
#
# Stages, in the order "all" runs them (most expensive first):
#   eks  lb  nat  eip  endpoints  waf  apigw  lambda  ecr  streams  analytics
#   flowlogs  logs  alarms  s3  dynamodb  cfn  vpc  sms  [numbers]  [instance]  [kms]
# =============================================================================
set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
VPC_NAME_TAG="${VPC_NAME_TAG:-mb-vpc}"
APPLY=0
INCLUDE_NUMBERS=0
INCLUDE_INSTANCE=0
INCLUDE_KMS=0
INCLUDE_UNTAGGED_EIPS=0
# Aliases that must never be scheduled for deletion by this script.
PROTECTED_KMS_ALIAS_PATTERN='connect-lab-events'

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }
q()   { aws --region "$REGION" "$@" 2>/dev/null; }          # quiet query
run() {                                                      # dry-run wrapper
  if [ "$APPLY" = 1 ]; then
    say "  [DELETE] aws --region $REGION $*"
    aws --region "$REGION" "$@" >/dev/null 2>&1 || say "  [WARN]   that call failed (already gone, or a dependency is still deleting)"
  else
    say "  [dry-run] aws --region $REGION $*"
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || { say "Missing required tool: $1"; exit 2; }; }
need aws
need jq

vpc_ids() {
  q ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME_TAG}" \
    --query 'Vpcs[].VpcId' --output text
}

# ----------------------------------------------------------------------------
# SCAN  (read-only)
# ----------------------------------------------------------------------------
scan() {
  say "Region: $REGION    (re-run with AWS_REGION=us-east-1 if you built anything there)"
  say "Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null | sed 's/[0-9]\{8\}/********/')"

  hdr "1. EKS clusters  (control plane bills every hour; old versions bill 6x more)"
  q eks list-clusters --query 'clusters[]' --output text | tr '\t' '\n' | while read -r c; do
    [ -z "$c" ] && continue
    q eks describe-cluster --name "$c" \
      --query 'cluster.{name:name,version:version,status:status,upgradePolicy:upgradePolicy.supportType}' --output text
  done
  say "  (supportType EXTENDED = the 0.60 USD/hour rate. Delete the cluster, do not leave it.)"

  hdr "2. NAT gateways  (hourly + per GB)"
  q ec2 describe-nat-gateways --filter Name=state,Values=pending,available \
    --query 'NatGateways[].[NatGatewayId,VpcId,State]' --output text

  hdr "3. Elastic IPs / public IPv4  (each address bills hourly, even when unattached)"
  q ec2 describe-addresses \
    --query 'Addresses[].[PublicIp,AllocationId,AssociationId,Tags[?Key==`Name`]|[0].Value]' --output text

  hdr "4. Interface VPC endpoints  (billed per hour per Availability Zone)"
  q ec2 describe-vpc-endpoints --filters Name=vpc-endpoint-type,Values=Interface \
    --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcId,length(SubnetIds)]' --output text

  hdr "5. Load balancers  (the EKS service creates one; each bills hourly)"
  q elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,VpcId]' --output text
  q elb describe-load-balancers --query 'LoadBalancerDescriptions[].[LoadBalancerName,Scheme,VPCId]' --output text

  hdr "6. EC2 instances and EBS volumes  (EKS worker nodes)"
  q ec2 describe-instances --filters Name=instance-state-name,Values=running,pending,stopped \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' --output text
  q ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State]' --output text

  hdr "7. WAF web ACLs  (monthly fee per ACL + per rule + per request)"
  q wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].[Name,Id]' --output text
  aws --region us-east-1 wafv2 list-web-acls --scope CLOUDFRONT --query 'WebACLs[].[Name,Id]' --output text 2>/dev/null \
    | sed 's/^/(CloudFront, us-east-1) /'

  hdr "8. API Gateway REST APIs / Lambda / ECR"
  q apigateway get-rest-apis --query 'items[].[name,id]' --output text
  q lambda list-functions --query 'Functions[].[FunctionName,Runtime,VpcConfig.VpcId]' --output text
  q ecr describe-repositories --query 'repositories[].repositoryName' --output text

  hdr "9. Kinesis streams / Firehose  (Kinesis bills per shard-hour even with no traffic)"
  q kinesis list-streams --query 'StreamNames[]' --output text
  q firehose list-delivery-streams --query 'DeliveryStreamNames[]' --output text

  hdr "10. Athena workgroups / Glue databases"
  q athena list-work-groups --query 'WorkGroups[].Name' --output text
  q glue get-databases --query 'DatabaseList[].Name' --output text

  hdr "11. KMS customer-managed keys  (about 1 USD per key per month)"
  q kms list-aliases --query 'Aliases[?!starts_with(AliasName,`alias/aws/`)].[AliasName,TargetKeyId]' --output text

  hdr "12. Secrets Manager secrets  (about 0.40 USD per secret per month)"
  q secretsmanager list-secrets --query 'SecretList[].Name' --output text

  hdr "13. CloudWatch alarms and log groups"
  q cloudwatch describe-alarms --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | sort | head -60
  q logs describe-log-groups --query 'logGroups[].[logGroupName,storedBytes,retentionInDays]' --output text

  hdr "14. S3 buckets  (storage + requests; Object Lock buckets cannot be emptied early)"
  q s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n'

  hdr "15. DynamoDB tables"
  q dynamodb list-tables --query 'TableNames[]' --output text

  hdr "16. Amazon Connect: instances and CLAIMED PHONE NUMBERS  (numbers bill daily)"
  q connect list-instances --query 'InstanceSummaryList[].[InstanceAlias,Id,InstanceStatus]' --output text
  q connect list-phone-numbers-v2 --query 'ListPhoneNumbersSummaryList[].[PhoneNumber,PhoneNumberId,PhoneNumberType]' --output text

  hdr "17. SMS originators (End User Messaging)"
  q pinpoint-sms-voice-v2 describe-phone-numbers --query 'PhoneNumbers[].[PhoneNumber,PhoneNumberId,Status]' --output text

  hdr "18. CloudFormation stacks"
  q cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED DELETE_FAILED \
    --query 'StackSummaries[].[StackName,StackStatus]' --output text

  say
  say "Not in this scan and worth a look in the console: Amazon Q in Connect / AI agents domain,"
  say "Bedrock model-invocation logging, Contact Lens, Voice ID domain, CloudFront distributions."
  say "Cost by service, last 7 days:  ./stop-the-meter.sh costs"
}

costs() {
  local start end
  start="$(date -u -d '7 days ago' +%F)"; end="$(date -u +%F)"
  aws ce get-cost-and-usage --time-period "Start=$start,End=$end" --granularity DAILY \
    --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --output json \
  | jq -r '.ResultsByTime[] | .TimePeriod.Start as $d | .Groups[]
           | select((.Metrics.UnblendedCost.Amount|tonumber) > 0.01)
           | [$d, .Keys[0], (.Metrics.UnblendedCost.Amount|tonumber|.*100|round/100)] | @tsv' \
  | sort -k1,1 -k3,3nr
}

# ----------------------------------------------------------------------------
# STAGES
# ----------------------------------------------------------------------------
stage_eks() {
  hdr "EKS: node groups first, then the cluster"
  local c ng
  for c in $(q eks list-clusters --query 'clusters[]' --output text); do
    case "$c" in
      meridian-lab*|mb-*) ;;
      *) say "  skip cluster '$c' (name is not a lab name)"; continue ;;
    esac
    if command -v eksctl >/dev/null 2>&1; then
      run_raw eksctl delete cluster --name "$c" --region "$REGION" --wait
      continue
    fi
    for ng in $(q eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]' --output text); do
      run eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng"
      [ "$APPLY" = 1 ] && aws --region "$REGION" eks wait nodegroup-deleted --cluster-name "$c" --nodegroup-name "$ng"
    done
    run eks delete-cluster --name "$c"
    [ "$APPLY" = 1 ] && aws --region "$REGION" eks wait cluster-deleted --name "$c"
  done
}

run_raw() {   # for non-aws commands (eksctl)
  if [ "$APPLY" = 1 ]; then say "  [DELETE] $*"; "$@" || say "  [WARN] failed: $*"; else say "  [dry-run] $*"; fi
}

stage_lb() {
  hdr "Load balancers inside $VPC_NAME_TAG"
  local v lb
  for v in $(vpc_ids); do
    for lb in $(q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$v'].LoadBalancerArn" --output text); do
      run elbv2 delete-load-balancer --load-balancer-arn "$lb"
    done
    for lb in $(q elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$v'].LoadBalancerName" --output text); do
      run elb delete-load-balancer --load-balancer-name "$lb"
    done
  done
}

wait_nat_gone() {
  local id="$1" s
  for _ in $(seq 1 40); do
    s="$(q ec2 describe-nat-gateways --nat-gateway-ids "$id" --query 'NatGateways[0].State' --output text)"
    [ "$s" = "deleted" ] || [ -z "$s" ] && return 0
    sleep 10
  done
  say "  [WARN] NAT gateway $id still deleting; re-run stage 'eip' in a few minutes"
}

stage_nat() {
  hdr "NAT gateways inside $VPC_NAME_TAG  (the single biggest network cost)"
  local v n
  for v in $(vpc_ids); do
    for n in $(q ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$v" Name=state,Values=pending,available \
        --query 'NatGateways[].NatGatewayId' --output text); do
      run ec2 delete-nat-gateway --nat-gateway-id "$n"
      [ "$APPLY" = 1 ] && wait_nat_gone "$n"
    done
  done
}

stage_eip() {
  hdr "Elastic IPs that are not attached to anything  (each bills hourly)"
  local a ip name
  q ec2 describe-addresses \
    --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp,Tags[?Key==`Name`]|[0].Value]' --output text \
  | while read -r a ip name; do
      [ -z "$a" ] && continue
      case "$name" in
        mb-*|MB-*|meridian*) run ec2 release-address --allocation-id "$a" ;;
        None|"")
          if [ "$INCLUDE_UNTAGGED_EIPS" = 1 ]; then run ec2 release-address --allocation-id "$a"
          else say "  untagged unattached address $ip ($a): the NAT gateway's address is usually untagged."
               say "    If it is yours, release it with --include-untagged-eips (or: aws ec2 release-address --allocation-id $a)"
          fi ;;
        *) say "  skip $ip ($a) tagged '$name' - not a lab name" ;;
      esac
    done
}

stage_endpoints() {
  hdr "Interface VPC endpoints inside $VPC_NAME_TAG  (gateway endpoints are free and stay)"
  local v ids
  for v in $(vpc_ids); do
    ids="$(q ec2 describe-vpc-endpoints \
      --filters "Name=vpc-id,Values=$v" Name=vpc-endpoint-type,Values=Interface \
      --query 'VpcEndpoints[].VpcEndpointId' --output text)"
    # shellcheck disable=SC2086
    [ -n "$ids" ] && run ec2 delete-vpc-endpoints --vpc-endpoint-ids $ids
  done
}

stage_waf() {
  hdr "WAF web ACLs named MB-* / mb-*"
  local id name lock arn r
  q wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].[Name,Id,ARN]' --output text \
  | while read -r name id arn; do
      case "$name" in MB-*|mb-*) ;; *) say "  skip web ACL '$name'"; continue ;; esac
      for r in $(q wafv2 list-resources-for-web-acl --web-acl-arn "$arn" --resource-type API_GATEWAY \
                   --query 'ResourceArns[]' --output text); do
        run wafv2 disassociate-web-acl --resource-arn "$r"
      done
      lock="$(q wafv2 get-web-acl --name "$name" --scope REGIONAL --id "$id" --query LockToken --output text)"
      run wafv2 delete-web-acl --name "$name" --scope REGIONAL --id "$id" --lock-token "${lock:-LOCK_TOKEN}"
    done
  say "  CloudFront-scope web ACLs live in us-east-1: run  AWS_REGION=us-east-1 ... delete waf  if you made one."
}

stage_apigw() {
  hdr "API Gateway REST APIs named MB-*"
  local id
  for id in $(q apigateway get-rest-apis --query "items[?starts_with(name,'MB-')].id" --output text); do
    run apigateway delete-rest-api --rest-api-id "$id"
  done
}

stage_lambda() {
  hdr "Lambda functions named MB-*"
  local f
  for f in $(q lambda list-functions --query "Functions[?starts_with(FunctionName,'MB-')].FunctionName" --output text); do
    run lambda delete-function --function-name "$f"
  done
}

stage_ecr() {
  hdr "ECR repositories named mb/*"
  local r
  for r in $(q ecr describe-repositories --query "repositories[?starts_with(repositoryName,'mb/')].repositoryName" --output text); do
    run ecr delete-repository --repository-name "$r" --force
  done
}

stage_streams() {
  hdr "Firehose first (it reads from Kinesis), then Kinesis streams named MB-* / mb-*"
  local s
  for s in $(q firehose list-delivery-streams --query 'DeliveryStreamNames[]' --output text); do
    case "$s" in MB-*|mb-*) run firehose delete-delivery-stream --delivery-stream-name "$s" ;; *) say "  skip firehose '$s'" ;; esac
  done
  for s in $(q kinesis list-streams --query 'StreamNames[]' --output text); do
    case "$s" in MB-*|mb-*) run kinesis delete-stream --stream-name "$s" --enforce-consumer-deletion ;; *) say "  skip kinesis '$s'" ;; esac
  done
  say "  If Connect still lists these under Data streaming, remove them there first (console)."
}

stage_analytics() {
  hdr "Athena workgroups and Glue databases named mb* "
  local w d
  for w in $(q athena list-work-groups --query 'WorkGroups[].Name' --output text); do
    case "$w" in mb-*|MB-*) run athena delete-work-group --work-group "$w" --recursive-delete-option ;; esac
  done
  for d in $(q glue get-databases --query 'DatabaseList[].Name' --output text); do
    case "$d" in mb_*|mb-*) run glue delete-database --name "$d" ;; esac
  done
}

stage_flowlogs() {
  hdr "VPC flow logs inside $VPC_NAME_TAG"
  local v f
  for v in $(vpc_ids); do
    for f in $(q ec2 describe-flow-logs --filter "Name=resource-id,Values=$v" --query 'FlowLogs[].FlowLogId' --output text); do
      run ec2 delete-flow-logs --flow-log-ids "$f"
    done
  done
}

stage_logs() {
  hdr "CloudWatch log groups created by the lab"
  local p g
  for p in /aws/vpc/mb- /aws/lambda/MB- /aws/apigateway/MB- /aws/eks/meridian-lab /aws/kinesisfirehose/mb- /aws/waf/mb- aws-waf-logs-mb-; do
    for g in $(q logs describe-log-groups --log-group-name-prefix "$p" --query 'logGroups[].logGroupName' --output text); do
      run logs delete-log-group --log-group-name "$g"
    done
  done
  say "  /aws/connect/<alias> (Connect flow logs) is NOT removed here: it belongs to the Connect instance."
}

stage_alarms() {
  hdr "CloudWatch alarms named MB-* / mb-*"
  local names
  names="$(q cloudwatch describe-alarms \
    --query "MetricAlarms[?starts_with(AlarmName,'MB-')||starts_with(AlarmName,'mb-')].AlarmName" --output text)"
  # shellcheck disable=SC2086
  [ -n "$names" ] && run cloudwatch delete-alarms --alarm-names $names
}

empty_bucket() {
  local b="$1" tmp n
  tmp="$(mktemp)"
  say "  emptying s3://$b (all versions and delete markers)"
  while :; do
    aws --region "$REGION" s3api list-object-versions --bucket "$b" --max-items 500 --output json 2>/dev/null \
    | jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key:.Key, VersionId:.VersionId})), Quiet: true}' > "$tmp"
    n="$(jq '.Objects|length' "$tmp" 2>/dev/null)"
    { [ -z "$n" ] || [ "$n" = 0 ]; } && break
    if ! aws --region "$REGION" s3api delete-objects --bucket "$b" --delete "file://$tmp" \
          --bypass-governance-retention >/dev/null 2>&1; then
      say "  [WARN] could not delete some objects in $b. If it has Object Lock COMPLIANCE retention,"
      say "         AWS will not allow deletion until the retention date passes. Leave the bucket; it costs storage only."
      rm -f "$tmp"; return 1
    fi
  done
  rm -f "$tmp"
}

stage_s3() {
  hdr "S3 buckets named mb-*"
  local b
  for b in $(q s3api list-buckets --query "Buckets[?starts_with(Name,'mb-')].Name" --output text); do
    if [ "$APPLY" = 1 ]; then
      empty_bucket "$b" && run s3api delete-bucket --bucket "$b"
    else
      say "  [dry-run] empty (all versions) and delete s3://$b"
    fi
  done
}

stage_dynamodb() {
  hdr "DynamoDB tables named MB-*"
  local t
  for t in $(q dynamodb list-tables --query "TableNames[?starts_with(@,'MB-')]" --output text); do
    run dynamodb delete-table --table-name "$t"
  done
}

stage_cfn() {
  hdr "CloudFormation stacks from this lab, in dependency order"
  local s
  # eksctl-made stacks first (node group before cluster), then this repo's stacks in
  # REVERSE deploy order: a stack that exports values cannot be deleted while another imports them.
  for s in $(q cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
      --query 'StackSummaries[].StackName' --output text); do
    case "$s" in eksctl-meridian-lab-nodegroup-*) run cloudformation delete-stack --stack-name "$s" ;; esac
  done
  for s in $(q cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
      --query 'StackSummaries[].StackName' --output text); do
    case "$s" in eksctl-meridian-lab-cluster) run cloudformation delete-stack --stack-name "$s" ;; esac
  done
  for s in mb-containers mb-compute mb-data mb-network; do
    if q cloudformation describe-stacks --stack-name "$s" >/dev/null; then
      run cloudformation delete-stack --stack-name "$s"
      [ "$APPLY" = 1 ] && aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$s"
    fi
  done
  say "  Stacks with a different PREFIX are not touched. The S3 buckets must be empty first: run 'delete s3' or cloudformation/destroy.sh."
}

stage_vpc() {
  hdr "The VPC itself  (free, but removing it stops public-IP and ENI surprises)"
  local v x
  for v in $(vpc_ids); do
    for x in $(q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$v" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
      run ec2 delete-vpc-endpoints --vpc-endpoint-ids "$x"
    done
    for x in $(q ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$v" \
                 --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output text | awk '{print $1}'); do
      say "  note: network interface $x still exists (Lambda/EKS ENIs clear up to ~20 minutes after the function/cluster is gone)"
    done
    for x in $(q ec2 describe-subnets --filters "Name=vpc-id,Values=$v" --query 'Subnets[].SubnetId' --output text); do
      run ec2 delete-subnet --subnet-id "$x"
    done
    for x in $(q ec2 describe-route-tables --filters "Name=vpc-id,Values=$v" \
                 --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
      run ec2 delete-route-table --route-table-id "$x"
    done
    for x in $(q ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$v" --query 'InternetGateways[].InternetGatewayId' --output text); do
      run ec2 detach-internet-gateway --internet-gateway-id "$x" --vpc-id "$v"
      run ec2 delete-internet-gateway --internet-gateway-id "$x"
    done
    for x in $(q ec2 describe-security-groups --filters "Name=vpc-id,Values=$v" \
                 --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
      run ec2 delete-security-group --group-id "$x"
    done
    run ec2 delete-vpc --vpc-id "$v"
  done
  say "  Security groups that reference each other can fail the first time. Re-run this stage once."
}

stage_sms() {
  hdr "SMS originators (End User Messaging)  - billed monthly"
  local id
  for id in $(q pinpoint-sms-voice-v2 describe-phone-numbers --query 'PhoneNumbers[].PhoneNumberId' --output text); do
    run pinpoint-sms-voice-v2 release-phone-number --phone-number-id "$id"
  done
  say "  Also try: AWS_REGION=us-east-1 $0 delete sms --yes   if you tested SMS from us-east-1."
}

stage_numbers() {
  hdr "Amazon Connect CLAIMED PHONE NUMBERS  (bills daily; you cannot get the same number back)"
  if [ "$INCLUDE_NUMBERS" != 1 ]; then
    say "  skipped: add --include-numbers to release these."
    q connect list-phone-numbers-v2 --query 'ListPhoneNumbersSummaryList[].[PhoneNumber,PhoneNumberId]' --output text
    return
  fi
  local id
  for id in $(q connect list-phone-numbers-v2 --query 'ListPhoneNumbersSummaryList[].PhoneNumberId' --output text); do
    run connect release-phone-number --phone-number-id "$id"
  done
}

stage_instance() {
  hdr "Amazon Connect instance  (no standing fee, but it holds numbers, storage and usage)"
  if [ "$INCLUDE_INSTANCE" != 1 ]; then
    say "  skipped: add --include-instance to delete. Check the alias first; this may be your EARLIER lab."
    q connect list-instances --query 'InstanceSummaryList[].[InstanceAlias,Id]' --output text
    return
  fi
  local id alias
  q connect list-instances --query 'InstanceSummaryList[].[Id,InstanceAlias]' --output text \
  | while read -r id alias; do
      case "$alias" in
        meridian-cc*) run connect delete-instance --instance-id "$id" ;;
        *) say "  skip instance '$alias' (alias is not meridian-cc*)" ;;
      esac
    done
}

stage_kms() {
  hdr "KMS customer-managed keys with alias alias/mb-*  (7-day waiting period, cancellable)"
  if [ "$INCLUDE_KMS" != 1 ]; then
    say "  skipped: add --include-kms to schedule deletion."
    return
  fi
  local alias key
  q kms list-aliases --query 'Aliases[].[AliasName,TargetKeyId]' --output text \
  | while read -r alias key; do
      case "$alias" in
        *${PROTECTED_KMS_ALIAS_PATTERN}*) say "  PROTECTED: $alias is used by the Q in Connect knowledge base - not touched"; continue ;;
        alias/mb-*|alias/MB-*) [ -n "$key" ] && run kms schedule-key-deletion --key-id "$key" --pending-window-in-days 7 ;;
      esac
    done
}

ALL_STAGES="eks lb nat eip endpoints waf apigw lambda ecr streams analytics flowlogs logs alarms s3 dynamodb cfn vpc sms numbers instance kms"

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
cmd="${1:-help}"; shift || true
stages=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)              APPLY=1 ;;
    --include-numbers)  INCLUDE_NUMBERS=1 ;;
    --include-instance) INCLUDE_INSTANCE=1 ;;
    --include-kms)      INCLUDE_KMS=1 ;;
    --include-untagged-eips) INCLUDE_UNTAGGED_EIPS=1 ;;
    --region)           shift; REGION="$1" ;;
    *)                  stages="$stages $1" ;;
  esac
  shift
done

case "$cmd" in
  scan)  scan ;;
  costs) costs ;;
  delete)
    [ -z "${stages// /}" ] && { say "Give a stage name or 'all'. Stages: $ALL_STAGES"; exit 1; }
    [ "$APPLY" = 1 ] && say "*** LIVE MODE: resources will be deleted in $REGION ***" || say "*** DRY RUN: nothing will be deleted. Add --yes to apply. ***"
    [ "${stages// /}" = "all" ] && stages="$ALL_STAGES"
    for s in $stages; do
      if declare -F "stage_$s" >/dev/null; then "stage_$s"; else say "Unknown stage: $s"; fi
    done
    say; say "Done. Run './stop-the-meter.sh scan' again to confirm it is empty." ;;
  *)
    sed -n '2,30p' "$0" ;;
esac
