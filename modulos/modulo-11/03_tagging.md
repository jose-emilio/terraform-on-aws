# Sección 3 — Estrategia de Etiquetado de Recursos

> [← Volver al índice](./README.md) | [Siguiente →](./04_finops.md)

---

## 1. Etiquetado como Disciplina de Ingeniería

En AWS, los tags no son metadata opcional — son el sistema nervioso de gobernanza, costes y automatización. Sin una estrategia de etiquetado, la nube se convierte en un caos ingobernable.

> **El profesor explica:** "Cuando entro a una cuenta AWS de un cliente y veo recursos sin tags o con tags inconsistentes, ya sé qué tipo de problemas voy a encontrar. Tags inconsistentes significan que el equipo no puede saber qué recursos pertenecen a qué equipo, no puede asignar costes a departamentos, no puede aplicar reglas de seguridad selectivas, y no puede automatizar operaciones de ciclo de vida. Los tags son el contrato que transforma una lista de recursos en una infraestructura gestionable. Y ese contrato debe definirse el día uno, no el día cien."

**Los tres pilares del etiquetado:**

| Pilar | Capacidades que habilita |
|-------|------------------------|
| **Gobernanza** | Identificar propietarios, auditar cumplimiento con Tag Policies |
| **FinOps** | Cost allocation por equipo, showback/chargeback, presupuestos automáticos |
| **Automatización** | Operaciones selectivas, IAM conditions ABAC, lifecycle rules |

---

## 2. Taxonomía de Tags: El Esquema Maestro

Una taxonomía bien diseñada agrupa tags en capas: identificación, propiedad, operación y compliance.

**Esquema de tags obligatorios:**

| Categoría | Tag Key | Valores de ejemplo | Obligatorio |
|-----------|---------|-------------------|-------------|
| **Identificación** | `Name` | `myapp-prd-api-alb` | Sí |
| | `Environment` | `dev` / `stg` / `prd` | Sí |
| | `Project` | `payments-api` | Sí |
| **Propiedad** | `Owner` | `payments-team@company.com` | Sí |
| | `Team` | `payments` / `platform` | Sí |
| | `CostCenter` | `CC-1234` | Sí |
| **Operación** | `Backup` | `daily` / `weekly` / `none` | Recomendado |
| | `PatchGroup` | `prod-tuesday` | Recomendado |
| | `DataClassification` | `confidential` / `public` | En datos |
| **Compliance** | `Regulatory` | `pci-dss` / `hipaa` | Si aplica |
| | `ManagedBy` | `terraform` | Sí |

---

## 3. Naming Conventions: Legibilidad Predecible

Un nombre consistente como `{project}-{env}-{service}-{resource}` elimina ambigüedad.

> **El profesor explica:** "El nombre de un recurso debe ser un contrato. Cuando veo `myapp-prd-api-alb` inmediatamente sé: proyecto myapp, entorno producción, servicio API, tipo load balancer. No necesito abrir los detalles del recurso. Esa legibilidad instantánea reduce el tiempo de debugging en incidentes y reduce los errores cuando alguien modifica o elimina recursos. La convención más inteligente es la que permite leer el recurso como una oración."

**Formato recomendado:** `{project}-{env}-{service}-{resource-type}`

| Segmento | Reglas | Ejemplos |
|----------|--------|---------|
| `project` | 3-8 chars, lowercase | `myapp`, `pay`, `plat` |
| `env` | Abreviatura fija | `dev`, `stg`, `prd` |
| `service` | Nombre funcional | `api`, `db`, `cache`, `web` |
| `resource-type` | Tipo técnico | `alb`, `rds`, `sg`, `asg` |

**Ejemplos completos:**
```
myapp-prd-api-alb        → ALB del API en producción
myapp-dev-db-rds         → RDS de la DB en desarrollo
myapp-stg-cache-redis    → ElastiCache Redis en staging
plat-prd-net-vpc         → VPC de la plataforma en producción
```

**Reglas de formato:**
- Siempre `lowercase` con guiones (`kebab-case`)
- Sin espacios, acentos ni caracteres especiales
- Máximo 63 caracteres (límite DNS de algunos servicios)
- Nunca usar mayúsculas — `MyApp-PRD` introduce inconsistencias

