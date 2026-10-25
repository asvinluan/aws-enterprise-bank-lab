output "table_names" {
  value = { customers = aws_dynamodb_table.customers.name, holidays = aws_dynamodb_table.holidays.name, contacts = aws_dynamodb_table.contacts.name }
}

output "bucket_ids" {
  value = { for k, b in aws_s3_bucket.this : k => b.id }
}

output "bucket_arns" {
  value = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "stream_arns" {
  value = { for k, s in aws_kinesis_stream.this : k => s.arn }
}

output "firehose_name" {
  value = try(aws_kinesis_firehose_delivery_stream.ctr[0].name, null)
}

output "glue_database" {
  value = aws_glue_catalog_database.this.name
}

output "athena_workgroup" {
  value = aws_athena_workgroup.this.name
}
