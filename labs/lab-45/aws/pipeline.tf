# ═══════════════════════════════════════════════════════════════════════════════
# SNS — Topic de aprobaciones manuales
# ═══════════════════════════════════════════════════════════════════════════════
#
# CodePipeline publica en este topic cuando la etapa de Approval requiere
# intervencion humana. La suscripcion de email debe confirmarse manualmente
# antes de que el primer ciclo del pipeline alcance esa etapa.

resource "aws_sns_topic" "approvals" {
  name = "${var.project}-approvals"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pipeline-manual-approval"
  }
}

resource "aws_sns_topic_subscription" "approvals_email" {
  topic_arn = aws_sns_topic.approvals.arn
  protocol  = "email"
  endpoint  = var.approval_email
}

# ═══════════════════════════════════════════════════════════════════════════════
# CodePipeline — Pipeline de cuatro etapas con plan inmutable
# ═══════════════════════════════════════════════════════════════════════════════
#
# Flujo completo:
#
#   Source  →  Build (parallel validate+scan → plan → lambda inspect)
#           →  Approval (manual, email SNS)
#           →  Deploy (apply con tfplan.bin inmutable → smoke tests)
#
# Principio clave — contrato inmutable:
#   tfplan.bin se genera UNA sola vez en la etapa Build y se almacena como
#   artefacto cifrado. La etapa Deploy recibe exactamente ese artefacto y
#   ejecuta "terraform apply tfplan.bin" sin re-planificar. Lo que el
#   aprobador autorizo es exactamente lo que se aplica.

resource "aws_codepipeline" "main" {
  name     = "${var.project}-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.artifacts.arn
      type = "KMS"
    }
  }

  # ── Etapa 1: Source ──────────────────────────────────────────────────────────
  # Captura el estado del repositorio en el momento del push. Este snapshot
  # es el unico input del resto del pipeline: todos los stages trabajan sobre
  # el mismo codigo, garantizando coherencia entre validacion y despliegue.

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]
      run_order        = 1

      configuration = {
        RepositoryName       = aws_codecommit_repository.terraform.repository_name
        BranchName           = var.branch
        OutputArtifactFormat = "CODE_ZIP"
        PollForSourceChanges = "false" # EventBridge gestiona el trigger
      }
    }
  }

  # ── Etapa 2: Build ───────────────────────────────────────────────────────────
  # Cuatro acciones en tres oleadas de ejecucion:
  #
  #   runOrder 1 (paralelas):
  #     ValidateAndLint  — formato, sintaxis, linting TFLint
  #     SecurityScan     — analisis estatico con Checkov
  #
  #   runOrder 2 (tras superar ambas del runOrder 1):
  #     Plan             — terraform plan → tfplan.bin + tfplan.json + tfplan.txt
  #
  #   runOrder 3 (tras Plan):
  #     InspectPlan      — Lambda que parsea tfplan.json y bloquea si se
  #                        supera el umbral de recursos destruidos

  stage {
    name = "Build"

    action {
      name            = "ValidateAndLint"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      run_order       = 1

      configuration = {
        ProjectName = aws_codebuild_project.validate.name
      }
    }

    action {
      name            = "SecurityScan"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      run_order       = 1

      configuration = {
        ProjectName = aws_codebuild_project.security_scan.name
      }
    }

    action {
      name             = "Plan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]
      run_order        = 2

      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }

    action {
      name            = "InspectPlan"
      category        = "Invoke"
      owner           = "AWS"
      provider        = "Lambda"
      version         = "1"
      input_artifacts = ["plan_output"]
      run_order       = 3

      configuration = {
        FunctionName = aws_lambda_function.plan_inspector.function_name
      }
    }
  }

  # ── Etapa 3: Approval ────────────────────────────────────────────────────────
  # Compuerta de aprobacion manual. CodePipeline envia una notificacion SNS
  # con un enlace directo a la consola del pipeline donde el aprobador puede:
  #   - Ver el historial de la ejecucion en curso
  #   - Navegar al bucket S3 para descargar tfplan.txt y revisar los cambios
  #   - Aprobar o rechazar con un comentario opcional
  #
  # El pipeline queda suspendido hasta que se apruebe, se rechace o expire
  # el timeout de aprobacion (por defecto 7 dias en CodePipeline).

  stage {
    name = "Approval"

    action {
      name      = "ManualApproval"
      category  = "Approval"
      owner     = "AWS"
      provider  = "Manual"
      version   = "1"
      run_order = 1

      configuration = {
        NotificationArn    = aws_sns_topic.approvals.arn
        CustomData         = "Revisa el plan de Terraform antes de aprobar. Descarga tfplan.txt del bucket de artefactos para ver los cambios detallados."
        ExternalEntityLink = "https://s3.console.aws.amazon.com/s3/object/${aws_s3_bucket.artifacts.bucket}?prefix=plans/latest/tfplan.txt"
      }
    }
  }

  # ── Etapa 4: Deploy ──────────────────────────────────────────────────────────
  # Dos acciones secuenciales:
  #
  #   runOrder 1: Apply
  #     Recibe plan_output (tfplan.bin aprobado). Ejecuta terraform apply
  #     con ese artefacto exacto. No re-planifica bajo ningun concepto.
  #
  #   runOrder 2: SmokeTest
  #     Verifica que los recursos creados son accesibles y tienen la
  #     configuracion esperada (cifrado, versionado, etc.).

  stage {
    name = "Deploy"

    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan_output", "source_output"]
      run_order       = 1

      configuration = {
        ProjectName          = aws_codebuild_project.apply.name
        PrimarySource        = "source_output"
      }
    }

    action {
      name            = "SmokeTest"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      run_order       = 2

      configuration = {
        ProjectName = aws_codebuild_project.smoketest.name
      }
    }
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
