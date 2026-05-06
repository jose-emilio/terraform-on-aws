# Laboratorio 25 — Framework de Pruebas: Plan, Apply e Idempotencia

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 6 — Módulos de Terraform](../../modulos/modulo-06/README.md)


## Visión general

Validar la estabilidad y el comportamiento de un módulo Terraform mediante el **framework nativo de testing** (`terraform test`). Crear tests unitarios con `mock_provider` (sin conectar a AWS), tests de integración con `command = apply` (recursos reales), y tests de idempotencia que verifican que no hay cambios pendientes tras un despliegue. Complementar con análisis estático usando `checkov` o `trivy`.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **`terraform test`** | Comando nativo (Terraform 1.6+) que ejecuta archivos `.tftest.hcl`. Crea un entorno aislado, ejecuta los tests, y destruye los recursos automáticamente |
| **`mock_provider`** | Bloque (Terraform 1.7+) que simula un proveedor sin conectar a AWS. Permite testear lógica de nombrado, tags y validaciones sin coste ni credenciales |
| **`mock_data`** | Dentro de `mock_provider`, simula las respuestas de data sources. Ej: `mock_data "aws_caller_identity"` devuelve un `account_id` ficticio |
| **`run` block** | Unidad de ejecución dentro de un test. Puede ser `command = plan` (solo planifica) o `command = apply` (crea recursos reales) |
| **`assert`** | Bloque dentro de `run` que verifica una condición. Si `condition = false`, el test falla con `error_message` |
| **Test de idempotencia** | Patrón de dos `run` consecutivos: primero `apply`, luego `plan`. Si el plan muestra cambios, el módulo no es idempotente (bug) |
| **Análisis estático** | Herramientas como `checkov` o `trivy` que escanean el código HCL buscando vulnerabilidades de seguridad sin ejecutar nada |

## Comparativa: Tipos de test en Terraform

| Tipo | Velocidad | Coste | Qué verifica | Herramienta |
|---|---|---|---|---|
| **Análisis estático** | ~1s | $0 | Patrones inseguros en el código | `checkov`, `trivy` |
| **Unit test (mock)** | ~2s | $0 | Lógica de nombrado, tags, validaciones | `terraform test` + `mock_provider` + `apply` simulado |
| **Integration test** | ~30s+ | Mínimo | Que los recursos se crean en AWS | `terraform test` + `command = apply` |
| **Idempotencia** | ~60s+ | Mínimo | Que el apply es estable (sin drifts) | `terraform test` + apply/plan |

## Prerrequisitos

- Laboratorio 02 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- AWS CLI configurado con credenciales válidas
- **Terraform >= 1.10** (necesario para `use_lockfile` en el backend S3; `mock_provider` ya está disponible desde 1.7, así que también queda cubierto)
- Opcional: `checkov` o `trivy` instalados para análisis estático

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"

# Verificar versión de Terraform
terraform version
# Terraform v1.10.0+ requerido (backend `use_lockfile` + `mock_provider`)
```

## Estructura del proyecto

```
lab-25/
├── README.md                                  <- Esta guía
├── aws/
│   ├── providers.tf                           <- Backend S3 parcial (>= 1.10)
│   ├── variables.tf                           <- Variables del Root Module
│   ├── main.tf                                <- Root Module: invoca tagged-bucket
│   ├── outputs.tf                             <- Outputs delegados al módulo
│   ├── aws.s3.tfbackend                       <- Parámetros del backend
│   ├── modules/
│   │   └── tagged-bucket/                     <- El módulo bajo test
│   │       ├── main.tf                        <- Bucket + tags + public access block
│   │       ├── variables.tf                   <- Entradas con validaciones
│   │       └── outputs.tf                     <- bucket_id, bucket_arn, effective_tags
│   └── tests/
│       ├── unit_naming.tftest.hcl             <- Unit test: mock_provider + plan
│       ├── integration.tftest.hcl             <- Integration test: apply real
│       └── idempotency.tftest.hcl             <- Idempotencia: apply + plan
└── localstack/
    └── README.md                              <- Limitaciones de testing en LocalStack
