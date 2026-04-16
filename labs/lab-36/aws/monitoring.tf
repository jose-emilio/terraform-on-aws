# ── SNS: topic de alertas ─────────────────────────────────────────────────────
#
# Las alarmas de CloudWatch envian notificaciones a este topic.
# Para recibir emails, añade una suscripcion con:
#   aws sns subscribe --topic-arn <arn> --protocol email \
#     --notification-endpoint tu@email.com
# y confirma el email de verificacion que recibiras.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  tags = local.tags
}

# ── CloudWatch: alarma CPU de Redis ──────────────────────────────────────────
#
# EngineCPUUtilization mide exclusivamente el uso de CPU del proceso Redis,
# no el de otros procesos del sistema. Es la metrica correcta para Redis 6.x+
# ya que Redis es single-threaded y su CPU determina el throughput maximo.
#
# Umbral: 65% durante 10 minutos (2 periodos de 5 minutos) es un indicador
# temprano de saturacion. Por encima del 80-90%, Redis empieza a encolar
# comandos y la latencia aumenta drasticamente.

resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${var.project}-redis-cpu-high"
  alarm_description   = "Redis EngineCPUUtilization > 65% durante 10 minutos — revisar carga de trabajo"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 65
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# ── CloudWatch: alarma de evictions de Redis ──────────────────────────────────
#
# Las evictions ocurren cuando Redis alcanza el limite de memoria (maxmemory)
# y expulsa claves para hacer espacio segun la politica de eviccion configurada.
# En un cache de aplicacion, las evictions indican que el cache no tiene suficiente
# memoria para retener el working set, lo que provoca un aumento de cache misses
# y mayor presion sobre DynamoDB.

resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${var.project}-redis-evictions"
  alarm_description   = "Redis Evictions > 100 en 60s — el cache se esta quedando sin memoria"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = local.tags
}
