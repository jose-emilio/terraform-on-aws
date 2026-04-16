# Versión LocalStack de Lab30.
#
# Recursos disponibles en LocalStack Community:
#   SQS (colas, redrive_policy, DLQ), Lambda, IAM, CloudWatch Logs,
#   archive_file, aws_lambda_event_source_mapping, aws_iam_role_policy.
#
# Limitaciones conocidas:
#   filter_criteria  — soporte parcial; en Community los filtros pueden no
#                      aplicarse y todos los mensajes activarían Lambda.
#   Lambda Destinations (aws_lambda_function_event_invoke_config) — soporte
#                      parcial; el recurso se crea sin errores pero LocalStack
#                      Community puede no enrutar el resultado a las colas.
#
# Para verificar el flujo completo con filtros y destinos garantizados usa AWS real.

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

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-dlq"
  message_retention_seconds = 1209600 # 14 días
  tags                      = merge(local.tags, { Name = "${var.project}-dlq" })
}

# ── SQS: Colas de destino para Lambda Destinations ───────────────────────────

resource "aws_sqs_queue" "success" {
  name = "${var.project}-success"
  tags = merge(local.tags, { Name = "${var.project}-success" })
}

resource "aws_sqs_queue" "failure" {
  name = "${var.project}-failure"
  tags = merge(local.tags, { Name = "${var.project}-failure" })
}

# ── SQS: Cola principal de órdenes ───────────────────────────────────────────

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
# Soporte parcial en LocalStack Community. El recurso se crea correctamente
# pero el enrutamiento hacia las colas puede no ejecutarse.

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
# filter_criteria tiene soporte parcial en LocalStack Community.
# Si los filtros no se aplican, mensajes de cualquier order_type activarán Lambda.

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
