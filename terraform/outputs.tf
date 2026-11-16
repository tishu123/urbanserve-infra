output "site_url" {
  description = "Open this in a browser."
  value       = length(var.domain_aliases) > 0 ? "https://${var.domain_aliases[0]}" : "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "cloudfront_domain" {
  description = "Point your DNS (CNAME / Route 53 alias) for domain_aliases here."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "alb_dns_name" {
  description = "Only with use_alb = true. If using alb_origin_domain, CNAME it to this."
  value       = var.use_alb ? one(aws_lb.api[*].dns_name) : null
}

output "api_origin" {
  description = "Where CloudFront sends /api/* (direct requests are blocked by the security group and origin secret)."
  value       = var.use_alb ? one(aws_lb.api[*].dns_name) : "${coalesce(one(aws_eip.app[*].public_dns), "n/a")}:8080"
}

output "app_instance_id" {
  description = "Shell access: aws ssm start-session --target <this>"
  value       = aws_instance.app.id
}

output "waf_web_acl_arn" {
  value = one(aws_wafv2_web_acl.cloudfront[*].arn)
}

output "db_endpoint" {
  description = "RDS endpoint, or 127.0.0.1 on the instance when db_mode = \"ec2\"."
  value       = local.use_rds ? one(aws_db_instance.main[*].address) : "127.0.0.1 (on ${aws_instance.app.id})"
}

output "app_config_parameter" {
  description = "SSM SecureString holding DB credentials, JWT key and origin secret."
  value       = aws_ssm_parameter.app_config.name
}

output "dispatch_config_parameter" {
  description = "SSM SecureString holding dispatch's DB credentials and queue URLs."
  value       = aws_ssm_parameter.dispatch_config.name
}

output "payment_config_parameter" {
  description = "SSM SecureString holding the payment service's DB credentials and Razorpay keys."
  value       = aws_ssm_parameter.payment_config.name
}

output "sqs_queue_urls" {
  description = "Booking <-> dispatch queues."
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "sqs_dead_letter_queues" {
  description = "Messages that failed 5 times end up here (an alarm emails budget_alert_email)."
  value       = { for k, q in aws_sqs_queue.dlq : k => q.name }
}

