# ── Red ───────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID de la VPC del laboratorio."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes publicas donde se despliega el ALB."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas donde se despliegan las instancias EC2."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "IP publica del NAT Gateway. Todo el trafico saliente de las instancias privadas usa esta IP."
  value       = aws_eip.nat.public_ip
}

output "selected_azs" {
  description = "AZs seleccionadas para el despliegue (filtradas por disponibilidad del tipo de instancia ARM64)."
  value       = local.arm64_azs
}

# ── ALB ───────────────────────────────────────────────────────────────────────
output "alb_dns_name" {
  description = "DNS publico del Application Load Balancer. Accede a la aplicacion desde el navegador con este nombre."
  value       = aws_lb.main.dns_name
}

output "alb_arn_suffix" {
  description = "Sufijo del ARN del ALB. Se usa como dimension en las metricas de CloudWatch."
  value       = aws_lb.main.arn_suffix
}

# ── Target Groups ─────────────────────────────────────────────────────────────
output "app_tg_arn" {
  description = "ARN del Target Group de la aplicacion."
  value       = aws_lb_target_group.app.arn
}

# ── S3 ────────────────────────────────────────────────────────────────────────
output "artifacts_bucket_name" {
  description = "Nombre del bucket S3 donde se suben los paquetes de despliegue."
  value       = aws_s3_bucket.artifacts.bucket
}

# ── CodeDeploy ────────────────────────────────────────────────────────────────
output "codedeploy_app_name" {
  description = "Nombre de la aplicacion CodeDeploy."
  value       = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group_name" {
  description = "Nombre del grupo de despliegue IN_PLACE."
  value       = aws_codedeploy_deployment_group.inplace.deployment_group_name
}

# ── CloudWatch ────────────────────────────────────────────────────────────────
output "alarm_name" {
  description = "Nombre de la alarma de tasa de errores 5xx. Usa este nombre para simular el rollback."
  value       = aws_cloudwatch_metric_alarm.error_rate.alarm_name
}

# ── Comandos utiles ───────────────────────────────────────────────────────────
output "deploy_commands" {
  description = "Comandos para desplegar la aplicacion y probar el rollback automatico."
  value       = <<-EOT

    # ── Paso 1: Desplegar v1 (despliegue inicial) ────────────────────────────
    cd Labs/Lab44/app/v1
    zip -r /tmp/app-v1.zip .
    aws s3 cp /tmp/app-v1.zip \
      s3://${aws_s3_bucket.artifacts.bucket}/releases/v1.zip \
      --region ${var.region}

    aws deploy create-deployment \
      --application-name ${aws_codedeploy_app.app.name} \
      --deployment-group-name ${aws_codedeploy_deployment_group.inplace.deployment_group_name} \
      --s3-location bucket=${aws_s3_bucket.artifacts.bucket},bundleType=zip,key=releases/v1.zip \
      --description "Despliegue inicial de v1" \
      --region ${var.region}

    # ── Paso 2: Verificar la aplicacion ─────────────────────────────────────
    curl http://${aws_lb.main.dns_name}/health
    curl http://${aws_lb.main.dns_name}/

    # ── Paso 3: Desplegar v2 (rolling IN_PLACE) ──────────────────────────────
    cd Labs/Lab44/app/v2
    zip -r /tmp/app-v2.zip .
    aws s3 cp /tmp/app-v2.zip \
      s3://${aws_s3_bucket.artifacts.bucket}/releases/v2.zip \
      --region ${var.region}

    DEPLOY_ID=$(aws deploy create-deployment \
      --application-name ${aws_codedeploy_app.app.name} \
      --deployment-group-name ${aws_codedeploy_deployment_group.inplace.deployment_group_name} \
      --s3-location bucket=${aws_s3_bucket.artifacts.bucket},bundleType=zip,key=releases/v2.zip \
      --description "Despliegue IN_PLACE rolling de v2" \
      --region ${var.region} \
      --query "deploymentId" --output text)
    echo "Deployment ID: $DEPLOY_ID"

    # ── Paso 4: Seguir el estado del despliegue ──────────────────────────────
    aws deploy get-deployment \
      --deployment-id "$DEPLOY_ID" \
      --region ${var.region} \
      --query "deploymentInfo.status"

    # ── Paso 5: Simular rollback por alarma ──────────────────────────────────
    aws cloudwatch set-alarm-state \
      --alarm-name ${aws_cloudwatch_metric_alarm.error_rate.alarm_name} \
      --state-value ALARM \
      --state-reason "Simulacion de tasa de error elevada para prueba de rollback" \
      --region ${var.region}

    # ── Paso 6: Verificar el rollback ────────────────────────────────────────
    aws deploy get-deployment \
      --deployment-id "$DEPLOY_ID" \
      --region ${var.region} \
      --query "deploymentInfo.{status:status,rollbackInfo:rollbackInfo}"
  EOT
}