```

## Análisis del código

### Arquitectura del laboratorio

```
┌─────────────────────────────────────────────────────────────────────┐
│                      terraform test                                 │
│                                                                     │
│  ┌──────────────────┐  ┌───────────────────┐  ┌─────────────────┐   │
│  │ unit_naming      │  │ integration       │  │ idempotency     │   │
│  │ .tftest.hcl      │  │ .tftest.hcl       │  │ .tftest.hcl     │   │
│  │                  │  │                   │  │                 │   │
│  │ mock_provider ── │  │ provider "aws" ── │  │ run 1: apply ── │   │
│  │ command = plan   │  │ command = apply   │  │ run 2: plan  ── │   │
│  │ 0 recursos reales│  │ recursos reales   │  │ 0 cambios?      │   │
│  └────────┬─────────┘  └────────┬──────────┘  └────────┬────────┘   │
│           │                     │                      │            │
│           └─────────────────────┼──────────────────────┘            │
│                                 ▼                                   │
│                    modules/tagged-bucket/                           │
│                    (el módulo bajo test)                            │
└─────────────────────────────────────────────────────────────────────┘
```

Tres archivos de test que verifican el mismo módulo desde ángulos diferentes:
1. **Unit**: ¿La lógica interna es correcta? (sin AWS)
2. **Integration**: ¿El recurso se crea en AWS?
3. **Idempotencia**: ¿El segundo plan está limpio?

### El módulo bajo test: `tagged-bucket`

```hcl
# modules/tagged-bucket/main.tf

locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "tagged-bucket"
  }

  effective_tags = merge(local.default_tags, var.tags)
}

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = true

  tags = merge(local.effective_tags, {
    Name = var.bucket_name
  })
}
```

El módulo tiene lógica testeable:
- **Nombrado**: el bucket recibe un nombre compuesto desde el Root Module
- **Etiquetado**: `merge()` combina tags por defecto con tags del llamador
- **Validaciones**: `bucket_name` debe cumplir regex, `environment` debe estar en una lista

### Unit test — `mock_provider` y `command = apply`

```hcl
# tests/unit_naming.tftest.hcl

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDACKCEVSQ6C2EXAMPLE"
    }
  }
}
```

**`mock_provider "aws"`** reemplaza al proveedor real. Terraform no contacta con AWS. Los recursos se "crean" en memoria con valores simulados.

**`mock_data "aws_caller_identity"`** simula la respuesta del data source. Sin esto, `data.aws_caller_identity.current.account_id` sería una cadena vacía, y el nombre del bucket no tendría el account ID.

```hcl
run "bucket_name_follows_convention" {
  command = apply

  variables {
    project_name  = "myapp"
    bucket_suffix = "logs"
    environment   = "production"
  }

  assert {
    condition     = output.bucket_id == "myapp-logs-123456789012"
    error_message = "El nombre del bucket debe ser '{project}-{suffix}-{account_id}'"
  }
}
```

Puntos clave:
- **`command = apply`** (no `plan`): con `mock_provider`, el apply es simulado — no crea recursos reales y se ejecuta en ~2 segundos. Usamos `apply` en vez de `plan` porque atributos computados como `bucket.id` solo están disponibles después del apply, incluso con mocks
- **`variables {}`**: sobreescribe las variables del Root Module para este test
- **`output.bucket_id`**: referencia un output del Root Module. Tras el apply simulado, los outputs ya están resueltos y se pueden usar en los `assert`
- **`assert`**: si `condition` es `false`, el test falla con `error_message`

Se pueden definir múltiples `assert` en el mismo `run` y múltiples `run` en el mismo archivo.

### Integration test — `command = apply` real

```hcl
# tests/integration.tftest.hcl

variables {
  project_name  = "lab25-inttest"
  bucket_suffix = "integration"
  environment   = "lab"
}

# --- Test 1: el bucket se crea correctamente (command = apply) ---

run "bucket_is_created" {
  command = apply

  assert {
    condition     = output.bucket_arn != ""
    error_message = "El bucket debe tener un ARN tras el apply"
  }

  assert {
    condition     = startswith(output.bucket_arn, "arn:aws:s3:::")
    error_message = "El ARN debe ser un ARN de S3 válido"
  }
}

# --- Test 2: las tags se aplicaron correctamente (command = plan) ---
# Aprovecha el state que dejó `bucket_is_created` y verifica los outputs
# sin volver a tocar AWS. El patrón "apply una vez + varios plan" es el
# habitual cuando varios runs comprueban distintas facetas del MISMO
# despliegue: ahorras 30+ segundos por run frente a un apply nuevo.

