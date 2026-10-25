############################################################################
# Kinesis: the reporting system of record (Module 12.1)
# Connect writes one Contact Trace Record per contact when it ends, plus agent
# state changes. Kinesis is SERVER-SIDE and AUTHORITATIVE; the Streams API is
# JavaScript in one agent's browser and only reports what that tab saw.
############################################################################
locals {
  streams = var.enable_kinesis ? {
    ctr          = "${upper(var.prefix)}-CTR"
    agent_events = "${upper(var.prefix)}-AgentEvents"
  } : {}
}

resource "aws_kinesis_stream" "this" {
  for_each = local.streams

  name             = each.value
  shard_count      = 1 # bills per shard-hour even when idle: delete when not testing
  retention_period = 24

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  encryption_type = var.encrypt_kinesis ? "KMS" : "NONE"
  kms_key_id      = var.encrypt_kinesis ? var.kms_key_arn : null
}

############################################################################
# Glue + Athena: query the CTRs in S3 with SQL
############################################################################
resource "aws_glue_catalog_database" "this" {
  name = "${var.prefix}_analytics"
}

resource "aws_glue_catalog_table" "ctr" {
  name          = "ctr"
  database_name = aws_glue_catalog_database.this.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "parquet"
    EXTERNAL       = "TRUE"

    # Partition projection: Athena works out the partition folders from the
    # template instead of needing MSCK REPAIR TABLE after every delivery.
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2024,2035"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "storage.location.template" = "s3://${aws_s3_bucket.this["datalake"].id}/ctr/year=$${year}/month=$${month}/day=$${day}/"
  }

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.this["datalake"].id}/ctr/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    # A deliberately small slice of the Contact Trace Record schema.
    # customerTier and lineOfBusiness are contact ATTRIBUTES, so they land in
    # the map automatically: per-tier reporting needs no extra instrumentation.
    columns {
      name = "contactid"
      type = "string"
    }
    columns {
      name = "channel"
      type = "string"
    }
    columns {
      name = "initiationmethod"
      type = "string"
    }
    columns {
      name = "initiationtimestamp"
      type = "string"
    }
    columns {
      name = "disconnecttimestamp"
      type = "string"
    }
    columns {
      name = "queue"
      type = "struct<name:string,arn:string,enqueuetimestamp:string>"
    }
    columns {
      name = "agent"
      type = "struct<username:string,arn:string,connectedtoagenttimestamp:string>"
    }
    columns {
      name = "attributes"
      type = "map<string,string>"
    }
  }
}

resource "aws_athena_workgroup" "this" {
  name          = "${var.prefix}-workgroup"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # A cost guard: Athena bills per byte scanned. A runaway query stops at 1 GB.
    bytes_scanned_cutoff_per_query = 1073741824

    result_configuration {
      output_location = "s3://${aws_s3_bucket.this["results"].id}/athena/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_athena_named_query" "calls_by_tier" {
  name        = "calls-by-customer-tier"
  description = "Per-tier volume with no extra instrumentation: customerTier is a contact attribute."
  workgroup   = aws_athena_workgroup.this.id
  database    = aws_glue_catalog_database.this.name
  query       = <<-SQL
    SELECT attributes['customerTier'] AS tier,
           COUNT(*)                   AS contacts
    FROM   ctr
    WHERE  year = '2026' AND month = '10'
    GROUP  BY 1
    ORDER  BY 2 DESC
  SQL
}

resource "aws_athena_named_query" "queue_wait" {
  name        = "contacts-by-queue"
  description = "Volume per queue, for service-level reporting."
  workgroup   = aws_athena_workgroup.this.id
  database    = aws_glue_catalog_database.this.name
  query       = <<-SQL
    SELECT queue.name AS queue_name,
           COUNT(*)   AS contacts
    FROM   ctr
    WHERE  year = '2026' AND month = '10'
    GROUP  BY 1
    ORDER  BY 2 DESC
  SQL
}

############################################################################
# Firehose: Kinesis -> S3 as Parquet (Module 12.1)
# Firehose if you only need delivery to S3 with buffering and format
# conversion (simpler, cheaper). Data Streams if you need several independent
# consumers or real-time processing.
############################################################################
locals {
  firehose_on = var.enable_kinesis && var.enable_firehose
}

resource "aws_cloudwatch_log_group" "firehose" {
  count             = local.firehose_on ? 1 : 0
  name              = "/aws/kinesisfirehose/${var.prefix}-ctr-to-s3"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose" {
  count          = local.firehose_on ? 1 : 0
  name           = "DestinationDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose[0].name
}

data "aws_iam_policy_document" "firehose_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "firehose" {
  count = local.firehose_on ? 1 : 0

  statement {
    sid       = "ReadStream"
    actions   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
    resources = [aws_kinesis_stream.this["ctr"].arn]
  }

  statement {
    sid = "WriteLake"
    actions = [
      "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
      "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject",
    ]
    resources = [aws_s3_bucket.this["datalake"].arn, "${aws_s3_bucket.this["datalake"].arn}/*"]
  }

  statement {
    sid       = "ReadSchema"
    actions   = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
    resources = ["*"]
  }

  statement {
    sid       = "UseKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }

  statement {
    sid       = "WriteDeliveryLogs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose[0].arn}:*"]
  }
}

resource "aws_iam_role" "firehose" {
  count              = local.firehose_on ? 1 : 0
  name               = "${upper(var.prefix)}-FirehoseRole"
  assume_role_policy = data.aws_iam_policy_document.firehose_trust.json
}

resource "aws_iam_role_policy" "firehose" {
  count  = local.firehose_on ? 1 : 0
  name   = "deliver-ctr-to-lake"
  role   = aws_iam_role.firehose[0].id
  policy = data.aws_iam_policy_document.firehose[0].json
}

resource "aws_kinesis_firehose_delivery_stream" "ctr" {
  count       = local.firehose_on ? 1 : 0
  name        = "${var.prefix}-ctr-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.this["ctr"].arn
    role_arn           = aws_iam_role.firehose[0].arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose[0].arn
    bucket_arn = aws_s3_bucket.this["datalake"].arn

    prefix              = "ctr/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    # 64 MB is the minimum buffer when format conversion is on.
    buffering_size     = 64
    buffering_interval = 300

    # Parquet does its own (Snappy) compression, so Firehose must not add more.
    compression_format = "UNCOMPRESSED"

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {}
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.this.name
        table_name    = aws_glue_catalog_table.ctr.name
        role_arn      = aws_iam_role.firehose[0].arn
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose[0].name
      log_stream_name = aws_cloudwatch_log_stream.firehose[0].name
    }
  }
}
