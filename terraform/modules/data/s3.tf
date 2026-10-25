locals {
  buckets = merge(
    {
      recordings = { name = var.bucket_names["recordings"], kms = true, versioned = true }
      datalake   = { name = var.bucket_names["datalake"], kms = true, versioned = false }
      results    = { name = var.bucket_names["results"], kms = false, versioned = false }
    },
    var.enable_evidence_bucket ? {
      evidence = { name = var.bucket_names["evidence"], kms = true, versioned = true }
    } : {}
  )

  # Only add a Glacier transition if it happens BEFORE the object expires.
  # S3 rejects a lifecycle rule whose transition is after its expiry.
  transition_ok = var.glacier_transition_days < var.recording_retention_days
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = each.value.name
  force_destroy = var.force_destroy_buckets

  # Object Lock can ONLY be switched on when the bucket is created.
  # It is an architecture decision, not an operations one.
  object_lock_enabled = each.key == "evidence"
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    # bucket_key_enabled cuts KMS request costs by roughly 99 percent.
    bucket_key_enabled = each.value.kms

    apply_server_side_encryption_by_default {
      sse_algorithm     = each.value.kms ? "aws:kms" : "AES256"
      kms_master_key_id = each.value.kms ? var.kms_key_arn : null
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = { for k, v in local.buckets : k => v if v.versioned }
  bucket   = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Deny any request that is not over TLS.
data "aws_iam_policy_document" "tls_only" {
  for_each = local.buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this[each.key].arn,
      "${aws_s3_bucket.this[each.key].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id
  policy   = data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

############################################################################
# Lifecycle for recordings (Module 12.3 and 12.4)
############################################################################
resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket = aws_s3_bucket.this["recordings"].id

  # THE TRAP: by default S3 does not transition objects under 128 KB, and short
  # call recordings are routinely smaller. The rule looks like it works and
  # nothing archives. Set this explicitly.
  transition_default_minimum_object_size = "varies_by_storage_class"

  rule {
    id     = "priority-audio"
    status = "Enabled"

    filter {
      prefix = "recordings/priority/"
    }

    # Priority audio -> Glacier INSTANT Retrieval: a dispute is exactly the
    # recording someone demands at short notice.
    dynamic "transition" {
      for_each = local.transition_ok ? [1] : []
      content {
        days          = var.glacier_transition_days
        storage_class = "GLACIER_IR"
      }
    }

    expiration {
      days = var.recording_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "general-audio"
    status = "Enabled"

    filter {
      prefix = "recordings/general/"
    }

    # General audio -> Glacier FLEXIBLE Retrieval: pure archive, minutes to hours is fine.
    dynamic "transition" {
      for_each = local.transition_ok ? [1] : []
      content {
        days          = var.glacier_transition_days
        storage_class = "GLACIER"
      }
    }

    expiration {
      days = var.recording_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "clean-up-landing-prefix"
    status = "Enabled"

    filter {
      prefix = "connect/"
    }

    expiration {
      days = 7
    }
  }

  # Copy-then-delete in the router leaves old versions behind in a versioned bucket.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.this["results"].id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

############################################################################
# Evidence copy: Object Lock (optional design demo)
# GOVERNANCE mode here so you can still clean up. In a bank this is COMPLIANCE
# mode in a SEPARATE ACCOUNT, because Compliance cannot be overridden by anyone.
############################################################################
resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  count  = var.enable_evidence_bucket ? 1 : 0
  bucket = aws_s3_bucket.this["evidence"].id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
