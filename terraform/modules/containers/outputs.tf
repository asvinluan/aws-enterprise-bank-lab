output "ecr_repository_url" {
  value = aws_ecr_repository.account_service.repository_url
}

output "ecr_repository_name" {
  value = aws_ecr_repository.account_service.name
}

output "eks_cluster_name" {
  value = try(aws_eks_cluster.this[0].name, null)
}

output "eks_endpoint" {
  value = try(aws_eks_cluster.this[0].endpoint, null)
}
