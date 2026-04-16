# Sección 2 — AWS CodeBuild: Motor de Ejecución de Terraform

> [← Volver al índice](./README.md) | [Siguiente →](./03_codedeploy.md)

---

## 1. CodeBuild: El Entorno Efímero y Aislado

CodeBuild ejecuta comandos en contenedores aislados que se destruyen tras cada build. No hay estado residual entre ejecuciones, no hay servidores que mantener, no hay drift de configuración. Cada `terraform plan` o `terraform apply` corre en un entorno perfectamente limpio con permisos IAM explícitos.

> **El profesor explica:** "CodeBuild resuelve el problema más común del CI/CD de infraestructura: '¿En qué máquina corre Terraform?' Con un servidor de CI tradicional, el estado local del servidor puede contaminar las ejecuciones — versiones de Terraform distintas, caché de providers corrupta, credenciales de sesiones anteriores. Con CodeBuild, cada build es una pizarra en blanco. Si algo falla, el entorno desaparece. No hay 'funciona en mi máquina de CI'."

**Ventajas del modelo efímero:**
- Sin estado residual entre ejecuciones.
- Entorno limpio garantizado en cada build.
- Pago por minuto de build — cero costo en idle.
- ARM y x86 disponibles.

---

## 2. Imagen Docker Personalizada vs. Estándar

```
Imagen Estándar AWS (aws/codebuild/standard:7.0)     Imagen Personalizada (ECR)
────────────────────────────────────────────────     ────────────────────────────
✗ Terraform puede no estar incluido                  ✓ TF versión exacta pinneada
✗ Versiones fijadas por AWS, no por ti               ✓ tflint + trivy + checkov
✗ Install phase larga: curl, unzip, pip...           ✓ Install phase: 0 segundos
✗ trivy, tflint, checkov no incluidos                ✓ Escaneada con ECR image scan
✗ No reproducible entre builds                       ✓ 100% reproducible y auditada
```

**Dockerfile multi-stage para runner de Terraform:**

```dockerfile
# Multi-stage: build stage descarga, final stage es slim
FROM amazonlinux:2023 AS builder

ARG TF_VERSION=1.7.5
ARG TFLINT_VERSION=0.50.3
ARG TRIVY_VERSION=0.69.3

RUN yum install -y unzip curl python3-pip && \
    # Terraform
    curl -Lo tf.zip "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" && \
    unzip tf.zip -d /usr/local/bin/ && \
    # TFLint
    curl -Lo tflint.zip "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" && \
    unzip tflint.zip -d /usr/local/bin/ && \
    # Checkov
    pip3 install checkov

# Imagen final minimal
FROM amazonlinux:2023-minimal

COPY --from=builder /usr/local/bin/terraform /usr/local/bin/
COPY --from=builder /usr/local/bin/tflint    /usr/local/bin/
COPY --from=builder /usr/local/lib/python3.11/ /usr/local/lib/

RUN yum install -y aws-cli-2 git jq && yum clean all

ENTRYPOINT ["/bin/bash"]
```

**Herramientas de la imagen:**

| Herramienta | Propósito | Por qué en la imagen |
|-------------|-----------|----------------------|
| Terraform | Motor de IaC | Core del pipeline |
| AWS CLI v2 | Interacción con servicios AWS | CodeArtifact auth, S3, SSM |
| tflint | Linting con reglas por provider | Detecta instance types inválidos |
| trivy / checkov | Escaneo de misconfigurations | CIS Benchmark, SOC2 compliance |
| jq | Parsing de JSON | Procesar outputs de plan |
| git | Control de versiones | Checkout en CodeBuild |

---

## 3. ECR: Alojamiento de la Imagen

```bash
# Pipeline de publicación de la imagen (CI dedicado)
aws ecr get-login-password --region us-east-1 | docker login --username AWS \
  --password-stdin 111111111111.dkr.ecr.us-east-1.amazonaws.com

docker build -t terraform-runner:1.14.8 .
docker tag terraform-runner:1.14.8 \
  111111111111.dkr.ecr.us-east-1.amazonaws.com/terraform-runner:1.14.8

docker push 111111111111.dkr.ecr.us-east-1.amazonaws.com/terraform-runner:1.14.8
```

```hcl
resource "aws_ecr_repository" "runner" {
  name                 = "terraform-runner"
  image_tag_mutability = "IMMUTABLE"   # Tags inmutables: 1.7.5 siempre es la misma imagen

  image_scanning_configuration {
    scan_on_push = true   # ECR escanea vulnerabilidades en cada push
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}
```

---

## 4. El `buildspec.yml` — Anatomía Completa

