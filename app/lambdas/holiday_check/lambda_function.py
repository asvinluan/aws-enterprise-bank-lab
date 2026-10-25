"""
MB-HolidayCheck

Returns a local time-of-day greeting and whether today is a holiday.
Fails OPEN: if the holiday table cannot be read, the contact centre stays open.
"""

import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

dynamodb = boto3.resource("dynamodb")
holidays = dynamodb.Table(os.environ["HOLIDAYS_TABLE"])
OFFSET = int(os.environ.get("UTC_OFFSET_HOURS", "10"))


def lambda_handler(event, context):
    # Lambda always runs in UTC regardless of Region. Convert deliberately.
    local_now = datetime.now(timezone.utc) + timedelta(hours=OFFSET)
    hour = local_now.hour

    if hour < 12:
        greeting = "Good morning"
    elif hour < 18:
        greeting = "Good afternoon"
    else:
        greeting = "Good evening"

    result = {"greeting": greeting, "isHoliday": "false", "holidayMessage": "NONE"}

    try:
        item = holidays.get_item(Key={"holidayDate": local_now.strftime("%Y-%m-%d")}).get("Item")
        if item:
            result["isHoliday"] = "true"
            result["holidayMessage"] = str(
                item.get("holidayMessage", "our contact centre is closed today")
            )
    except ClientError as exc:
        # FAIL OPEN. Treating a normal working day as a holiday would close the
        # contact centre for every caller because of one database blip.
        print(f"Holiday lookup failed, defaulting to open: {exc}")

    print(f"Returning: {result}")
    return result
