# Sección 5 — GitOps con Terraform en AWS

> [← Volver al índice](./README.md)

---

## 1. GitOps: Git como Fuente de Verdad de la Infraestructura

GitOps es el modelo operativo donde Git es la única fuente de verdad para el estado deseado de la infraestructura. Todo cambio pasa por un Pull Request, es revisado, aprobado, y el pipeline lo aplica automáticamente. La infraestructura nunca se toca directamente — solo a través del repositorio.

> **El profesor explica:** "GitOps no es una herramienta — es una cultura y un proceso. La pregunta que define si un equipo hace GitOps real es: ¿puede alguien con acceso a AWS hacer un cambio que no está en Git? Si la respuesta es sí, no hay GitOps. El objetivo es que la respuesta sea no — y que el mecanismo técnico (RBAC + pipeline) lo enforce, no la confianza en las personas."

**Los cuatro principios de GitOps:**

| Principio | Descripción | Herramienta en AWS |
|-----------|-------------|-------------------|
| **Declarativo** | El estado deseado se describe, no se prescribe | Terraform (HCL) |
| **Versionado e inmutable** | Todo cambio tiene historial en Git | CodeCommit |
| **Pull automático** | El sistema aplica el estado deseado | CodePipeline + CodeBuild |
| **Reconciliación continua** | Detecta y corrige desviaciones | `terraform plan -refresh-only` |

---

## 2. La Arquitectura GitOps Completa en AWS

```
┌─────────────────────────────────────────────────────────────────────┐
│                     FLUJO GITOPS COMPLETO                           │
│                                                                     │
│  Dev laptop          CodeCommit           CodePipeline              │
│  ──────────          ──────────           ──────────────            │
│  git commit ──push──▶ main branch ──EB──▶ Source Stage             │
│  (con pre-commit                           │                        │
│   hooks locales)                           ▼                       │
│                                         Build Stage                 │
│                                         (CodeBuild)                 │
│                                         terraform fmt -check        │
│                                         tflint + checkov            │
│                                         terraform plan -out=tfplan  │
│                                           │                         │
│                                           ▼                         │
│                                         Approval Gate               │
│  📧 SNS email ◀─────────────────────────│ (tfplan review)          │
│  💬 Slack alert                          │                          │
│                                      ✓ Approve                      │
│                                           │                         │
│                                           ▼                         │
│                                         Deploy Stage                │
│                                         (CodeBuild)                 │
│                                         terraform apply tfplan      │
│                                           │                         │
│                                           ▼                         │
│                                         AWS Cloud ✓                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. El Contrato de Calidad: Pre-commit hasta Pipeline

GitOps de calidad tiene múltiples capas de validación. Cada capa detecta una categoría diferente de problemas:

```
Developer (local)               Pipeline (CI/CD)
─────────────────               ─────────────────
terraform fmt         ──────►  terraform fmt -check  (falla si no formateado)
terraform validate    ──────►  terraform validate    (falla si sintaxis rota)
tflint               ──────►  tflint --format=junit  (falla en errores lógicos)
trivy / checkov      ──────►  checkov --framework tf  (falla en misconfigs)
                               terraform plan -out    (genera artefacto)
                               Manual Approval        (revisor humano)
                               terraform apply tfplan (inmutable)
```

**Stack de herramientas por categoría:**

| Categoría | Local | CI/CD | Qué detecta |
|-----------|-------|-------|-------------|
| Formato | `terraform fmt` | `terraform fmt -check` | Estilo HCL, indentación |
| Sintaxis | `terraform validate` | `terraform validate` | Tipos, referencias rotas |
| Linting | `tflint` | `tflint` | Instance types inválidos, deprecated attrs |
| Seguridad | `trivy` | `checkov` | S3 público, SG `0.0.0.0/0`, IMDSv1 |
| Compliance | `checkov` | `checkov` | CIS Benchmark, SOC2, HIPAA |
| Cambios | `terraform plan` | `terraform plan -out` | Qué va a cambiar en la infra |

---

## 4. Estructura del Repositorio Monorepo GitOps

```
terraform-iac/                    ← repositorio en CodeCommit
├── .pre-commit-config.yaml       ← hooks locales
├── .gitignore                    ← excluir .terraform/, *.tfstate, *.tfvars
├── buildspec-plan.yml            ← fases de validación + plan
├── buildspec-apply.yml           ← fase de apply
│
├── modules/                      ← módulos reutilizables (o en CodeArtifact)
│   ├── vpc/
│   ├── rds/
│   └── ecs-service/
│
├── environments/                 ← configuración por entorno
│   ├── dev/
│   │   ├── main.tf               ← invoca módulos con vars de dev
│   │   ├── backend.hcl           ← S3 key: dev/terraform.tfstate
│   │   └── dev.tfvars            ← variables no sensibles de dev
│   ├── staging/
│   │   └── ...
│   └── prod/
│       ├── main.tf
│       ├── backend.hcl
│       └── prod.tfvars
│
└── pipeline/                     ← la infraestructura del propio pipeline
    ├── main.tf                   ← aws_codepipeline, CodeBuild, etc.
    └── backend.hcl
