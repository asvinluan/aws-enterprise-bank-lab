variable "prefix" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "enable_eks" {
  type = bool
}

variable "cluster_name" {
  type    = string
  default = "meridian-lab"
}

variable "eks_version" {
  type = string
}

variable "node_instance_type" {
  type = string
}

variable "node_desired" {
  type = number
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "public_access_cidrs" {
  type = list(string)
}