run "tags_are_applied" {
  command = plan

  assert {
    condition     = output.effective_tags["Project"] == "lab25-inttest"
    error_message = "El tag Project no coincide tras el apply"
  }

  assert {
    condition     = output.effective_tags["Environment"] == "lab"
    error_message = "El tag Environment no coincide tras el apply"
  }
}
```

Diferencias con el unit test:
- **Sin `mock_provider`**: usa el proveedor real configurado en `providers.tf`.
- **`command = apply` en el primer run**: crea el bucket **de verdad** en la cuenta de AWS.
- **`command = plan` en runs posteriores**: leen los outputs del state generado por el `apply` anterior. No tocan AWS, son rápidos. Es el patrón recomendado cuando varios `assert` verifican distintas propiedades del mismo despliegue — apply una sola vez, varios `plan` después.
- **Limpieza automática**: `terraform test` destruye los recursos al finalizar el archivo de test (no del run).
- **`variables {}` a nivel de archivo**: se comparten entre todos los `run` del archivo (ojo: cada `run` puede sobreescribirlas con su propio bloque `variables {}`).

### Test de idempotencia — Apply + Plan

```hcl
# tests/idempotency.tftest.hcl

run "initial_deploy" {
  command = apply

  assert {
    condition     = output.bucket_id != ""
    error_message = "El bucket debe crearse en el primer apply"
  }
}

run "no_changes_on_replan" {
  command = plan

  assert {
    condition     = output.bucket_id == run.initial_deploy.bucket_id
    error_message = "El bucket_id no debe cambiar entre apply y plan"
  }

  assert {
    condition     = output.bucket_arn == run.initial_deploy.bucket_arn
    error_message = "El bucket_arn no debe cambiar entre apply y plan"
  }
}
```

El patrón de idempotencia:
1. **`run "initial_deploy"`** con `command = apply`: crea los recursos
2. **`run "no_changes_on_replan"`** con `command = plan`: planifica **sin cambios**

Si el módulo es idempotente, el plan no mostrará cambios y los outputs serán idénticos. Si algún recurso tiene un atributo que cambia en cada plan (ej: un `timestamp()`), el test fallará — lo cual es el comportamiento deseado, ya que indica un bug de idempotencia.

**`run.initial_deploy.bucket_id`** referencia el output del run anterior. Esto permite comparar valores entre ejecuciones.

### `expect_failures` — Probar el camino fallido

`assert` verifica que algo es **cierto**. Su contraparte es `expect_failures`, que verifica que **una validación o precondition falla** intencionalmente. Es la forma de testear el "camino infeliz" de un módulo: comprobar que las validaciones rechazan inputs malos.

```hcl
run "rejects_bad_input" {
  command = plan

  variables {
    environment = "invalid"   # ← valor que la validación NO acepta
  }

  expect_failures = [var.environment]
}
```

`expect_failures` es una **lista** de referencias a las variables (o recursos) cuya validación se espera que falle. Si la validación **sí** falla → el test pasa. Si la validación **no** falla (es decir, si la regla está rota y acepta valores que no debería) → el test falla, alertándote.

Diferencias clave con `assert`:

| Aspecto | `assert` | `expect_failures` |
|---|---|---|
| Espera... | que `condition = true` | que la validación de un input falle |
| Comprueba... | el camino satisfactorio | el camino fallido |
| Si la condición/validación pasa | el test pasa | el test **falla** |

El Reto 1 (más abajo) lo aplica para verificar que la validación de `environment` rechaza valores inválidos.

---

## Ejecución de los tests

### Inicializar (sin backend)

```bash
cd labs/lab-25/aws

# Para tests, inicializar sin backend (el state es efímero)
terraform init -backend=false
```

> **El state durante un test:** `terraform test` mantiene el state de cada archivo `.tftest.hcl` **en memoria, sin persistirlo en ningún backend** ni en disco. Cuando termina la ejecución del archivo, el state desaparece junto con los recursos que se hayan creado. Por eso usamos `-backend=false` durante el `init` — no hay nada que guardar.
>
> **Tiempo del primer `init`:** la primera vez tarda 5–15 segundos descargando el provider AWS (`hashicorp/aws`). En ejecuciones posteriores se sirve desde la caché local (`.terraform/providers/`) y es prácticamente instantáneo.

### Ejecutar todos los tests

```bash
terraform test
```

Salida esperada:

```
tests/idempotency.tftest.hcl... in progress
  run "initial_deploy"... pass
  run "no_changes_on_replan"... pass
