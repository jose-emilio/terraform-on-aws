# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol de servicio de CodeBuild
# ═══════════════════════════════════════════════════════════════════════════════
#
# Estructura de permisos:
#
#   Rol:  lab43-codebuild-role
#   ├── Politica inline: codebuild-logs
#   │   └── logs:CreateLogStream, logs:PutLogEvents en el grupo de CloudWatch
#   │
#   ├── Politica inline: codebuild-s3
#   │   ├── s3:PutObject                       (escribir el tfplan como artefacto)
#   │   ├── s3:ListBucket                      (metadatos del bucket)
#   │   └── s3:GetBucketAcl, s3:GetBucketLocation (metadatos que CodeBuild lee)
#   │
#   ├── Politica inline: codebuild-codecommit
#   │   └── codecommit:GitPull                 (clonar el repositorio)
#   │
#   └── Politica inline: codebuild-ecr
#       ├── ecr:GetAuthorizationToken          (autenticarse con ECR)
#       ├── ecr:GetDownloadUrlForLayer         (descargar capas de la imagen)
#       ├── ecr:BatchGetImage                  (descargar manifiesto)
#       └── ecr:BatchCheckLayerAvailability    (verificar disponibilidad)
#
# Principio de minimo privilegio:
#   Cada politica restringe las acciones al recurso especifico (ARN del bucket,
#   ARN del repositorio ECR o ARN del grupo de logs). ecr:GetAuthorizationToken
#   es la unica excepcion — no soporta restriccion por recurso y necesita "*".

# ── Trust Policy — quien puede asumir el rol ──────────────────────────────────
data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    sid    = "AllowCodeBuildAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    # La condicion aws:SourceAccount impide el confused-deputy problem:
    # solo un proyecto CodeBuild de ESTA cuenta puede asumir el rol.
    # Sin esta condicion, un atacante que controlase un servicio AWS podria
    # abusar de la trust policy para escalar privilegios entre cuentas.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.project}-codebuild-role"
  path               = "/iac-pipeline/"
  description        = "Rol de servicio para el runner de IaC en CodeBuild. Lab43."
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codebuild-service-role"
  }
}

# ── Politica: CloudWatch Logs ─────────────────────────────────────────────────
#
# CodeBuild necesita crear el log stream de cada build y escribir los logs
# de las fases install, pre_build y build en CloudWatch.
# CreateLogGroup no es necesario porque el grupo se crea con Terraform.
data "aws_iam_policy_document" "codebuild_logs" {
  statement {
    sid    = "AllowWriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${aws_cloudwatch_log_group.codebuild.arn}",
      "${aws_cloudwatch_log_group.codebuild.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_logs" {
  name   = "codebuild-logs"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_logs.json
}

# ── Politica: S3 (solo artefactos) ────────────────────────────────────────────
#
# Con CodeCommit como fuente ya no se necesita leer el zip del bucket.
# CodeBuild solo necesita:
#   - Subir los artefactos:  s3:PutObject
#   - Metadatos del bucket:  s3:ListBucket + s3:GetBucketAcl + s3:GetBucketLocation
#     (CodeBuild verifica permisos sobre el bucket antes de iniciar el build)
data "aws_iam_policy_document" "codebuild_s3" {
  statement {
    sid    = "AllowWriteArtifacts"
    effect = "Allow"

    actions = ["s3:PutObject"]

    resources = ["${aws_s3_bucket.pipeline.arn}/artifacts/*"]
  }

  statement {
    sid    = "AllowBucketMetadata"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
    ]

    resources = [aws_s3_bucket.pipeline.arn]
  }
}

# ── Politica: CodeCommit (clonar el repositorio) ──────────────────────────────
#
# CodeBuild clona el repositorio de CodeCommit en cada build usando HTTPS.
# codecommit:GitPull es la unica accion necesaria — agrupa internamente las
# operaciones git clone, git fetch y git pull sobre el repositorio.
data "aws_iam_policy_document" "codebuild_codecommit" {
  statement {
    sid    = "AllowGitPull"
    effect = "Allow"

    actions   = ["codecommit:GitPull"]
    resources = [aws_codecommit_repository.terraform_code.arn]
  }
}

resource "aws_iam_role_policy" "codebuild_s3" {
  name   = "codebuild-s3"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_s3.json
}

# ── Politica: ECR (pull de la imagen custom) ──────────────────────────────────
#
# Para que CodeBuild pueda usar la imagen custom del runner de IaC, el rol
# de servicio necesita:
#   1. ecr:GetAuthorizationToken — obtiene el token de autenticacion de Docker
#      para el registro ECR. Esta accion no soporta restriccion por recurso:
#      siempre necesita "Resource": "*".
#   2. ecr:GetDownloadUrlForLayer, ecr:BatchGetImage,
#      ecr:BatchCheckLayerAvailability — descargar la imagen capa a capa.
#      Estas SI se pueden restringir al ARN del repositorio especifico.
#
# image_pull_credentials_type = "SERVICE_ROLE" en el proyecto CodeBuild
# activa este mecanismo (en lugar del "CODEBUILD" que usa credenciales internas).
data "aws_iam_policy_document" "codebuild_ecr" {
  statement {
    sid    = "AllowECRLogin"
    effect = "Allow"

    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowPullImage"
    effect = "Allow"

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]

    resources = [aws_ecr_repository.iac_runner.arn]
  }
}

