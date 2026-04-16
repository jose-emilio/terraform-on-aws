# Sección 1 — Observabilidad Proactiva con CloudWatch

> [← Volver al índice](./README.md) | [Siguiente →](./02_logs_trazas.md)

---

## 1. CloudWatch: El Centro de Control de la Infraestructura

La observabilidad es el pilar de la estabilidad operativa. CloudWatch centraliza Logs, Metrics, Alarms y Dashboards, ofreciendo una vista unificada de la salud de la infraestructura. Es el punto de partida para gestionar operaciones desde el código con Terraform.

> **El profesor explica:** "Observabilidad no es lo mismo que monitorización. Monitorizar es saber si el servicio está arriba o caído. Observabilidad es entender *por qué* se cayó, cuándo empezó a degradarse, y qué cambio lo provocó. CloudWatch te da los tres pilares para construir esa capacidad: logs para el 'qué pasó', métricas para el 'cuánto y con qué frecuencia', y alarmas para el 'avísame cuando supere el umbral'. La diferencia entre un equipo reactivo y uno proactivo es si estas tres piezas están configuradas como código antes de que ocurra el problema."

**Los tres pilares de CloudWatch:**

| Pilar | Herramienta | Función |
|-------|-------------|---------|
| **Captura** | CloudWatch Logs | Eventos en tiempo real con retención configurable |
| **Métricas** | CloudWatch Metrics | Estándar, personalizadas y detección de anomalías |
| **Acción** | Alarms & Dashboards | Alertas reactivas/compuestas y paneles as code |

---

## 2. Log Groups: El Historial de Ejecución

Un Log Group sin política de retención almacena datos indefinidamente, generando costes crecientes. Configurar `retention_in_days` y cifrado con KMS es esencial para cumplimiento y ahorro.

> **El profesor explica:** "El error más caro que veo en auditorías de costes AWS es Log Groups sin política de retención. Cada gigabyte de logs cuesta $0.03 al mes en almacenamiento — para siempre. Para una aplicación que emite 10 GB de logs diarios, eso se convierte en miles de dólares anuales de deuda silenciosa. La línea `retention_in_days = 30` es la configuración con mejor ROI de todo el módulo. Cuesta cero implementarla y puede ahorrar miles."

```hcl
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/app/${var.environment}/logs"
  retention_in_days = var.log_retention_days   # Valores válidos: 1,3,5,7,14,30,60,90,120,150,180,365...

  kms_key_id = aws_kms_key.logs.arn   # Cifrado at-rest: SOC2 / HIPAA compliance

  tags = merge(var.default_tags, {
    Name = "${var.project}-app-logs"
  })
}
```

**Política de retención por tipo de log:**

| Tipo de log | Retención recomendada | Razón |
|-------------|----------------------|-------|
| Aplicación (debug) | 7-14 días | Alto volumen, valor decae rápido |
| Aplicación (errores) | 30-90 días | Debugging post-incidente |
| VPC Flow Logs | 30-90 días | Auditoría de red |
| CloudTrail | 365+ días | Requisito normativo |
| Sin valor definido | Infinita — ⚠️ evitar | Coste creciente sin límite |

---

## 3. Metric Alarms: Detectando el Fallo

Las alarmas de CloudWatch monitorizan métricas y ejecutan acciones cuando se superan umbrales definidos. Cada alarma transita entre tres estados: `OK`, `ALARM` e `INSUFFICIENT_DATA`.

