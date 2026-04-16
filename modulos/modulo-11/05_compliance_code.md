# Sección 5 — Compliance as Code

> [← Volver al índice](./README.md)

---

## 1. Compliance as Code: La Ley en el Repositorio

Compliance as Code transforma las políticas de cumplimiento en reglas ejecutables dentro del repositorio. Se pasa de auditorías manuales anuales a validaciones automatizadas en tiempo real.

> **El profesor explica:** "En el modelo tradicional de compliance, un auditor externo llega una vez al año con una lista de 200 controles, revisa manualmente que estén implementados, y si encuentra un problema te da 90 días para corregirlo. Con Compliance as Code, esa lista de 200 controles está codificada como reglas que se ejecutan continuamente. No hay 'auditoría anual' — hay un estado de compliance evaluado cada hora. Si algo cambia y rompe un control, lo sabes en minutos, no en meses. La agilidad no se sacrifica por el cumplimiento — se integran."

**Auditoría tradicional vs Compliance as Code:**

| Aspecto | Auditoría Manual | Compliance as Code |
|---------|-----------------|-------------------|
| Frecuencia | Anual | Continua (tiempo real) |
| Detección de desviaciones | Semanas o meses | Minutos |
| Coste | Alto (equipos externos) | Bajo (automatizado) |
| Trazabilidad | Snapshots puntuales | Historial completo en Git |
| Respuesta | 90 días de remediación | Auto-remediation inmediata |

---

## 2. Frameworks y Mapeo de Controles

Mapear controles de frameworks como CIS, PCI DSS y HIPAA directamente a parámetros de Terraform permite verificar cumplimiento desde el código.

| Framework | Área | Control clave → Parámetro Terraform |
|-----------|------|-------------------------------------|
| **CIS AWS Foundations** | S3 | Bloqueo de acceso público → `aws_s3_bucket_public_access_block` |
| | CloudTrail | Multi-región → `is_multi_region_trail = true` |
| | IAM | MFA obligatoria → `aws_iam_account_password_policy` |
| **PCI DSS** | Cifrado | Datos en reposo → `storage_encrypted = true` |
| | Acceso | Segregación de redes → subnets privadas + SG restrictivos |
| | Logs | Registro de actividad → CloudTrail + 1 año de retención |
| **HIPAA** | PHI | Cifrado E2E → `kms_key_id` en todos los servicios de datos |
| | Acceso | RBAC estricto → IAM roles con least privilege |
| | Auditoría | Accesos auditados → CloudTrail + Config |

---

## 3. AWS Config Rules: El Vigilante Continuo

AWS Config evalúa continuamente si la configuración de los recursos cumple con las reglas definidas. Terraform despliega estas reglas como código.

```hcl
# Regla administrada: volúmenes EBS deben estar cifrados
resource "aws_config_config_rule" "ebs_encryption" {
  name        = "encrypted-volumes"
  description = "Verifica que todos los volúmenes EBS estén cifrados"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Volume"]
  }

  depends_on = [aws_config_configuration_recorder.main]
}

# Regla administrada: S3 sin acceso público
resource "aws_config_config_rule" "s3_no_public" {
  name = "s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
}

# Regla personalizada con Lambda: lógica de compliance específica de la organización
resource "aws_config_config_rule" "custom_tagging" {
  name = "required-tags-check"

  source {
    owner = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.tag_checker.arn

    source_detail {
      event_source = "aws.config"
      message_type = "ConfigurationItemChangeNotification"
    }
  }

  scope {
    compliance_resource_types = ["AWS::EC2::Instance", "AWS::RDS::DBInstance"]
  }
}
```

**Reglas administradas de AWS Config más usadas:**

| Regla | Qué evalúa | Framework |
|-------|-----------|-----------|
| `ENCRYPTED_VOLUMES` | EBS cifrados | CIS / PCI |
| `S3_BUCKET_PUBLIC_READ_PROHIBITED` | S3 sin acceso público | CIS / PCI |
| `RDS_STORAGE_ENCRYPTED` | RDS con cifrado | PCI / HIPAA |
| `CLOUD_TRAIL_ENABLED` | CloudTrail activo | CIS / PCI / HIPAA |
| `REQUIRED_TAGS` | Tags obligatorios | Gobernanza interna |
| `IAM_USER_MFA_ENABLED` | MFA para usuarios IAM | CIS |
| `SECURITY_GROUP_OPEN_TO_WORLD` | SG sin `0.0.0.0/0` | CIS / PCI |

---

## 4. Conformance Packs: Compliance a Gran Escala

Los Conformance Packs son colecciones de reglas de Config y acciones de remediación empaquetadas. Permiten desplegar conjuntos completos de políticas de forma masiva.

