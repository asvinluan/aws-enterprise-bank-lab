# The cheap profile: the whole design, nothing that bills by the hour.
# VPC, subnets, route tables, security groups, gateway endpoints, Lambda,
# API Gateway, DynamoDB, S3, ECR, Glue, Athena, flow logs: pennies a month.
enable_nat                 = false
enable_interface_endpoints = false
enable_eks                 = false
enable_kinesis             = false
enable_firehose            = false
enable_waf                 = false
enable_alarms              = false
enable_flow_logs           = true