El `buildspec.yml` es el contrato entre tu código y CodeBuild. Define 4 fases secuenciales:

```
install → pre_build → build → post_build
   ↓           ↓        ↓          ↓
Config      Validate   Plan     Artifacts
.netrc      fmt check  -out     Upload S3
token CA    tflint     apply    Notify SNS
versions    checkov    JSON     Cleanup
```

### Buildspec completo para Terraform Plan

```yaml
version: 0.2

env:
  secrets-manager:
    TF_VAR_db_password: prod/db/password         # Secret desde Secrets Manager
  parameter-store:
    TF_VAR_account_id: /infra/aws/account_id     # Param desde Parameter Store
  variables:
    ENVIRONMENT: "production"                     # PLAINTEXT: no sensible
    DOMAIN: "acme-corp"
    CA_ENDPOINT: "acme-corp-111111111111.d.codeartifact.us-east-1.amazonaws.com"

phases:
  install:
    commands:
      # Token CodeArtifact para descargar módulos privados
      - export CA_TOKEN=$(aws codeartifact get-authorization-token \
          --domain ${DOMAIN} --query authorizationToken --output text)
      - |
        cat > ~/.netrc <<EOF
        machine ${CA_ENDPOINT}
        login aws
        password ${CA_TOKEN}
        EOF
      - chmod 600 ~/.netrc

  pre_build:
    commands:
      - echo "=== Validando formato ==="
      - terraform fmt -check -recursive      # Falla si el código no está formateado
      - terraform init -backend-config=backend.hcl
      - terraform validate

      - echo "=== Linting ==="
      - tflint --init                        # Descarga reglas del provider AWS
      - tflint --format=junit > tflint-report.xml

      - echo "=== Security scan ==="
      - checkov -d . --framework terraform \
          --output junitxml sarif \
          --output-file-path checkov-report

  build:
    commands:
      - echo "=== Generando plan ==="
      - terraform plan \
          -out=tfplan \
          -var-file="${ENVIRONMENT}.tfvars" \
          -no-color               # Logs legibles sin escape codes ANSI
      - terraform show -json tfplan > plan.json   # Plan legible para auditoría

  post_build:
    commands:
      - echo "=== Subiendo artefactos ==="
      - aws s3 cp tfplan   s3://${ARTIFACT_BUCKET}/${CODEBUILD_BUILD_ID}/tfplan
      - aws s3 cp plan.json s3://${ARTIFACT_BUCKET}/${CODEBUILD_BUILD_ID}/plan.json

      # Notificar resultado
      - |
        if [ "${CODEBUILD_BUILD_SUCCEEDING}" = "1" ]; then
          aws sns publish --topic-arn ${SNS_TOPIC} \
            --message "✅ Plan exitoso: ${CODEBUILD_BUILD_ID}"
        else
          aws sns publish --topic-arn ${SNS_TOPIC} \
            --message "❌ Plan fallido: ${CODEBUILD_BUILD_ID}"
        fi

      # Limpiar credenciales sensibles
      - rm -f ~/.netrc

artifacts:
  files:
    - tfplan
    - plan.json
    - tflint-report.xml
    - "checkov-report/**"
  discard-paths: no

reports:
  tflint-report:
    files: ["tflint-report.xml"]
    file-format: JUNITXML
  checkov-report:
    files: ["checkov-report/*.xml"]
    file-format: JUNITXML
```

---

## 5. Buildspec para `terraform apply`

```yaml
# buildspec-apply.yml — Stage Deploy del pipeline
version: 0.2

phases:
  pre_build:
    commands:
      - echo "=== Verificando plan ==="
      - ls -la tfplan   # Verificar que el artefacto llegó

  build:
    commands:
      - echo "=== Aplicando infraestructura ==="
      # terraform apply con el plan exacto (NO re-planifica)
      - terraform apply tfplan
      - terraform output -json > outputs.json

  post_build:
    commands:
      - aws s3 cp outputs.json s3://${ARTIFACT_BUCKET}/${CODEBUILD_BUILD_ID}/
      - aws sns publish --topic-arn ${SNS_TOPIC} \
          --message "✅ Apply completado: ${CODEBUILD_BUILD_ID}"
      - rm -f ~/.netrc
```

**Punto crítico:** `terraform apply tfplan` — sin `-auto-approve`, sin re-planificación. El plan fue aprobado; se ejecuta exactamente lo que fue revisado.

---

## 6. Variables de Entorno — Tres Tipos