```hcl
# Conformance Pack de CIS AWS Foundations Benchmark
resource "aws_config_conformance_pack" "cis_foundation" {
  name = "Operational-Best-Practices-for-CIS"

  template_body = <<EOT
Parameters:
  AccessKeysRotatedParamMaxAccessKeyAge:
    Default: '90'
    Type: String

Resources:
  CloudTrailEnabled:
    Properties:
      ConfigRuleName: cloudtrail-enabled
      Source:
        Owner: AWS
        SourceIdentifier: CLOUD_TRAIL_ENABLED
    Type: AWS::Config::ConfigRule

  EncryptedVolumes:
    Properties:
      ConfigRuleName: encrypted-volumes
      Source:
        Owner: AWS
        SourceIdentifier: ENCRYPTED_VOLUMES
    Type: AWS::Config::ConfigRule

  S3BucketPublicReadProhibited:
    Properties:
      ConfigRuleName: s3-bucket-public-read-prohibited
      Source:
        Owner: AWS
        SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED
    Type: AWS::Config::ConfigRule
EOT
}

# Despliegue multi-cuenta via Organizations
resource "aws_config_organization_conformance_pack" "pci" {
  name            = "PCI-DSS-Requirements"
  template_s3_uri = "s3://${aws_s3_bucket.config.bucket}/conformance-packs/pci-dss.yaml"

  # Excluir cuentas de sandbox
  excluded_accounts = var.sandbox_account_ids
}
```

---

## 5. Remediación Automática con SSM

SSM permite corregir automáticamente recursos que no cumplen con las reglas de Config sin intervención manual.

> **El profesor explica:** "La tríada de Compliance as Code tiene tres capas: detectar (AWS Config), prevenir (OPA/Trivy) y remediar (SSM). La remediación automática cierra el ciclo. Si Config detecta un bucket S3 con acceso público habilitado, SSM ejecuta el documento `AWS-ConfigureS3BucketPublicAccessBlock` y lo corrige automáticamente en minutos. El ingeniero recibe una notificación de que se detectó Y se corrigió — no una tarea pendiente. La postura de seguridad se mantiene sin degradar la velocidad del equipo."

```
Flujo de auto-remediación:

1. AWS Config detecta recurso NON_COMPLIANT
         │
2. Evaluación contra regla (ej: ENCRYPTED_VOLUMES)
         │
3. Dispara Remediation Configuration
         │
4. SSM Document ejecuta corrección automática
         │
5. Config re-evalúa → COMPLIANT
         │
6. CloudTrail registra: quién remedi ó, cuándo y qué
```

```hcl
# Remediación: bloquear acceso público a S3 automáticamente
resource "aws_config_remediation_configuration" "s3_public" {
  config_rule_name = aws_config_config_rule.s3_no_public.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWS-ConfigureS3BucketPublicAccessBlock"

  automatic = true   # Auto-remediate sin esperar aprobación

  parameter {
    name         = "BucketName"
    resource_value = "RESOURCE_ID"   # Config inyecta el nombre del bucket
  }
  parameter {
    name         = "RestrictPublicBuckets"
    static_value = "true"
  }

  retry_attempt_seconds = 60
  maximum_automatic_attempts = 5
}

# Remediación: cifrar volumen EBS non-compliant
resource "aws_config_remediation_configuration" "ebs_encrypt" {
  config_rule_name = aws_config_config_rule.ebs_encryption.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWSSupport-StartEC2RescueWorkflow"

  automatic = false   # Requiere aprobación manual — acción destructiva
}
```

---

## 6. OPA y Rego: Políticas Preventivas en el Pipeline

Open Policy Agent (OPA) valida el plan de Terraform con el lenguaje Rego antes de que los recursos se creen. Las políticas actúan como guardrails preventivos en CI/CD.

```
Flujo con OPA en el pipeline:

git push
  → terraform plan -out=plan.tfplan
  → terraform show -json plan.tfplan > plan.json
  → opa eval -d policy/ -i plan.json "data.terraform.deny"
       → Si hay resultados de deny → BLOQUEAR el apply
       → Si no hay resultados → CONTINUAR con el apply
```

```rego
# policy/deny_http_lb.rego
package terraform.analysis

# Denegar Load Balancers con protocolo HTTP
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "aws_lb_listener"
  resource.change.after.protocol == "HTTP"
  msg = sprintf(
    "Error: Listener '%s' usa HTTP. Solo se permite HTTPS.",
    [resource.address]
  )
}

# Denegar instancias EC2 sin cifrado en el root volume
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "aws_instance"
  not resource.change.after.root_block_device[_].encrypted
  msg = sprintf(
    "Error: Instancia '%s' no tiene cifrado en el root volume.",
    [resource.address]
  )
}

# Denegar Security Groups con ingreso abierto al mundo
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "aws_security_group_rule"
  resource.change.after.type == "ingress"
  resource.change.after.cidr_blocks[_] == "0.0.0.0/0"
  resource.change.after.from_port == 0
  msg = sprintf(
    "Error: SG Rule '%s' permite todo el tráfico desde Internet.",
    [resource.address]
  )
}
```