tests/idempotency.tftest.hcl... tearing down
tests/idempotency.tftest.hcl... pass

tests/integration.tftest.hcl... in progress
  run "bucket_is_created"... pass
  run "tags_are_applied"... pass
tests/integration.tftest.hcl... tearing down
tests/integration.tftest.hcl... pass

tests/unit_naming.tftest.hcl... in progress
  run "bucket_name_follows_convention"... pass
  run "default_tags_are_present"... pass
  run "different_project_changes_name"... pass
tests/unit_naming.tftest.hcl... tearing down
tests/unit_naming.tftest.hcl... pass

Success! 7 passed, 0 failed.
```

### Ejecutar solo los tests unitarios (sin AWS)

```bash
# Filtrar por archivo de test
terraform test -filter=tests/unit_naming.tftest.hcl
```

Esto ejecuta **solo** el test con `mock_provider`. No necesita credenciales de AWS ni genera costes. Ideal para CI/CD en las primeras etapas del pipeline.

### Modo verbose

```bash
terraform test -verbose
```

Muestra los detalles del plan/apply de cada `run`, incluyendo los outputs y los recursos creados.

---

## Análisis estático

El análisis estático complementa los tests de Terraform escaneando el código HCL en busca de vulnerabilidades **sin ejecutar nada**.

### Instalación de checkov

```bash
pip install checkov

# O con pipx (recomendado para no contaminar el entorno)
pipx install checkov
```

### Ejecutar checkov sobre el módulo

```bash
checkov -d modules/tagged-bucket/ --framework terraform
```

Salida típica:

```
Passed checks: 10, Failed checks: 5, Skipped checks: 0

Check: CKV_AWS_19: "Ensure all data stored in the S3 bucket is securely encrypted at rest"
        PASSED for resource: aws_s3_bucket.this
Check: CKV_AWS_21: "Ensure all data stored in the S3 bucket have versioning enabled"
        PASSED for resource: aws_s3_bucket.this
Check: CKV_AWS_53: "Ensure S3 bucket has block public ACLS enabled"
        PASSED for resource: aws_s3_bucket_public_access_block.this
Check: CKV_AWS_54: "Ensure S3 bucket has block public policy enabled"
        PASSED for resource: aws_s3_bucket_public_access_block.this
Check: CKV2_AWS_6:  "Ensure that S3 bucket has a Public Access block"
        PASSED for resource: aws_s3_bucket.this
...

Check: CKV_AWS_18:  "Ensure the S3 bucket has access logging enabled"
        FAILED for resource: aws_s3_bucket.this
Check: CKV_AWS_144: "Ensure that S3 bucket has cross-region replication enabled"
        FAILED for resource: aws_s3_bucket.this
Check: CKV_AWS_145: "Ensure that S3 buckets are encrypted with KMS by default"
        FAILED for resource: aws_s3_bucket.this
Check: CKV2_AWS_61: "Ensure that an S3 bucket has a lifecycle configuration"
        FAILED for resource: aws_s3_bucket.this
Check: CKV2_AWS_62: "Ensure S3 buckets should have event notifications enabled"
        FAILED for resource: aws_s3_bucket.this
```

Las cinco comprobaciones que fallan corresponden a buenas prácticas que el módulo no implementa intencionadamente para mantener la docencia (`access logging`, `cross-region replication`, cifrado con `KMS`, `lifecycle` y `event notifications`). Es un buen ejemplo de cómo `checkov` complementa a los tests funcionales: los `.tftest.hcl` verifican el contrato del módulo, mientras que el análisis estático señala buenas prácticas adicionales que el equipo decide adoptar (o suprimir explícitamente con `--skip-check`).

### Alternativa: Trivy

Instalación oficial según el sistema operativo (ver [docs](https://trivy.dev/docs/latest/getting-started/installation/)):

```bash
# macOS (Homebrew)
brew install trivy
```

```bash
# Linux Debian/Ubuntu (repositorio APT)
sudo apt-get install -y wget gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
```

```bash
# Linux RHEL/CentOS/Fedora (repositorio YUM/DNF)
cat <<EOF | sudo tee /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
sudo dnf install -y trivy
```

Si no quieres añadir un repositorio, puedes descargar el binario suelto desde [GitHub Releases](https://github.com/aquasecurity/trivy/releases) (paquete `.deb`/`.rpm` o tarball para extraer en `~/.local/bin`).

Ejecución sobre el módulo:

```bash
trivy config modules/tagged-bucket/
```

Salida típica:

```
Report Summary

