# ═══════════════════════════════════════════════════════════════════════════════
# SNS Topic — Canal de notificaciones para alertas de presupuesto
# ═══════════════════════════════════════════════════════════════════════════════
#
# AWS Budgets publica notificaciones a un topic SNS cuando el gasto o la
# predicción supera el umbral configurado. El topic actúa como bus de eventos:
# puedes suscribir emails, webhooks, funciones Lambda o colas SQS para
# procesar la alerta de distintas formas.

resource "aws_sns_topic" "budget_alerts" {
  name = module.naming["sns_budget"].name

  # default_tags inyecta: Environment, Project, ManagedBy, CostCenter
  # La tag Name no se usa en SNS (los topics se identifican por nombre y ARN).
}

# ── Política del topic SNS ────────────────────────────────────────────────────
#
# Por defecto, solo el owner del topic puede publicar en él. AWS Budgets es un
# servicio externo que necesita permiso explícito. La condición ArnLike
# restringe que solo el budget de ESTA cuenta pueda publicar, evitando que
# otros budgets de otras cuentas (en entornos Organizations) usen el mismo topic.

resource "aws_sns_topic_policy" "budget_alerts" {
  arn = aws_sns_topic.budget_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetsToPublish"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.budget_alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

# ── Suscripción email (opcional) ──────────────────────────────────────────────
#
# Solo se crea si se proporciona una dirección de email. La suscripción queda
# en estado "PendingConfirmation" hasta que el destinatario confirma desde el
# email de AWS SNS. Si no confirmas, el topic sigue funcionando (no falla el plan).

resource "aws_sns_topic_subscription" "budget_email" {
  count = var.budget_alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

# ═══════════════════════════════════════════════════════════════════════════════
# AWS Budgets — Presupuesto mensual con alerta por predicción (forecast)
# ═══════════════════════════════════════════════════════════════════════════════
#
# aws_budgets_budget soporta dos tipos de umbral:
#
#   ACTUAL     → se dispara cuando el gasto REAL supera el umbral
#   FORECASTED → se dispara cuando la PREDICCIÓN de cierre de mes supera el umbral
#
# La estrategia preventiva FinOps usa FORECASTED: si a mitad de mes la tendencia
# indica que cerrarás en $17 con un límite de $20 (85%), recibe la alerta a tiempo
# para actuar ANTES de superar el presupuesto, no después.
#
# Tipos de umbrales de comparación:
#   PERCENTAGE     → porcentaje del límite (ej: 85% de $20 = $17)
#   ABSOLUTE_VALUE → importe fijo en USD (ej: $17)
#
# Este laboratorio usa PERCENTAGE con FORECASTED para la alerta preventiva.

resource "aws_budgets_budget" "monthly" {
  name         = module.naming["budget"].name
  budget_type  = "COST"
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # ── Alerta preventiva por predicción ────────────────────────────────────────
  # Se dispara cuando el FORECAST de gasto del mes en curso supera el 85%
  # del límite mensual. Aviso: en cuentas nuevas o con pocos datos históricos
  # la predicción puede ser imprecisa hasta que AWS acumula suficiente historia.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.budget_alert_threshold_pct
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }

  # ── Alerta reactiva por gasto real al 100% ──────────────────────────────────
  # Complementa la alerta preventiva. Se dispara cuando el gasto REAL supera
  # el 100% del límite. En este punto el presupuesto ya se ha excedido, pero
  # la alerta sirve para acción inmediata de contención.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}
