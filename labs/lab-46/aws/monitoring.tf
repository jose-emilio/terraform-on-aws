# ═══════════════════════════════════════════════════════════════════════════════
# SNS — Canal de notificaciones para alarmas
# ═══════════════════════════════════════════════════════════════════════════════
#
# La suscripción requiere confirmación manual: AWS envía un correo con un enlace
# "Confirm subscription" que el destinatario debe pulsar antes de recibir alertas.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Log Group — Cifrado con KMS, retención limitada
# ═══════════════════════════════════════════════════════════════════════════════
#
# kms_key_id vincula la CMK creada en main.tf. CloudWatch Logs cifra cada
# evento antes de escribirlo en disco. Sin retention_in_days, los logs
# se acumulan indefinidamente generando costes crecientes.
#
# IMPORTANTE: la CMK debe tener el statement AllowCloudWatchLogs en su política
# antes de crear este recurso. Terraform gestiona el orden via la referencia
# aws_kms_key.logs.arn, que crea una dependencia implícita.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Log Metric Filter — Transforma "ERROR" en una métrica numérica
# ═══════════════════════════════════════════════════════════════════════════════
#
# El pattern "ERROR" es una búsqueda de texto simple (case-sensitive).
# CloudWatch también soporta patrones JSON ({ $.level = "ERROR" }) y patrones
# de espacio (para logs con campos separados por espacios).
#
# default_value = "0" garantiza que los periodos sin errores publican un
# datapoint con valor 0 en lugar de ausencia de datos. Esto permite que las
# alarmas evalúen correctamente la métrica incluso en periodos tranquilos.
#
# La métrica se publica en el namespace personalizado "${var.project}/Application"
# para separarla de las métricas de AWS y facilitar su localización en el dashboard.

resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "${var.project}-error-count"
  pattern        = "ERROR"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "ErrorCount"
    namespace     = "${var.project}/Application"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Alarma 1 — Anomaly Detection: CPU con Machine Learning
# ═══════════════════════════════════════════════════════════════════════════════
#
# ANOMALY_DETECTION_BAND(m1, N) genera una banda de valores "normales" usando
# un modelo ML entrenado sobre el historial de m1 (mínimo 15 minutos de datos,
# modelo completo tras ~24 horas). N es el número de desviaciones típicas de
# anchura: N=2 captura ~95% de los valores normales históricos.
#
# comparison_operator = "GreaterThanUpperThreshold" activa la alarma cuando la
# CPU supera el límite superior de la banda. threshold_metric_id = "e1" apunta
# a la expresión de la banda, no a un umbral numérico fijo.
#
# Ventaja sobre umbral fijo: si la CPU normalmente sube al 60% cada día a las
# 9:00 (batch matutino), la banda aprende ese patrón y no genera falsa alarma.
# Un umbral fijo del 50% dispararía cada mañana.

resource "aws_cloudwatch_metric_alarm" "cpu_anomaly" {
  alarm_name          = "${var.project}-cpu-anomaly"
  alarm_description   = "CPU fuera del rango historico esperado por el modelo ML de Anomaly Detection."
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "e1"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, ${var.anomaly_band_width})"
    label       = "CPU — banda normal (ML)"
    return_data = true
  }

  metric_query {
    id          = "m1"
    return_data = true

    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 300
      stat        = "Average"
      dimensions = {
        InstanceId = aws_instance.app.id
      }
    }
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Alarma 2 — Status Check (componente de la Composite Alarm)
# ═══════════════════════════════════════════════════════════════════════════════
#
# StatusCheckFailed = 1 cuando falla algún health check de EC2 (de instancia o
# de sistema). Esta alarma NO tiene alarm_actions: actuar solo cuando el health
# check falla aisladamente generaría ruido (el hipervisor puede reiniciar la
# instancia automáticamente). Su propósito es ser un componente de la Composite.

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.project}-status-check"
  alarm_description   = "EC2 health check fallido (instancia o sistema)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Alarma 3 — CPU Alta (componente de la Composite Alarm)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Umbral fijo sobre CPUUtilization. Sin alarm_actions: notificar solo por CPU
# alta generaría ruido en instancias con cargas legítimas elevadas (compilaciones,
# backups, etc.). Se reserva la notificación para cuando CPU alta coincide con
# un fallo de health check simultáneo.

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project}-cpu-high"
  alarm_description   = "CPU por encima del ${var.cpu_threshold}% durante 3 periodos consecutivos de 5 minutos."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Composite Alarm — Solo dispara si health check Y CPU alta coinciden
