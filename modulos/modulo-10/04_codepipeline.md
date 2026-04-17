# Sección 4 — AWS CodePipeline: El Orquestador CI/CD

> [← Volver al índice](./README.md) | [Siguiente →](./05_gitops.md)

---

## 1. CodePipeline: El Pegamento del CD

CodePipeline es el orquestador de entrega continua de AWS. Conecta Source (CodeCommit), Build (CodeBuild), Approval (Manual) y Deploy (CodeBuild Apply) en un flujo repetible, auditable y completamente gestionado como código.

> **En la práctica:** "El principio más importante del pipeline de Terraform es: el `apply` ejecuta exactamente el mismo plan que fue revisado y aprobado. Nunca re-planifica. El archivo `tfplan` es el contrato. Si entre el plan y el apply alguien cambió algo en la nube manualmente, el plan aprobado es el que manda — no un plan nuevo. Esto es lo que da confianza al equipo: lo que apruebas es lo que se despliega."

**El flujo inmutable:**

```
Commit en main
      ↓
Source Stage (CodeCommit)
      ↓
Build Stage (CodeBuild: terraform plan -out=tfplan)
      ↓         → artefacto: tfplan (binario inmutable)
Approval Stage (Manual + SNS email/Slack)
      ↓         → revisor: ¿aceptar o rechazar?
Deploy Stage (CodeBuild: terraform apply tfplan)
      ↓         → lo aprobado = lo que se ejecuta
```

---

## 2. `aws_codepipeline` — Estructura Base

```hcl
resource "aws_codepipeline" "terraform" {
  name     = "${var.project}-iac-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  # Bucket S3 cifrado para artefactos entre stages
  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_kms_key.pipeline.arn
      type = "KMS"   # Cifrado KMS: el rol del pipeline necesita kms:Decrypt
    }
  }

  # Los stages se definen a continuación...
  stage { name = "Source"   action { ... } }
  stage { name = "Build"    action { ... } }
  stage { name = "Approval" action { ... } }
  stage { name = "Deploy"   action { ... } }
}
```

---

## 3. Stage Source — Detectando el Cambio

```hcl
stage {
  name = "Source"

  action {
    name             = "SourceCode"
    category         = "Source"
    owner            = "AWS"
    provider         = "CodeCommit"
    version          = "1"
    output_artifacts = ["SourceOutput"]

    configuration = {
      RepositoryName       = aws_codecommit_repository.iac_repo.repository_name
      BranchName           = "main"
      PollForSourceChanges = false   # EventBridge detecta el push (no polling)
    }
  }
}
```

**EventBridge como trigger (más eficiente que polling):**

```hcl
resource "aws_cloudwatch_event_rule" "pipeline_trigger" {
  name        = "${var.project}-pipeline-trigger"
  description = "Dispara pipeline en push a main"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    detail = {
      event         = ["referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
      repositoryName = [aws_codecommit_repository.iac_repo.repository_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule     = aws_cloudwatch_event_rule.pipeline_trigger.name
  arn      = aws_codepipeline.terraform.arn
  role_arn = aws_iam_role.eventbridge_pipeline.arn
}
```

---

## 4. Stage Build — Generando el Plan Inmutable

```hcl
stage {
  name = "Build"

  action {
    name             = "TerraformPlan"
    category         = "Build"
    owner            = "AWS"
    provider         = "CodeBuild"
    version          = "1"
    input_artifacts  = ["SourceOutput"]
    output_artifacts = ["PlanOutput"]   # tfplan + plan.json

    configuration = {
      ProjectName = aws_codebuild_project.terraform_plan.name
    }
  }
}
```

**Por qué `-out=tfplan` es crítico:**
- El artefacto binario contiene exactamente qué recursos se crearán/modificarán/destruirán.
- No se puede alterar sin invalidar el hash.
- La etapa Deploy lo usa sin re-planificar: `terraform apply tfplan`.
- Lo que el revisor aprueba es exactamente lo que se ejecuta.

---

## 5. Backend S3 con Locking Nativo (TF 1.10+)

```hcl
# Ya no se necesita DynamoDB para el locking del state
terraform {
  backend "s3" {
    bucket       = "${var.project}-tf-state"
    key          = "${var.env}/terraform.tfstate"
    region       = var.region
    encrypt      = true
    use_lockfile = true    # Locking nativo S3 (desde Terraform 1.10)
    kms_key_id   = aws_kms_key.state.arn
  }
}

# Sin aws_dynamodb_table para locks — S3 gestiona el .tflock junto al .tfstate

# Migración desde DynamoDB (si vienes de versión anterior):
# 1. Actualizar Terraform CLI a >= 1.10
# 2. Agregar use_lockfile = true al backend
# 3. Eliminar dynamodb_table del bloque backend
# 4. terraform init -migrate-state
# 5. Eliminar el recurso aws_dynamodb_table del código
```

