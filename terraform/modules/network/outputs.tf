output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  value = aws_subnet.isolated[*].id
}

output "private_subnet_zone_ids" {
  description = "Check these are three DIFFERENT zone IDs: that is what real multi-AZ means."
  value       = aws_subnet.private[*].availability_zone_id
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "sg_lambda_id" {
  value = aws_security_group.lambda.id
}

output "sg_account_service_id" {
  value = aws_security_group.account_service.id
}

output "sg_endpoints_id" {
  value = aws_security_group.endpoints.id
}

output "nat_gateway_id" {
  value = try(aws_nat_gateway.this[0].id, null)
}
