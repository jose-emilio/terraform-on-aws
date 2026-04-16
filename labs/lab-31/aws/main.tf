# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Empaquetado del código fuente ─────────────────────────────────────────────
#
# archive_file genera ZIPs localmente (sin llamadas a AWS).
# output_base64sha256 calcula el hash del contenido del ZIP; pasarlo a
# source_code_hash de aws_lambda_function / aws_lambda_layer_version garantiza
# que Terraform redepliegue la función o la capa cada vez que el código cambie,
# aunque el nombre del fichero ZIP no varíe.

data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/src/layer"
  output_path = "${path.module}/layer.zip"
}

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src/function"
  output_path = "${path.module}/function.zip"
}

# ── CloudWatch Logs ────────────────────────────────────────────────────────────
#
# Crear el log group antes que la función garantiza que los logs de cold start
# se capturen desde el primer instante; sin él, Lambda crea el grupo sin
# retention_in_days, acumulando logs indefinidamente.

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

# AWSLambdaBasicExecutionRole permite escribir logs en CloudWatch.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Lambda Layer ──────────────────────────────────────────────────────────────
#
# La Layer empaqueta el módulo 'utils' en python/utils.py. Lambda añade
# python/ al sys.path del runtime, por lo que el handler puede importarlo
# con: from utils import format_response, get_metadata
#
# La Layer y la función tienen source_code_hash independientes: un cambio en
# utils.py solo redespliega la capa; un cambio en handler.py solo redespliega
# la función. Sin source_code_hash, Terraform no detectaría cambios en el
# contenido del ZIP (solo en el nombre del fichero).

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
  role             = aws_iam_role.lambda.arn

  # Referencia a la Layer por su ARN versionado.
  # Al actualizar la capa (nueva layer_version), basta con que este ARN cambie
  # para que Terraform redepliegue la función con la nueva versión.
  layers = [aws_lambda_layer_version.utils.arn]

  environment {
    variables = {
      APP_ENV     = var.app_env
      APP_PROJECT = var.project
    }
  }

  # depends_on garantiza que el log group exista antes de que Lambda
  # intente escribir en él durante su primer arranque.
  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.tags, { Name = "${var.project}-function" })
}

# ── API Gateway v2 (HTTP API) ─────────────────────────────────────────────────
#
# API Gateway v2 ofrece HTTP API (más barata y rápida) y WebSocket API.
# protocol_type = "HTTP" crea una HTTP API; la REST API (v1) usaría un recurso
# aws_api_gateway_rest_api diferente.

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  description   = "HTTP API del Lab31 — Lambda, API Gateway v2 y Layers"
  tags          = local.tags
}

# ── Stage ─────────────────────────────────────────────────────────────────────
#
# El stage "$default" es el stage predeterminado de las HTTP API. Su URL no
# incluye el nombre del stage en el path (a diferencia de REST API v1).
# auto_deploy = true publica los cambios de rutas e integraciones de forma
# automática; en producción se suele preferir auto_deploy = false y usar
# aws_apigatewayv2_deployment explícito para mayor control.

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  tags        = local.tags
}

# ── Integración AWS_PROXY ─────────────────────────────────────────────────────
#
# integration_type = "AWS_PROXY" delega toda la lógica HTTP a Lambda:
# API Gateway reenvía el evento completo (método, path, headers, body…) y
# Lambda devuelve la respuesta con el formato {statusCode, headers, body}.
# payload_format_version = "2.0" usa el esquema simplificado de v2 que
# proporciona requestContext.http.method, rawPath, etc.

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

# ── Rutas ─────────────────────────────────────────────────────────────────────
#
# route_key = "<MÉTODO> <path>". El placeholder {id} se expone en Lambda
# como event["pathParameters"]["id"].

resource "aws_apigatewayv2_route" "get_items" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "get_item" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "post_items" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# ── Permiso Lambda ────────────────────────────────────────────────────────────
#
# Sin este recurso, API Gateway obtiene un 403 al invocar Lambda.
# source_arn limita el permiso al ARN de ejecución de esta API concreta
# (execution_arn/<stage>/<método>/<path>). El patrón "/*/*" cubre
# cualquier stage, método y ruta de esta API — más seguro que "*".

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
