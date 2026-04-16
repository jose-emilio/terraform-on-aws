# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Empaquetado del código fuente ─────────────────────────────────────────────

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src/function"
  output_path = "${path.module}/function.zip"
}

# ── SQS: Dead Letter Queue ────────────────────────────────────────────────────
#
# La DLQ recibe los mensajes que fallaron maxReceiveCount veces en la cola
# principal. Retención de 14 días para análisis post-mortem.

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-dlq"
  message_retention_seconds = 1209600 # 14 días
  tags                      = merge(local.tags, { Name = "${var.project}-dlq" })
}

# ── SQS: Colas de destino para Lambda Destinations ───────────────────────────
#
# Estas colas reciben los registros de invocación generados por Lambda cuando
# se invoca la función de forma asíncrona (InvocationType = Event).
# No intervienen en el path de SQS Event Source Mapping.

resource "aws_sqs_queue" "success" {
  name = "${var.project}-success"
  tags = merge(local.tags, { Name = "${var.project}-success" })
}

resource "aws_sqs_queue" "failure" {
  name = "${var.project}-failure"
  tags = merge(local.tags, { Name = "${var.project}-failure" })
}

# ── SQS: Cola principal de órdenes ───────────────────────────────────────────
#
# Cola de entrada del sistema. La política de redrive mueve los mensajes a
# la DLQ tras 3 intentos fallidos de procesamiento.
#
# visibility_timeout debe ser >= timeout de la función Lambda para evitar
# que el mensaje vuelva a ser visible mientras Lambda lo está procesando.

resource "aws_sqs_queue" "orders" {
  name                       = "${var.project}-orders"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400 # 1 día

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.tags, { Name = "${var.project}-orders" })
}

# ── CloudWatch Logs ────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-processor"
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

# Permisos SQS: leer de la cola de órdenes y escribir en las colas de destino.
# El Event Source Mapping requiere ReceiveMessage + DeleteMessage + GetQueueAttributes.
# Lambda Destinations requiere SendMessage en las colas de éxito y fallo.

resource "aws_iam_role_policy" "sqs" {
  name = "${var.project}-sqs-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOrdersQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.orders.arn
      },
      {
        Sid    = "WriteDestinationQueues"
        Effect = "Allow"
        Action = ["sqs:SendMessage"]
        Resource = [
          aws_sqs_queue.success.arn,
          aws_sqs_queue.failure.arn,
        ]
      },
    ]
  })
}

# ── Lambda Function ───────────────────────────────────────────────────────────

resource "aws_lambda_function" "processor" {
  function_name    = "${var.project}-processor"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda.arn
  timeout          = 30

  environment {
    variables = {
      APP_ENV     = var.app_env
      APP_PROJECT = var.project
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.sqs,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.tags, { Name = "${var.project}-processor" })
}

# ── Lambda Destinations ───────────────────────────────────────────────────────
#
# Configura los destinos para invocaciones ASÍNCRONAS de Lambda.
# Cuando se invoca la función con InvocationType = Event:
#   - Si retorna con éxito → Lambda envía un registro a on_success (success-queue)
#   - Si lanza una excepción → Lambda envía un registro a on_failure (failure-queue)
#
# IMPORTANTE: estos destinos NO se activan en el path de SQS Event Source Mapping
# porque ese path usa invocación síncrona. Para el path SQS, los fallos se
# gestionan con la redrive_policy de aws_sqs_queue.orders (→ DLQ tras 3 intentos).

resource "aws_lambda_function_event_invoke_config" "processor" {
  function_name = aws_lambda_function.processor.function_name

  destination_config {
    on_success {
      destination = aws_sqs_queue.success.arn
    }
    on_failure {
      destination = aws_sqs_queue.failure.arn
    }
  }
}

# ── Event Source Mapping ──────────────────────────────────────────────────────
#
# Configura el polling de Lambda sobre la cola de órdenes.
#
# filter_criteria: Lambda solo procesa mensajes cuyo body (JSON parseado)
# contenga "order_type": "premium". Los mensajes que no coincidan se eliminan
# automáticamente de la cola sin invocar Lambda.
#
# batch_size = 10: Lambda acumula hasta 10 mensajes por invocación, reduciendo
# el número de llamadas y aprovechando el paralelismo del handler.

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10
  enabled          = true

  filter_criteria {
    filter {
      pattern = jsonencode({
        body = {
          order_type = ["premium"]
        }
      })
    }
  }
}