```hcl
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3          # Deben superarse 3 períodos consecutivos
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300        # Cada 5 minutos
  statistic           = "Average"
  threshold           = 80         # >80% CPU → ALARM

  treat_missing_data = "notBreaching"   # Sin datos no dispara falsos positivos

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

**Parámetros clave de una alarma:**

| Parámetro | Función | Ejemplo |
|-----------|---------|---------|
| `evaluation_periods` | Períodos consecutivos para confirmar | `3` (evita picos transitorios) |
| `period` | Duración de cada período (segundos) | `300` = 5 minutos |
| `statistic` | Agregación: Average, Sum, Max, Min | `Average` para CPU |
| `threshold` | Valor límite | `80` (para CPU%) |
| `treat_missing_data` | Comportamiento sin datos | `notBreaching` / `breaching` |

---

## 4. SNS: El Canal de Notificaciones

SNS es el sistema de mensajería que conecta las alarmas con los equipos. Terraform gestiona topics y suscripciones de forma declarativa y reproducible.

```hcl
# Canal central de alertas
resource "aws_sns_topic" "alerts" {
  name              = "${var.project}-alerts"
  kms_master_key_id = aws_kms_key.sns.id   # Cifrado opcional

  tags = local.common_tags
}

# Suscripción: email al equipo de ops
resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "ops-team@company.com"
}

# Suscripción: Lambda para lógica custom (PagerDuty, auto-remediation)
resource "aws_sns_topic_subscription" "lambda_handler" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alert_handler.arn
}
```

**Protocolos de suscripción disponibles:**

| Protocolo | Uso | Confirmación |
|-----------|-----|-------------|
| `email` | Notificación directa al equipo | Manual (click en email) |
| `https` | Webhook a PagerDuty / OpsGenie | Automática |
| `lambda` | Lógica personalizada, auto-remediación | Automática |
| `sqs` | Buffer para procesamiento desacoplado | Automática |

---

## 5. Metric Filters: De Logs a Métricas

`aws_cloudwatch_log_metric_filter` busca patrones en logs y los convierte en métricas CloudWatch. Esto crea telemetría sin modificar el código de la aplicación.

> **El profesor explica:** "Este es uno de los recursos más infrautilizados de CloudWatch. La idea es simple pero poderosa: tienes logs que ya se están emitiendo, y en lugar de parsearlo manualmente, defines un patrón — por ejemplo, la cadena 'ERROR' — y CloudWatch cuenta cuántas veces aparece por unidad de tiempo. Ese contador se convierte en una métrica sobre la que puedes poner alarmas. La mejor observabilidad no requiere cambiar el código de la aplicación — solo cambiar cómo capturas su output."

```hcl
resource "aws_cloudwatch_log_metric_filter" "error_count" {
  name           = "ErrorCount"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.level = \"ERROR\" }"   # JSON filter syntax

  metric_transformation {
    name          = "AppErrorCount"
    namespace     = "Custom/${var.project}"
    value         = "1"            # Incremento por cada match
    default_value = "0"           # Emite cero cuando no hay errores
  }
}

# Alarma sobre la métrica extraída
resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.project}-app-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AppErrorCount"
  namespace           = "Custom/${var.project}"
  period              = 300
  statistic           = "Sum"
  threshold           = 10

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

---

## 6. Composite Alarms: Inteligencia contra la Fatiga

Las alarmas compuestas agrupan múltiples alarmas base con operadores AND/OR. Solo se disparan cuando la condición combinada se cumple, reduciendo falsos positivos y fatiga de alertas.

> **El profesor explica:** "La fatiga de alertas es uno de los problemas más serios en equipos de operaciones. Cuando las alarmas se disparan constantemente por picos transitorios o condiciones que no son realmente críticas, los ingenieros aprenden a ignorarlas. Y el día que hay una alerta real e importante, pasa desapercibida. Las alarmas compuestas son la solución: en lugar de alertar cuando CPU > 80% — que puede ser un pico de 5 minutos — alertas cuando CPU > 80% AND error rate > 5% AND health check failing. Esa combinación confirma un problema real."

```hcl
resource "aws_cloudwatch_composite_alarm" "service_health" {
  alarm_name = "${var.project}-service-health"

  # OR: cualquier alarma dispara la compuesta
  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.high_cpu.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.error_rate.alarm_name})"
  ])

  # AND: todas deben fallar para alertar
  # alarm_rule = "ALARM(${...cpu.alarm_name}) AND ALARM(${...errors.alarm_name})"

  alarm_actions = [aws_sns_topic.critical.arn]
}
```

