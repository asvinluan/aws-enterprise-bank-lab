############################################################################
# CloudWatch alarms + SNS (Module 14)
# An alarm wired to an SNS topic nobody subscribes to is decoration. Route to
# something on-call actually watches: set alarm_email.
############################################################################
resource "aws_sns_topic" "alarms" {
  name = "${var.prefix}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  actions = [aws_sns_topic.alarms.arn]
  upper   = upper(var.prefix)

  # AWS/Connect metrics worth an alarm. ContactFlowErrors = a block took its error
  # branch (recoverable if you connected it). ContactFlowFatalErrors = the caller was
  # dropped. CallRecordingUploadError = silent to the caller, catastrophic in a dispute.
  connect_metrics = {
    ContactFlowErrors        = { statistic = "Sum", threshold = 1, op = "GreaterThanOrEqualToThreshold", metric_group = "" }
    ContactFlowFatalErrors   = { statistic = "Sum", threshold = 1, op = "GreaterThanOrEqualToThreshold", metric_group = "" }
    MissedCalls              = { statistic = "Sum", threshold = 3, op = "GreaterThanOrEqualToThreshold", metric_group = "" }
    CallRecordingUploadError = { statistic = "Sum", threshold = 1, op = "GreaterThanOrEqualToThreshold", metric_group = "" }
    # Alarm well BELOW 100 percent of the concurrency quota.
    ConcurrentCallsPercentage = { statistic = "Maximum", threshold = 80, op = "GreaterThanOrEqualToThreshold", metric_group = "VoiceCalls" }
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.function_names

  alarm_name          = "${each.value}-Errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.function_names

  alarm_name          = "${each.value}-Throttles"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# p99, not the average. If 99 invocations take 200 ms and one takes 9 seconds the
# average looks healthy and one caller heard silence then hit the Error branch.
# Connect's ceiling is 8 seconds, so alarm around 5 to give yourself warning.
resource "aws_cloudwatch_metric_alarm" "lambda_duration_p99" {
  for_each = var.function_names

  alarm_name          = "${each.value}-DurationP99"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = each.value }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.upper}-Web-API-5XX"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = var.api_name, Stage = var.api_stage_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

resource "aws_cloudwatch_metric_alarm" "connect" {
  for_each = var.connect_instance_id == "" ? {} : local.connect_metrics

  alarm_name          = "${local.upper}-Connect-${each.key}"
  namespace           = "AWS/Connect"
  metric_name         = each.key
  dimensions          = merge({ InstanceId = var.connect_instance_id }, each.value.metric_group == "" ? {} : { MetricGroup = each.value.metric_group })
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}
