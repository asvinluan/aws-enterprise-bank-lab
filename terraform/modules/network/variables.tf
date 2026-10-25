variable "prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "enable_nat" {
  type = bool
}

variable "enable_interface_endpoints" {
  type = bool
}

variable "enable_flow_logs" {
  type = bool
}

variable "interface_endpoint_services" {
  type = list(string)
}

variable "flow_log_retention_days" {
  type = number
}

variable "s3_allowed_bucket_arns" {
  description = "Bucket ARNs the S3 gateway endpoint policy permits (the data-exfiltration control)."
  type        = list(string)
}

variable "extra_s3_endpoint_resources" {
  description = "Extra S3 ARNs to permit through the endpoint, e.g. AWS-owned buckets that ECR image layers are served from."
  type        = list(string)
  default     = []
}