**Operadores lógicos en `alarm_rule`:**

| Operador | Semántica | Caso de uso |
|----------|-----------|-------------|
| `AND` | Todas deben estar en ALARM | Confirmar fallo real (reduce falsos positivos) |
| `OR` | Al menos una en ALARM | Alertar ante cualquier señal de problema |
| `NOT` | Inversión del estado | Alertar cuando un servicio se recupera |
| Combinados | `(A AND B) OR C` | Lógica compleja multi-condición |

---

## 7. Anomaly Detection: Alarmas Dinámicas con ML

Las bandas de anomalía usan modelos de machine learning para detectar desviaciones del comportamiento normal. Se adaptan a ciclos estacionales sin necesidad de recalibrar manualmente.

```hcl
resource "aws_cloudwatch_metric_alarm" "anomaly_cpu" {
  alarm_name          = "${var.project}-cpu-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "ad1"   # Referencia a la banda de anomalía

  # Métrica base
  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 300
      stat        = "Average"
    }
  }

  # Banda de anomalía (entrenada con historial de 14 días)
  metric_query {
    id         = "ad1"
    expression = "ANOMALY_DETECTION_BAND(m1, 2)"   # 2 = sensibilidad (desviaciones estándar)
    label      = "CPU Anomaly Band"
    return_data = true
  }
}
```

**Ventajas vs alarmas estáticas:**

| Aspecto | Alarma estática | Anomaly Detection |
|---------|----------------|-------------------|
| Umbral | Fijo (ej: 80%) | Dinámico (aprendido del historial) |
| Tráfico estacional | No se adapta | Se adapta automáticamente |
| Falsos positivos | Altos en picos normales | Reducidos |
| Configuración inicial | Simple | 14 días para entrenar el modelo |
| Ideal para | Límites técnicos fijos | Patrones de negocio variables |

---

## 8. Dashboards as Code: Paneles que Viajan con el Código

Los dashboards definidos en Terraform se versionan, se replican entre entornos y se destruyen limpiamente. El `dashboard_body` es un JSON que describe widgets gráficos con métricas.

```hcl
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x = 0; y = 0; width = 12; height = 6
        properties = {
          title   = "CPU Utilization"
          metrics = [["AWS/EC2", "CPUUtilization"]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x = 12; y = 0; width = 12; height = 6
        properties = {
          title   = "App Error Rate"
          metrics = [["Custom/${var.project}", "AppErrorCount"]]
          period  = 300
          stat    = "Sum"
        }
      }
    ]
  })
}
```

**Tipos de widgets disponibles:**

| Tipo | Descripción |
|------|-------------|
| `metric` | Gráfico de series temporales de métricas |
| `text` | Texto Markdown informativo |
| `log` | Consulta de Logs Insights embebida |
| `alarm` | Estado actual de una alarma |
| `explorer` | Explorador de métricas dinámico |

---

## 9. Logs Insights: Consultas Ad-hoc

Logs Insights permite consultar múltiples Log Groups simultáneamente con un lenguaje propio. Terraform gestiona query definitions para guardar consultas frecuentes.

```hcl
resource "aws_cloudwatch_query_definition" "top_errors" {
  name            = "Top Errors by Source"
  log_group_names = [aws_cloudwatch_log_group.app_logs.name]

  query_string = <<-EOT
    fields @timestamp, @message
    | filter @message like /ERROR/
    | stats count(*) as errors by bin(1h)
    | sort errors desc
    | limit 20
  EOT
}
```

**Sintaxis de Logs Insights:**

```sql
-- Errores en la última hora
fields @timestamp, @message
| filter @message like /ERROR/
| stats count(*) as errors by bin(1h)
| sort errors desc
| limit 20

-- Latencia P99 de Lambda
filter @type = "REPORT"
| stats avg(@duration) as avgDuration,
        pct(@duration, 99) as p99Duration
        by bin(5m)
```

---

## 10. Cross-Account Observability con OAM

