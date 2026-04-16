# ── Empaquetado del codigo ────────────────────────────────────────────────────
#
# data.archive_file crea el ZIP de la Lambda localmente en tiempo de plan.
# source_code_hash garantiza que Terraform detecta cambios en lambda_function.py
# y re-despliega la funcion automaticamente con terraform apply.

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda/lambda.zip"
  source_file = "${path.module}/lambda/lambda_function.py"
}

# ── Funcion Lambda CDC ────────────────────────────────────────────────────────
#
# Procesa cada batch de registros del stream de DynamoDB:
#   1. Extrae el tipo de evento (INSERT / MODIFY / REMOVE).
#   2. Recupera los atributos clave del producto afectado.
#   3. Escribe un item de auditoria en la tabla de eventos con TTL de 7 dias.
#
# La Lambda corre fuera de la VPC: DynamoDB es un servicio con endpoint publico
# y no requiere conectividad VPC para ser accedido desde Lambda.

resource "aws_lambda_function" "cdc_processor" {
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  function_name    = "${var.project}-cdc-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      EVENTS_TABLE = aws_dynamodb_table.events.name
      REGION       = var.region
    }
  }

  tags = local.tags
}

# ── Event Source Mapping desde DynamoDB Streams ───────────────────────────────
#
# Conecta el stream de la tabla de productos con la funcion Lambda.
# DynamoDB invoca la Lambda en batch cuando detecta nuevos registros.
#
# starting_position = "LATEST": procesa solo los eventos nuevos desde el
#   momento del despliegue. "TRIM_HORIZON" procesaria desde el inicio del stream.

resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  event_source_arn  = aws_dynamodb_table.products.stream_arn
  function_name     = aws_lambda_function.cdc_processor.arn
  starting_position = "LATEST"
  batch_size        = 10

  depends_on = [aws_iam_role_policy_attachment.lambda_dynamodb_stream]
}
