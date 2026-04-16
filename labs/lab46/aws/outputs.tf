output "dashboard_url" {
  description = "URL directa al dashboard de CloudWatch en la consola de AWS."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "instance_id" {
  description = "ID de la instancia EC2 que genera los logs."
  value       = aws_instance.app.id
}

output "log_group_name" {
  description = "Nombre del log group de CloudWatch."
  value       = aws_cloudwatch_log_group.app.name
}

output "kms_key_arn" {
  description = "ARN de la CMK KMS usada para cifrar los logs."
  value       = aws_kms_key.logs.arn
}

output "alert_topic_arn" {
  description = "ARN del topic SNS que recibe las alertas de la Composite Alarm."
  value       = aws_sns_topic.alerts.arn
}

output "ssm_session_command" {
  description = "Comando para abrir una sesion SSM en la instancia EC2."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.region}"
}
