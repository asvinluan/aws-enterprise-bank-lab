"""
MB-CallerLookup

Identifies the caller from their calling number, optionally fetches a balance
from the account service, and records contactId -> tier so the recording
router can classify the audio after the call ends.

Design rules (from the lab):
  * every return path returns EVERY key, as strings
  * nothing raises: a caught error becomes a status the flow can branch on
  * clients are created outside the handler so warm invocations reuse them
"""

import json
import os
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
customers = dynamodb.Table(os.environ["CUSTOMERS_TABLE"])
contacts = dynamodb.Table(os.environ["CONTACTS_TABLE"])
ACCOUNT_API = os.environ.get("ACCOUNT_API", "").strip()


def lambda_handler(event, context):
    details = event.get("Details", {})
    contact_id = details.get("ContactData", {}).get("ContactId", "UNKNOWN")
    params = details.get("Parameters", {})
    caller = (params.get("callerNumber") or "").strip()

    result = {
        "lookupResult": "NOT_FOUND",
        "customerName": "there",
        "customerTier": "GENERAL",
        "accountId": "NONE",
        "lineOfBusiness": "NONE",
        "balance": "NONE",
    }

    if not caller:
        _record(contact_id, result["customerTier"], caller)
        return result

    try:
        item = customers.get_item(Key={"phoneNumber": caller}).get("Item")
    except ClientError as exc:
        print(f"DynamoDB error: {exc}")
        result["lookupResult"] = "SYSTEM_ERROR"
        _record(contact_id, result["customerTier"], caller)
        return result

    if item:
        result.update(
            {
                "lookupResult": "FOUND",
                "customerName": str(item.get("customerName", "there")),
                "customerTier": str(item.get("customerTier", "GENERAL")),
                "accountId": str(item.get("accountId", "NONE")),
                "lineOfBusiness": str(item.get("lineOfBusiness", "NONE")),
            }
        )
        balance = _fetch_balance(result["accountId"])
        if balance:
            result["balance"] = balance

    _record(contact_id, result["customerTier"], caller)
    print(f"Returning lookupResult={result['lookupResult']} tier={result['customerTier']}")
    return result


def _fetch_balance(account_id):
    """Call the account service on EKS. Degrade quietly if unavailable."""
    if not ACCOUNT_API or account_id == "NONE":
        return None
    try:
        # Timeout well inside Connect's 8 second ceiling. A slow upstream
        # must never become a dropped caller.
        with urllib.request.urlopen(f"{ACCOUNT_API}/accounts/{account_id}", timeout=3) as response:
            return str(json.loads(response.read().decode()).get("available"))
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        print(f"Account service unavailable: {exc}")
        return None


def _record(contact_id, tier, caller):
    """Persist the tier so the post-call recording router can classify audio."""
    try:
        contacts.put_item(
            Item={"contactId": contact_id, "customerTier": tier, "callerNumber": caller}
        )
    except ClientError as exc:
        # Non-fatal. The call must proceed even if classification fails.
        print(f"Could not write contact record: {exc}")