En organizaciones multi-cuenta, OAM (Observability Access Manager) permite centralizar métricas, logs y traces en una cuenta de monitoring. Terraform gestiona los links y sinks para compartir telemetría entre cuentas de forma segura.

```hcl
# Cuenta central receptora: OAM Sink
resource "aws_oam_sink" "central" {
  name = "central-monitoring-sink"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = ["oam:CreateLink", "oam:UpdateLink"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = var.org_id
        }
      }
    }]
  })
}

# Cuenta workload: OAM Link → conecta con el Sink central
resource "aws_oam_link" "workload" {
  label_template  = "$AccountName"
  resource_types  = [
    "AWS::CloudWatch::Metric",
    "AWS::Logs::LogGroup",
    "AWS::XRay::Trace",
  ]
  sink_identifier = aws_oam_sink.central.arn
}
```

---

## 11. FinOps de CloudWatch: Controlar el Coste de la Observabilidad

CloudWatch cobra por ingestión, almacenamiento y consultas. Terraform permite definir políticas de retención, elegir Infrequent Access y eliminar recursos huérfanos automáticamente.

**Precios de referencia (us-east-1):**

| Recurso | Precio | Palanca de ahorro |
|---------|--------|------------------|
| Ingestión de logs | $0.50/GB | Filtrar logs verbosos antes de ingestar |
| Almacenamiento | $0.03/GB/mes | Política `retention_in_days` |
| Logs Insights | $0.005/GB consultado | Limitar rango de búsqueda |
| Alarmas | $0.10/alarma/mes | Eliminar alarmas huérfanas |
| Dashboards | 3 gratis, $3/mes el resto | Consolidar en pocos dashboards |

```hcl
# Infrequent Access: 50% menos coste de ingestión
# (sin Insights ni Metric Filters sobre este grupo)
resource "aws_cloudwatch_log_group" "archive_logs" {
  name              = "/app/${var.environment}/archive"
  retention_in_days = 90
  log_group_class   = "INFREQUENT_ACCESS"   # Clase IA

  kms_key_id = aws_kms_key.logs.arn
}
```

---

## 12. Patrones Anti-Frágiles de Monitorización

La monitorización debe ser inmune a los mismos fallos que detecta.

```hcl
# Heartbeat Alarm: detectar ausencia de datos
# Si el sistema no emite métricas → es un problema
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  alarm_name          = "${var.project}-heartbeat"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1

  treat_missing_data = "breaching"   # Sin datos = alarma

  alarm_actions = [aws_sns_topic.critical.arn]
}
```

**Patrones anti-frágiles:**

| Patrón | Implementación | Protección |
|--------|----------------|------------|
| **Heartbeat Alarm** | `treat_missing_data = "breaching"` | Detecta ausencia total de datos |
| **Multi-Región** | Provider aliases en segunda región | Alarmas funcionan si la región primaria falla |
| **Auto-Remediation** | Alarma → SNS → Lambda → Fix | Corrección sin intervención humana |
| **Canary sintético** | CloudWatch Synthetics | Valida endpoints desde fuera de la VPC |

---

## 13. El Flujo Completo: De la Emisión al Acción

```
Aplicación emite log
      │
      ▼
CloudWatch Log Group (retención + KMS)
      │
      ├─ Logs Insights (investigación ad-hoc)
      │
      ├─ Metric Filter (extrae métricas del texto)
      │       │
      │       ▼
      │  CloudWatch Metric
      │       │
      │       ├─ Metric Alarm (umbral estático)
      │       ├─ Anomaly Detection (umbral dinámico)
      │       └─ Composite Alarm (lógica booleana)
      │               │
      │               ▼
      │         SNS Topic
      │               │
      │         ┌─────┴──────┐
      │         ▼            ▼
      │    Email/Slack    Lambda
      │                    │
      │                    ▼
      │              Auto-Remediación
      │
      └─ Dashboard (visualización continua)
```

---

> [← Volver al índice](./README.md) | [Siguiente →](./02_logs_trazas.md)
