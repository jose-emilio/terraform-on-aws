# ═══════════════════════════════════════════════════════════════════════════════
# Notificaciones — CodeStar Notifications + EventBridge
# ═══════════════════════════════════════════════════════════════════════════════
#
# Arquitectura de notificaciones:
#
#  ┌─────────────────────────────────────────────────────────────────────────┐
#  │                          CodeCommit                                     │
#  │                                                                         │
#  │  PR creado ──────────────────────────────────┐                         │
#  │  PR actualizado ─── CodeStar Notifications ──┼──► SNS Topic            │
#  │  PR merged / cerrado ────────────────────────┘    pr-notifications      │
#  │  Comentario en PR                                       │               │
#  │  Aprobacion cambiada                                    │               │
#  │                                                         ▼               │
#  │  Push / merge a main ──── EventBridge ──────────────── SNS Topic       │
#  │  (auditoria de seguridad)                               │               │
#  └─────────────────────────────────────────────────────────│───────────────┘
#                                                            │
#                        ┌───────────────────────────────────┤
#                        │                                   │
#                        ▼                                   ▼
#               HTTPS (Slack/Teams)               Email (opcional)
#               webhook.site (pruebas)

# ── CodeStar Notification Rule ────────────────────────────────────────────────
#
# detail_type = "FULL":
#   La notificacion incluye el contenido completo del evento: titulo del PR,
#   descripcion, rama origen/destino, lista de commits incluidos y autor.
#   Recomendado para canales de Slack donde el equipo quiere contexto completo.
#
# detail_type = "BASIC":
#   Solo el nombre del evento y el recurso. Util si el mensaje es procesado
#   por una Lambda que lo reformatea antes de enviarlo al canal.
#
# Eventos suscritos:
#   - pull-request-created       : un desarrollador abre un PR
#   - pull-request-source-updated: nuevos commits en la rama de origen del PR
#   - pull-request-status-changed: el PR se cierra (sin merge)
#   - pull-request-merged        : el tech lead completa el merge
#   - comments-on-pull-request   : alguien comenta en el PR (code review)
#   - approval-state-changed     : un aprobador aprueba o rechaza el PR
#   - approval-rule-override     : alguien anula las reglas de aprobacion
#                                  (este evento es critico para auditoria)
resource "aws_codestarnotifications_notification_rule" "pull_requests" {
  name        = "${var.project}-pr-notifications"
  status      = "ENABLED"
  detail_type = "FULL"
  resource    = aws_codecommit_repository.this.arn

  event_type_ids = [
    "codecommit-repository-pull-request-created",
    "codecommit-repository-pull-request-source-updated",
    "codecommit-repository-pull-request-status-changed",
    "codecommit-repository-pull-request-merged",
    "codecommit-repository-comments-on-pull-requests",
    "codecommit-repository-approvals-status-changed",
    "codecommit-repository-approvals-rule-override",
  ]

  target {
    type    = "SNS"
    address = aws_sns_topic.pr_notifications.arn
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pr-lifecycle-notifications"
  }

  depends_on = [aws_sns_topic_policy.pr_notifications]
}

# ── Suscripcion HTTPS — Slack / Teams / webhook.site ─────────────────────────
#
# SNS enviara un POST JSON a esta URL ante cada evento publicado en el topic.
#
# NOTA IMPORTANTE — confirmacion de suscripcion:
#   Cuando SNS crea una suscripcion HTTPS, primero envia una peticion de
#   confirmacion con un token. El endpoint debe responder con 200 OK y
#   visitar la SubscribeURL incluida en el cuerpo, O bien tener activada
#   la confirmacion automatica (endpoint_auto_confirms = true).
#
#   webhook.site confirma automaticamente, por eso endpoint_auto_confirms
#   funciona alli. Slack y Teams NO confirman automaticamente — necesitas
#   un intermediario (API Gateway + Lambda) que extraiga la SubscribeURL
#   del primer mensaje y haga un GET a ella, o usar AWS Chatbot en su lugar
#   (ver Reto 2 del laboratorio).
#
# Politica de reintentos:
#   3 intentos con 20s entre cada uno si el endpoint devuelve error.
#   Esto previene la perdida de notificaciones ante caidas cortas del webhook.
resource "aws_sns_topic_subscription" "slack_webhook" {
  count = var.slack_webhook_url != "" ? 1 : 0

  topic_arn              = aws_sns_topic.pr_notifications.arn
  protocol               = "https"
  endpoint               = var.slack_webhook_url
  endpoint_auto_confirms = false

  delivery_policy = jsonencode({
    healthyRetryPolicy = {
      minDelayTarget     = 20
      maxDelayTarget     = 60
      numRetries         = 3
      numMaxDelayRetries = 1
      numNoDelayRetries  = 0
      numMinDelayRetries = 1
      backoffFunction    = "linear"
    }
  })
}

