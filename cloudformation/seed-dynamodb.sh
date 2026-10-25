#!/usr/bin/env bash
# CloudFormation cannot create DynamoDB ITEMS, so seed the lab data from the CLI.
# Uses made-up numbers. Replace the first with your own mobile in E.164 format
# (0421 000 000 becomes +61421000000) so the "known caller" test hits PRIORITY.
set -euo pipefail
REGION="${AWS_REGION:-ap-southeast-2}"
UP="${NAME_PREFIX_UPPER:-MB}"

put() { aws dynamodb put-item --region "$REGION" --table-name "$1" --item "$2"; }

put "${UP}-Customers" '{"phoneNumber":{"S":"+61400000001"},"customerName":{"S":"Alex"},"customerTier":{"S":"PRIORITY"},"accountId":{"S":"MB-770001"},"lineOfBusiness":{"S":"HOME_LOAN"}}'
put "${UP}-Customers" '{"phoneNumber":{"S":"+61400000002"},"customerName":{"S":"Sarah"},"customerTier":{"S":"GENERAL"},"accountId":{"S":"MB-770002"},"lineOfBusiness":{"S":"EVERYDAY"}}'
# No apostrophes or ampersands in values: text-to-speech reads punctuation aloud.
put "${UP}-Holidays"  '{"holidayDate":{"S":"2026-12-25"},"holidayName":{"S":"Christmas Day"},"holidayMessage":{"S":"our contact centre is closed today"}}'
echo "Seeded."