---

## 4. `default_tags`: El Mapa Base del Provider

El bloque `default_tags` en el provider AWS inyecta etiquetas en cada recurso sin repetir código. Es la base del etiquetado consistente en toda la infraestructura.

```hcl
# provider.tf — Tags base aplicados automáticamente a todos los recursos
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment      # dev / stg / prd
      Project     = var.project_name     # Identificador del proyecto
      ManagedBy   = "terraform"          # Siempre: indica origen del recurso
      Owner       = var.owner_email      # Email del equipo responsable
      CostCenter  = var.cost_center      # Código contable para FinOps
    }
  }
}

# Cualquier recurso hereda estos tags automáticamente:
resource "aws_instance" "app" {
  ami           = data.aws_ami.latest.id
  instance_type = "t3.medium"

  # Solo los tags específicos de esta instancia
  tags = {
    Name     = "${var.project}-${var.environment}-app-ec2"
    Backup   = "daily"
    PatchGroup = "prod-tuesday"
  }
  # Los tags base (Environment, Project, ManagedBy...) se heredan del provider
}
```

**Flujo de herencia de tags:**

```
provider "aws" → default_tags (base para todos)
     │
     └── resource "aws_instance" → tags (específicos del recurso)
              │
              └── Resultado final = merge(default_tags, resource.tags)
                  Override: si el mismo key existe en ambos, gana resource.tags
```

---

## 5. Locals y merge(): Propagación de Tags por Capas

Para tags que requieren lógica computada, el patrón `locals` + `merge()` construye el mapa final de forma legible.

```hcl
# variables.tf
variable "extra_tags" {
  type    = map(string)
  default = {}
  description = "Tags adicionales específicos del entorno o proyecto"
}

# locals.tf — Construir el mapa de tags completo
locals {
  common_tags = merge(
    # Base: tags de entorno y proyecto
    {
      Environment    = var.environment
      Project        = var.project_name
      ManagedBy      = "terraform"
      Owner          = var.owner_email
      CostCenter     = var.cost_center
    },
    # Operativos: configuración de ciclo de vida
    {
      Backup         = var.environment == "prd" ? "daily" : "none"
      DataRetention  = var.environment == "prd" ? "365d" : "30d"
    },
    # Extra: cualquier tag adicional pasado como variable
    var.extra_tags,
  )
}

# Uso en cualquier recurso
resource "aws_db_instance" "main" {
  # ... configuración ...
  tags = merge(local.common_tags, {
    Name     = "${var.project}-${var.environment}-main-rds"
    Engine   = "postgres"
    Tier     = "database"
  })
}
```

---

## 6. Tag Policies: Enforcement Organizacional

Las Tag Policies definen qué tags son obligatorios, qué valores son válidos y qué tipos de recurso deben cumplir. Son el enforcement centralizado que evita la anarquía de etiquetado.

```hcl
# Tag Policy: enforce valores del tag Environment
resource "aws_organizations_policy" "tag_env" {
  name        = "RequireEnvironmentTag"
  description = "Requiere tag Environment con valores controlados"
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key = {
          "@@assign" = "Environment"    # Case-sensitive: solo "Environment", no "env"
        }
        tag_value = {
          "@@assign" = ["dev", "stg", "prd"]   # Solo estos valores son válidos
        }
        enforced_for = {
          "@@assign" = ["ec2:*", "rds:*", "s3:*"]   # Tipos de recurso obligados
        }
      }
      ManagedBy = {
        tag_key = { "@@assign" = "ManagedBy" }
        tag_value = { "@@assign" = ["terraform"] }
        enforced_for = { "@@assign" = ["ec2:*", "rds:*"] }
      }
    }
  })
}

# Asociar la política a la OU de producción
resource "aws_organizations_policy_attachment" "prod_ou" {
  policy_id = aws_organizations_policy.tag_env.id
  target_id = var.prod_ou_id
}
```

---

## 7. ABAC: Seguridad Basada en Tags

ABAC (Attribute-Based Access Control) usa tags como conditions en políticas IAM. Un developer solo opera recursos con `Environment=dev` sin tocar las policies cuando escala el equipo.