resource "aws_iam_role_policy" "codebuild_ecr" {
  name   = "codebuild-ecr"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_ecr.json
}

# ── Política: CodeBuild Reports ───────────────────────────────────────────────
#
# Para que el buildspec pueda publicar informes JUnit en la pestaña Reports,
# el rol de servicio necesita cinco acciones sobre el report group del proyecto:
#
#   codebuild:CreateReportGroup   — crea el grupo en la primera ejecucion
#   codebuild:CreateReport        — crea un informe por build
#   codebuild:UpdateReport        — marca el informe como completado
#   codebuild:BatchPutTestCases   — escribe los casos de test individuales
#   codebuild:BatchPutCodeCoverages — requerida por el agente de CodeBuild aunque
#                                     no se usen coverage reports: sin ella el
#                                     agente puede fallar silenciosamente al
#                                     finalizar el upload del report JUnit.
#
# El ARN del report group sigue el patron:
#   arn:aws:codebuild:<region>:<account>:report-group/<project-name>-<report-name>
#
# Usamos un wildcard al final para cubrir cualquier report group del proyecto
# sin tener que conocer el nombre exacto en tiempo de despliegue.
data "aws_iam_policy_document" "codebuild_reports" {
  statement {
    sid    = "AllowPublishReports"
    effect = "Allow"

    actions = [
      "codebuild:CreateReportGroup",
      "codebuild:CreateReport",
      "codebuild:UpdateReport",
      "codebuild:BatchPutTestCases",
      "codebuild:BatchPutCodeCoverages",
    ]

    resources = [
      "arn:aws:codebuild:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:report-group/${var.project}-${var.codebuild_project_name}-*"
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_reports" {
  name   = "codebuild-reports"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_reports.json
}

resource "aws_iam_role_policy" "codebuild_codecommit" {
  name   = "codebuild-codecommit"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_codecommit.json
}

# ── Rol de servicio para EventBridge ─────────────────────────────────────────
#
# EventBridge necesita un rol con permisos para llamar a codebuild:StartBuild
# en el proyecto especifico. Sin este rol, la regla de EventBridge no puede
# lanzar el build cuando detecta un push en CodeCommit.

data "aws_iam_policy_document" "events_trust" {
  statement {
    sid    = "AllowEventsAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.project}-events-role"
  path               = "/iac-pipeline/"
  description        = "Rol de EventBridge para disparar CodeBuild en push a CodeCommit. Lab43."
  assume_role_policy = data.aws_iam_policy_document.events_trust.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "eventbridge-codebuild-trigger"
  }
}

data "aws_iam_policy_document" "events_codebuild" {
  statement {
    sid    = "AllowStartBuild"
    effect = "Allow"

    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.iac_runner.arn]
  }
}

resource "aws_iam_role_policy" "events_codebuild" {
  name   = "events-start-build"
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events_codebuild.json
}