# ── Suscripcion por email ─────────────────────────────────────────────────────
#
# La suscripcion de email envia el JSON crudo del evento de CodeStar.
# El contenido no es legible para humanos directamente, pero es util como
# registro de auditoria en buzon de correo del equipo.
#
# Para emails legibles, considera:
#   - AWS Chatbot (integracion nativa con Slack/Teams, formato enriquecido)
#   - Lambda suscrita al SNS que transforma el JSON y reenvía a SES
#
# IMPORTANTE: la suscripcion queda en estado "PendingConfirmation" hasta
# que el destinatario haga clic en el enlace del email de confirmacion.
resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.pr_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ── EventBridge Rule — auditoria de cambios en ramas protegidas ───────────────
#
# CodeStar Notifications cubre el ciclo de vida de Pull Requests, pero NO
# emite eventos cuando un administrador (o tech lead) hace push directo a main
# sin pasar por un PR. Esta regla de EventBridge llena ese vacio.
#
# Detecta:
#   - referenceUpdated (push / merge a una rama existente)
#   - referenceCreated (nueva rama creada con nombre "main" — raro pero posible)
#
# El filtro 'referenceName = ["main"]' hace que solo se dispare para la rama
# main. Para cubrir release/*, añadiria un segundo event pattern o una segunda
# regla (EventBridge no admite wildcards en filtros de array).
resource "aws_cloudwatch_event_rule" "main_branch_write_audit" {
  name        = "${var.project}-main-branch-write-audit"
  description = "Auditoria: detecta cualquier escritura (push directo o merge) en la rama main."
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [aws_codecommit_repository.this.arn]
    detail = {
      event         = ["referenceUpdated", "referenceCreated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "security-audit"
  }
}

resource "aws_cloudwatch_event_target" "main_branch_write_audit_to_sns" {
  rule      = aws_cloudwatch_event_rule.main_branch_write_audit.name
  target_id = "SendAuditAlertToSNS"
  arn       = aws_sns_topic.pr_notifications.arn

  # Transformar el evento de EventBridge en un mensaje legible.
  # Las variables entre <> son referencias a los input_paths definidos abajo.
  # El valor del template debe ser una cadena JSON valida (entrecomillada).
  input_transformer {
    input_paths = {
      repo       = "$.detail.repositoryName"
      branch     = "$.detail.referenceName"
      actor      = "$.detail.callerUserArn"
      event_type = "$.detail.event"
      old_commit = "$.detail.oldCommitId"
      new_commit = "$.detail.commitId"
      timestamp  = "$.time"
    }

    input_template = <<-EOT
      "[AUDITORIA CODECOMMIT] Escritura en rama protegida | Repositorio: <repo> | Rama: <branch> | Tipo: <event_type> | Actor: <actor> | Commit anterior: <old_commit> | Commit nuevo: <new_commit> | Hora UTC: <timestamp>"
    EOT
  }
}

# ── Grupo de logs de CloudTrail ───────────────────────────────────────────────
#
# El metric filter requiere que el log group exista. En produccion, CloudTrail
# crea este grupo automaticamente al configurar la entrega a CloudWatch Logs.
# En el laboratorio lo creamos explicitamente para que el apply no falle.
#
# Si ya tienes CloudTrail activo enviando a este grupo, Terraform simplemente
# adoptara el grupo existente con terraform import o con un import {} block.
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project}"
  retention_in_days = 30

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "cloudtrail-audit-logs"
  }
}

# ── CloudWatch Alarm — sobretasa de override de reglas de aprobacion ──────────
#
# Si alguien llama repetidamente a OverridePullRequestApprovalRules, puede
# estar intentando saltar la proteccion de forma sistematica. Esta alarma
# dispara si se registran mas de 0 overrides en 5 minutos (cualquier override
# es anomalo y debe revisarse).
#
# La metrica se genera mediante un filtro de metricas sobre CloudWatch Logs.
# CodeCommit envia eventos de API a CloudTrail; si CloudTrail esta configurado
# con un grupo de logs en CloudWatch, este filtro los captura.
#
# NOTA: Esta alarma solo funciona si CloudTrail esta activo y envia logs al
# grupo /aws/cloudtrail/${var.project}. El grupo se crea arriba; los eventos
# llegaran cuando configures CloudTrail para usar ese destino.
resource "aws_cloudwatch_log_metric_filter" "approval_override_attempts" {
  name           = "${var.project}-approval-rule-override-attempts"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ ($.eventSource = \"codecommit.amazonaws.com\") && ($.eventName = \"OverridePullRequestApprovalRules\") }"

  metric_transformation {
    name          = "ApprovalRuleOverrideCount"
    namespace     = "Lab41/Governance"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "approval_override_alert" {
  alarm_name          = "${var.project}-approval-override-detected"
  alarm_description   = "Alerta: se detecto un intento de anular las reglas de aprobacion de un PR en ${var.repo_name}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApprovalRuleOverrideCount"
  namespace           = "Lab41/Governance"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.pr_notifications.arn]
  ok_actions    = []

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Severity  = "HIGH"
  }
}