┌─────────┬───────────┬───────────────────┐
│ Target  │   Type    │ Misconfigurations │
├─────────┼───────────┼───────────────────┤
│ main.tf │ terraform │         2         │
└─────────┴───────────┴───────────────────┘

main.tf (terraform)
===================
Tests: 2 (SUCCESSES: 0, FAILURES: 2)
Failures: 2 (UNKNOWN: 0, LOW: 1, MEDIUM: 0, HIGH: 1, CRITICAL: 0)

AWS-0089 (LOW):  Bucket has logging disabled
AWS-0132 (HIGH): Bucket does not encrypt data with a customer managed key.
```

Trivy reporta menos hallazgos que `checkov` porque aplica un catálogo de reglas más reducido y centrado en severidad. Ambos son complementarios: `checkov` da más cobertura, `trivy` clasifica por severidad (`LOW`/`MEDIUM`/`HIGH`/`CRITICAL`), útil para fijar umbrales de fallo en CI (por ejemplo `--severity HIGH,CRITICAL`).

### Pipeline recomendado

```
1. checkov/trivy     →  Análisis estático (0s, $0)
2. terraform test -filter=tests/unit_naming.tftest.hcl
                     →  Unit tests con mock_provider (~2s, $0)
3. terraform test    →  Integration + idempotencia (~60s, coste mínimo)
```

Ejecutar en este orden permite detectar problemas lo antes posible ("shift left"), minimizando el tiempo de feedback y el coste.

---

## Retos

### Reto 1 — Test unitario que verifica que las validaciones rechazan inputs inválidos

**Situación**: El módulo `tagged-bucket` tiene validaciones en `bucket_name` y `environment`. Quieres escribir un test que verifique que Terraform **rechaza** valores inválidos, sin necesidad de conectarse a AWS.

**Tu objetivo**:

1. Crear un nuevo archivo `tests/unit_validations.tftest.hcl`
2. Usar `mock_provider` para no necesitar AWS
3. Crear un `run` que pase un `environment` inválido (ej: `"invalid"`) y verificar que Terraform falla con `expect_failures`
4. Crear otro `run` que pase un `bucket_suffix` que genere un nombre con mayúsculas y verificar que la validación del módulo lo rechaza

**Pistas**:
- `expect_failures` es una lista de referencias a las variables/recursos que esperas que fallen
- Para validaciones de variable: `expect_failures = [var.environment]` (a nivel de root module)
- `command = plan` es suficiente — las validaciones se evalúan antes de contactar con AWS
- El nombre del bucket se genera en el Root Module como `${project}-${suffix}-${account_id}`, pero la validación está en el módulo

### Reto 2 — Test de integración que verifica el bloqueo de acceso público

**Situación**: El módulo `tagged-bucket` incluye un `aws_s3_bucket_public_access_block`. Quieres verificar con un test de integración que el bucket realmente tiene bloqueado el acceso público en AWS, no solo en el código.

**Tu objetivo**:

1. Añadir un output `public_access_block` al módulo `tagged-bucket` que exponga los 4 atributos del bloqueo de acceso público
2. Propagar ese output a través del Root Module
3. Crear un nuevo archivo `tests/integration_security.tftest.hcl`
4. Usar `command = apply` para crear el bucket real y verificar con `assert` que las cuatro opciones de bloqueo están en `true`

**Pistas**:
- El output puede ser un objeto con los 4 campos: `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`
- Accede a los atributos del recurso: `aws_s3_bucket_public_access_block.this.block_public_acls`
- En el test, referencia con `output.public_access_block["block_public_acls"]`

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Test unitario que verifica que las validaciones rechazan inputs inválidos</strong></summary>

### Solución al Reto 1 — Test unitario que verifica que las validaciones rechazan inputs inválidos

#### Archivo `tests/unit_validations.tftest.hcl`

```hcl
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDACKCEVSQ6C2EXAMPLE"
    }
  }
}

