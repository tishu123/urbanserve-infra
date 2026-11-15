# One distribution, two origins:
#   /*      -> S3 (React build)          cached, SPA routing via CloudFront Function
#   /api/*  -> EC2 (or ALB -> EC2)      never cached, all methods
# Same domain for UI and API, so the browser never needs CORS.

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.name}-oac"
  description                       = "OAC for ${aws_s3_bucket.site.bucket}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Shared secret CloudFront adds to every /api request; the ALB (if used) and the Spring app
# reject requests without it.
resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

# --- Managed policies (looked up by name, so no hard-coded IDs) ---
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# --- SPA routing: /services/home-cleaning -> /index.html (only for the S3 behaviour,
#     so real API 404s are not rewritten into HTML). ---
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${local.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Serve index.html for client-side routes"
  publish = true
  code    = <<-JS
    function handler(event) {
      var req = event.request;
      var uri = req.uri;
      // Paths without a file extension are React routes.
      if (uri === '/' || uri.lastIndexOf('.') <= uri.lastIndexOf('/')) {
        req.uri = '/index.html';
      }
      return req;
    }
  JS
}

# --- Security headers on every response ---
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${local.name}-security-headers"
  comment = "HSTS, CSP, frame/sniff protection"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000 # 2 years
      include_subdomains         = true
      preload                    = false # set true only once you're sure every subdomain is HTTPS
      override                   = true
    }
    content_security_policy {
      # 'unsafe-inline' for styles only: React style={{...}} props render as style attributes.
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "upgrade-insecure-requests",
      ])
      override = true
    }
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    xss_protection {
      protection = false # legacy header; CSP replaces it. Sends "X-XSS-Protection: 0".
      override   = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), payment=()"
      override = true
    }
  }

  remove_headers_config {
    items { header = "Server" }
    items { header = "X-Powered-By" }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "${local.name} web + api"
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = var.domain_aliases
  web_acl_id          = one(aws_wafv2_web_acl.cloudfront[*].arn)

  # ---------- Origins ----------
  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    origin_id   = "api"
    # Lean: the instance's Elastic IP DNS name, port 8080. Scale: the ALB.
    domain_name = var.use_alb ? (local.alb_https ? var.alb_origin_domain : one(aws_lb.api[*].dns_name)) : one(aws_eip.app[*].public_dns)

    custom_origin_config {
      http_port                = var.use_alb ? 80 : 8080
      https_port               = 443
      origin_protocol_policy   = var.use_alb && local.alb_https ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  # ---------- Behaviours ----------
  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # ---------- TLS ----------
  viewer_certificate {
    cloudfront_default_certificate = var.cloudfront_certificate_arn == null
    acm_certificate_arn            = var.cloudfront_certificate_arn
    ssl_support_method             = var.cloudfront_certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.cloudfront_certificate_arn == null ? "TLSv1" : "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" } # geo blocking is handled in WAF
  }

  logging_config {
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    prefix          = "cloudfront/"
    include_cookies = false
  }

  depends_on = [aws_s3_bucket_ownership_controls.logs]
}