```

---

## 5. Gestión de Secretos en GitOps

En GitOps, los secretos NUNCA van al repositorio. El pipeline los inyecta en tiempo de ejecución desde AWS Secrets Manager o SSM Parameter Store.

```hcl
# Variables de entorno en CodeBuild desde Secrets Manager
resource "aws_codebuild_project" "apply" {
  environment {
    environment_variable {
      name  = "TF_VAR_db_password"
      value = "prod/rds/master-password"   # ARN del secreto en SM
      type  = "SECRETS_MANAGER"
    }
    environment_variable {
      name  = "TF_VAR_api_key"
      value = "/prod/external-api/key"     # Ruta en SSM Parameter Store
      type  = "PARAMETER_STORE"
    }
  }
}
```

```hcl
# En Terraform: leer secretos desde SSM en tiempo de apply
data "aws_ssm_parameter" "db_password" {
  name            = "/prod/rds/master-password"
  with_decryption = true
}

resource "aws_db_instance" "prod" {
  password = data.aws_ssm_parameter.db_password.value
}
```

**Jerarquía de secretos:**

| Tipo | Almacén | Cuándo usar |
|------|---------|-------------|
| Credenciales DB | Secrets Manager | Rotación automática disponible |
| Configuración sensible | SSM Parameter Store (SecureString) | Sin rotación, referenciable en múltiples servicios |
| Claves de cifrado | KMS | Nunca exponer el material de clave |
| Variables de entorno | CodeBuild env vars (SECRETS_MANAGER) | Inyección en tiempo de build |

---

## 6. Drift Detection como Práctica GitOps

En GitOps, el drift es una violación del principio de que Git es la fuente de verdad. La detección debe ser continua y automatizada.

```yaml
# GitHub Actions / CodePipeline cron: drift detection diario
name: Drift Detection

on:
  schedule:
    - cron: '0 8 * * 1-5'   # Lun-Vie 8AM UTC

jobs:
  detect-drift:
    runs-on: ubuntu-latest
    steps:
      - name: Terraform Init
        run: terraform init -backend-config=prod/backend.hcl

      - name: Detect Drift
        id: drift
        run: |
          terraform plan -detailed-exitcode -refresh-only
          echo "exitcode=$?" >> $GITHUB_OUTPUT
        continue-on-error: true

      - name: Notify if Drift
        if: steps.drift.outputs.exitcode == '2'
        run: |
          aws sns publish \
            --topic-arn $SNS_TOPIC \
            --message "⚠️ DRIFT DETECTADO en producción. Revisar cambios manuales."
```

**Política de respuesta al drift:**

```
Drift detectado
      │
      ├─ ¿Fue un cambio de emergencia intencional?
      │   → Sí: actualizar el código Terraform, crear PR, aplicar
      │   → No: ejecutar terraform apply para revertir al estado declarado
      │
      └─ ¿Fue un cambio accidental?
          → Revertir: terraform apply
          → Investigar: CloudTrail → quién, cuándo, qué
          → Prevenir: RBAC más estricto, SCP
