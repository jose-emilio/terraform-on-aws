# ═══════════════════════════════════════════════════════════════════════════════
# Lambda — Inspector de plan de Terraform
# ═══════════════════════════════════════════════════════════════════════════════
#
# La funcion actua como compuerta programatica ANTES de la aprobacion manual.
# Recibe el artefacto plan_output del pipeline, extrae tfplan.json y lo
# analiza para detectar cambios peligrosos:
#
#   - Cuenta los recursos por tipo de accion (create/update/delete/replace)
#   - Bloquea el pipeline si el numero de destrucciones supera max_destroys
#   - Exporta variables de salida con el resumen del plan para que el aprobador
#     tenga contexto visible en la consola de CodePipeline
#
# El variable max_destroys_threshold controla el umbral:
#   -1  → solo inspecciona y reporta, nunca bloquea
#    0  → bloquea si hay cualquier destruccion
#    N  → bloquea si hay mas de N destrucciones
#
# Integracion con CodePipeline:
#   La funcion recibe credenciales temporales en el evento para acceder al
#   artefacto cifrado en S3. Debe llamar a put_job_success_result o
#   put_job_failure_result antes de que expire el timeout (60 s).

data "archive_file" "plan_inspector" {
  type        = "zip"
  source_file = "${path.module}/lambda/plan_inspector.py"
  output_path = "${path.module}/lambda/plan_inspector.zip"
}

resource "aws_lambda_function" "plan_inspector" {
  filename         = data.archive_file.plan_inspector.output_path
  function_name    = "${var.project}-plan-inspector"
  role             = aws_iam_role.lambda_plan_inspector.arn
  handler          = "plan_inspector.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.plan_inspector.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      MAX_DESTROYS = tostring(var.max_destroys_threshold)
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pipeline-plan-inspector"
  }
}

resource "aws_cloudwatch_log_group" "lambda_plan_inspector" {
  name              = "/aws/lambda/${aws_lambda_function.plan_inspector.function_name}"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}
