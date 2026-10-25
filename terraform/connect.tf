############################################################################
# Wiring to your Amazon Connect instance (optional)
#
# The Connect instance, flows, queues and routing profiles are NOT created
# here. The lab builds them in the admin site, and Module 15 itself advises
# authoring flows in the console, exporting, templating and committing. This
# file only connects the pieces Terraform DOES own to an instance you pass in.
# Set wire_connect = true and connect_instance_id = "<uuid>".
############################################################################

# Without this association the functions do not appear in the flow designer's
# dropdown, and a runtime invocation fails. (Module 4.6)
resource "aws_connect_lambda_function_association" "this" {
  for_each = local.wire_connect ? toset(["caller_lookup", "holiday_check", "send_sms"]) : toset([])

  instance_id  = var.connect_instance_id
  function_arn = module.compute.function_arns[each.key]
}

# All recordings go to ONE S3 location. You cannot branch the destination
# inside a flow, so MB-RecordingRouter separates them by tier afterwards.
resource "aws_connect_instance_storage_config" "recordings" {
  count = local.wire_connect ? 1 : 0

  instance_id   = var.connect_instance_id
  resource_type = "CALL_RECORDINGS"

  storage_config {
    storage_type = "S3"

    s3_config {
      bucket_name   = module.data.bucket_ids["recordings"]
      bucket_prefix = "connect"

      encryption_config {
        encryption_type = "KMS"
        key_id          = module.security.kms_key_arn
      }
    }
  }
}

resource "aws_connect_instance_storage_config" "ctr" {
  count = local.wire_connect && var.enable_kinesis ? 1 : 0

  instance_id   = var.connect_instance_id
  resource_type = "CONTACT_TRACE_RECORDS"

  storage_config {
    storage_type = "KINESIS_STREAM"

    kinesis_stream_config {
      stream_arn = module.data.stream_arns["ctr"]
    }
  }
}

resource "aws_connect_instance_storage_config" "agent_events" {
  count = local.wire_connect && var.enable_kinesis ? 1 : 0

  instance_id   = var.connect_instance_id
  resource_type = "AGENT_EVENTS"

  storage_config {
    storage_type = "KINESIS_STREAM"

    kinesis_stream_config {
      stream_arn = module.data.stream_arns["agent_events"]
    }
  }
}