> **El profesor explica:** "ABAC es el salto evolutivo de RBAC (Role-Based) a ABAC (Attribute-Based). Con RBAC necesitas crear un rol por cada combinación de equipo y entorno: DeveloperDevRole, DeveloperStagingRole, OperationsDevRole... En empresas medianas esto se convierte en un centenar de roles que alguien tiene que mantener. Con ABAC, el tag del recurso y el tag del usuario hacen toda la lógica automáticamente: si `aws:ResourceTag/Environment` coincide con `aws:PrincipalTag/Environment`, el acceso está permitido. El número de policies se mantiene constante aunque escales de 10 a 200 personas."

```hcl
# Política ABAC: solo operar recursos de tu mismo entorno
data "aws_iam_policy_document" "abac_ec2" {
  statement {
    sid    = "AllowOperateOwnEnvironment"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances",
      "ec2:DescribeInstances",
    ]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      # El valor del tag del recurso debe coincidir con el tag del usuario
      values = ["${aws:PrincipalTag/Environment}"]
    }
  }

  statement {
    sid    = "DenyTerminateProduction"
    effect = "Deny"
    actions = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["prd"]
    }
  }
}

# IAM User con tag de entorno
resource "aws_iam_user" "developer" {
  name = "john.doe"

  tags = {
    Environment = "dev"   # Este tag define a qué puede acceder
    Team        = "payments"
  }
}
```

---

## 8. Cost Allocation Tags: FinOps con Etiquetas

Los Cost Allocation Tags son tags activados en Billing que aparecen como columnas en los Cost Reports. Permiten showback y chargeback por equipo, proyecto o entorno.

```hcl
# Activar tags para cost allocation (via AWS Billing API)
resource "aws_ce_cost_allocation_tag" "environment" {
  tag_key = "Environment"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "team" {
  tag_key = "Team"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "cost_center" {
  tag_key = "CostCenter"
  status  = "Active"
}

# Budget por equipo (usando tag como filtro)
resource "aws_budgets_budget" "per_team" {
  name         = "payments-team-budget"
  budget_type  = "COST"
  limit_amount = "2000"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["Team$payments"]   # Formato: TagKey$TagValue
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["payments-lead@company.com"]
  }
}
```

---

## 9. AWS Config: Compliance de Etiquetado

AWS Config evalúa continuamente si los recursos cumplen las políticas de etiquetado. Las reglas `required-tags` marcan como `NON_COMPLIANT` los recursos que faltan tags obligatorios.

```hcl
# Regla: todos los recursos EC2 deben tener los tags obligatorios
resource "aws_config_config_rule" "required_tags" {
  name        = "required-tags-ec2"
  description = "EC2 instances must have Environment, Team, and CostCenter tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key   = "Environment"
    tag1Value = "dev,stg,prd"
    tag2Key   = "Team"
    tag3Key   = "CostCenter"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::Instance", "AWS::RDS::DBInstance"]
  }
}

# Auto-remediation: Lambda que aplica tags por defecto a recursos non-compliant
resource "aws_config_remediation_configuration" "auto_tag" {
  config_rule_name = aws_config_config_rule.required_tags.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWS-RunPythonScript"
  automatic        = false   # Semi-automático: notifica pero no aplica sin aprobación

  parameter {
    name         = "commands"
    static_value = "aws ec2 create-tags --resources $RESOURCE_ID --tags Key=ManagedBy,Value=terraform"
  }
}
```

---

## 10. Naming Module: Convención Centralizada

Un módulo de naming centraliza la lógica: recibe `project`, `environment` y `service` como inputs, y genera nombre, tags base y hash único.

```hcl
# modules/naming/main.tf
variable "project"     { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "Environment debe ser: dev, stg o prd."
  }
}
variable "service"     { type = string }
variable "extra_tags"  { type = map(string); default = {} }

locals {
  name_prefix = "${var.project}-${var.environment}-${var.service}"

  common_tags = merge({
    Project     = var.project
    Environment = var.environment
    Service     = var.service
    ManagedBy   = "terraform"
  }, var.extra_tags)
}

output "name_prefix"  { value = local.name_prefix }
output "common_tags"  { value = local.common_tags }
output "resource_id"  { value = substr(md5(local.name_prefix), 0, 8) }
```

