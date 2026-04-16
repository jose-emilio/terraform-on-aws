output "db_endpoint" {
  description = "Endpoint de la instancia RDS principal (DNS:puerto)"
  value       = "${aws_db_instance.main.address}:${aws_db_instance.main.port}"
}

output "db_host" {
  description = "Hostname de la instancia RDS principal"
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "Puerto PostgreSQL"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Nombre de la base de datos"
  value       = aws_db_instance.main.db_name
}

output "db_username" {
  description = "Usuario maestro"
  value       = aws_db_instance.main.username
}

output "db_resource_id" {
  description = "Resource ID de la instancia principal (usado en la politica IAM de autenticacion)"
  value       = aws_db_instance.main.resource_id
}

output "replica_endpoint" {
  description = "Endpoint de la read replica (DNS:puerto)"
  value       = "${aws_db_instance.replica.address}:${aws_db_instance.replica.port}"
}

output "replica_resource_id" {
  description = "Resource ID de la read replica"
  value       = aws_db_instance.replica.resource_id
}

output "secret_arn" {
  description = "ARN del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "secret_name" {
  description = "Nombre del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.db_password.name
}

output "kms_key_arn" {
  description = "ARN de la CMK KMS"
  value       = aws_kms_key.rds.arn
}

output "kms_alias" {
  description = "Alias de la CMK KMS"
  value       = aws_kms_alias.rds.name
}

output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "app_role_arn" {
  description = "ARN del rol IAM de la aplicacion (para autenticacion IAM a RDS)"
  value       = aws_iam_role.app.arn
}

output "app_url" {
  description = "URL publica de la aplicacion web via ALB"
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_dns" {
  description = "DNS del Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "app_artifacts_bucket" {
  description = "Bucket S3 con el codigo de la aplicacion"
  value       = aws_s3_bucket.app_artifacts.bucket
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID del Launch Template"
  value       = aws_launch_template.app.id
}

output "get_secret_command" {
  description = "Comando para recuperar las credenciales desde Secrets Manager"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db_password.name} --query SecretString --output text | python3 -m json.tool"
}

output "generate_iam_token_command" {
  description = "Comando para generar un token IAM de autenticacion a RDS"
  value       = "aws rds generate-db-auth-token --hostname ${aws_db_instance.main.address} --port ${aws_db_instance.main.port} --region ${var.region} --username ${var.db_username}"
}
