# ── Data sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ═══════════════════════════════════════════════════════════════════════════════
# CodeCommit — Repositorio del codigo Terraform objetivo
# ═══════════════════════════════════════════════════════════════════════════════
#
# El codigo Terraform que el pipeline valida vive aqui. Cada push a la rama
# main dispara automaticamente un build de CodeBuild via EventBridge.
# El buildspec.yml tambien vive en este repositorio junto al codigo.

resource "aws_codecommit_repository" "terraform_code" {
  repository_name = "${var.project}-${var.codecommit_repo_name}"
  description     = "Codigo Terraform objetivo del pipeline de validacion IaC. Lab43."

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "iac-source-code"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# EventBridge — Trigger automatico en push a CodeCommit
# ═══════════════════════════════════════════════════════════════════════════════
#
# CodeCommit emite un evento referenceUpdated cada vez que se hace push.
# La regla filtra por:
#   - El repositorio especifico (evita builds de otros repos)
#   - La rama main (evita builds de ramas de feature)
# El target es el proyecto CodeBuild, que se lanza con el rol de eventos.

resource "aws_cloudwatch_event_rule" "codecommit_push" {
  name        = "${var.project}-on-push-main"
  description = "Dispara CodeBuild en cada push a main del repo de codigo Terraform."

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.terraform_code.arn]
    detail = {
      event         = ["referenceUpdated", "referenceCreated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_cloudwatch_event_target" "codebuild" {
  rule     = aws_cloudwatch_event_rule.codecommit_push.name
  arn      = aws_codebuild_project.iac_runner.arn
  role_arn = aws_iam_role.events.arn
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Bucket de pipeline (solo artefactos)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Con CodeCommit como fuente, el bucket ya no necesita almacenar el zip del
# codigo. Solo se usa para los artefactos generados por el build:
#   artifacts/<BUILD_ID>/plan  — tfplan y tfplan.txt comprimidos
#
# Se aplican los controles de seguridad estandar: cifrado SSE-S3, versionado,
# bloqueo de acceso publico y politica de bucket que impide trafico no cifrado.

resource "aws_s3_bucket" "pipeline" {
  bucket        = "${var.project}-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codebuild-source-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline" {
  bucket                  = aws_s3_bucket.pipeline.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Politica de bucket: exige HTTPS para todas las operaciones.
# CodeBuild, la AWS CLI y el SDK de AWS siempre usan HTTPS, por lo que
# esta restriccion no afecta a los clientes legitimos.
data "aws_iam_policy_document" "pipeline_bucket_policy" {
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.pipeline.arn, "${aws_s3_bucket.pipeline.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id
  policy = data.aws_iam_policy_document.pipeline_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.pipeline]
}

# Regla de ciclo de vida: elimina automaticamente los artefactos de builds
# con mas de 90 dias para controlar el coste de almacenamiento.
resource "aws_s3_bucket_lifecycle_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    filter {
      prefix = "artifacts/"
    }

    expiration {
      days = 90
    }
  }

}

# ═══════════════════════════════════════════════════════════════════════════════
# ECR — Repositorio de imagenes del runner de IaC
# ═══════════════════════════════════════════════════════════════════════════════
#
# El repositorio almacena la imagen Docker del runner (Terraform + TFLint +
# tfsec + Checkov). Cada push a ECR activa un escaneo de vulnerabilidades
# automatico con Amazon Inspector (Enhanced Scanning) o con el escaner nativo
# de ECR, segun lo que este habilitado en la cuenta.
#
# image_tag_mutability = "IMMUTABLE":
#   Un tag (como "latest" o "v1.0.0") no puede ser reasignado a un digest
#   diferente una vez publicado. Para actualizar "latest" hay que borrar el
#   tag anterior o usar un tag nuevo. Esto garantiza que CodeBuild siempre
#   descarga exactamente el binario que se publico con ese tag — sin sorpresas
#   silenciosas por sobreescritura del tag.
#
# scan_on_push = true:
#   Cada push dispara un analisis de vulnerabilidades contra la base de datos
#   CVE de Amazon Inspector. Los resultados son visibles en la consola de ECR
#   y exportables via EventBridge para integracion con sistemas de alertas.

resource "aws_ecr_repository" "iac_runner" {
  name                 = "${var.project}/${var.ecr_repo_name}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "iac-runner-image"
  }
}

# Politica de ciclo de vida del repositorio ECR:
#   Regla 1 — Mantener como maximo N imagenes etiquetadas (por fecha de push).
#             Las mas antiguas se eliminan automaticamente cuando se supera el limite.
#   Regla 2 — Eliminar imagenes sin etiquetar tras 1 dia.
#             Las imagenes sin tag son capas intermedias o builds fallidos que
#             ocupan espacio sin valor operacional.
resource "aws_ecr_lifecycle_policy" "iac_runner" {
  repository = aws_ecr_repository.iac_runner.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Mantener las ultimas ${var.ecr_max_images} imagenes etiquetadas"
        selection = {
          tagStatus   = "tagged"
          tagPatternList = ["*"]
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_max_images
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Eliminar imagenes sin etiquetar tras 1 dia"
        selection = {
          tagStatus = "untagged"
          countType = "sinceImagePushed"
          countUnit = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Politica del repositorio ECR:
#   Permite al rol de servicio de CodeBuild autenticarse y descargar la imagen.
#   CodeBuild necesita tres acciones para usar una imagen ECR:
#     ecr:GetDownloadUrlForLayer  — URL de descarga de cada capa
#     ecr:BatchGetImage           — descarga del manifiesto de la imagen
#     ecr:BatchCheckLayerAvailability — verifica que las capas esten disponibles
#
#   La accion ecr:GetAuthorizationToken (necesaria para el login de Docker)
#   no se puede restringir por recurso — se gestiona en la politica de identidad.

data "aws_iam_policy_document" "ecr_repository_policy" {
  statement {
    sid    = "AllowCodeBuildPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.codebuild.arn]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "iac_runner" {
  repository = aws_ecr_repository.iac_runner.name
  policy     = data.aws_iam_policy_document.ecr_repository_policy.json
}

# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Logs — Grupo de logs del proyecto CodeBuild
# ═══════════════════════════════════════════════════════════════════════════════
#
# Los logs de CodeBuild se estructuran en:
#   /aws/codebuild/<project-name>   — grupo del proyecto
#       <build-id>                  — stream de cada ejecucion
#
# Gestionar el grupo con Terraform en lugar de dejar que CodeBuild lo cree
# automaticamente permite controlar la retencion y aplicar politicas de cifrado.

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project}-${var.codebuild_project_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CodeBuild — Proyecto de validacion y planificacion de IaC
# ═══════════════════════════════════════════════════════════════════════════════
#
# El proyecto orquesta tres fases definidas en buildspec.yml:
#
#   install   — Verifica que las herramientas de la imagen estan disponibles.
#
#   pre_build — Ejecuta las validaciones de calidad en orden:
#               1. terraform fmt   (formato)
#               2. terraform init + validate (sintaxis)
#               3. tflint          (errores logicos y uso de APIs)
#               4. tfsec           (misconfiguraciones de seguridad conocidas)
#               5. checkov         (politicas de seguridad como codigo)
#               Si cualquier paso falla (exit code != 0) el build se aborta
#               inmediatamente — patron "Fail Fast".
#
#   build     — Solo se ejecuta si pre_build supero todas las validaciones.
#               Genera el tfplan que sera revisado o aplicado.
#
# image_pull_credentials_type = "SERVICE_ROLE":
#   CodeBuild usa las credenciales del rol de servicio para autenticarse
#   con ECR. Esto hace explicitos los permisos necesarios (visibles en iam.tf)
#   y permite usar repositorios ECR de cualquier cuenta, no solo la propia.

resource "aws_codebuild_project" "iac_runner" {
  name          = "${var.project}-${var.codebuild_project_name}"
  description   = "Runner de IaC: valida la calidad del codigo Terraform y genera el plan. Lab43."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type           = "S3"
    location       = aws_s3_bucket.pipeline.bucket
    path           = "artifacts"
    name           = "plan"
    namespace_type = "BUILD_ID"
    packaging      = "ZIP"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "${aws_ecr_repository.iac_runner.repository_url}:latest"
    image_pull_credentials_type = "SERVICE_ROLE"

    # TF_IN_AUTOMATION suprime mensajes interactivos de Terraform
    # (como "Do you want to perform these actions?") que bloquean el pipeline.
    environment_variable {
      name  = "TF_IN_AUTOMATION"
      value = "1"
    }

    # TF_CLI_ARGS_plan aplica flags adicionales a todos los subcomandos 'plan'.
    # -lock=false: no intentar bloquear el estado (no hay backend configurado).
    # -input=false: no solicitar input interactivo.
    environment_variable {
      name  = "TF_CLI_ARGS_plan"
      value = "-lock=false -input=false"
    }

    # CHECKOV_RUNNER_REGISTRY_URL puede usarse para apuntar Checkov a un
    # registro privado de politicas. Vacio = usar las politicas integradas.
    environment_variable {
      name  = "CHECKOV_RUNNER_REGISTRY_URL"
      value = ""
    }
  }

  # El codigo fuente viene de CodeCommit. CodeBuild clona el repo en cada build
  # usando las credenciales del rol de servicio (codecommit:GitPull).
  # El buildspec.yml se lee del propio repositorio — vive junto al codigo.
  source {
    type            = "CODECOMMIT"
    location        = aws_codecommit_repository.terraform_code.clone_url_http
    git_clone_depth = 1
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = "build"
      status      = "ENABLED"
    }

    s3_logs {
      status = "DISABLED"
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "iac-validation-pipeline"
  }
}
