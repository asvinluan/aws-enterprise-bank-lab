############################################################################
# API Gateway: the door the website knocks on (Module 9.4)
# Browser -> API Gateway -> MB-StartChat (holds the credentials) -> Connect.
# The browser never holds AWS keys.
############################################################################
resource "aws_api_gateway_rest_api" "this" {
  name = "${local.upper}-Web-API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "chat"
}

# POST starts a chat. OPTIONS is the browser's CORS preflight; the Lambda
# answers both (Lambda proxy integration).
resource "aws_api_gateway_method" "chat" {
  for_each = toset(["POST", "OPTIONS"])

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.chat.id
  http_method   = each.key
  authorization = "NONE" # public by design: a customer has not logged in yet. That is exactly why WAF sits in front.
}

resource "aws_api_gateway_integration" "chat" {
  for_each = aws_api_gateway_method.chat

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = each.value.http_method
  integration_http_method = "POST" # API Gateway always calls Lambda with POST
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.fn["start_chat"].invoke_arn
}

resource "aws_lambda_permission" "apigw_invoke_chat" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["start_chat"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*/chat"
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redeploy whenever the API definition changes. Editing without deploying is
  # the API Gateway version of "I changed the flow and forgot to publish".
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.chat.id,
      [for m in aws_api_gateway_method.chat : m.id],
      [for i in aws_api_gateway_integration.chat : i.id],
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.api_stage_name
}

# A second layer behind WAF: even without WAF the stage cannot be driven faster than this.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    throttling_burst_limit = 50
    throttling_rate_limit  = 25
  }
}
