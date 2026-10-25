"""
MB-RecordingRouter

Triggered by S3 ObjectCreated on the Connect recordings prefix. Looks up the
tier captured during the call and copies the recording into a tier-specific
prefix so lifecycle rules can treat each tier differently.
"""

import os
import re
import urllib.parse

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
contacts = boto3.resource("dynamodb").Table(os.environ["CONTACTS_TABLE"])
BUCKET = os.environ["BUCKET"]

CONTACT_ID_RE = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.IGNORECASE
)


def lambda_handler(event, context):
    for record in event.get("Records", []):
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        # Ignore anything already routed, or the function fires on its own
        # output and recurses forever. (The S3 trigger prefix is layer one.)
        if key.startswith("recordings/"):
            continue

        match = CONTACT_ID_RE.search(key)
        if not match:
            print(f"No contact id in key, skipping: {key}")
            continue

        contact_id = match.group(1)
        tier = _lookup_tier(contact_id)
        destination = f"recordings/{tier.lower()}/{key.rsplit('/', 1)[-1]}"

        try:
            s3.copy_object(
                Bucket=BUCKET,
                Key=destination,
                CopySource={"Bucket": BUCKET, "Key": key},
                Tagging=f"customerTier={tier}&contactId={contact_id}",
                TaggingDirective="REPLACE",
            )
            # Delete the original only AFTER a successful copy.
            s3.delete_object(Bucket=BUCKET, Key=key)
            print(f"Routed {key} -> {destination}")
        except ClientError as exc:
            # Raise so Lambda retries and the failure shows in the Errors
            # metric. Silently swallowing this loses recordings.
            print(f"Failed to route {key}: {exc}")
            raise

    return {"status": "ok"}


def _lookup_tier(contact_id):
    try:
        item = contacts.get_item(Key={"contactId": contact_id}).get("Item")
        if item:
            return str(item.get("customerTier", "GENERAL")).upper()
    except ClientError as exc:
        print(f"Tier lookup failed for {contact_id}: {exc}")
    # Misclassifying is recoverable. Failing to store is not.
    return "GENERAL"
