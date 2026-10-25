data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Built from NAMES, not from resource references, so this module does not
  # depend on the data module (which would create a cycle: the data module
  # needs this module's KMS key).
  table_arn = { for k, name in var.table_names : k => "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${name}" }

  connect_arn = var.connect_instance_id == "" ? "arn:aws:connect:${local.region}:${local.account_id}:instance/*" : "arn:aws:connect:${local.region}:${local.account_id}:instance/${var.connect_instance_id}/*"
}

############################################################################
# KMS: one customer-managed key for recordings, the data lake and (optionally) streams
############################################################################
resource "aws_kms_key" "this" {
  description             = "${var.prefix} lab: recordings and data lake"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # the minimum. Costs about 1 USD/month while it exists.
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.prefix}-recordings"
  target_key_id = aws_kms_key.this.key_id
}

############################################################################
# The one role every Lambda uses (Module 1.2)
#
# What is deliberately ABSENT:
#   * no dynamodb:Scan   (a scan reads every row; needing one means the model is wrong)
#   * no DeleteItem      (nothing in this application deletes)
#   * no wildcard on tables or buckets
############################################################################
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "ReadReferenceData"
    actions   = ["dynamodb:GetItem"]
    resources = [local.table_arn["customers"], local.table_arn["holidays"]]
  }

  statement {
    sid       = "WriteContactRecords"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [local.table_arn["contacts"]]
  }

  statement {
    sid       = "StartContacts"
    actions   = ["connect:StartChatContact", "connect:StartTaskContact"]
    resources = [local.connect_arn]
  }

  statement {
    sid = "RouteRecordings"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:GetObjectTagging",
      "s3:PutObjectTagging", "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${var.recordings_bucket_name}/*"]
  }

  statement {
    sid       = "UseRecordingKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.this.arn]
  }

  statement {
    sid       = "SendSms"
    actions   = ["sms-voice:SendTextMessage"]
    resources = ["*"] # End User Messaging does not support resource-level scoping for this action
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${upper(var.prefix)}-LambdaRole"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_policy" "lambda" {
  name   = "${upper(var.prefix)}-LambdaPolicy"
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_role_policy_attachment" "custom" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Without this a VPC-attached Lambda cannot create the network interfaces it needs.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
