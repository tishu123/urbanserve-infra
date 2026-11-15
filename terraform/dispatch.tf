# urbanserve-dispatch: assigns a free professional to each booking. Runs on the app instance as a
# second systemd service (urbanserve-dispatch), listening on 127.0.0.1:8090 only (no inbound rule,
# not reachable from CloudFront). Its own PostgreSQL database "dispatch" lives on the same server
# (db_mode = "ec2") or the same RDS instance (db_mode = "rds").

locals {
  dispatch_db_name = "dispatch"
  dispatch_db_user = "dispatch_app"
  dispatch_db_url = local.use_rds ? (
    "jdbc:postgresql://${one(aws_db_instance.main[*].address)}:${one(aws_db_instance.main[*].port)}/${local.dispatch_db_name}?sslmode=require"
  ) : "jdbc:postgresql://127.0.0.1:5432/${local.dispatch_db_name}"
}

resource "random_password" "dispatch_db" {
  length           = 32
  special          = true
  override_special = "!#%^*()-_=+[]{}<>:?"
}

resource "aws_ssm_parameter" "dispatch_config" {
  name        = "/${var.project}/${var.environment}/dispatch-config"
  description = "urbanserve-dispatch runtime config: DB credentials and SQS queue URLs"
  type        = "SecureString"
  tier        = "Standard"
  value = jsonencode({
    DB_URL                         = local.dispatch_db_url
    DB_USERNAME                    = local.dispatch_db_user
    DB_PASSWORD                    = random_password.dispatch_db.result
    DISPATCH_TRANSPORT             = "sqs"
    APP_SQS_BOOKING_REQUESTED_URL  = aws_sqs_queue.main["booking-requested"].url
    APP_SQS_BOOKING_CANCELLED_URL  = aws_sqs_queue.main["booking-cancelled"].url
    APP_SQS_BOOKING_ASSIGNMENT_URL = aws_sqs_queue.main["booking-assignment"].url
    SERVER_ADDRESS                 = "127.0.0.1" # internal endpoints stay on the box
  })
}
