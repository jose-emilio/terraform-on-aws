# Laboratorio 25 — Framework de Pruebas: Plan, Apply e Idempotencia

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

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- AWS CLI configurado con credenciales válidas
- **Terraform >= 1.7** (requerido para `mock_provider`)
- Opcional: `checkov` o `trivy` instalados para análisis estático

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"

# Verificar versión de Terraform
terraform version
# Terraform v1.7.0+ requerido
```

## Estructura del proyecto

```
lab25/
├── README.md                                  <- Esta guía
├── aws/
│   ├── providers.tf                           <- Backend S3 parcial (>= 1.7)
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

## 1. Análisis del código

### 1.1 Arquitectura del laboratorio

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
│  └────────┬─────────┘  └────────┬──────────┘  └───────┬─────────┘   │
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

### 1.2 El módulo bajo test: `tagged-bucket`

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

### 1.3 Unit test — `mock_provider` y `command = apply`

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
- **`output.bucket_id`**: referencia un output del Root Module. Con `plan` y mock, los valores conocidos en tiempo de plan (como `bucket = var.bucket_name`) sí están disponibles
- **`assert`**: si `condition` es `false`, el test falla con `error_message`

Se pueden definir múltiples `assert` en el mismo `run` y múltiples `run` en el mismo archivo.

### 1.4 Integration test — `command = apply` real

```hcl
# tests/integration.tftest.hcl

variables {
  project_name  = "lab25-inttest"
  bucket_suffix = "integration"
  environment   = "lab"
}

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
```

Diferencias con el unit test:
- **Sin `mock_provider`**: usa el proveedor real configurado en `providers.tf`
- **`command = apply`**: crea el bucket **de verdad** en la cuenta de AWS
- **Limpieza automática**: `terraform test` destruye los recursos al finalizar el archivo de test
- **`variables {}` a nivel de archivo**: se comparten entre todos los `run` del archivo

### 1.5 Test de idempotencia — Apply + Plan

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

---

## 2. Ejecucion de los tests

### 2.1 Inicializar (sin backend)

```bash
cd labs/lab25/aws

# Para tests, inicializar sin backend (el state es efímero)
terraform init -backend=false
```

### 2.2 Ejecutar todos los tests

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

Success! 8 passed, 0 failed.
```

### 2.3 Ejecutar solo los tests unitarios (sin AWS)

```bash
# Filtrar por archivo de test
terraform test -filter=tests/unit_naming.tftest.hcl
```

Esto ejecuta **solo** el test con `mock_provider`. No necesita credenciales de AWS ni genera costes. Ideal para CI/CD en las primeras etapas del pipeline.

### 2.4 Modo verbose

```bash
terraform test -verbose
```

Muestra los detalles del plan/apply de cada `run`, incluyendo los outputs y los recursos creados.

---

## 3. Analisis estatico

El análisis estático complementa los tests de Terraform escaneando el código HCL en busca de vulnerabilidades **sin ejecutar nada**.

### 3.1 Instalación de checkov

```bash
pip install checkov

# O con pipx (recomendado para no contaminar el entorno)
pipx install checkov
```

### 3.2 Ejecutar checkov sobre el módulo

```bash
checkov -d modules/tagged-bucket/ --framework terraform
```

Salida típica:

```
Passed checks: 4, Failed checks: 0, Skipped checks: 0

Check: CKV_AWS_18: "Ensure the S3 bucket has access logging enabled"
        PASSED for resource: aws_s3_bucket.this
Check: CKV_AWS_19: "Ensure the S3 bucket has server-side encryption"
        PASSED for resource: aws_s3_bucket.this
Check: CKV_AWS_53: "Ensure S3 bucket has block public ACLS enabled"
        PASSED for resource: aws_s3_bucket_public_access_block.this
...
```

### 3.3 Alternativa: Trivy

```bash
# Instalación
brew install trivy    # macOS; en Linux: descarga el binario de GitHub Releases

# Ejecución
trivy config modules/tagged-bucket/
```

### 3.4 Pipeline recomendado

```
1. checkov/trivy     →  Análisis estático (0s, $0)
2. terraform test    →  Unit tests con mock_provider (~2s, $0)
   -filter=unit_*
