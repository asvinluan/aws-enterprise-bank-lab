#!/usr/bin/env bash
# =============================================================================
# destroy.sh - delete the lab stacks in the SAFE order (reverse of deploy).
#
#   ./destroy.sh            DRY RUN: shows what would be deleted
#   ./destroy.sh --yes      deletes: containers -> compute -> data -> network
#
# Stacks that do not exist are skipped. The S3 buckets in stack 2 must be empty
# before CloudFormation can delete them, so this script empties them first.
# =============================================================================
set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
PREFIX="${PREFIX:-mb}"
APPLY=0
[ "${1:-}" = "--yes" ] && APPLY=1
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

exists() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1; }

empty_bucket() {
  local b="$1" tmp n
  aws s3api head-bucket --bucket "$b" 2>/dev/null || return 0
  tmp="$(mktemp)"
  echo "  emptying s3://$b (all versions and delete markers)"
  while :; do
    aws --region "$REGION" s3api list-object-versions --bucket "$b" --max-items 500 --output json 2>/dev/null \
      | jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key:.Key, VersionId:.VersionId})), Quiet: true}' > "$tmp"
    n="$(jq '.Objects|length' "$tmp" 2>/dev/null)"
    { [ -z "$n" ] || [ "$n" = 0 ]; } && break
    aws --region "$REGION" s3api delete-objects --bucket "$b" --delete "file://$tmp" \
      --bypass-governance-retention >/dev/null 2>&1 || { echo "  [WARN] could not empty $b (Object Lock COMPLIANCE?)"; rm -f "$tmp"; return 1; }
  done
  rm -f "$tmp"
}

drop() {
  local stack="$1"
  if ! exists "$stack"; then echo "- $stack: not deployed, skipping"; return; fi
  echo "- $stack: delete"
  [ "$APPLY" = 1 ] || return
  aws cloudformation delete-stack --region "$REGION" --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$stack" \
    || echo "  [WARN] $stack did not delete cleanly; check the stack events in the console"
}

[ "$APPLY" = 1 ] && echo "*** LIVE: deleting stacks in $REGION ***" || echo "*** DRY RUN: add --yes to delete ***"

drop "${PREFIX}-containers"

# Remove the S3 trigger first so nothing fires while the function is being deleted.
if [ "$APPLY" = 1 ] && exists "${PREFIX}-compute"; then
  aws s3api put-bucket-notification-configuration --region "$REGION" \
    --bucket "${PREFIX}-recordings-${ACCOUNT}" --notification-configuration '{}' 2>/dev/null || true
fi
drop "${PREFIX}-compute"

if [ "$APPLY" = 1 ] && exists "${PREFIX}-data"; then
  for b in recordings datalake athena-results; do empty_bucket "${PREFIX}-${b}-${ACCOUNT}"; done
fi
drop "${PREFIX}-data"
drop "${PREFIX}-network"

echo
echo "Also remove the artifact bucket if you want it gone:"
echo "  aws s3 rb s3://${PREFIX}-cfn-artifacts-${ACCOUNT}-${REGION} --force"
echo "The evidence bucket (if you enabled it) is RETAINED on purpose: Object Lock buckets are not auto-deleted."
