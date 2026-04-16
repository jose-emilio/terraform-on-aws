# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Roles para los servicios del pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# Roles creados:
#   pipeline               → codepipeline.amazonaws.com
#   codebuild-validate     → validate + security_scan  (analisis estatico)
#   codebuild-plan         → plan                      (ReadOnlyAccess + artefactos)
#   codebuild-apply        → apply                     (AdministratorAccess)
#   codebuild-smoketest    → smoketest                 (ReadOnlyAccess + KMS target)
#   lambda_plan_inspector  → lambda.amazonaws.com
#   events                 → events.amazonaws.com      (EventBridge → CodePipeline)

locals {
  # Permisos de pipeline comunes a todos los roles CodeBuild
  codebuild_pipeline_statements = [
    {
      Sid    = "ArtifactsBucket"
      Effect = "Allow"
      Action = [
        "s3:GetObject", "s3:GetObjectVersion",
        "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*"
      ]
    },
    {
      Sid    = "ArtifactsKms"
      Effect = "Allow"
      Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = [aws_kms_key.artifacts.arn]
    }
  ]
}

# ── 1. CodePipeline ───────────────────────────────────────────────────────────

resource "aws_iam_role" "pipeline" {
  name        = "${var.project}-pipeline"
  description = "Rol de ejecucion para el pipeline CodePipeline de ${var.project}."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${var.project}-pipeline-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactsBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:GetObjectVersion",
          "s3:PutObject", "s3:GetBucketVersioning"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Sid    = "ArtifactsKms"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.artifacts.arn]
      },
      {
        Sid    = "SourceCodeCommit"
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch", "codecommit:GetCommit",
          "codecommit:UploadArchive", "codecommit:GetUploadArchiveStatus",
          "codecommit:CancelUploadArchive"
        ]
        Resource = [aws_codecommit_repository.terraform.arn]
      },
      {
        Sid    = "CodeBuildActions"
        Effect = "Allow"
        Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = [
          aws_codebuild_project.validate.arn,
          aws_codebuild_project.security_scan.arn,
          aws_codebuild_project.plan.arn,
          aws_codebuild_project.apply.arn,
          aws_codebuild_project.smoketest.arn
        ]
      },
      {
        Sid      = "LambdaInvoke"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction", "lambda:ListFunctions"]
        Resource = [aws_lambda_function.plan_inspector.arn]
      },
      {
        Sid      = "SnsApprovals"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.approvals.arn]
      },
      {
        Sid    = "IamPassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.codebuild_validate.arn,
          aws_iam_role.codebuild_plan.arn,
          aws_iam_role.codebuild_apply.arn,
          aws_iam_role.codebuild_smoketest.arn,
        ]
      }
    ]
  })
}

# ── 2a. CodeBuild — validate + security_scan ─────────────────────────────────
#
# Analisis estatico sobre el codigo fuente. No necesita acceso al state
# backend ni permisos de infraestructura. Solo logs, reports y leer
# el artefacto source_output del bucket de artefactos.

resource "aws_iam_role" "codebuild_validate" {
  name        = "${var.project}-codebuild-validate"
  description = "Rol para los proyectos ValidateAndLint y SecurityScan."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "codebuild_validate" {
  name = "${var.project}-codebuild-validate-policy"
  role = aws_iam_role.codebuild_validate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.codebuild_pipeline_statements, [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-validate*",
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-security-scan*"
        ]
      },
      {
        Sid    = "CodeBuildReports"
        Effect = "Allow"
        Action = [
          "codebuild:CreateReportGroup", "codebuild:CreateReport",
          "codebuild:UpdateReport", "codebuild:BatchPutTestCases"
        ]
        Resource = "arn:aws:codebuild:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:report-group/${var.project}-*"
      }
    ])
  })
}

# ── 2b. CodeBuild — plan ──────────────────────────────────────────────────────
#
# Ejecuta terraform plan. Necesita leer el estado remoto y hacer refresh
# de los recursos existentes. ReadOnlyAccess cubre el refresh sin necesidad
# de enumerar cada tipo de recurso del target.