---

## 7. Sentinel: Compliance en HCP Terraform

Sentinel es el framework de Policy-as-Code nativo de HCP Terraform/Enterprise. A diferencia de OPA, está integrado directamente en el flujo de trabajo de Terraform.

```python
# Ejemplo de política Sentinel (lenguaje propio de HashiCorp)
import "tfplan/v2" as tfplan

# Regla: todos los recursos EC2 deben usar instancias Graviton (ARM)
allowed_instance_families = ["t4g", "m7g", "c7g", "r7g"]

deny_non_graviton = rule {
  all tfplan.resource_changes as _, resource_change {
    resource_change.type is not "aws_instance" or
    any allowed_instance_families as family {
      strings.has_prefix(resource_change.change.after.instance_type, family)
    }
  }
}

# Niveles de enforcement en Sentinel:
# advisory   → Warning: permite el apply, pero notifica la violación
# soft-mandatory → Bloquea el apply pero puede ser aprobado manualmente
# hard-mandatory → Bloquea el apply sin posibilidad de override
main = rule {
  deny_non_graviton
}
```

**OPA vs Sentinel:**

| Aspecto | OPA (Open Policy Agent) | Sentinel (HashiCorp) |
|---------|------------------------|---------------------|
| Integración | Requiere configuración en CI/CD | Nativo en HCP Terraform/Enterprise |
| Lenguaje | Rego (declarativo) | Sentinel (propio de HashiCorp) |
| Scope | Genérico: Kubernetes, APIs, Terraform | Solo Terraform |
| Acceso al plan | Vía `terraform show -json` | Directo al tfplan y tfstate |
| Open Source | Sí | No (comercial) |
| Niveles | Allow / Deny | Advisory / Soft / Hard mandatory |

---

## 8. Escaneo Estático: Trivy y Checkov

Herramientas de análisis estático escanean el código HCL en busca de malas prácticas antes del `terraform plan`.

```yaml
# pre-commit-config.yaml — Escaneo local antes de cada commit
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.88.0
    hooks:
      - id: terraform_trivy
        args:
          - --args=--severity=HIGH,CRITICAL   # Solo HIGH y CRITICAL bloquean
      - id: terraform_checkov
        args:
          - --args=--framework terraform
          - --args=--skip-check CKV_AWS_18   # Excepciones documentadas
```

```yaml
# Checkov Custom Rule: regla específica de la organización
check:
  id: "CUSTOM_AWS_001"
  name: "Asegurar que todas las EC2 tengan Tag de Seguridad"
  categories:
    - "Convention"
  resource: ["aws_instance"]
  condition:
    attribute: "tags.SecurityLevel"
    operator: "exists"
```

**Comparativa Trivy vs Checkov:**

| Aspecto | Trivy | Checkov |
|---------|-------|---------|
| Velocidad | Muy rápido (Go) | Medio (Python) |
| Frameworks | IaC, contenedores, filesystem, secretos | Terraform, CloudFormation, K8s, Helm |
| Reglas built-in | ~500 IaC (heredadas de tfsec) | +1000 |
| Custom checks | Sí (Rego/YAML) | Sí (Python/YAML) |
| IDE plugin | VS Code | VS Code, IntelliJ |
| Output | SARIF, JSON, JUnit (template) | SARIF, JSON, JUnit |
| Graph analysis | No | Sí (dependencias entre recursos) |

---

## 9. Security Hub: Vista Unificada de Postura

Security Hub centraliza los hallazgos de AWS Config, GuardDuty, Inspector y escaneos de Terraform en una consola única.

```hcl
# Habilitar Security Hub en la cuenta
resource "aws_securityhub_account" "main" {}

# Suscribirse al estándar CIS AWS Foundations
resource "aws_securityhub_standards_subscription" "cis" {
  depends_on    = [aws_securityhub_account.main]
  standards_arn = "arn:aws:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/5.0.0"
}

# Suscribirse al estándar PCI DSS
resource "aws_securityhub_standards_subscription" "pci" {
  depends_on    = [aws_securityhub_account.main]
  standards_arn = "arn:aws:securityhub:${var.region}::standards/pci-dss/v/3.2.1"
}

# Agregar hallazgos desde Checkov via EventBridge
resource "aws_cloudwatch_event_rule" "checkov_findings" {
  name = "checkov-to-security-hub"
  event_pattern = jsonencode({
    source      = ["checkov"]
    detail-type = ["Security Finding"]
  })
}
```

