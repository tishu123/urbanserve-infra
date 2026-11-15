# WAF in front of CloudFront (scope CLOUDFRONT => must be created in us-east-1).
# Created only when var.enable_waf = true (off in the lean/free-credits profile).
# Rule order: allow nothing explicitly; block bad IPs/geos, rate-limit, then AWS managed rules.

resource "aws_wafv2_ip_set" "blocked" {
  count    = var.enable_waf ? 1 : 0
  provider           = aws.us_east_1
  name               = "${local.name}-blocked-ips"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.blocked_ip_cidrs
}

resource "aws_wafv2_web_acl" "cloudfront" {
  count    = var.enable_waf ? 1 : 0
  provider    = aws.us_east_1
  name        = "${local.name}-cloudfront"
  description = "Protects ${local.name} web and API"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 1. Manual IP blocklist
  rule {
    name     = "block-listed-ips"
    priority = 0
    action {
      block {}
    }
    statement {
      ip_set_reference_statement { arn = aws_wafv2_ip_set.blocked[0].arn }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-listed-ips"
      sampled_requests_enabled   = true
    }
  }

  # 2. Optional geo blocking
  dynamic "rule" {
    for_each = length(var.blocked_countries) > 0 ? [1] : []
    content {
      name     = "block-countries"
      priority = 1
      action {
        block {}
      }
      statement {
        geo_match_statement { country_codes = var.blocked_countries }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "block-countries"
        sampled_requests_enabled   = true
      }
    }
  }

  # 3. AWS threat-intel IP reputation (botnets, known attackers)
  rule {
    name     = "aws-ip-reputation"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # 4. Anonymous IPs (VPN/Tor/hosting). Count-only unless block_anonymous_ips = true.
  rule {
    name     = "aws-anonymous-ip"
    priority = 3
    override_action {
      dynamic "none" {
        for_each = var.block_anonymous_ips ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.block_anonymous_ips ? [] : [1]
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAnonymousIpList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-anonymous-ip"
      sampled_requests_enabled   = true
    }
  }

  # 5. Rate limit on the API (booking spam, enumeration of /api/bookings?phone=)
  rule {
    name     = "rate-limit-api"
    priority = 4
    action {
      block {
        custom_response { response_code = 429 }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.api_rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-api"
      sampled_requests_enabled   = true
    }
  }

  # 6. Overall rate limit (basic L7 flood protection)
  rule {
    name     = "rate-limit-site"
    priority = 5
    action {
      block {
        custom_response { response_code = 429 }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.site_rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-site"
      sampled_requests_enabled   = true
    }
  }

  # 7. OWASP-style common protections (XSS, LFI, bad bots, oversize requests)
  rule {
    name     = "aws-common"
    priority = 6
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  # 8. Known bad inputs (Log4Shell, Java deserialization, etc. — relevant for Spring)
  rule {
    name     = "aws-known-bad-inputs"
    priority = 7
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # 9. SQL injection
  rule {
    name     = "aws-sqli"
    priority = 8
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-sqli"
      sampled_requests_enabled   = true
    }
  }

  # 10. OTP abuse: SMS costs money and OTP endpoints are a brute-force target.
  #     (The app also limits per phone: 30 s cooldown, 5 codes/hour, 5 attempts per code.)
  rule {
    name     = "rate-limit-otp"
    priority = 9
    action {
      block {
        custom_response { response_code = 429 }
      }
    }
    statement {
      rate_based_statement {
        limit                 = var.otp_rate_limit_per_5min
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/auth/otp/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-otp"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-cloudfront"
    sampled_requests_enabled   = true
  }
}

# WAF logs: blocked requests only, to CloudWatch (log group name must start with aws-waf-logs-).
resource "aws_cloudwatch_log_group" "waf" {
  count    = var.enable_waf ? 1 : 0
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  count    = var.enable_waf ? 1 : 0
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.cloudfront[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition { action = "BLOCK" }
      }
    }
  }
}
