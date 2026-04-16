# ═══════════════════════════════════════════════════════════════════════════════
# CodeBuild — Cuatro proyectos para las acciones del pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# Variables de entorno comunes inyectadas en todos los proyectos:
#   TF_VERSION        Version de Terraform a instalar
#   TFLINT_VERSION    Version de TFLint a instalar
#   CHECKOV_VERSION   Version de Checkov a instalar via pip
#   OPA_VERSION       Version de OPA a descargar (usado por PolicyCheck en Reto 3)
#   TF_STATE_BUCKET   Bucket S3 donde se guarda el estado del target
#   TF_STATE_KEY      Prefijo/clave del estado del target en S3
#
# El buildspec de cada proyecto esta en el repositorio CodeCommit bajo buildspecs/.

locals {
  common_env = [
    {
      name  = "TF_VERSION"
      value = var.terraform_version
      type  = "PLAINTEXT"
    },
    {
      name  = "TFLINT_VERSION"
      value = var.tflint_version
      type  = "PLAINTEXT"
    },
    {
      name  = "CHECKOV_VERSION"
      value = var.checkov_version
      type  = "PLAINTEXT"
    },
    {
      name  = "OPA_VERSION"
      value = var.opa_version
      type  = "PLAINTEXT"
    },
    {
      name  = "TF_STATE_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
      type  = "PLAINTEXT"
    },
    {
      name  = "TF_STATE_KEY"
      value = "${var.project}/pipeline/terraform.tfstate"
      type  = "PLAINTEXT"
    },
  ]
}

# ── 1. ValidateAndLint ────────────────────────────────────────────────────────
#
# Ejecuta en paralelo con SecurityScan (runOrder=1 en el pipeline).
# Verifica formato (terraform fmt -check), sintaxis (terraform validate)
# y linting de buenas practicas AWS con TFLint.
# El buildspec descarga Terraform y TFLint en la fase install.

resource "aws_codebuild_project" "validate" {
  name          = "${var.project}-validate"
  description   = "Verifica formato, sintaxis y linting del codigo Terraform."
  service_role  = aws_iam_role.codebuild_validate.arn
  build_timeout = 10

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/validate.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.validate.name
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── 2. SecurityScan ───────────────────────────────────────────────────────────
#
# Ejecuta en paralelo con ValidateAndLint (runOrder=1).
# Analiza el codigo Terraform con Checkov en busca de configuraciones inseguras
# (buckets publicos, grupos de seguridad abiertos, cifrado desactivado...).
# Usa el patron Collect-and-Fail: siempre genera el informe JUnit y lo publica
# en CodeBuild Reports, fallando al final si encuentra hallazgos bloqueantes.

resource "aws_codebuild_project" "security_scan" {
  name          = "${var.project}-security-scan"
  description   = "Analisis de seguridad estatico con Checkov sobre el codigo Terraform."
  service_role  = aws_iam_role.codebuild_validate.arn
  build_timeout = 10

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/security_scan.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.security_scan.name
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── 3. Plan ───────────────────────────────────────────────────────────────────
#
# Ejecuta tras superar ValidateAndLint y SecurityScan (runOrder=2).
# Genera tres ficheros del plan y los empaqueta como artefacto de salida:
#   tfplan.bin   Plan binario para terraform apply (el contrato inmutable)
#   tfplan.json  Plan en JSON para procesamiento programatico (Lambda inspector)
#   tfplan.txt   Plan en texto plano para revision humana (en el email de aprobacion)
#
# -detailed-exitcode: exit 0 = sin cambios, exit 2 = hay cambios (normal),
#   exit 1 = error. El buildspec trata exit 2 como exito.

resource "aws_codebuild_project" "plan" {
  name          = "${var.project}-plan"
  description   = "Genera el plan de Terraform y lo exporta como artefacto inmutable."
  service_role  = aws_iam_role.codebuild_plan.arn
  build_timeout = 20

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/plan.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.plan.name
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── 4. Apply ──────────────────────────────────────────────────────────────────
#
# Recibe dos artefactos:
#   plan_output    Contiene tfplan.bin, tfplan.json, tfplan.txt
#   source_output  Contiene el codigo Terraform (necesario para terraform init)
#
# PrimarySource = "source_output": los ficheros de source_output se extraen en
# el directorio de trabajo raiz; plan_output se extrae en un subdirectorio
# con su nombre. El buildspec referencia tfplan.bin via la ruta correcta.
#
# CRITICO: terraform apply recibe tfplan.bin directamente. No llama a
# terraform plan. Lo que el aprobador vio y autorizo es exactamente lo que
# se aplica — no puede haber desviacion.

resource "aws_codebuild_project" "apply" {
  name          = "${var.project}-apply"
  description   = "Aplica el plan aprobado. No re-planifica bajo ningun concepto."
  service_role  = aws_iam_role.codebuild_apply.arn
  build_timeout = 30

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/apply.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.apply.name
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── 5. SmokeTest ──────────────────────────────────────────────────────────────
#
# Ejecuta tras Apply (runOrder=2 en el stage Deploy).
# Lee los outputs del estado de Terraform y verifica que los recursos
# desplegados tienen la configuracion esperada mediante llamadas a la API de AWS:
#   - Bucket S3: existe, versionado habilitado, cifrado habilitado
#   - Parametro SSM: existe con el valor esperado
#   - Log group: existe con el periodo de retencion correcto

resource "aws_codebuild_project" "smoketest" {
  name          = "${var.project}-smoketest"
  description   = "Smoke tests post-despliegue: verifica estado real de los recursos via API."
  service_role  = aws_iam_role.codebuild_smoketest.arn
  build_timeout = 10

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/smoketest.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.smoketest.name
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