```hcl
resource "aws_codebuild_project" "terraform" {
  name = "${var.project}-terraform-plan"

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "${aws_ecr_repository.runner.repository_url}:${var.tf_version}"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
      type  = "PLAINTEXT"          # Visible en consola — no usar para secretos
    }

    environment_variable {
      name  = "/infra/aws/account_id"
      value = "/infra/aws/account_id"
      type  = "PARAMETER_STORE"   # Lee de SSM Parameter Store — versionado
    }

    environment_variable {
      name  = "TF_VAR_db_password"
      value = "prod/db/password"
      type  = "SECRETS_MANAGER"   # Rotación automática — para secretos reales
    }
  }
}
```

**Regla:** Nunca hardcodear valores sensibles en el `buildspec.yml`. El buildspec va al repositorio — los secretos no.

---

## 7. IAM Service Role — Privilegio Mínimo

```hcl
resource "aws_iam_role" "codebuild" {
  name = "${var.project}-codebuild-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild.name

  policy = jsonencode({
    Statement = [
      # S3: state + artefactos del pipeline
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      # DynamoDB: locks del state (si no usa S3 native locking)
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tf_locks.arn
      },
      # CloudWatch Logs
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      # CodeArtifact: descargar módulos
      {
        Effect   = "Allow"
        Action   = ["codeartifact:GetAuthorizationToken", "codeartifact:GetPackageVersionAsset"]
        Resource = "*"
      },
      # STS: para CodeArtifact auth
      {
        Effect   = "Allow"
        Action   = "sts:GetServiceBearerToken"
        Resource = "*"
        Condition = {
          StringEquals = { "sts:AWSServiceName" = "codeartifact.amazonaws.com" }
        }
      },
      # Recursos de Terraform (scoped por condición)
      {
        Effect   = "Allow"
        Action   = ["ec2:*", "vpc:*", "rds:*", "s3:*"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.region }
        }
      },
    ]
  })
}
```

**Mejores prácticas IAM:**
- Rol separado para `plan` (solo lectura + state) vs `apply` (escritura de recursos).
- `Permission Boundaries` para prevenir escalada de privilegios.
- SCP a nivel de OU para bloquear acciones prohibidas (ej: `iam:CreateUser`).
- Revisar con IAM Access Analyzer periódicamente.

---

## 8. Caché: De 90 Segundos a <10 Segundos en `init`

```hcl
resource "aws_codebuild_project" "terraform" {
  # ...

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.build_cache.bucket}/terraform"
    # Persiste entre builds: .terraform/providers/ (~200MB comprimido)
  }

  # Cache local combinado (volátil, mismo host)
  secondary_artifacts {}
}
```

```yaml
# buildspec.yml — configuración de caché
cache:
  paths:
    - ".terraform/providers/**/*"   # Providers descargados
    - "/root/.terraform.d/**/*"     # Plugin cache global
```

**Sin caché:** `terraform init` descarga 200MB de providers → 90 segundos.
**Con caché S3:** providers desde caché → <10 segundos.

---

## 9. Compute Types — Elegir el Tamaño Correcto

| Tipo | RAM | vCPUs | Costo Linux/min | Ideal para |
|------|-----|-------|-----------------|-----------|
| `BUILD_GENERAL1_SMALL` | 3 GB | 2 | ~$0.005 | Plan + validate (<500 recursos) |
| `BUILD_GENERAL1_MEDIUM` | 7 GB | 4 | ~$0.010 | Apply + Docker builds (500-2000) |
| `BUILD_GENERAL1_LARGE` | 15 GB | 8 | ~$0.020 | Monorepos masivos, `-parallelism=10+` |
| `BUILD_GENERAL1_2XLARGE` | 145 GB | 72 | ~$0.145 | Builds extremos (raro en IaC) |

**Regla:** `terraform plan` es CPU-light pero I/O-heavy (API calls, descargas). Para la mayoría de proyectos, `SMALL` es suficiente. Solo escalar a `MEDIUM` cuando el plan supera los 5 minutos con caché habilitada.

---

## 10. Observabilidad con CloudWatch

```hcl
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/aws/codebuild/${var.project}-terraform"
  retention_in_days = 30
}

# Alarma: build fallido
resource "aws_cloudwatch_metric_alarm" "build_failure" {
  alarm_name          = "${var.project}-codebuild-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedBuilds"
  namespace           = "AWS/CodeBuild"
  period              = 300
  statistic           = "Sum"
  threshold           = 0

  dimensions = {
    ProjectName = aws_codebuild_project.terraform.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

**Consultas de CloudWatch Insights para debugging:**

```sql
-- Builds más lentos del último mes
fields @timestamp, @duration, @buildId
| filter @logStream like /plan/
| sort @duration desc
| limit 10
```

---

> [← Volver al índice](./README.md) | [Siguiente →](./03_codedeploy.md)
