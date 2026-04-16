# ===========================================================================
# Módulo db-config — Configuración de DB (LocalStack)
# ===========================================================================
# Usa SSM SecureString en lugar de Secrets Manager para la contraseña,
# ya que tiene mejor emulación en LocalStack Community.

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/db/password"
  type  = "SecureString"
  value = var.db_password

  tags = var.tags
}

resource "aws_ssm_parameter" "db_engine" {
  name  = "/${var.project_name}/db/engine"
  type  = "String"
  value = var.db_config.engine

  tags = var.tags
}

resource "aws_ssm_parameter" "db_engine_version" {
  name  = "/${var.project_name}/db/engine-version"
  type  = "String"
  value = var.db_config.engine_version

  tags = var.tags
}

resource "aws_ssm_parameter" "db_instance_class" {
  name  = "/${var.project_name}/db/instance-class"
  type  = "String"
  value = var.db_config.instance_class

  tags = var.tags
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.project_name}/db/port"
  type  = "String"
  value = tostring(var.db_config.port)

  tags = var.tags
}

resource "aws_ssm_parameter" "db_config_json" {
  name  = "/${var.project_name}/db/config"
  type  = "String"
  value = jsonencode(var.db_config)

  tags = var.tags
}
