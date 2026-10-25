############################################################################
# Identity and naming
############################################################################
variable "region" {
  description = "AWS Region. Everything in the lab lives in Sydney."
  type        = string
  default     = "ap-southeast-2"
}

variable "prefix" {
  description = "Short lower-case prefix. Resources become mb-* (network, buckets) and MB-* (Lambda, DynamoDB), as in the lab."
  type        = string
  default     = "mb"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.prefix))
    error_message = "prefix must be 2-6 lower-case letters or digits, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags added to every resource."
  type        = map(string)
  default     = {}
}

############################################################################
# COST SWITCHES. Everything that bills by the hour defaults to OFF.
# See docs/CLEANUP.md for what each one costs.
############################################################################
variable "enable_nat" {
  description = "NAT gateway + Elastic IP (about 0.059 USD/hour plus data in Sydney). Gives private subnets a route OUT to the internet."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Interface VPC endpoints (billed per endpoint per AZ per hour). Keeps AWS API traffic off the internet."
  type        = bool
  default     = false
}

variable "enable_eks" {
  description = "EKS cluster and managed node group. Needs enable_nat. About 0.10 USD/hour control plane (0.60 if the version is in extended support) plus nodes."
  type        = bool
  default     = false
}

variable "enable_kinesis" {
  description = "Kinesis Data Streams for contact trace records and agent events (per shard-hour, even idle)."
  type        = bool
  default     = false
}

variable "enable_firehose" {
  description = "Firehose delivery stream from Kinesis to S3 as Parquet. Needs enable_kinesis."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "WAF web ACL on the chat API (monthly fee per ACL and per rule)."
  type        = bool
  default     = false
}

variable "enable_alarms" {
  description = "CloudWatch alarms and an SNS topic (about 0.10 USD per alarm per month)."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "VPC flow logs to CloudWatch Logs (pay per GB ingested; tiny at lab volumes)."
  type        = bool
  default     = true
}

variable "enable_evidence_bucket" {
  description = "A second, Object Lock bucket for the evidence copy of recordings (design demo; GOVERNANCE mode so you can still clean it up)."
  type        = bool
  default     = false
}

############################################################################
# Network
############################################################################
variable "vpc_cidr" {
  description = "VPC CIDR. Must be a /16 so the subnet maths in modules/network lines up with the lab's plan."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR block."
  }
}

variable "interface_endpoint_services" {
  description = "Interface endpoint service short names (used only when enable_interface_endpoints = true)."
  type        = list(string)
  default     = ["kms", "secretsmanager", "kinesis-streams", "bedrock-runtime", "ecr.api", "ecr.dkr", "logs", "sts"]
}

variable "flow_log_retention_days" {
  description = "Retention for the VPC flow log group."
  type        = number
  default     = 7
}

############################################################################
# Data and records
############################################################################
variable "recording_retention_days" {
  description = "Expiry for recordings. 2555 days = 7 years (legal number). Use 30 in a dev environment."
  type        = number
  default     = 30
}

variable "glacier_transition_days" {
  description = "Days before recordings move to Glacier storage classes. Must be less than recording_retention_days."
  type        = number
  default     = 180
}

variable "force_destroy_buckets" {
  description = "Let terraform destroy empty and delete the buckets. Right for a lab, wrong for production."
  type        = bool
  default     = true
}

variable "seed_customers" {
  description = "Rows for MB-Customers. Keys are E.164 phone numbers. Use made-up numbers in anything you commit."
  type = map(object({
    customerName   = string
    customerTier   = string
    accountId      = string
    lineOfBusiness = string
  }))
  default = {
    "+61400000001" = { customerName = "Alex", customerTier = "PRIORITY", accountId = "MB-770001", lineOfBusiness = "HOME_LOAN" }
    "+61400000002" = { customerName = "Sarah", customerTier = "GENERAL", accountId = "MB-770002", lineOfBusiness = "EVERYDAY" }
  }
}

variable "seed_holidays" {
  description = "Rows for MB-Holidays. Keys are YYYY-MM-DD. No apostrophes or ampersands in messages (text-to-speech)."
  type = map(object({
    holidayName    = string
    holidayMessage = string
  }))
  default = {
    "2026-12-25" = { holidayName = "Christmas Day", holidayMessage = "our contact centre is closed today" }
  }
}

############################################################################
# Compute and edge
############################################################################
variable "connect_instance_id" {
  description = "ID of your Amazon Connect instance (a UUID). Leave empty to skip everything that needs Connect."
  type        = string
  default     = ""
}

variable "connect_contact_flow_id" {
  description = "Contact flow the chat Lambda starts (the MB-Main flow id)."
  type        = string
  default     = "REPLACE-WITH-FLOW-ID"
}

variable "wire_connect" {
  description = "Associate the Lambdas, recordings bucket and Kinesis streams with the Connect instance. Needs connect_instance_id."
  type        = bool
  default     = false
}

variable "account_api_url" {
  description = "Base URL of the account service (the internal load balancer DNS name, with http:// and port). Empty = skip the balance lookup."
  type        = string
  default     = ""
}

variable "caller_lookup_in_vpc" {
  description = "Attach MB-CallerLookup to the three private subnets (Module 10.9)."
  type        = bool
  default     = true
}

variable "api_rate_limit_per_5min" {
  description = "WAF rate limit per source IP per 5 minutes on the chat endpoint."
  type        = number
  default     = 100
}

variable "api_stage_name" {
  description = "API Gateway stage name."
  type        = string
  default     = "prod"
}

############################################################################
# Containers
############################################################################
variable "eks_version" {
  description = "Kubernetes version. CHECK the EKS release calendar: a version past standard support bills 6x more."
  type        = string
  default     = "1.35"
}

variable "eks_node_instance_type" {
  description = "Worker node instance type."
  type        = string
  default     = "t3.small"
}

variable "eks_node_desired" {
  description = "Worker node count."
  type        = number
  default     = 2
}

variable "eks_public_access_cidrs" {
  description = "Who may reach the Kubernetes API endpoint from the internet. Set this to your own IP /32. A bank would disable public access entirely."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

############################################################################
# Alerts
############################################################################
variable "alarm_email" {
  description = "Email subscribed to the alarm topic. An alarm to a topic nobody reads is decoration."
  type        = string
  default     = ""
}
