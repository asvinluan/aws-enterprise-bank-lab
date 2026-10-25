variable "prefix" {
  type = string
}

variable "table_names" {
  type = map(string)
}

variable "bucket_names" {
  description = "{ recordings, datalake, results, evidence }"
  type        = map(string)
}

variable "kms_key_arn" {
  type = string
}

variable "enable_kinesis" {
  type = bool
}

variable "enable_firehose" {
  type = bool
}

variable "enable_evidence_bucket" {
  type = bool
}

variable "force_destroy_buckets" {
  type = bool
}

variable "recording_retention_days" {
  type = number
}

variable "glacier_transition_days" {
  type = number
}

variable "seed_customers" {
  type = map(object({
    customerName   = string
    customerTier   = string
    accountId      = string
    lineOfBusiness = string
  }))
}

variable "seed_holidays" {
  type = map(object({
    holidayName    = string
    holidayMessage = string
  }))
}

variable "encrypt_kinesis" {
  description = "Encrypt streams with the CMK. Leave false until you have confirmed Connect delivers, then grant the Connect service-linked role kms:GenerateDataKey."
  type        = bool
  default     = false
}
