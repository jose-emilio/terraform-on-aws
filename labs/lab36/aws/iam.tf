# ── IAM Role para EC2 ─────────────────────────────────────────────────────────
#
# La instancia necesita:
#   - SSM: acceso sin SSH desde la consola AWS.
#   - DynamoDB: CRUD sobre las tablas de productos y eventos.
#   - S3: descarga del artefacto app.py.
#   - Secrets Manager: recupera el AUTH token de Redis.
#   - CloudWatch: describe alarmas para mostrar su estado en la UI.

resource "aws_iam_role" "app" {
  name        = "${var.project}-app-role"
  description = "Rol EC2: SSM + DynamoDB + S3 + SecretsManager + CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.project}-app-policy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Scan", "dynamodb:Query",
          "dynamodb:BatchWriteItem", "dynamodb:DescribeTable"
        ]
        Resource = [
          aws_dynamodb_table.products.arn,
          "${aws_dynamodb_table.products.arn}/index/*",
          aws_dynamodb_table.events.arn,
        ]
      },
      {
        Sid      = "S3Artifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.app_artifacts.arn}/*"
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.redis_auth.arn
      },
      {
        Sid      = "CloudWatchAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.app.name
}

# ── IAM Role para Lambda ──────────────────────────────────────────────────────
#
# La Lambda que procesa el stream de DynamoDB necesita:
#   - AWSLambdaBasicExecutionRole: escribe logs en CloudWatch Logs.
#   - AWSLambdaDynamoDBExecutionRole: lee del stream de DynamoDB
#     (GetRecords, GetShardIterator, DescribeStream, ListStreams).
#   - dynamodb:PutItem sobre la tabla de eventos (politica inline).

resource "aws_iam_role" "lambda" {
  name        = "${var.project}-lambda-role"
  description = "Rol Lambda CDC: leer stream DynamoDB + escribir tabla de eventos"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_stream" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
}

resource "aws_iam_role_policy" "lambda_events" {
  name = "${var.project}-lambda-events"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteEvents"
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem"]
      Resource = aws_dynamodb_table.events.arn
    }]
  })
}
