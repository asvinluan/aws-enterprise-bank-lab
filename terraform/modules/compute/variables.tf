variable "prefix" {
  type = string
}

variable "source_root" {
  description = "Directory that holds one folder per Lambda (app/lambdas)."
  type        = string
}

variable "lambda_role_arn" {
  type = string
}

variable "table_names" {
  type = map(string)
}

variable "recordings_bucket_id" {
  type = string
}

variable "recordings_bucket_arn" {
  type = string
}

variable "caller_lookup_in_vpc" {
  type = bool
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "lambda_security_group_id" {
  type = string
}

variable "connect_instance_id" {
  type = string
}

variable "connect_contact_flow_id" {
  type = string
}

variable "account_api_url" {
  type = string
}

variable "enable_waf" {
  type = bool
}

variable "api_rate_limit_per_5min" {
  type = number
}

variable "api_stage_name" {
  type = string
}
