variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "urbanserve"
}

variable "environment" {
  description = "Environment name (prod, staging, ...)."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "Region for S3, ALB and EC2. ap-south-1 = Mumbai."
  type        = string
  default     = "ap-south-1"
}

# ---------- Custom domain (optional) ----------
variable "domain_aliases" {
  description = "Custom domains for the site, e.g. [\"www.urbanserve.in\"]. Empty = use the *.cloudfront.net domain."
  type        = list(string)
  default     = []
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 covering domain_aliases. Required when domain_aliases is set."
  type        = string
  default     = null
}

variable "price_class" {
  description = "PriceClass_200 includes India; PriceClass_All adds South America/Australia."
  type        = string
  default     = "PriceClass_200"
}

# ---------- Backend (EC2 + ALB) ----------
variable "vpc_id" {
  description = "VPC for the ALB and EC2. null = default VPC."
  type        = string
  default     = null
}

variable "alb_subnet_ids" {
  description = "Public subnets (2+ AZs) for the ALB. Empty = all default-VPC subnets."
  type        = list(string)
  default     = []
}

variable "ec2_subnet_id" {
  description = "Subnet for the EC2 instance. Prefer a private subnet with a NAT gateway. null = first ALB subnet."
  type        = string
  default     = null
}

variable "ec2_associate_public_ip" {
  description = "Give EC2 a public IP (needed in default-VPC public subnets to reach S3/SSM without NAT). No inbound ports are opened either way."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "t4g.medium (ARM, 4 GB) runs the API, dispatch and PostgreSQL together. t4g.small (2 GB) is too tight for two Java services."
  type        = string
  default     = "t4g.medium"
}

# ---------- Cost profile ----------
variable "use_alb" {
  description = "false (lean): CloudFront talks directly to EC2. true: put an Application Load Balancer in between (~$18/month + 2 public IPs)."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Attach AWS WAF to CloudFront (~$15/month + requests). Turn on before a public launch or if you see abuse."
  type        = bool
  default     = false
}

variable "db_mode" {
  description = "\"ec2\" = PostgreSQL on the app instance (cheapest). \"rds\" = managed RDS PostgreSQL."
  type        = string
  default     = "ec2"
  validation {
    condition     = contains(["ec2", "rds"], var.db_mode)
    error_message = "db_mode must be \"ec2\" or \"rds\"."
  }
}

variable "pgdata_volume_gb" {
  description = "Size of the separate PostgreSQL data disk when db_mode = \"ec2\"."
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Email for AWS Budgets alerts. null = no budget created (not recommended)."
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Monthly budget; alerts at 50%, 80% and 100% (actual) and 100% (forecast)."
  type        = number
  default     = 30
}

variable "alb_certificate_arn" {
  description = "ACM cert (in var.region) for alb_origin_domain. Set both to encrypt CloudFront->ALB traffic (recommended)."
  type        = string
  default     = null
}

variable "alb_origin_domain" {
  description = "DNS name (e.g. origin-api.urbanserve.in) CNAME'd to the ALB, matching alb_certificate_arn."
  type        = string
  default     = null
}

variable "alb_deletion_protection" {
  type    = bool
  default = true
}

# ---------- WAF ----------
variable "api_rate_limit_per_5min" {
  description = "Max /api/* requests per client IP per 5 minutes before blocking."
  type        = number
  default     = 300
}

variable "site_rate_limit_per_5min" {
  description = "Max requests (any path) per client IP per 5 minutes."
  type        = number
  default     = 2000
}

variable "blocked_countries" {
  description = "ISO 3166 country codes to block, e.g. [\"KP\"]. Empty = no geo blocking."
  type        = list(string)
  default     = []
}

variable "blocked_ip_cidrs" {
  description = "IPv4 CIDRs to always block, e.g. [\"203.0.113.0/24\"]."
  type        = list(string)
  default     = []
}

variable "block_anonymous_ips" {
  description = "Block VPNs/Tor/hosting-provider IPs (AWS managed list). Can block some genuine users; starts in count mode when false."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 90
}

# ---------- Database (RDS PostgreSQL) ----------
variable "db_instance_class" {
  description = "db.t4g.micro is fine to start; db.t4g.small+ for real traffic."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "16"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  description = "Standby replica in a second AZ (roughly doubles DB cost). Recommended for production."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_subnet_ids" {
  description = "Subnets (2+ AZs) for RDS. Prefer private subnets. Empty = same as ALB subnets (DB is still not publicly accessible)."
  type        = list(string)
  default     = []
}

# ---------- Auth / OTP ----------
variable "otp_sender" {
  description = "\"messagecentral\" = Message Central VerifyNow (real SMS, no DLT registration of your own). \"sns\" = Amazon SNS (needs your own DLT registration). \"log\" = codes in the server log (testing only)."
  type        = string
  default     = "messagecentral"
  validation {
    condition     = contains(["messagecentral", "sns", "log"], var.otp_sender)
    error_message = "otp_sender must be \"messagecentral\", \"sns\" or \"log\"."
  }
}

variable "messagecentral_customer_id" {
  description = "Message Central customer ID (console home page). Used when otp_sender = \"messagecentral\"."
  type        = string
  default     = "C-DC8D1C144CA446C"
}

variable "messagecentral_password" {
  description = "Message Central account password. Required when otp_sender = \"messagecentral\". Set it in terraform.tfvars (git-ignored) or TF_VAR_messagecentral_password; it is stored only in the encrypted SSM parameter (and Terraform state)."
  type        = string
  default     = null
  sensitive   = true
}

variable "messagecentral_flow_type" {
  description = "How Message Central delivers the OTP: \"SMS\" or \"WHATSAPP\"."
  type        = string
  default     = "SMS"
  validation {
    condition     = contains(["SMS", "WHATSAPP"], var.messagecentral_flow_type)
    error_message = "messagecentral_flow_type must be \"SMS\" or \"WHATSAPP\"."
  }
}

variable "admin_phones" {
  description = "10-digit phones that get the ADMIN role in the app."
  type        = list(string)
  default     = []
}

variable "sms_sender_id" {
  description = "SNS SMS sender ID (6 letters for India, registered on DLT)."
  type        = string
  default     = ""
}

variable "dlt_entity_id" {
  description = "India DLT principal entity ID (required by TRAI for SMS to Indian numbers)."
  type        = string
  default     = ""
}

variable "dlt_template_id" {
  description = "India DLT content template ID for the OTP message."
  type        = string
  default     = ""
}

variable "sms_monthly_spend_limit_usd" {
  description = "SNS SMS monthly spend cap. Must not exceed your account's SMS quota (new accounts: 1 USD until raised)."
  type        = number
  default     = 1
}

variable "otp_rate_limit_per_5min" {
  description = "Max /api/auth/otp/* requests per client IP per 5 minutes (WAF minimum is 10)."
  type        = number
  default     = 10
}