**Fuentes de findings en Security Hub:**

| Fuente | Tipo de hallazgo |
|--------|-----------------|
| AWS Config | Non-compliant resources |
| Amazon GuardDuty | Amenazas activas (cryptomining, brute force) |
| Amazon Inspector | Vulnerabilidades en EC2/Lambda/ECR |
| AWS IAM Access Analyzer | Accesos no intencionados cross-account |
| Trivy/Checkov | Misconfigurations en IaC |

---

## 10. El Pipeline de Compliance Completo

El pipeline integra tres fases: Scan → Report → Remediate.

```
Developer (local)               Pipeline CI/CD              AWS (Runtime)
─────────────────               ──────────────              ──────────────
terraform fmt         ──────►  terraform fmt -check
terraform validate    ──────►  terraform validate
trivy config         ──────►  checkov --framework tf      AWS Config Rules
                               OPA / Sentinel              (evaluación continua)
                               terraform plan -out=tfplan       │
                               terraform show -json             │
                                     │                    NON_COMPLIANT
                               ✅ Pass / ❌ Deny               │
                               (bloqueo preventivo)            SSM Remediation
                                                               (auto-corrección)
                               ─────────────────────           │
                               Reportes JUnit / SARIF          Security Hub
                               Infracost cost diff             (findings centralizados)
                               SNS: "✅ Deploy ok"             CloudTrail
                                                               (auditoría inmutable)
```

---

## 11. Gobernanza de Datos: Cifrado y Retención

Con Terraform se asegura que ningún recurso de datos se despliegue sin cifrado.

```hcl
# S3: Deny HTTP, SSE-KMS obligatorio, versionado
resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true   # Reducir costes de KMS API calls
  }
}

resource "aws_s3_bucket_policy" "deny_http" {
  bucket = aws_s3_bucket.data.id

  policy = jsonencode({
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = ["${aws_s3_bucket.data.arn}/*", aws_s3_bucket.data.arn]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# RDS: cifrado + backups + SSL obligatorio
resource "aws_db_instance" "compliant" {
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  backup_retention_period = 35     # 35 días (máximo: requisito PCI/HIPAA)
  deletion_protection     = true   # Previene eliminación accidental

  ca_cert_identifier       = "rds-ca-rsa2048-g1"   # TLS en conexiones
  iam_database_authentication_enabled = true         # Sin contraseñas de larga duración
}

# DynamoDB: CMK + PITR
resource "aws_dynamodb_table" "compliant" {
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ddb.arn
  }

  point_in_time_recovery {
    enabled = true   # PITR para recuperación sin pérdida de datos
  }
}
```

---

## 12. Troubleshooting: Cuando las Políticas Bloquean

| Situación | Diagnóstico | Resolución |
|-----------|-------------|-----------|
| OPA bloquea el apply | Leer el mensaje `deny` completo, buscar la regla activada | Corregir el HCL o pedir excepción temporal documentada en Git |
| Checkov falla en pre-commit | Ver el ID del check (CKV_AWS_XXX) | Corregir, o añadir `#checkov:skip=CKV_AWS_XXX:razón` si es falso positivo |
| Config marca como NON_COMPLIANT | Verificar qué atributo viola la regla | Actualizar el recurso en Terraform y hacer apply |
| Sentinel advisory no bloquea | Por diseño: advisory solo notifica | Subir a soft-mandatory si el equipo lo decide |
| SSM remediation falla | Ver CloudTrail para error de ejecución | Revisar permisos del rol de remediation y el SSM Document |

---

## 13. La Tríada: Detección + Prevención + Remediación

```
PREVENCIÓN (shift-left)          DETECCIÓN (runtime)           REMEDIACIÓN (automática)
────────────────────             ────────────────────          ────────────────────────
Trivy / Checkov                  AWS Config Rules              SSM Documents
  (en pre-commit local)            (evaluación continua)         (auto-corrección)
OPA / Rego                       Conformance Packs             Config Remediation
  (en pipeline CI/CD)              (CIS/PCI/HIPAA)               (sin intervención)
Sentinel                         Security Hub                  EventBridge → Lambda
  (en HCP Terraform)               (vista unificada)             (lógica personalizada)

        │                                │                              │
        └────────────────────────────────┴──────────────────────────────┘
                                         │
                              CloudTrail (auditoría inmutable)
                              Git (historial de todas las políticas)
                              Security Hub (score de compliance global)
```

**El resultado:** la infraestructura deja de ser un punto débil para convertirse en un bastión de seguridad. Las políticas son código, el cumplimiento es continuo, y las auditorías se convierten en un `terraform plan` y un informe de Config.

---

> [← Volver al índice](./README.md)
