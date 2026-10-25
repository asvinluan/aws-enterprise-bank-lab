############################################################################
# AWS WAF: the bouncer (Module 9.5)
# WAF governs contact INITIATION, not contact CONTENT. Once the browser holds a
# participant token it talks to Connect's own service, which you cannot attach a
# web ACL to. Content is controlled by Contact Lens redaction, Bedrock
# guardrails and your flow logic.
#
# A blocked request never reaches API Gateway, never invokes the Lambda and
# never creates a (billable) contact in Connect.
############################################################################
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${local.upper}-Web-ACL"
  description = "Protects the public chat-start endpoint"
  scope       = "REGIONAL" # must match the API's Region

  default_action {
    allow {}
  }

  # Rule 1: one person can start a few chats a minute, not a few thousand.
  # Honest limit: an attacker rotating IPs stays under the threshold. This stops
  # the lazy attack and the accidental one (a broken integration retrying in a loop).
  rule {
    name     = "RateLimitPerIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.api_rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS writes and updates these. You get AWS's threat research for free.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: COUNT, do not block. Customers travel and use VPNs; blocking outright
  # locks out your own customer in Bali. Count gives visibility without false
  # positives. Tighten later once you have data.
  rule {
    name     = "NonAustralianTraffic"
    priority = 4

    action {
      count {}
    }

    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = ["AU"]
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "NonAustralianTraffic"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.upper}-Web-ACL"
    sampled_requests_enabled   = true
  }
}

# Associate with a specific STAGE so prod can be protected differently from dev.
resource "aws_wafv2_web_acl_association" "api" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
