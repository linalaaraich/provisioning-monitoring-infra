# =============================================================================
# AWS Budgets — PRIMARY monthly cost guardrail (audit TF-N1, HIGH).
# =============================================================================
# WHY THIS EXISTS / Budgets vs the CloudWatch EstimatedCharges alarm:
#
#   * The CloudWatch alarm in gateway.tf watches the AWS/Billing
#     `EstimatedCharges` metric. That metric publishes NO datapoints until the
#     account's "Receive Billing Alerts" preference is enabled. That preference
#     is a CONSOLE-ONLY, root/payer-account toggle (Billing Console -> Billing
#     Preferences -> "Receive Billing Alerts") — it CANNOT be set from
#     Terraform. Until Lina toggles it, the EstimatedCharges alarm sits in
#     INSUFFICIENT_DATA forever and can never fire. With the g5.xlarge GPU
#     running 24/7 (~$724/mo) the account is otherwise spending-blind.
#
#       >>> ACTION REQUIRED (Lina, once, manually): log into the payer/root
#       >>> account and enable Billing Console -> Preferences -> "Receive
#       >>> Billing Alerts" to light up the CloudWatch EstimatedCharges path.
#
#   * AWS Budgets (this file) does NOT depend on that preference. Cost-budget
#     data is always available, so this is the guardrail that actually protects
#     the account today. The two are complementary: Budgets is the reliable
#     primary alert; the CloudWatch alarm becomes a secondary near-real-time-ish
#     (6h) signal once the preference is on.
#
# Budgets is a GLOBAL service whose API is fronted in us-east-1, so we reuse the
# `aws.us_east_1` aliased provider that the billing alarm already uses, and the
# same notification email (var.alarm_email_to) so confirmations land in one
# place. Email notifications via Budgets do NOT require SNS subscription
# confirmation — they are sent directly by the Budgets service.
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_cost" {
  provider     = aws.us_east_1
  name         = "triage-monthly-cost-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% of ACTUAL spend — early warning that we are tracking toward the cap.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email_to]
  }

  # 100% of ACTUAL spend — the cap has been reached this month.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email_to]
  }

  # 100% FORECASTED — AWS predicts month-end spend will breach the cap, even if
  # actual is still under. Gives a heads-up before the money is actually spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alarm_email_to]
  }
}