```hcl
# Uso del naming module en otros módulos
module "naming" {
  source      = "../../modules/naming"
  project     = var.project
  environment = var.environment
  service     = "api"
}

resource "aws_lb" "api" {
  name               = "${module.naming.name_prefix}-alb"   # myapp-prd-api-alb
  load_balancer_type = "application"
  tags               = module.naming.common_tags
}
```

---

## 11. Tag Drift: Detección y Corrección Continua

El tag drift ocurre cuando alguien modifica tags manualmente en la consola o cuando un pipeline no aplica los últimos cambios.

```
Causas de tag drift:
  1. Edición manual en consola AWS
  2. SDK/CLI que no pasa tags en sus llamadas
  3. Pipeline incompleto que no ejecutó el último apply

Detección:
  terraform plan -detailed-exitcode
      → Exit code 2 = hay cambios (incluyendo tags)

  AWS Config required-tags rule
      → Evalúa continuamente y reporta NON_COMPLIANT

  Resource Groups Tag Editor
      → Búsqueda masiva de recursos sin tags específicos
```

```hcl
# Lambda correctora de tags via EventBridge (scheduled)
resource "aws_cloudwatch_event_rule" "tag_compliance" {
  name                = "tag-compliance-check"
  description         = "Detecta recursos sin tags obligatorios"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "tag_fixer" {
  rule      = aws_cloudwatch_event_rule.tag_compliance.name
  target_id = "TagComplianceLambda"
  arn       = aws_lambda_function.tag_fixer.arn
}
```

---

## 12. Multi-Account: Tag Strategy a Escala

En landing zones multi-cuenta, los tags deben ser consistentes cross-account desde el día cero.

```hcl
# Organizations Tag Policy: herencia por OU jerárquica
resource "aws_organizations_policy" "corp_tags" {
  name = "CorporateTaggingStandard"
  type = "TAG_POLICY"

  content = jsonencode({
    tags = {
      CostCenter = {
        tag_key   = { "@@assign" = "CostCenter" }
        enforced_for = { "@@assign" = ["ec2:*", "rds:*", "s3:*", "lambda:*"] }
      }
    }
  })
}

# Attach a la raíz de la organización (aplica a todas las cuentas)
resource "aws_organizations_policy_attachment" "root" {
  policy_id = aws_organizations_policy.corp_tags.id
  target_id = data.aws_organizations_organization.current.roots[0].id
}
```

---

## 13. Anti-Patrones: Errores Comunes en Etiquetado

| Anti-patrón | Problema | Solución |
|-------------|---------|---------|
| `env` vs `Environment` vs `Env` | Inconsistencia: no se puede filtrar automáticamente | Validation blocks en Terraform + Tag Policy |
| Tags duplicados con variantes | `team` y `Team` coexisten con valores distintos | Un solo key definido en el naming module |
| Más de 20 tags por recurso | Sobre-ingeniería sin consumidor real | Auditar qué systems consumen qué tags |
| Tags solo en la consola | Drift garantizado: no hay IaC de respaldo | Todo tag nace en Terraform o en default_tags |
| Valores en mayúsculas inconsistentes | `DEV` vs `dev` rompen los filtros de IAM y Cost Explorer | Enforced en Tag Policy: valores en minúscula |

---

## 14. Resumen: Los Pilares del Etiquetado Maduro

```
Tag Strategy Completa
│
├── 1. DEFINICIÓN
│   ├── Taxonomía (8-12 tags obligatorios)
│   ├── Naming Convention (kebab-case predecible)
│   └── Naming Module (DRY, punto único de verdad)
│
├── 2. IMPLEMENTACIÓN
│   ├── default_tags en provider (herencia automática)
│   ├── locals + merge() (lógica de tags en una sola capa)
│   └── Validation blocks (errores en plan, no en producción)
│
├── 3. GOVERNANCE
│   ├── Tag Policies en Organizations (enforcement jerárquico)
│   ├── SCP: Deny create sin tags requeridos
│   └── Config Rules: detección continua de non-compliant
│
└── 4. OPERACIONES
    ├── Cost Allocation Tags → FinOps por equipo
    ├── ABAC IAM → seguridad basada en tags
    └── Drift detection → remediation automática
```

---

> [← Volver al índice](./README.md) | [Siguiente →](./04_finops.md)
