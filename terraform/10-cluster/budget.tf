# Backstop only. A budget alert tells you after the money is spent; setting
# `tier: none` (or running the destroy workflow) is what stops the spend.
#
# Scoped to the Project tag so it tracks this lab rather than the whole account.

resource "aws_sns_topic" "budget" {
  count = var.budget_alert_email == null ? 0 : 1

  name = "${var.project}-budget-alerts"

  tags = local.tags
}

resource "aws_sns_topic_subscription" "budget_email" {
  count = var.budget_alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.budget[0].arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "this" {
  count = var.budget_alert_email == null ? 0 : 1

  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project}"]
  }

  # 80% actual: you are over budget and should know.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # 100% forecast: a GPU left running will trip this long before the actual
  # spend arrives, which is the alert that actually saves money.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
