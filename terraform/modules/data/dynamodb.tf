# On-demand capacity: contact-centre traffic is spiky, and on-demand costs
# nothing when idle. Partition keys are the thing you LOOK UP by, so every
# read is a single-key GetItem and never a scan.

resource "aws_dynamodb_table" "customers" {
  name         = var.table_names["customers"]
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phoneNumber"

  attribute {
    name = "phoneNumber"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "holidays" {
  name         = var.table_names["holidays"]
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "holidayDate"

  attribute {
    name = "holidayDate"
    type = "S"
  }
}

resource "aws_dynamodb_table" "contacts" {
  name         = var.table_names["contacts"]
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "contactId"

  attribute {
    name = "contactId"
    type = "S"
  }

  # Written during the call, read after it. Nothing here needs to live forever.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table_item" "customer" {
  for_each   = var.seed_customers
  table_name = aws_dynamodb_table.customers.name
  hash_key   = aws_dynamodb_table.customers.hash_key

  item = jsonencode({
    phoneNumber    = { S = each.key }
    customerName   = { S = each.value.customerName }
    customerTier   = { S = each.value.customerTier }
    accountId      = { S = each.value.accountId }
    lineOfBusiness = { S = each.value.lineOfBusiness }
  })
}

resource "aws_dynamodb_table_item" "holiday" {
  for_each   = var.seed_holidays
  table_name = aws_dynamodb_table.holidays.name
  hash_key   = aws_dynamodb_table.holidays.hash_key

  item = jsonencode({
    holidayDate    = { S = each.key }
    holidayName    = { S = each.value.holidayName }
    holidayMessage = { S = each.value.holidayMessage }
  })
}
