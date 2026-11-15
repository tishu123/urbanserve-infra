# Two network layouts, chosen by var.use_alb:
#
# LEAN (default, use_alb = false) — cheapest, for launch / free credits
#   CloudFront --(X-Origin-Verify header)--> EC2:8080 (Elastic IP)
#   EC2 SG admits ONLY CloudFront's origin-facing IP ranges on 8080; the Spring app rejects
#   any request without the secret header. No SSH; admin via SSM Session Manager.
#
# SCALE (use_alb = true)
#   CloudFront --> ALB (CloudFront IPs only, header + /api/* rule) --> EC2:8080 (ALB SG only)

# ---------- Network lookups ----------
data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  alb_subnets = length(var.alb_subnet_ids) > 0 ? var.alb_subnet_ids : data.aws_subnets.default.ids
  ec2_subnet  = coalesce(var.ec2_subnet_id, local.alb_subnets[0])
  # Graviton (ARM) families end in "g" (t4g, m7g, c7g...): cheaper per hour.
  is_arm = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
}

data "aws_subnet" "ec2" {
  id = local.ec2_subnet
}

# AWS-maintained list of CloudFront origin-facing IPs (auto-updates; no manual IP lists).
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ---------- App security group ----------
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Spring Boot app: inbound only from CloudFront or the ALB, no SSH"
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_cloudfront" {
  count             = var.use_alb ? 0 : 1
  security_group_id = aws_security_group.app.id
  description       = "App port from CloudFront origin-facing ranges"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  count                        = var.use_alb ? 1 : 0
  security_group_id            = aws_security_group.app.id
  description                  = "App port from ALB"
  referenced_security_group_id = aws_security_group.alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS out for S3, SSM, SNS, Message Central (cpaas.messagecentral.com) and OS updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP out for OS package mirrors"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# ---------- ALB (only when use_alb = true) ----------
resource "aws_security_group" "alb" {
  count       = var.use_alb ? 1 : 0
  name        = "${local.name}-alb"
  description = "ALB: inbound only from CloudFront"
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  count             = var.use_alb ? 1 : 0
  security_group_id = aws_security_group.alb[0].id
  description       = "CloudFront origin-facing ranges"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = local.alb_https ? 443 : 80
  to_port           = local.alb_https ? 443 : 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  count                        = var.use_alb ? 1 : 0
  security_group_id            = aws_security_group.alb[0].id
  description                  = "To app instances"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_lb" "api" {
  count                      = var.use_alb ? 1 : 0
  name                       = substr("${local.name}-api", 0, 32)
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb[0].id]
  subnets                    = local.alb_subnets
  drop_invalid_header_fields = true
  enable_deletion_protection = var.alb_deletion_protection
  idle_timeout               = 60
}

resource "aws_lb_target_group" "api" {
  count                = var.use_alb ? 1 : 0
  name                 = substr("${local.name}-api", 0, 32)
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.selected.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/api/categories"
    matcher             = "200-403" # app rejects requests without the CloudFront header with 403
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_target_group_attachment" "api" {
  count            = var.use_alb ? 1 : 0
  target_group_arn = aws_lb_target_group.api[0].arn
  target_id        = aws_instance.app.id
  port             = 8080
}

resource "aws_lb_listener" "api" {
  count             = var.use_alb ? 1 : 0
  load_balancer_arn = aws_lb.api[0].arn
  port              = local.alb_https ? 443 : 80
  protocol          = local.alb_https ? "HTTPS" : "HTTP"
  ssl_policy        = local.alb_https ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn   = local.alb_https ? var.alb_certificate_arn : null

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  count        = var.use_alb ? 1 : 0
  listener_arn = aws_lb_listener.api[0].arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
  condition {
    path_pattern { values = ["/api/*"] }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}

# ---------- IAM for the instance ----------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager instead of SSH keys / port 22.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app_runtime" {
  statement {
    sid       = "ReadBackendJar"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/backend/*"]
  }
  statement {
    sid       = "WriteDbBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/db-backups/*"]
  }
  statement {
    sid       = "ReadAppConfig"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.app_config.arn, aws_ssm_parameter.dispatch_config.arn]
  }
  # urbanserve-api and urbanserve-dispatch both run on this instance (see sqs.tf for who uses which queue).
  statement {
    sid = "BookingDispatchQueues"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [for q in aws_sqs_queue.main : q.arn]
  }
  # Only when SMS goes through Amazon SNS (Message Central is called over HTTPS with its own credentials).
  dynamic "statement" {
    for_each = var.otp_sender == "sns" ? [1] : []
    content {
      sid       = "SendOtpSms"
      actions   = ["sns:Publish"]
      resources = ["*"] # direct-to-phone SMS has no resource ARN, so this cannot be scoped further
    }
  }
}

resource "aws_iam_role_policy" "app_runtime" {
  name   = "app-runtime"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_runtime.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app"
  role = aws_iam_role.app.name
}

# ---------- EC2 instance ----------
data "aws_ssm_parameter" "al2023" {
  name = local.is_arm ? "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Separate disk for PostgreSQL data (db_mode = "ec2"), so the database survives instance replacement.
resource "aws_ebs_volume" "pgdata" {
  count             = local.use_rds ? 0 : 1
  availability_zone = data.aws_subnet.ec2.availability_zone
  size              = var.pgdata_volume_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-pgdata" }

  lifecycle { prevent_destroy = true } # protects customer data from an accidental destroy
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = local.ec2_subnet
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = var.ec2_associate_public_ip

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    artifact_bucket       = aws_s3_bucket.artifacts.bucket
    region                = var.region
    config_param          = aws_ssm_parameter.app_config.name
    dispatch_config_param = aws_ssm_parameter.dispatch_config.name
    db_mode               = var.db_mode
    pgdata_volume         = replace(join("", aws_ebs_volume.pgdata[*].id), "-", "") # "" when db_mode = "rds"
    rds_host              = join("", aws_db_instance.main[*].address)          # "" when db_mode = "ec2"
  })
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-app" }

  lifecycle {
    ignore_changes = [ami] # don't replace the instance every time a new AMI is published
  }
}

resource "aws_volume_attachment" "pgdata" {
  count       = local.use_rds ? 0 : 1
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.pgdata[0].id
  instance_id = aws_instance.app.id
}

# Stable public DNS name for CloudFront's origin (lean mode). Same price as any public IPv4.
resource "aws_eip" "app" {
  count    = var.use_alb ? 0 : 1
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = { Name = "${local.name}-app" }
}