# --- Test 1: Entorno inválido es rechazado ---

run "rejects_invalid_environment" {
  command = plan

  variables {
    project_name  = "myapp"
    bucket_suffix = "data"
    environment   = "invalid"
  }

  expect_failures = [var.environment]
}

# --- Test 2: bucket_suffix con mayúsculas es rechazado por el módulo ---

run "rejects_uppercase_bucket_suffix" {
  command = plan

  variables {
    project_name  = "myapp"
    bucket_suffix = "DATA"   # genera "myapp-DATA-123456789012", inválido por la regex
    environment   = "lab"
  }

  expect_failures = [module.bucket.var.bucket_name]
}

# --- Test 3: Entorno válido es aceptado ---

run "accepts_valid_environment" {
  command = apply

  variables {
    project_name  = "myapp"
    bucket_suffix = "data"
    environment   = "staging"
  }

  # Sin expect_failures = debe pasar sin errores
  assert {
    condition     = output.effective_tags["Environment"] == "staging"
    error_message = "El entorno staging debe ser aceptado"
  }
}
```

#### Verificar

```bash
terraform test -filter=tests/unit_validations.tftest.hcl
```

```
tests/unit_validations.tftest.hcl... in progress
  run "rejects_invalid_environment"... pass
  run "rejects_uppercase_bucket_suffix"... pass
  run "accepts_valid_environment"... pass
tests/unit_validations.tftest.hcl... tearing down
tests/unit_validations.tftest.hcl... pass

Success! 3 passed, 0 failed.
```

El test `rejects_invalid_environment` **pasa** porque `expect_failures = [var.environment]` le dice a Terraform: "espero que esta variable falle su validación". Si la validación NO fallara (es decir, si aceptara `"invalid"`), **el test fallaría** — alertándonos de que la validación está rota.

#### Reflexión: testear el camino satisfactorio y el fallido

| Tipo de test | Qué verifica | Sin `expect_failures` |
|---|---|---|
| Camino satisfactorio | Inputs válidos producen outputs correctos | `assert { condition = ... }` |
| Camino fallido       | Inputs inválidos son rechazados | `expect_failures = [...]` |

Ambos son necesarios:
- Sin tests de camino feliz, no sabes si el módulo funciona
- Sin tests de camino infeliz, no sabes si las validaciones protegen contra errores

---

</details>

<details>
<summary><strong>Solución al Reto 2 — Test de integración que verifica el bloqueo de acceso público</strong></summary>

### Solución al Reto 2 — Test de integración que verifica el bloqueo de acceso público

#### Paso 1: Añadir output al módulo `tagged-bucket`

En `modules/tagged-bucket/outputs.tf` — añadir el bloque sin tocar los outputs existentes:

```hcl
output "public_access_block" {
  description = "Configuración de bloqueo de acceso público"
  value = {
    block_public_acls       = aws_s3_bucket_public_access_block.this.block_public_acls
    block_public_policy     = aws_s3_bucket_public_access_block.this.block_public_policy
    ignore_public_acls      = aws_s3_bucket_public_access_block.this.ignore_public_acls
    restrict_public_buckets = aws_s3_bucket_public_access_block.this.restrict_public_buckets
  }
}
```

> **Cambio retro-compatible:** este Paso solo **añade** un output nuevo, no modifica ni elimina los existentes (`bucket_id`, `bucket_arn`, `effective_tags`). Los consumidores del módulo que ya usan los outputs anteriores no se ven afectados, así que se puede mergear sin ciclo de migración.

#### Paso 2: Propagar en el Root Module

En `outputs.tf`:

```hcl
output "public_access_block" {
  description = "Configuración de bloqueo de acceso público"
  value       = module.bucket.public_access_block
}
```

#### Paso 3: Archivo de test

```hcl
# tests/integration_security.tftest.hcl

variables {
  project_name  = "lab25-sectest"
  bucket_suffix = "security"
  environment   = "lab"
}

