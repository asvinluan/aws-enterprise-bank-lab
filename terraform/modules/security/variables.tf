variable "prefix" {
  type = string
}

variable "table_names" {
  description = "DynamoDB table names: { customers, holidays, contacts }."
  type        = map(string)
}

variable "recordings_bucket_name" {
  type = string
}

variable "connect_instance_id" {
  description = "Empty string = allow any instance in this account/Region."
  type        = string
  default     = ""
}
