# Booking <-> dispatch messaging (Amazon SQS). Effectively free at this scale: the first 1M
# requests/month are always free, and three long-polled idle queues use roughly 400k.
#
#   booking-requested   urbanserve-api  -> dispatch   "find a professional"
#   booking-cancelled   urbanserve-api  -> dispatch   "free the slot"
#   booking-assignment  dispatch -> urbanserve-api    ASSIGNED {pro, arrival window} | NO_PROVIDER
#
# Each queue has a dead-letter queue: after 5 failed deliveries a message is parked there and a
# CloudWatch alarm emails budget_alert_email. Same names/settings as compose/elasticmq.conf.

locals {
  dispatch_queues = toset(["booking-requested", "booking-cancelled", "booking-assignment"])
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = local.dispatch_queues
  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to inspect and redrive
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  for_each                   = local.dispatch_queues
  name                       = "${local.name}-${each.key}"
  visibility_timeout_seconds = 60     # a failed message is retried after 60 s
  receive_wait_time_seconds  = 20     # long polling: fewer (billed) empty receives
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each  = local.dispatch_queues
  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

# ---------- Alert when anything lands in a dead-letter queue ----------
resource "aws_sns_topic" "alerts" {
  count = var.budget_alert_email == null ? 0 : 1
  name  = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.budget_alert_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email" # confirm the subscription email AWS sends
  endpoint  = var.budget_alert_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each            = var.budget_alert_email == null ? toset([]) : local.dispatch_queues
  alarm_name          = "${local.name}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages failed 5 times and were parked in ${aws_sqs_queue.dlq[each.key].name}. Check the app/dispatch logs, then redrive from the SQS console."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts[0].arn]
  ok_actions          = [aws_sns_topic.alerts[0].arn]
}
