"""
MB-StartChat

Invoked by API Gateway when a customer clicks Chat on the website.
Holds the AWS credentials the browser must never have (a credential broker).
"""

import json
import os

import boto3
from botocore.exceptions import ClientError

connect = boto3.client("connect")
INSTANCE_ID = os.environ["INSTANCE_ID"]
CONTACT_FLOW_ID = os.environ["CONTACT_FLOW_ID"]

# Tighten Allow-Origin to the bank's real website once you have one.
CORS = {
    "Access-Control-Allow-Origin": os.environ.get("ALLOWED_ORIGIN", "*"),
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def reply(status, body):
    return {"statusCode": status, "headers": CORS, "body": json.dumps(body)}


def lambda_handler(event, context):
    # Browsers send a preflight OPTIONS request before a cross-origin POST.
    if event.get("httpMethod") == "OPTIONS":
        return reply(200, {"ok": True})

    try:
        payload = json.loads(event.get("body") or "{}")
    except ValueError:
        return reply(400, {"error": "invalid_json"})

    name = str(payload.get("name", "")).strip()[:50]
    if not name:
        return reply(400, {"error": "name_required"})

    try:
        response = connect.start_chat_contact(
            InstanceId=INSTANCE_ID,
            ContactFlowId=CONTACT_FLOW_ID,
            Attributes={"customerName": name, "channel": "WEB_CHAT"},
            ParticipantDetails={"DisplayName": name},
        )
    except ClientError as exc:
        # Log the real reason, return something generic. Never leak an AWS
        # error message from a public endpoint.
        print(f"StartChatContact failed: {exc}")
        return reply(502, {"error": "chat_unavailable"})

    return reply(
        200,
        {
            "contactId": response["ContactId"],
            "participantId": response["ParticipantId"],
            "participantToken": response["ParticipantToken"],
        },
    )
