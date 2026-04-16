# ===========================================================================
# Módulo db-config — Configuración de DB con tipos complejos y secretos
# ===========================================================================
# Valida la configuración de la base de datos usando un tipo object con
# campos obligatorios y opcionales. Almacena la contraseña en Secrets
# Manager (sensitive) y los parámetros de configuración en SSM.

# --- Secrets Manager: contraseña almacenada de forma segura ---

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/db-password"
  description             = "Contraseña del administrador de la base de datos"
  recovery_window_in_days = 0

  tags = merge(var.tags, {
    Name   = "${var.project_name}-db-password"
    Module = "db-config"
  })
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

# --- SSM Parameter Store: configuración desestructurada ---

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
