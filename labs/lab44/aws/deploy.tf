# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch — Alarma de tasa de errores 5xx
# ═══════════════════════════════════════════════════════════════════════════════
#
# La alarma usa Metric Math para calcular el porcentaje de errores 5xx sobre
# el total de peticiones al ALB. Si supera el umbral en dos periodos consecutivos
# de 60 segundos, CodeDeploy detiene el despliegue y reinstala la revision anterior.
#
# IF(requests > 0, ...) evita la division por cero cuando el ALB no ha recibido
# peticiones todavia (p. ej. en los primeros segundos tras el despliegue).
#
# treat_missing_data = "notBreaching": si no hay datos (sin peticiones), la alarma
# no se dispara. Sin esto, la alarma podria activarse al inicio del despliegue
# antes de que llegue trafico real.

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.project}-5xx-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.error_rate_threshold
  alarm_description   = "Tasa de errores HTTP 5xx > ${var.error_rate_threshold}% en 2 periodos consecutivos. Rollback automatico de CodeDeploy."
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, (errors / requests) * 100, 0)"
    label       = "Tasa de errores 5xx (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CodeDeploy — Aplicacion, configuracion de despliegue y grupo
# ═══════════════════════════════════════════════════════════════════════════════
#
# La aplicacion es el contenedor logico en CodeDeploy.
# compute_platform = "Server" indica que el objetivo son instancias EC2
# (en contraposicion a "ECS" o "Lambda", que tienen modelos de despliegue distintos).

resource "aws_codedeploy_app" "app" {
  name             = "${var.project}-app"
  compute_platform = "Server"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# Configuracion de despliegue con minimo de salud del 75%:
#   FLEET_PERCENT: 75 significa que al menos el 75% de las instancias del ASG
#   deben estar en estado healthy durante el despliegue. Con 4 instancias esto
#   permite un lote maximo de 1 instancia por ronda (el 25% restante).
resource "aws_codedeploy_deployment_config" "healthy_75" {
  deployment_config_name = "${var.project}-MinimumHealthy75Pct"
  compute_platform       = "Server"

  minimum_healthy_hosts {
    type  = "FLEET_PERCENT"
    value = 75
  }
}

# Grupo de despliegue IN_PLACE con control de trafico ALB y rollback por alarma.
#
# Flujo completo de un despliegue:
#
#   1. CodeDeploy selecciona un lote de instancias del ASG (hasta el 25% segun
#      la politica MinimumHealthy75Pct) y las deregistra del Target Group del ALB.
#      El ALB deja de enviarles trafico; las conexiones existentes drenan durante
#      el deregistration_delay (10 s).
#
#   2. El agente CodeDeploy en cada instancia descarga el zip de S3 y ejecuta
#      los hooks del appspec.yml:
#        ApplicationStop  → detiene Apache si esta en ejecucion
#        BeforeInstall    → elimina ficheros previos de /var/www/html
#        AfterInstall     → copia ficheros y arranca Apache con la nueva version
#        ValidateService  → verifica que /health responde 200
#
#   3. Cuando las instancias pasan ValidateService y el health check del ALB,
#      CodeDeploy las vuelve a registrar en el Target Group y procesa el
#      siguiente lote hasta completar todas las instancias.
#
#   4. Rollback automatico:
#      Si ValidateService falla o la alarma de errores 5xx se dispara,
#      CodeDeploy detiene el despliegue y reinstala la revision anterior
#      en las instancias afectadas.
#
# Nota: el trigger_configuration (notificaciones SNS) forma parte del Reto 1.

resource "aws_codedeploy_deployment_group" "inplace" {
  app_name              = aws_codedeploy_app.app.name
  deployment_group_name = "${var.project}-inplace-dg"
  service_role_arn      = aws_iam_role.codedeploy.arn

  deployment_config_name = aws_codedeploy_deployment_config.healthy_75.id

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  autoscaling_groups = [aws_autoscaling_group.app.name]

  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app.name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.error_rate.alarm_name]
    enabled = true
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