resource "aws_iam_role" "codebuild_plan" {
  name        = "${var.project}-codebuild-plan"
  description = "Rol para el proyecto Plan."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "codebuild_plan_readonly" {
  role       = aws_iam_role.codebuild_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "codebuild_plan" {
  name = "${var.project}-codebuild-plan-policy"
  role = aws_iam_role.codebuild_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.codebuild_pipeline_statements, [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-plan*"
      },
      {
        Sid    = "TerraformStateBackend"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/tfstate/*"]
      },
      {
        # Necesario para que terraform plan pueda refrescar recursos cifrados
        # con CMKs del target (ej. SSM SecureString, S3 SSE-KMS, CW Log Group).
        # El ARN de esas keys no se conoce en tiempo de provision del pipeline.
        Sid      = "KmsDecryptTarget"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region }
        }
      }
    ])
  })
}

# ── 2c. CodeBuild — apply ─────────────────────────────────────────────────────
#
# Ejecuta terraform apply sobre infraestructura arbitraria. Necesita permisos
# plenos para crear, modificar y destruir cualquier tipo de recurso AWS.
# AdministratorAccess es la solucion correcta para un rol de despliegue.

resource "aws_iam_role" "codebuild_apply" {
  name        = "${var.project}-codebuild-apply"
  description = "Rol para el proyecto Apply. Permisos de administrador para terraform apply."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "codebuild_apply_admin" {
  role       = aws_iam_role.codebuild_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── 2d. CodeBuild — smoketest ─────────────────────────────────────────────────
#
# Lee outputs del estado de Terraform y verifica los recursos via API.
# ReadOnlyAccess cubre todas las llamadas de verificacion. Se anade kms:Decrypt
# en * para poder descifrar el parametro SSM SecureString del target (cuyo
# key ARN no se conoce hasta el momento del apply).

resource "aws_iam_role" "codebuild_smoketest" {
  name        = "${var.project}-codebuild-smoketest"
  description = "Rol para el proyecto SmokeTest."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy_attachment" "codebuild_smoketest_readonly" {
  role       = aws_iam_role.codebuild_smoketest.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "codebuild_smoketest" {
  name = "${var.project}-codebuild-smoketest-policy"
  role = aws_iam_role.codebuild_smoketest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.codebuild_pipeline_statements, [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-smoketest*"
      },
      {
        Sid    = "TerraformStateBackend"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/tfstate/*"]
      },
      {
        # Necesario para descifrar el parametro SSM SecureString del target
        Sid      = "KmsDecryptTarget"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region }
        }
      }
    ])
  })
}

# ── 3. Lambda — plan inspector ────────────────────────────────────────────────

resource "aws_iam_role" "lambda_plan_inspector" {
  name        = "${var.project}-lambda-plan-inspector"
  description = "Rol de ejecucion para la Lambda inspectora del plan de Terraform."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "lambda_plan_inspector" {
  name = "${var.project}-lambda-plan-inspector-policy"
  role = aws_iam_role.lambda_plan_inspector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda_plan_inspector.arn}:*"
      },
      {
        Sid      = "ArtifactsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Sid      = "ArtifactsKms"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.artifacts.arn]
      },
      {
        Sid    = "CodePipelineJobResult"
        Effect = "Allow"
        Action = ["codepipeline:PutJobSuccessResult", "codepipeline:PutJobFailureResult"]
        Resource = "*"
      }
    ]
  })
}

# ── 4. EventBridge → CodePipeline ────────────────────────────────────────────

resource "aws_iam_role" "events" {
  name        = "${var.project}-events"
  description = "Permite a EventBridge disparar el pipeline ${var.project} en cada push."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "events" {
  name = "${var.project}-events-policy"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartPipeline"
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = [aws_codepipeline.main.arn]
    }]
  })
}
