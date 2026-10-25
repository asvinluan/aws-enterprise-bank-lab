locals {
  upper = upper(var.prefix)

  functions = {
    caller_lookup = {
      name    = "${local.upper}-CallerLookup"
      timeout = 8 # Connect gives a Lambda 8 seconds. Higher is pointless: Connect has already taken the Error branch.
      in_vpc  = var.caller_lookup_in_vpc
      env = {
        CUSTOMERS_TABLE = var.table_names["customers"]
        CONTACTS_TABLE  = var.table_names["contacts"]
        ACCOUNT_API     = var.account_api_url
      }
    }
    holiday_check = {
      name    = "${local.upper}-HolidayCheck"
      timeout = 8
      in_vpc  = false
      env = {
        HOLIDAYS_TABLE   = var.table_names["holidays"]
        UTC_OFFSET_HOURS = "10"
      }
    }
    start_chat = {
      name    = "${local.upper}-StartChat"
      timeout = 10
      in_vpc  = false # must reach Connect's public API; a VPC Lambda would need a Connect endpoint or a NAT
      env = {
        INSTANCE_ID     = var.connect_instance_id == "" ? "REPLACE-WITH-INSTANCE-ID" : var.connect_instance_id
        CONTACT_FLOW_ID = var.connect_contact_flow_id
      }
    }
    recording_router = {
      name    = "${local.upper}-RecordingRouter"
      timeout = 60
      in_vpc  = false
      env = {
        CONTACTS_TABLE = var.table_names["contacts"]
        BUCKET         = var.recordings_bucket_id
      }
    }
    send_sms = {
      name    = "${local.upper}-SendSms"
      timeout = 8
      in_vpc  = false
      env = {
        ORIGINATION_NUMBER = ""
        CONFIG_SET         = "${var.prefix}-sms"
      }
    }
  }
}

data "archive_file" "fn" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${var.source_root}/${each.key}"
  output_path = "${path.module}/.build/${each.key}.zip"
}

# Created explicitly so that terraform destroy removes the logs too and the
# retention is not "never expire".
resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.functions
  name              = "/aws/lambda/${each.value.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name = each.value.name
  role          = var.lambda_role_arn
  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "lambda_function.lambda_handler"
  timeout       = each.value.timeout
  memory_size   = 256

  filename         = data.archive_file.fn[each.key].output_path
  source_code_hash = data.archive_file.fn[each.key].output_base64sha256

  environment {
    variables = each.value.env
  }

  # Three private subnets in three AZs is the point: a VPC Lambda is only as
  # resilient as the subnets you give it. One subnet is one AZ.
  dynamic "vpc_config" {
    for_each = each.value.in_vpc ? [1] : []
    content {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.lambda_security_group_id]
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

############################################################################
# S3 -> MB-RecordingRouter
# The prefix filter is NOT optional. Without it the function fires on the
# objects it writes itself and recurses forever. The startswith guard in the
# code is the second layer of defence.
############################################################################
resource "aws_lambda_permission" "s3_invoke_router" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["recording_router"].function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.recordings_bucket_arn
}

resource "aws_s3_bucket_notification" "recordings" {
  bucket = var.recordings_bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.fn["recording_router"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "connect/"
  }

  depends_on = [aws_lambda_permission.s3_invoke_router]
}
