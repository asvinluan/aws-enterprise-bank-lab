output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "kms_key_id" {
  value = aws_kms_key.this.key_id
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "lambda_role_name" {
  value = aws_iam_role.lambda.name
}