run "deploy_and_verify_public_access" {
  command = apply

  assert {
    condition     = output.bucket_id != ""
    error_message = "El bucket debe existir"
  }

  assert {
    condition     = output.public_access_block["block_public_acls"] == true
    error_message = "block_public_acls debe estar activado"
  }

  assert {
    condition     = output.public_access_block["block_public_policy"] == true
    error_message = "block_public_policy debe estar activado"
  }

  assert {
    condition     = output.public_access_block["ignore_public_acls"] == true
    error_message = "ignore_public_acls debe estar activado"
  }

  assert {
    condition     = output.public_access_block["restrict_public_buckets"] == true
    error_message = "restrict_public_buckets debe estar activado"
  }
}
```

#### Paso 4: Verificar

```bash
terraform test -filter=tests/integration_security.tftest.hcl
```

```
tests/integration_security.tftest.hcl... in progress
  run "deploy_and_verify_public_access"... pass
tests/integration_security.tftest.hcl... tearing down
tests/integration_security.tftest.hcl... pass

Success! 1 passed, 0 failed.
```

#### Reflexión: outputs como contrato testeable

En vez de usar un data source auxiliar para consultar el estado real, exponemos los atributos de seguridad como **outputs del módulo**. Esto tiene ventajas:

- **Sin módulos auxiliares**: todo se verifica en un solo `run`
- **Contrato explícito**: el output `public_access_block` documenta que el módulo garantiza estas propiedades
- **Reutilizable**: cualquier consumidor del módulo puede verificar programáticamente que el bloqueo está activo
- **Funciona con mock**: el output también está disponible en tests unitarios con `mock_provider`

</details>

---

## Resumen de comandos

```bash
# Ejecutar los tests unitarios (sin AWS)
cd labs/lab-25/aws
terraform test -filter=tests/unit_naming.tftest.hcl
# Esperado: 0 errors, X tests passed

# Ejecutar los tests de idempotencia
terraform test -filter=tests/idempotency.tftest.hcl
# Esperado: 0 changes pending tras el apply

# Ejecutar todos los tests de integración
terraform test
# Esperado: All tests passed

# Análisis estático con checkov
checkov -d . --quiet

# Análisis estático con trivy (alternativa, ordena por severidad)
trivy config modules/tagged-bucket/
```

---

## Limpieza

`terraform test` destruye automáticamente los recursos que crea. **No necesitas hacer limpieza manual** de los tests.

Si desplegaste el Root Module directamente (con `terraform apply`, no con `terraform test`):

```bash
terraform destroy
```

> **Nota:** `terraform test` crea un bucket S3 temporal y lo destruye automáticamente al final de cada archivo de test. **No destruyas el bucket de tfstate del lab-02** (`terraform-state-labs-<ACCOUNT_ID>`), ya que es un recurso compartido entre laboratorios.

---

## LocalStack

Los tests unitarios con `mock_provider` **no necesitan LocalStack ni AWS** — funcionan en cualquier entorno.

Para los tests de integración, consulta [localstack/README.md](localstack/README.md).

---

## Buenas prácticas aplicadas

- **Tests unitarios con `mock_provider`**: validar la lógica de naming y tagging sin desplegar recursos reales acelera el ciclo de desarrollo y permite ejecutar los tests en cualquier entorno sin credenciales AWS.
- **Tests de idempotencia**: verificar que un segundo `terraform apply` no produce cambios es la prueba definitiva de que el módulo está correctamente diseñado y no tiene side effects.
- **Filtrado de tests por archivo**: usar `-filter` permite ejecutar solo los tests relevantes durante el desarrollo sin esperar a que corran todos los tests de integración.
- **Análisis estático complementario**: `checkov` y `trivy` detectan problemas de seguridad que los tests funcionales no cubren (cifrado, logging, acceso público).
- **Tests como documentación ejecutable**: los archivos `.tftest.hcl` documentan el comportamiento esperado del módulo de forma verificable, complementando el README.

---

## Recursos

- [Terraform: Tests](https://developer.hashicorp.com/terraform/language/tests)
- [Terraform: Mock Providers](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [Terraform: `terraform test` command](https://developer.hashicorp.com/terraform/cli/commands/test)
- [Terraform: Test assertions](https://developer.hashicorp.com/terraform/language/tests#assertions)
- [checkov: Documentación](https://www.checkov.io/)
- [Trivy: Documentación](https://trivy.dev/)
- [HashiCorp Blog: Testing Terraform](https://www.hashicorp.com/blog/testing-hashicorp-terraform)
