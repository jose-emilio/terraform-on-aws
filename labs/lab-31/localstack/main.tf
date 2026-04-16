# Versión LocalStack de Lab31.
#
# API Gateway v2 (aws_apigatewayv2_*) y aws_lambda_permission NO están incluidos
# en LocalStack Community (requieren licencia Pro). Se han eliminado de este fichero.
# En LocalStack solo se despliegan los recursos disponibles en Community:
#   archive_file, Lambda Layer, Lambda Function, IAM y CloudWatch Logs.
#
# Para probar el flujo completo HTTP API → Lambda usa aws/ con AWS real.
# Para invocar la función localmente usa:
#   awslocal lambda invoke --function-name <nombre> --payload '<evento>' /tmp/out.json

# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Empaquetado del código fuente ─────────────────────────────────────────────
#
# LocalStack Community no monta Lambda Layers correctamente: aunque el recurso
# aws_lambda_layer_version se crea sin errores, el módulo no queda accesible
# en /opt/python y el handler falla con "No module named 'utils'".
#
# Solución: la Layer se sigue creando (para demostrar su creación en LocalStack)
# pero utils.py se empaqueta también dentro del ZIP de la función usando bloques
# source {}, de modo que "from utils import ..." resuelve desde el mismo directorio.
# En AWS real (aws/main.tf) el ZIP de la función NO incluye utils.py — lo provee
# la Layer correctamente montada en /opt/python.

data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/src/layer"
  output_path = "${path.module}/layer.zip"
}

data "archive_file" "function" {
  type        = "zip"
  output_path = "${path.module}/function.zip"

  # handler.py — código principal de la función
  source {
    content  = file("${path.module}/src/function/handler.py")
    filename = "handler.py"
  }

  # utils.py — incluido directamente porque LocalStack no monta la Layer
  source {
    content  = file("${path.module}/src/layer/python/utils.py")
    filename = "utils.py"
  }
}

# ── CloudWatch Logs ────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-function"
  retention_in_days = 7
  tags              = local.tags
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-lambda-role" })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Lambda Layer ──────────────────────────────────────────────────────────────

resource "aws_lambda_layer_version" "utils" {
  layer_name          = "${var.project}-utils"
  filename            = data.archive_file.layer.output_path
  source_code_hash    = data.archive_file.layer.output_base64sha256
  compatible_runtimes = [var.runtime]
  description         = "Utilidades compartidas: format_response y get_metadata"
}

# ── Lambda Function ───────────────────────────────────────────────────────────

resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-function"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role = aws_iam_role.lambda.arn

  # layers no se usa en LocalStack: utils.py ya viene empaquetado en el ZIP
  # de la función (ver data "archive_file" "function" arriba).

  environment {
    variables = {
      APP_ENV     = var.app_env
      APP_PROJECT = var.project
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.tags, { Name = "${var.project}-function" })
}

# ── API Gateway v2 y Lambda Permission ────────────────────────────────────────
# No disponibles en LocalStack Community. Ver comentario en la cabecera del fichero.