3. terraform test    →  Integration + idempotencia (~60s, coste mínimo)
```

Ejecutar en este orden permite detectar problemas lo antes posible ("shift left"), minimizando el tiempo de feedback y el coste.

---

## 4. Reto: Test unitario que verifica que las validaciones rechazan inputs invalidos

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

La solución está en la [sección 5](#5-solución-del-reto).

---

## 5. Solución del Reto

### Archivo `tests/unit_validations.tftest.hcl`

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

# --- Test 2: Entorno válido es aceptado ---

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

### Verificar

```bash
terraform test -filter=tests/unit_validations.tftest.hcl
```

```
tests/unit_validations.tftest.hcl... in progress
  run "rejects_invalid_environment"... pass
  run "accepts_valid_environment"... pass
tests/unit_validations.tftest.hcl... tearing down
tests/unit_validations.tftest.hcl... pass

Success! 2 passed, 0 failed.
```

El test `rejects_invalid_environment` **pasa** porque `expect_failures = [var.environment]` le dice a Terraform: "espero que esta variable falle su validación". Si la validación NO fallara (es decir, si aceptara `"invalid"`), **el test fallaría** — alertándonos de que la validación está rota.

### Reflexión: testear el camino satisfactorio y el fallido

| Tipo de test | Qué verifica | Sin `expect_failures` |
|---|---|---|
| Camino satisfactorio | Inputs válidos producen outputs correctos | `assert { condition = ... }` |
| Camino fallido       | Inputs inválidos son rechazados | `expect_failures = [...]` |

Ambos son necesarios:
- Sin tests de camino feliz, no sabes si el módulo funciona
- Sin tests de camino infeliz, no sabes si las validaciones protegen contra errores

---

## 6. Reto 2: Test de integración que verifica el bloqueo de acceso público

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

La solución está en la [sección 7](#7-solución-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Añadir output al módulo `tagged-bucket`

En `modules/tagged-bucket/outputs.tf`:

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

### Paso 2: Propagar en el Root Module

En `outputs.tf`:

```hcl
output "public_access_block" {
  description = "Configuración de bloqueo de acceso público"
  value       = module.bucket.public_access_block
}
```

### Paso 3: Archivo de test

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

### Paso 4: Verificar

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

### Reflexión: outputs como contrato testeable

En vez de usar un data source auxiliar para consultar el estado real, exponemos los atributos de seguridad como **outputs del módulo**. Esto tiene ventajas:

- **Sin módulos auxiliares**: todo se verifica en un solo `run`
- **Contrato explícito**: el output `public_access_block` documenta que el módulo garantiza estas propiedades
- **Reutilizable**: cualquier consumidor del módulo puede verificar programáticamente que el bloqueo está activo
- **Funciona con mock**: el output también está disponible en tests unitarios con `mock_provider`

---

## Verificación final

```bash
# Ejecutar los tests unitarios (sin AWS)
cd labs/lab25/aws
terraform test -filter=tests/unit_naming.tftest.hcl
# Esperado: 0 errors, X tests passed

# Ejecutar los tests de idempotencia
terraform test -filter=tests/idempotency.tftest.hcl
# Esperado: 0 changes pending tras el apply

# Ejecutar todos los tests de integracion
terraform test
# Esperado: All tests passed

# Analisis estatico con checkov
checkov -d . --quiet
```

---

## 8. Limpieza

`terraform test` destruye automáticamente los recursos que crea. **No necesitas hacer limpieza manual** de los tests.

Si desplegaste el Root Module directamente (con `terraform apply`, no con `terraform test`):

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** No destruyas el bucket S3 del lab02.

---

## 9. LocalStack

Los tests unitarios con `mock_provider` **no necesitan LocalStack ni AWS** — funcionan en cualquier entorno.

Para los tests de integración, consulta [localstack/README.md](localstack/README.md).

---

## Buenas prácticas aplicadas

- **Tests unitarios con `mock_provider`**: validar la lógica de naming y tagging sin desplegar recursos reales acelera el ciclo de desarrollo y permite ejecutar los tests en cualquier entorno sin credenciales AWS.
- **Tests de idempotencia**: verificar que un segundo `terraform apply` no produce cambios es la prueba definitiva de que el módulo está correctamente diseñado y no tiene side effects.
- **Filtrado de tests por archivo**: usar `-filter` permite ejecutar solo los tests relevantes durante el desarrollo sin esperar a que corran todos los tests de integración.
- **Análisis estático complementario**: `checkov` y `trivy` detectan problemas de seguridad que los tests funcionales no cubren (cifrado, logging, acceso público).
- **No versionar artefactos generados**: los ZIPs de funciones Lambda y los archivos `.terraform` deben estar en `.gitignore` para mantener el repositorio limpio.
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