# ═══════════════════════════════════════════════════════════════════════════════
#
# alarm_rule usa la sintaxis de expresión booleana de CloudWatch:
#   ALARM("nombre") → verdadero si la alarma está en estado ALARM
#   AND / OR / NOT  → operadores lógicos
#
# La lógica AND garantiza que solo se notifica un incidente real:
#   - CPU alta sola → probablemente un proceso legítimo (batch, compilación)
#   - Health check fallido solo → puede ser transitorio (AWS lo recupera solo)
#   - Ambos a la vez → la instancia está bajo presión Y degradada: notificar
#
# ok_actions envía una notificación de recuperación cuando ambas alarmas
# vuelven a OK, cerrando el ciclo del incidente.

resource "aws_cloudwatch_composite_alarm" "app_critical" {
  alarm_name        = "${var.project}-app-critical"
  alarm_description = "CRITICO: health check fallido Y CPU elevada de forma simultanea."

  alarm_rule = join(" AND ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.status_check.alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.cpu_high.alarm_name}\")"
  ])

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Dashboard — Panel visual generado con jsonencode
# ═══════════════════════════════════════════════════════════════════════════════
#
# jsonencode convierte el mapa HCL a JSON válido para la API de CloudWatch.
# Las referencias a recursos Terraform (aws_instance.app.id, ARNs, nombres)
# se resuelven en tiempo de apply: el dashboard siempre apunta a los recursos
# reales aunque cambien de nombre o ID tras una recreación.
#
# Layout (24 columnas × filas de 6):
#   Fila 0 (y=0): CPU+ML (12 cols) | ErrorCount (12 cols)
#   Fila 1 (y=6): Estado alarmas (24 cols, 3 filas)
#   Fila 2 (y=9): Health Check (12 cols) | IncomingLogEvents (12 cols)

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project

  dashboard_body = jsonencode({
    widgets = [
      # ── Widget 1: CPU con banda de Anomaly Detection ──────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU — Anomaly Detection (ML)"
          view    = "timeSeries"
          stacked = false
          region  = var.region
          period  = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id,
              { id = "m1", stat = "Average", label = "CPU real (%)", color = "#2196F3" }],
            [{ expression = "ANOMALY_DETECTION_BAND(m1, ${var.anomaly_band_width})",
               id = "e1", label = "Rango normal (ML)", color = "#95A5A6" }]
          ]
        }
      },
      # ── Widget 2: ErrorCount desde log metric filter ──────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Errores de aplicacion (log metric filter)"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          metrics = [
            ["${var.project}/Application", "ErrorCount",
              { stat = "Sum", label = "Errores/min", color = "#F44336" }]
          ]
        }
      },
      # ── Widget 3: Estado de todas las alarmas ─────────────────────────────────
      {
        type   = "alarm"
        x      = 0
        y      = 6
        width  = 24
        height = 3
        properties = {
          title  = "Estado de alarmas"
          alarms = [
            aws_cloudwatch_metric_alarm.cpu_anomaly.arn,
            aws_cloudwatch_metric_alarm.status_check.arn,
            aws_cloudwatch_metric_alarm.cpu_high.arn,
            aws_cloudwatch_composite_alarm.app_critical.arn,
          ]
        }
      },
      # ── Widget 4: Health check desglosado ────────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title   = "Health Check de instancia EC2"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.app.id,
              { stat = "Maximum", label = "Total", color = "#FF5722" }],
            ["AWS/EC2", "StatusCheckFailed_Instance", "InstanceId", aws_instance.app.id,
              { stat = "Maximum", label = "Instancia", color = "#FF9800" }],
            ["AWS/EC2", "StatusCheckFailed_System", "InstanceId", aws_instance.app.id,
              { stat = "Maximum", label = "Sistema (hardware AWS)", color = "#FFC107" }]
          ]
        }
      },
      # ── Widget 5: Volumen de log entries entrantes ────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title   = "Eventos entrantes al log group"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          metrics = [
            ["AWS/Logs", "IncomingLogEvents", "LogGroupName", aws_cloudwatch_log_group.app.name,
              { stat = "Sum", label = "Eventos/min", color = "#4CAF50" }]
          ]
        }
      }
    ]
  })
}
