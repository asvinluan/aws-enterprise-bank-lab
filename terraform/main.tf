data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  upper      = upper(var.prefix)

  # Names are computed once, here, and passed down. That lets the IAM policy and
  # the network's S3 endpoint policy refer to buckets and tables BY NAME without
  # depending on the modules that create them (which would be a dependency cycle).
  table_names = {
    customers = "${local.upper}-Customers"
    holidays  = "${local.upper}-Holidays"
    contacts  = "${local.upper}-Contacts"
  }

  bucket_names = {
    recordings = "${var.prefix}-recordings-${local.account_id}"
    datalake   = "${var.prefix}-datalake-${local.account_id}"
    results    = "${var.prefix}-athena-results-${local.account_id}"
    evidence   = "${var.prefix}-evidence-${local.account_id}"
  }

  endpoint_bucket_arns = [
    for k, name in local.bucket_names : "arn:aws:s3:::${name}"
    if k != "evidence" || var.enable_evidence_bucket
  ]

  # ECR serves image LAYERS from an AWS-owned S3 bucket. A strict S3 endpoint
  # policy that names only your buckets silently breaks image pulls unless this
  # one is allowed too. A real lesson from locking the network down.
  ecr_layer_bucket = "arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*"

  wire_connect = var.wire_connect && var.connect_instance_id != ""
}

############################################################################
# Fail early, with a sentence a human can act on, instead of half-way through an apply.
############################################################################
resource "terraform_data" "guards" {
  lifecycle {
    precondition {
      condition     = !var.enable_eks || var.enable_nat
      error_message = "enable_eks needs enable_nat: worker nodes in private subnets reach the cluster, the internet and AWS APIs through the NAT gateway. Set enable_nat = true."
    }

    precondition {
      condition     = !var.enable_firehose || var.enable_kinesis
      error_message = "enable_firehose reads from the Kinesis stream, so it needs enable_kinesis = true."
    }

    precondition {
      condition     = !var.wire_connect || var.connect_instance_id != ""
      error_message = "wire_connect = true needs connect_instance_id (the UUID of your Connect instance)."
    }

    precondition {
      condition     = var.glacier_transition_days >= 30
      error_message = "S3 requires at least 30 days before a Glacier transition."
    }
  }
}

############################################################################
# Module 1: identity and encryption
############################################################################
module "security" {
  source = "./modules/security"

  prefix                 = var.prefix
  table_names            = local.table_names
  recordings_bucket_name = local.bucket_names["recordings"]
  connect_instance_id    = var.connect_instance_id
}

############################################################################
# Module 10: the network
############################################################################
module "network" {
  source = "./modules/network"

  prefix                      = var.prefix
  vpc_cidr                    = var.vpc_cidr
  enable_nat                  = var.enable_nat
  enable_interface_endpoints  = var.enable_interface_endpoints
  enable_flow_logs            = var.enable_flow_logs
  interface_endpoint_services = var.interface_endpoint_services
  flow_log_retention_days     = var.flow_log_retention_days
  s3_allowed_bucket_arns      = local.endpoint_bucket_arns
  extra_s3_endpoint_resources = [local.ecr_layer_bucket]
}

############################################################################
# Modules 3 and 12: data, records, streaming, analytics
############################################################################
module "data" {
  source = "./modules/data"

  prefix                   = var.prefix
  table_names              = local.table_names
  bucket_names             = local.bucket_names
  kms_key_arn              = module.security.kms_key_arn
  enable_kinesis           = var.enable_kinesis
  enable_firehose          = var.enable_firehose
  enable_evidence_bucket   = var.enable_evidence_bucket
  force_destroy_buckets    = var.force_destroy_buckets
  recording_retention_days = var.recording_retention_days
  glacier_transition_days  = var.glacier_transition_days
  seed_customers           = var.seed_customers
  seed_holidays            = var.seed_holidays
}

############################################################################
# Modules 4, 9 and 13: Lambda, API Gateway, WAF
############################################################################
module "compute" {
  source = "./modules/compute"

  prefix                   = var.prefix
  source_root              = "${path.root}/../app/lambdas"
  lambda_role_arn          = module.security.lambda_role_arn
  table_names              = module.data.table_names
  recordings_bucket_id     = module.data.bucket_ids["recordings"]
  recordings_bucket_arn    = module.data.bucket_arns["recordings"]
  caller_lookup_in_vpc     = var.caller_lookup_in_vpc
  private_subnet_ids       = module.network.private_subnet_ids
  lambda_security_group_id = module.network.sg_lambda_id
  connect_instance_id      = var.connect_instance_id
  connect_contact_flow_id  = var.connect_contact_flow_id
  account_api_url          = var.account_api_url
  enable_waf               = var.enable_waf
  api_rate_limit_per_5min  = var.api_rate_limit_per_5min
  api_stage_name           = var.api_stage_name
}

############################################################################
# Module 11: containers
############################################################################
module "containers" {
  source = "./modules/containers"

  prefix              = var.prefix
  kms_key_arn         = module.security.kms_key_arn
  enable_eks          = var.enable_eks
  eks_version         = var.eks_version
  node_instance_type  = var.eks_node_instance_type
  node_desired        = var.eks_node_desired
  private_subnet_ids  = module.network.private_subnet_ids
  public_subnet_ids   = module.network.public_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs

  depends_on = [terraform_data.guards]
}

############################################################################
# Module 14: observability
############################################################################
module "observability" {
  count  = var.enable_alarms ? 1 : 0
  source = "./modules/observability"

  prefix              = var.prefix
  alarm_email         = var.alarm_email
  function_names      = module.compute.function_names
  api_name            = module.compute.api_name
  api_stage_name      = var.api_stage_name
  connect_instance_id = var.connect_instance_id
}
