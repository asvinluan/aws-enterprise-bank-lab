output "function_names" {
  value = { for k, f in aws_lambda_function.fn : k => f.function_name }
}

output "function_arns" {
  value = { for k, f in aws_lambda_function.fn : k => f.arn }
}

output "chat_url" {
  description = "POST {\"name\":\"Test\"} here. Public and unauthenticated by design."
  value       = "${aws_api_gateway_stage.this.invoke_url}/chat"
}

output "api_name" {
  value = aws_api_gateway_rest_api.this.name
}

output "web_acl_arn" {
  value = try(aws_wafv2_web_acl.this[0].arn, null)
}
