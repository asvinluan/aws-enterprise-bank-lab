data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Three AZs. ap-southeast-2 has exactly three. ZoneIds are exported below
  # because zone NAMES are shuffled per account but zone IDs are not.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # The CIDR plan from the lab, expressed as maths on the /16:
  #   public   10.20.0.0/24  .1.0/24  .2.0/24     (netnum 0..2, +8 bits)
  #   private  10.20.10.0/23 .12.0/23 .14.0/23    (netnum 5..7, +7 bits)
  #   isolated 10.20.30.0/24 .31.0/24 .32.0/24    (netnum 30..32, +8 bits)
  public_cidrs   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 7, i + 5)]
  isolated_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 30)]

  endpoint_services = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])
}

############################################################################
# VPC
############################################################################
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required for interface endpoints to resolve to private addresses.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.prefix}-vpc" }
}

# The default security group allows all traffic between its members.
# Strip every rule so nothing can accidentally rely on it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-default-locked" }
}

############################################################################
# Subnets: three tiers x three Availability Zones
############################################################################
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # nothing in here needs an automatic public address

  tags = { Name = "${var.prefix}-public-${substr(local.azs[count.index], -1, 1)}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.prefix}-private-${substr(local.azs[count.index], -1, 1)}", Tier = "private" }
}

resource "aws_subnet" "isolated" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.isolated_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.prefix}-isolated-${substr(local.azs[count.index], -1, 1)}", Tier = "isolated" }
}

############################################################################
# Internet gateway, NAT gateway, route tables
############################################################################
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # a NAT lives in a PUBLIC subnet
  tags          = { Name = "${var.prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# PUBLIC: default route to the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# PRIVATE: default route goes to the NAT, NOT the internet gateway.
# Traffic can go OUT. Nothing can come IN. That is what "private" means.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-rt-private" }
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ISOLATED: no default route at all. A compromised database cannot phone home.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-rt-isolated" }
}

resource "aws_route_table_association" "isolated" {
  count          = 3
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

############################################################################
# Security groups. Rules reference GROUPS, not CIDRs: the rule follows the
# workload wherever it runs.
############################################################################
resource "aws_security_group" "lambda" {
  name        = "${var.prefix}-sg-lambda"
  description = "Lambda functions reaching internal services"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.prefix}-sg-lambda" }
}

resource "aws_security_group" "account_service" {
  name        = "${var.prefix}-sg-account-service"
  description = "Account service - reachable only from the Lambda"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.prefix}-sg-account-service" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.prefix}-sg-endpoints"
  description = "VPC interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.prefix}-sg-endpoints" }
}

# "Anything wearing the Lambda badge may reach port 8080 on anything wearing
# the account-service badge." No IP addresses involved.
resource "aws_vpc_security_group_ingress_rule" "service_from_lambda" {
  security_group_id            = aws_security_group.account_service.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Account service from Lambda"
}

# Endpoints accept HTTPS from inside the VPC only.
resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from inside the VPC"
}

# A security group created by Terraform has NO egress rule (the console adds
# allow-all for you). So the Lambda's permitted destinations are explicit.
resource "aws_vpc_security_group_egress_rule" "lambda_to_service" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.account_service.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "To the account service"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_endpoints" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "To interface endpoints"
}

# Gateway endpoints are reached through a managed PREFIX LIST of the service's
# addresses, not through the VPC CIDR. Without these two rules a VPC Lambda
# cannot reach DynamoDB or S3 even though the endpoints exist.
resource "aws_vpc_security_group_egress_rule" "lambda_to_dynamodb" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.dynamodb.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "To DynamoDB via the gateway endpoint"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "To S3 via the gateway endpoint"
}

############################################################################
# VPC endpoints: where security and cost agree
############################################################################
# GATEWAY endpoints (S3 and DynamoDB only) are free: a route-table entry,
# not a network interface.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.isolated.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json
  tags              = { Name = "${var.prefix}-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.isolated.id]
  tags              = { Name = "${var.prefix}-vpce-dynamodb" }
}

# Endpoint policy = data-exfiltration control. Without it, code inside the VPC
# can reach ANY bucket in the world through this endpoint.
data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "OnlyOurBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetObjectTagging", "s3:PutObjectTagging", "s3:DeleteObject"]
    resources = concat(var.s3_allowed_bucket_arns, [for a in var.s3_allowed_bucket_arns : "${a}/*"], var.extra_s3_endpoint_resources)

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

# INTERFACE endpoints: everything else. Billed per hour per AZ plus per GB.
# private_dns_enabled makes kms.ap-southeast-2.amazonaws.com resolve to a
# private address, so application code does not change at all.
resource "aws_vpc_endpoint" "interface" {
  for_each = local.endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.prefix}-vpce-${replace(each.key, ".", "-")}" }
}

############################################################################
# Flow logs: your CDRs for the network
############################################################################
resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/${var.prefix}-flowlogs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_write" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.flow[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_flow_logs ? 1 : 0
  name               = "${var.prefix}-flowlogs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_trust.json
}

resource "aws_iam_role_policy" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  name   = "write-flow-logs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_write[0].json
}

resource "aws_flow_log" "this" {
  count                    = var.enable_flow_logs ? 1 : 0
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn             = aws_iam_role.flow[0].arn
  max_aggregation_interval = 600
  tags                     = { Name = "${var.prefix}-flowlog" }
}
