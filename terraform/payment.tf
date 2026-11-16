# urbanserve-payment: Razorpay payments. Runs on the app instance as a third systemd service
# (urbanserve-payment) on 127.0.0.1:8091, with its own PostgreSQL database "payment".
# All runtime settings live in an encrypted SSM parameter that the service reads on every start,
# so nothing is copied onto the server by hand. Razorpay keys come from terraform.tfvars
# (git-ignored) or TF_VAR_razorpay_* env vars, never from this repo.

locals {
  payment_port    = 8091
  payment_db_name = "payment"
  payment_db_user = "payment_app"
  payment_db_url = local.use_rds ? (
    "jdbc:postgresql://${one(aws_db_instance.main[*].address)}:${one(aws_db_instance.main[*].port)}/${local.payment_db_name}?sslmode=require"
  ) : "jdbc:postgresql://127.0.0.1:5432/${local.payment_db_name}"
}

resource "random_password" "payment_db" {
  length           = 32
  special          = true
  override_special = "!#%^*()-_=+[]{}<>:?"
}

resource "random_password" "payment_internal_token" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "payment_config" {
  name        = "/${var.project}/${var.environment}/payment-config"
  description = "urbanserve-payment runtime config: DB credentials, Razorpay keys, webhook secret, internal token"
  type        = "SecureString" # encrypted with the AWS-managed aws/ssm key
  tier        = "Standard"
  value = jsonencode({
    SPRING_DATASOURCE_URL      = local.payment_db_url
    SPRING_DATASOURCE_USERNAME = local.payment_db_user
    SPRING_DATASOURCE_PASSWORD = random_password.payment_db.result
    SERVER_ADDRESS             = "127.0.0.1" # stays on the box; the API calls it locally
    SERVER_PORT                = tostring(local.payment_port)
    RAZORPAY_KEY_ID         = var.razorpay_key_id
    RAZORPAY_KEY_SECRET     = var.razorpay_key_secret == null ? "" : var.razorpay_key_secret
    RAZORPAY_WEBHOOK_SECRET = var.razorpay_webhook_secret == null ? "" : var.razorpay_webhook_secret
    PAYMENT_INTERNAL_TOKEN  = random_password.payment_internal_token.result
  })

  lifecycle {
    precondition {
      condition     = var.razorpay_key_id == "" || (var.razorpay_key_secret != null && var.razorpay_key_secret != "")
      error_message = "razorpay_key_id is set but razorpay_key_secret is empty. Set it in terraform.tfvars or TF_VAR_razorpay_key_secret."
    }
  }
}
