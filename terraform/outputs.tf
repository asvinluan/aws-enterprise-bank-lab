output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "private_subnet_zone_ids" {
  description = "Must be three different zone IDs. Module 10.12 verification."
  value       = module.network.private_subnet_zone_ids
}

output "sg_lambda_id" {
  value = module.network.sg_lambda_id
}

output "sg_account_service_id" {
  description = "Put this in k8s/deployment.yaml (aws-load-balancer-security-groups)."
  value       = module.network.sg_account_service_id
}

output "chat_url" {
  value = module.compute.chat_url
}

output "lambda_functions" {
  value = module.compute.function_names
}

output "ecr_repository_url" {
  value = module.containers.ecr_repository_url
}

output "eks_cluster_name" {
  value = module.containers.eks_cluster_name
}

output "buckets" {
  value = module.data.bucket_ids
}

output "athena_workgroup" {
  value = module.data.athena_workgroup
}

output "kms_key_arn" {
  value = module.security.kms_key_arn
}

output "cost_switches" {
  description = "What is switched ON that bills by the hour. Everything here should be false when you are not testing."
  value = {
    nat_gateway         = var.enable_nat
    interface_endpoints = var.enable_interface_endpoints
    eks                 = var.enable_eks
    kinesis             = var.enable_kinesis
    firehose            = var.enable_firehose
    waf                 = var.enable_waf
    alarms              = var.enable_alarms
  }
}
