# Database: two modes, chosen by var.db_mode
#   "ec2" (default, lean): PostgreSQL 16 on the app instance, data on a separate encrypted EBS
#         volume, nightly pg_dump to S3. Listens on localhost only. ~$15/month cheaper than RDS.
#   "rds": managed RDS PostgreSQL (private, TLS enforced, automated backups). Use once you have traffic.

locals {
  use_rds    = var.db_mode == "rds"
  db_subnets = length(var.db_subnet_ids) > 0 ? var.db_subnet_ids : local.alb_subnets
  db_name    = "urbanserve"
  db_user    = "urbanserve_app"
  db_url = local.use_rds ? (
    "jdbc:postgresql://${one(aws_db_instance.main[*].address)}:${one(aws_db_instance.main[*].port)}/${local.db_name}?sslmode=require"
  ) : "jdbc:postgresql://127.0.0.1:5432/${local.db_name}"
}

# Characters RDS forbids in passwords (/ @ " space) and ones that are awkward in env files are excluded.
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%^*()-_=+[]{}<>:?"
}

# ---------- RDS (db_mode = "rds") ----------
resource "aws_db_subnet_group" "main" {
  count      = local.use_rds ? 1 : 0
  name       = "${local.name}-db"
  subnet_ids = local.db_subnets
}

resource "aws_security_group" "db" {
  count       = local.use_rds ? 1 : 0
  name        = "${local.name}-db"
  description = "PostgreSQL: inbound only from the app instances"
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  count                        = local.use_rds ? 1 : 0
  security_group_id            = aws_security_group.db[0].id
  description                  = "Postgres from app"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  count                        = local.use_rds ? 1 : 0
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres to RDS"
  referenced_security_group_id = aws_security_group.db[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "pg" {
  count  = local.use_rds ? 1 : 0
  name   = "${local.name}-pg${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_db_instance" "main" {
  count          = local.use_rds ? 1 : 0
  identifier     = "${local.name}-pg"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = local.db_name
  username = local.db_user
  password = random_password.db.result

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = var.db_allocated_storage_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.pg[0].name

  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "20:00-21:00" # 01:30-02:30 IST
  maintenance_window        = "sun:21:30-sun:22:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-pg-final"

  auto_minor_version_upgrade      = true
  allow_major_version_upgrade     = false
  enabled_cloudwatch_logs_exports = ["postgresql"]
  apply_immediately               = false
}

# ---------- App configuration (SSM Parameter Store SecureString: free, KMS-encrypted) ----------
resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "app_config" {
  name        = "/${var.project}/${var.environment}/app-config"
  description = "UrbanServe runtime config: DB credentials, JWT key, origin secret, OTP settings (incl. Message Central)"
  type        = "SecureString" # encrypted with the AWS-managed aws/ssm key
  tier        = "Standard"
  value = jsonencode({
    SPRING_PROFILES_ACTIVE  = "prod"
    DB_URL                  = local.db_url
    DB_USERNAME             = local.db_user
    DB_PASSWORD             = random_password.db.result
    APP_JWT_SECRET          = random_password.jwt.result
    APP_ORIGIN_SECRET       = random_password.origin_verify.result
    APP_ADMIN_PHONES        = join(",", var.admin_phones)
    APP_OTP_SENDER          = var.otp_sender
    APP_OTP_SNS_SENDER_ID   = var.sms_sender_id
    APP_OTP_SNS_ENTITY_ID   = var.dlt_entity_id
    APP_OTP_SNS_TEMPLATE_ID = var.dlt_template_id
    APP_OTP_MC_CUSTOMER_ID  = var.messagecentral_customer_id
    APP_OTP_MC_PASSWORD     = var.messagecentral_password == null ? "" : var.messagecentral_password
    APP_OTP_MC_FLOW_TYPE    = var.messagecentral_flow_type
  })

  lifecycle {
    precondition {
      condition     = var.otp_sender != "messagecentral" || (trimspace(var.messagecentral_customer_id) != "" && var.messagecentral_password != null && var.messagecentral_password != "")
      error_message = "otp_sender = \"messagecentral\" needs messagecentral_customer_id and messagecentral_password (set them in terraform.tfvars or TF_VAR_messagecentral_password)."
    }
  }
}

# ---------- SMS (Amazon SNS) account settings ----------
resource "aws_sns_sms_preferences" "main" {
  count               = var.otp_sender == "sns" ? 1 : 0
  default_sms_type    = "Transactional"
  monthly_spend_limit = var.sms_monthly_spend_limit_usd
  default_sender_id   = var.sms_sender_id == "" ? null : var.sms_sender_id
}
