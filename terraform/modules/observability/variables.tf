variable "prefix" {
  type = string
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "function_names" {
  type = map(string)
}

variable "api_name" {
  type = string
}

variable "api_stage_name" {
  type = string
}

variable "connect_instance_id" {
  type    = string
  default = ""
}
