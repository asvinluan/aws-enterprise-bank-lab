"""
MB-SendSms

Invoked from a contact flow to send a confirmation SMS through
AWS End User Messaging. Never raises: a failed SMS must not change
the caller's experience.
"""

import os

import boto3
from botocore.exceptions import ClientError

sms = boto3.client("pinpoint-sms-voice-v2")
ORIGINATION = os.environ.get("ORIGINATION_NUMBER", "")
CONFIG_SET = os.environ.get("CONFIG_SET", "mb-sms")


def lambda_handler(event, context):
    params = event.get("Details", {}).get("Parameters", {})
    destination = (params.get("destinationNumber") or "").strip()
    message = (params.get("messageBody") or "").strip()[:300]

    result = {"smsResult": "FAILED", "messageId": "NONE"}

    if not destination or not message or not ORIGINATION:
        result["smsResult"] = "MISSING_INPUT"
        return result

    try:
        response = sms.send_text_message(
            DestinationPhoneNumber=destination,
            OriginationIdentity=ORIGINATION,
            MessageBody=message,
            # TRANSACTIONAL = messages the customer asked for. PROMOTIONAL is
            # marketing: priced, routed and consented differently.
            MessageType="TRANSACTIONAL",
            ConfigurationSetName=CONFIG_SET,
        )
    except ClientError as exc:
        print(f"SendTextMessage failed: {exc}")
        return result

    result.update({"smsResult": "SENT", "messageId": response["MessageId"]})
    return result