```

---

## 7. Gobernanza: RBAC + SCP para Prevenir Bypass del Pipeline

Un pipeline GitOps es débil si los ingenieros pueden hacer cambios directamente en la consola. RBAC estricto + Service Control Policies cierran ese agujero.

```hcl
# SCP: prohibir creación de recursos sin tag ManagedBy=Terraform
resource "aws_organizations_policy" "require_terraform_tag" {
  name = "RequireTerraformTag"
  type = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Statement = [{
      Effect    = "Deny"
      Action    = [
        "ec2:RunInstances",
        "rds:CreateDBInstance",
        "s3:CreateBucket",
      ]
      Resource  = "*"
      Condition = {
        "StringNotEquals" = {
          "aws:RequestTag/ManagedBy" = "Terraform"
        }
      }
    }]
  })
}
```

```hcl
# IAM: rol de developer sin permisos de escritura directa en infra crítica
resource "aws_iam_policy" "developer_readonly" {
  name = "DeveloperReadOnly"

  policy = jsonencode({
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "rds:Describe*", "s3:List*", "s3:Get*"]
        Resource = "*"
      },
      {
        Effect   = "Deny"
        Action   = ["ec2:RunInstances", "rds:CreateDBInstance", "iam:Create*"]
        Resource = "*"
      },
    ]
  })
}
```

---

## 8. Pipeline Self-Service para Equipos

En organizaciones grandes, cada equipo necesita su propio pipeline sin conocer todos los detalles de la infraestructura. El patrón de "plataforma de IaC" provee pipelines estandarizados como servicio.

```hcl
# Módulo: pipeline estándar que los equipos invocan
module "team_pipeline" {
  source = "./modules/iac-pipeline"

  project_name  = "payments-service"
  team          = "payments"
  repo_name     = "payments-iac"
  environments  = ["dev", "staging", "prod"]
  approver_email = "payments-lead@acme.com"

  # El módulo crea:
  # - CodeCommit repo
  # - CodePipeline (Source → Plan → Approval → Deploy)
  # - CodeBuild projects (plan + apply)
  # - IAM roles mínimos
  # - S3 state bucket
  # - SNS notifications
}
```

---

## 9. Métricas de Madurez GitOps

| Nivel | Característica | Indicadores |
|-------|---------------|-------------|
| **L0** | Sin GitOps | Cambios manuales en consola, sin auditoría |
| **L1** | IaC básico | Terraform existe pero sin pipeline CI/CD |
| **L2** | CI/CD manual | Pipeline existe pero requiere intervención manual en cada etapa |
| **L3** | GitOps básico | Todo cambio pasa por PR + pipeline automático |
| **L4** | GitOps avanzado | Drift detection automático + RBAC enforcement + multi-cuenta |
| **L5** | Platform Engineering | Pipeline como servicio, self-service para equipos, Policy-as-Code |

**Roadmap para llegar a L4:**
1. `terraform init` en CI (L1 → L2): CodeBuild básico.
2. `terraform plan` en PR (L2 → L3): pipeline de plan automático.
3. `terraform apply` automatizado con approval gate (L3).
4. Drift detection diario (L3 → L4).
5. RBAC + SCP para prevenir cambios manuales (L4).

---

## 10. Resumen: El Flujo GitOps Completo con AWS Developer Tools

```
Developer
   │
   ├─ git commit (con pre-commit: fmt, validate, tflint, checkov)
   │
   └─ git push → CodeCommit
                     │
                     ├─ EventBridge detecta push a main
                     │
                     └─ CodePipeline se activa
                           │
                           ├─ [Source] Checkout del código
                           │
                           ├─ [Build] CodeBuild Plan:
                           │   terraform fmt -check
                           │   terraform init
                           │   terraform validate
                           │   tflint + checkov
                           │   terraform plan -out=tfplan
                           │   → artefacto: tfplan
                           │
                           ├─ [Approval] SNS → email/Slack
                           │   Revisor inspecciona plan.json
                           │   ✓ Approve / ✗ Reject
                           │
                           └─ [Deploy] CodeBuild Apply:
                               terraform apply tfplan (inmutable)
                               terraform output -json
                               SNS: "✅ Infraestructura aplicada"

Paralelo (cron diario):
   CodePipeline → CodeBuild:
   terraform plan -refresh-only -detailed-exitcode
   Exit 2 → SNS alert: "⚠️ Drift detectado"
```

**El resultado:** Cada cambio de infraestructura es revisado, aprobado, registrado en CloudTrail y auditable. Nadie puede hacer cambios que no estén en Git. El equipo duerme tranquilo porque sabe que el estado en Git es exactamente lo que hay en AWS.

---

> [← Volver al índice](./README.md)