**Bucket S3 para el state:**

```hcl
resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project}-tf-state-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

## 6. Manual Approval Gate — La Compuerta Humana

```hcl
# SNS Topic para notificar al equipo con el plan a revisar
resource "aws_sns_topic" "approval" {
  name = "${var.project}-pipeline-approval"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.approval.arn
  protocol  = "email"
  endpoint  = var.approver_email
}

# Stage de Approval en el pipeline
stage {
  name = "Approval"

  action {
    name     = "ManualApproval"
    category = "Approval"
    owner    = "AWS"
    provider = "Manual"
    version  = "1"

    configuration = {
      NotificationArn    = aws_sns_topic.approval.arn
      CustomData         = "Revisar el plan de Terraform en CodeBuild antes de aprobar."
      ExternalEntityLink = "https://console.aws.amazon.com/codesuite/codepipeline/pipelines/${var.project}"
    }
  }
}
```

**Flujo de aprobación:**
1. CodeBuild completa el plan → artefacto `tfplan` en S3.
2. SNS notifica al equipo (email / Slack via Chatbot).
3. Revisor accede a los logs de CodeBuild para ver los cambios propuestos.
4. Aprueba → el pipeline continúa al stage Deploy con el artefacto exacto.
5. Rechaza → pipeline detenido, motivo registrado en CloudTrail.

---

## 7. Stage Deploy — Aplicando con el Plan Aprobado

```hcl
stage {
  name = "Deploy"

  action {
    name            = "TerraformApply"
    category        = "Build"
    owner           = "AWS"
    provider        = "CodeBuild"
    version         = "1"
    input_artifacts = ["PlanOutput"]   # El mismo tfplan del stage Build

    configuration = {
      ProjectName = aws_codebuild_project.terraform_apply.name
    }
  }
}
```

```yaml
# buildspec-apply.yml
version: 0.2

phases:
  pre_build:
    commands:
      # Verificar que el artefacto llegó intacto
      - ls -la tfplan
      - terraform init -backend-config=backend.hcl

  build:
    commands:
      # apply con el plan exacto — sin re-planificar, sin -auto-approve extra
      - terraform apply tfplan
      - terraform output -json > outputs.json

  post_build:
    commands:
      - aws s3 cp outputs.json s3://${ARTIFACT_BUCKET}/${CODEBUILD_BUILD_ID}/
      - |
        if [ "${CODEBUILD_BUILD_SUCCEEDING}" = "1" ]; then
          aws sns publish --topic-arn ${SNS_TOPIC} \
            --message "✅ Infraestructura desplegada exitosamente"
        fi
      - rm -f ~/.netrc
```

---

## 8. Pipeline IAM Role — Permisos Mínimos del Orquestador

```hcl
resource "aws_iam_role" "pipeline" {
  name = "${var.project}-pipeline-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  role = aws_iam_role.pipeline.name

  policy = jsonencode({
    Statement = [
      # S3: artefactos
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = ["${aws_s3_bucket.artifacts.arn}", "${aws_s3_bucket.artifacts.arn}/*"]
      },
      # KMS: cifrado de artefactos
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.pipeline.arn
      },
      # CodeCommit: leer el repositorio
      {
        Effect   = "Allow"
        Action   = ["codecommit:GetBranch", "codecommit:GetCommit", "codecommit:UploadArchive"]
        Resource = aws_codecommit_repository.iac_repo.arn
      },
      # CodeBuild: disparar builds
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = [aws_codebuild_project.terraform_plan.arn, aws_codebuild_project.terraform_apply.arn]
      },
      # SNS: notificaciones de approval
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.approval.arn
      },
    ]
  })
}
```

---

## 9. Multi-Environment: Dev → Staging → Prod

```hcl
# Pipeline con múltiples etapas de despliegue y approval gates
resource "aws_codepipeline" "full" {
  name     = "${var.project}-multi-env"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store { ... }

  # Source
  stage { name = "Source" action { ... } }

  # Build: plan para DEV
  stage {
    name = "PlanDev"
    action {
      name = "TerraformPlanDev"
      # buildspec usa: TF_WORKSPACE=dev, -var-file=dev.tfvars
    }
  }

  # Deploy automático a DEV (sin approval)
  stage {
    name = "DeployDev"
    action {
      name = "TerraformApplyDev"
      # buildspec: terraform apply tfplan-dev
    }
  }

  # Approval para STAGING
  stage {
    name = "ApprovalStaging"
    action {
      name     = "ApproveStaging"
      category = "Approval"
      provider = "Manual"
      configuration = {
        NotificationArn = aws_sns_topic.approval.arn
        CustomData      = "Aprobar despliegue en Staging"
      }
    }
  }

  # Deploy a STAGING
  stage { name = "DeployStaging" action { ... } }

  # Approval manual obligatorio para PROD (Tech Lead)
  stage {
    name = "ApprovalProd"
    action {
      name     = "ApproveProd"
      category = "Approval"
      provider = "Manual"
    }
  }

  # Deploy a PROD
  stage { name = "DeployProd" action { ... } }
}
```

---

## 10. Cross-Account: Despliegue Multi-Cuenta

```hcl
# En la cuenta DESTINO (Prod/Staging)
resource "aws_iam_role" "cross_account" {
  name = "terraform-deploy-from-tooling"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.tooling_account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# En el provider de Terraform (cuenta Tooling asume role en Prod)
provider "aws" {
  alias  = "prod"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.prod_account_id}:role/terraform-deploy-from-tooling"
  }
}
```

**Arquitectura multi-cuenta:**

```
┌─────────────────────────────────────────────────────────┐
│  Cuenta Tooling (Central)                               │
│  • CodePipeline + CodeBuild + CodeCommit                │
│  • Bucket S3: artefactos cifrados                       │
│  • KMS key compartida cross-account                     │
└──────────────────┬──────────────────────────────────────┘
                   │ sts:AssumeRole
       ┌───────────┼───────────────┐
       ▼           ▼               ▼
  Dev Account  Staging Account  Prod Account
  (Trust:      (Trust:          (Trust: solo tooling
   tooling)     tooling)         + manual approval)
```

---

## 11. Self-Mutating Pipeline

El pipeline de Terraform puede actualizarse a sí mismo. Cuando el código del propio `aws_codepipeline` cambia en el repositorio, el primer stage detecta el cambio y re-aplica la infraestructura del pipeline.

```hcl
# Stage 0: actualizar el propio pipeline antes de continuar
stage {
  name = "UpdatePipeline"

  action {
    name     = "SelfUpdate"
    category = "Build"
    provider = "CodeBuild"
    configuration = {
      ProjectName = aws_codebuild_project.self_update.name
      # buildspec: terraform apply -target=aws_codepipeline.main
    }
  }
}
```

**Flujo:** Primer deploy manual (bootstrap) → Después: cada commit actualiza tanto la infraestructura como el pipeline.

---

## 12. Estrategias de Rollback

Terraform no tiene `rollback` nativo. El pipeline proporciona tres mecanismos:

| Estrategia | Cómo | Cuándo |
|-----------|------|--------|
| **Git Revert** | `git revert HEAD && git push` → dispara nuevo pipeline con config anterior | Rollback de código Terraform |
| **Pipeline Re-execution** | Repetir ejecución exitosa anterior desde la consola | Rollback rápido usando artefacto anterior |
| **State Backup** | S3 versionado → restaurar `.tfstate` anterior + `terraform import` | Último recurso en corrupción de state |

```bash
# Git Revert: el más seguro
git revert HEAD
git push origin main
# → Pipeline se activa automáticamente con la configuración anterior
```

---

## 13. Notificaciones: AWS Chatbot + Slack

```hcl
# EventBridge captura estado del pipeline
resource "aws_cloudwatch_event_rule" "pipeline_state" {
  name = "${var.project}-pipeline-state"
  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    "detail-type" = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      state    = ["FAILED", "SUCCEEDED", "STOPPED"]
      pipeline = [aws_codepipeline.terraform.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "notify_sns" {
  rule = aws_cloudwatch_event_rule.pipeline_state.name
  arn  = aws_sns_topic.pipeline_alerts.arn
}

# AWS Chatbot: conecta SNS con Slack
resource "aws_chatbot_slack_channel_configuration" "pipeline" {
  configuration_name = "${var.project}-pipeline-alerts"
  iam_role_arn       = aws_iam_role.chatbot.arn
  slack_workspace_id = var.slack_workspace_id
  slack_channel_id   = var.slack_channel_id

  sns_topic_arns = [aws_sns_topic.pipeline_alerts.arn]
}
```

---

## 14. Best Practices del Pipeline de Terraform

| Categoría | Práctica |
|-----------|----------|
| **Inmutabilidad** | Nunca re-planificar en Deploy — usar el artefacto de Build |
| **Seguridad** | KMS para artefactos y state; IAM mínimo por stage |
| **Velocidad** | Provider cache en S3; imagen Docker custom; jobs paralelos |
| **Trazabilidad** | CloudTrail para aprobaciones; CloudWatch para duración |
| **Rollback** | Git revert como mecanismo principal; S3 versionado como respaldo |
| **Multi-env** | Un workspace/state por entorno; approval gates entre envs |
| **Observabilidad** | Dashboard con tasa de éxito, duración promedio, fallos |

---

> [← Volver al índice](./README.md) | [Siguiente →](./05_gitops.md)
