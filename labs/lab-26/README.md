# Laboratorio 26 — Gobernanza, Documentación y Publicación "Lean"

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 6 — Módulos de Terraform](../../modulos/modulo-06/README.md)


## Visión general

Preparar un módulo Terraform para ser consumido por otros equipos con garantías de calidad. Automatizar la generación de documentación con `terraform-docs`, crear un catálogo de ejemplos (`/examples`), configurar hooks de `pre-commit` que bloqueen commits con código sin formatear o documentación desactualizada, y simular la publicación del módulo con un tag de Git semántico (`v1.0.0`) que otros proyectos referencian con `?ref=`.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **terraform-docs** | Herramienta que genera automáticamente tablas de variables, outputs y providers a partir del código HCL. Inyecta el resultado entre marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->` |
| **`.terraform-docs.yml`** | Archivo de configuración que controla el formato, orden y estilo de la documentación generada. Se coloca en la raíz del módulo |
| **Catálogo de ejemplos** | Carpeta `/examples` con subdirectorios que demuestran diferentes formas de usar el módulo. Cada ejemplo es un Root Module independiente con su propio `main.tf` |
| **pre-commit** | Framework que ejecuta hooks antes de cada `git commit`. Si algún hook falla, el commit se rechaza hasta que se corrija el problema |
| **Versionado semántico** | Convención `MAJOR.MINOR.PATCH` (ej: `v1.2.3`). MAJOR = cambio incompatible, MINOR = nueva funcionalidad compatible, PATCH = corrección de bug |
| **Git tag** | Etiqueta inmutable que marca un commit específico. Terraform puede referenciar un módulo en un commit concreto con `source = "git::url?ref=v1.0.0"` |
| **`?ref=`** | Parámetro en el source de Git que fija la versión. Sin él, Terraform usa la rama por defecto, que puede cambiar en cualquier momento |

## Comparativa: Distribucion de modulos

| Método | Ventajas | Desventajas | Caso de uso |
|---|---|---|---|
| Ruta local (`./modules/`) | Simple, sin setup | No versionable, solo un repo | Desarrollo, monorepo |
| Git tag (`?ref=v1.0.0`) | Versionado, gratis, privado | Init más lento, sin search | Empresas, repos privados |
| Terraform Registry | Search, docs auto, versionado | Solo GitHub público (o TFE/HCP) | Open source, HCP Terraform |
| S3/GCS bucket | Control total, privado | Manual, sin versionado integrado | Casos especiales |

## Prerrequisitos

- Git configurado
- Terraform >= 1.5
- AWS CLI configurado con credenciales válidas (para los ejemplos)
- Herramientas opcionales (se instalan durante el lab):
  - `terraform-docs` >= 0.18
  - `pre-commit` >= 3.0

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"
```

## Estructura del proyecto

```
lab26/
├── README.md                                          <- Esta guía
├── aws/
│   ├── .pre-commit-config.yaml                        <- Hooks de pre-commit
│   ├── consumer/
│   │   ├── aws.s3.tfbackend                           <- Parametros del backend S3 (sin bucket)
│   │   └── main.tf                                    <- Proyecto que consume el módulo via Git
│   └── modules/
│       └── secure-bucket/                             <- El módulo a publicar
│           ├── main.tf                                <- Bucket + bloqueo + versionado + cifrado + logging
│           ├── variables.tf                           <- Entradas documentadas
│           ├── outputs.tf                             <- Salidas documentadas
│           ├── README.md                              <- Docs con marcadores terraform-docs
│           ├── .terraform-docs.yml                    <- Configuración de terraform-docs
│           └── examples/
│               ├── basic/
│               │   ├── main.tf                        <- Mínima configuración
│               │   └── README.md
│               └── advanced/
│                   ├── main.tf                        <- Con cifrado y logging
│                   └── README.md
└── localstack/
    └── README.md                                      <- Notas sobre LocalStack
```

## 1. Análisis del código

### 1.1 Arquitectura del laboratorio

```
┌────────────────────────────────────────────────────────────────────┐
│                    Ciclo de gobernanza                             │
│                                                                    │
│  1. Desarrollar ──► modules/secure-bucket/                         │
│  2. Documentar  ──► terraform-docs (auto-genera tablas)            │
│  3. Validar     ──► pre-commit (fmt + docs + trivy)                │
│  4. Publicar    ──► git tag v1.0.0                                 │
│  5. Consumir    ──► source = "git::...?ref=v1.0.0"                 │
│                                                                    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │   examples/  │    │  .terraform  │    │ .pre-commit  │          │
│  │   basic/     │    │  -docs.yml   │    │ -config.yaml │          │
│  │   advanced/  │    │              │    │              │          │
│  └──────────────┘    └──────────────┘    └──────────────┘          │
└────────────────────────────────────────────────────────────────────┘
```

### 1.2 El módulo: `secure-bucket`

El módulo tiene todas las buenas prácticas de seguridad activables:

```hcl
# modules/secure-bucket/main.tf

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags = merge(local.effective_tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true    # Siempre activado
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count  = var.enable_encryption ? 1 : 0   # Condicional
  bucket = aws_s3_bucket.this.id
  # ...
}

resource "aws_s3_bucket_logging" "this" {
  count  = var.enable_access_logging ? 1 : 0   # Condicional
  bucket = aws_s3_bucket.this.id
  # ...
}
```

El bloqueo de acceso público está **siempre activado** (no configurable). El cifrado, versionado y logging son opcionales con valores por defecto seguros.

### 1.3 Documentación automatizada — `terraform-docs`

El README del módulo tiene marcadores especiales:

```markdown
<!-- BEGIN_TF_DOCS -->
<!-- terraform-docs inyecta aqui las tablas de variables y outputs -->
<!-- END_TF_DOCS -->
```

Al ejecutar `terraform-docs`, el contenido entre estos marcadores se reemplaza automáticamente con tablas generadas del código:

```bash
terraform-docs markdown table --output-file README.md --output-mode inject modules/secure-bucket/
```

Resultado inyectado (ejemplo):

```markdown
| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| bucket_name | Nombre del bucket S3... | `string` | n/a | yes |
| environment | Entorno de despliegue... | `string` | `"lab"` | no |
| enable_versioning | Habilitar versionado... | `bool` | `true` | no |
```

El archivo `.terraform-docs.yml` controla el formato:

```yaml
formatter: "markdown table"

output:
  file: "README.md"
  mode: "inject"      # Inyecta entre BEGIN/END_TF_DOCS

sort:
  enabled: true
  by: "required"       # Variables requeridas primero
```

**¿Por qué `mode: inject`?** Permite mantener contenido manual (ejemplos de uso, explicaciones) fuera de los marcadores, mientras que las tablas se regeneran automáticamente. Si usaras `mode: replace`, perdería todo el contenido manual.

### 1.4 Catálogo de ejemplos

```
examples/
├── basic/         <- "Quiero un bucket, ¿cuál es el mínimo?"
│   ├── main.tf
│   └── README.md
└── advanced/      <- "Quiero todo: cifrado, logging, tags custom"
    ├── main.tf
    └── README.md
```

Cada ejemplo es un Root Module independiente que invoca el módulo con `source = "../../"`:

```hcl
# examples/basic/main.tf
module "bucket" {
  source        = "../../"
  bucket_name   = "example-basic-${data.aws_caller_identity.current.account_id}"
  environment   = "lab"
  force_destroy = true
}
```

Los ejemplos sirven para:
- **Documentación viva**: el código siempre funciona (se puede testear con `terraform test`)
- **Onboarding rápido**: copiar-pegar → funciona
- **Cobertura**: el ejemplo avanzado ejercita todas las opciones del módulo

### 1.5 Pre-commit — Pipeline local

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.3
    hooks:
      - id: terraform_fmt          # ¿Código formateado?
      - id: terraform_validate     # ¿Sintaxis válida?
      - id: terraform_docs         # ¿Docs actualizadas?
      - id: terraform_trivy        # ¿Vulnerabilidades?
```

Flujo al hacer `git commit`:

```
git commit -m "feat: add logging"
  │
  ├─ terraform_fmt ───── ¿Formateado? ──── FAIL → corrige y vuelve a commitear
  ├─ terraform_validate ─ ¿Sintaxis? ──── FAIL → corrige
  ├─ terraform_docs ──── ¿Docs al día? ── FAIL → regenera docs
  └─ terraform_trivy ─── ¿Seguro? ─────── WARN → revisa
  │
  ✓ Commit aceptado
```

Si algún hook falla, el commit se rechaza. El desarrollador debe corregir el problema y volver a intentar. Esto garantiza que **todo commit tiene código formateado, documentación actualizada y sin vulnerabilidades conocidas**.

### 1.6 Versionado semántico y Git tags

```
v1.0.0 ── Release inicial
v1.1.0 ── Nueva funcionalidad (enable_access_logging)
v1.1.1 ── Fix: corregir default de logging_target_prefix
v2.0.0 ── Breaking change: renombrar variable bucket_name → name
```

Reglas:
- **MAJOR** (v1 → v2): cambio incompatible (renombrar variables, eliminar outputs)
- **MINOR** (v1.0 → v1.1): nueva funcionalidad compatible (añadir variable opcional)
- **PATCH** (v1.0.0 → v1.0.1): corrección de bug sin cambiar la interfaz

El consumidor elige la versión con `?ref=`:

```hcl
# Versión fija (recomendado para producción)
source = "git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0"

# Última de la rama (NO recomendado — puede romper)
source = "git::https://github.com/<org>/terraform-aws-secure-bucket.git"
```

---

## 2. Despliegue

### 2.1 Instalar herramientas

**terraform-docs:**

> **Importante:** Ejecuta la descarga desde un directorio temporal (ej: `/tmp`), **no** desde el directorio del módulo. El tar.gz incluye un `README.md` que sobreescribiría el README del módulo.

```bash
# Linux (ejecutar desde /tmp o cualquier directorio temporal)
cd /tmp
curl -sSLo terraform-docs.tar.gz https://terraform-docs.io/dl/v0.19.0/terraform-docs-v0.19.0-linux-amd64.tar.gz
tar -xzf terraform-docs.tar.gz
chmod +x terraform-docs && sudo mv terraform-docs /usr/local/bin/
rm -f terraform-docs.tar.gz README.md LICENSE
cd -

# macOS
brew install terraform-docs
```

**pre-commit:**

```bash
# Linux / macOS (con pip)
pip install pre-commit

# macOS (con brew)
brew install pre-commit
```

Verificar instalación:

```bash
terraform-docs version
# v0.19.0

pre-commit --version
# pre-commit 3.x.x
```

### 2.2 Generar documentación

```bash
cd labs/lab26/aws/modules/secure-bucket

terraform-docs markdown table \
  --output-file README.md \
  --output-mode inject \
  .
```

Verifica que el README del módulo ahora tiene las tablas de variables y outputs entre los marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->`.

### 2.3 Configurar pre-commit

```bash
cd labs/lab26/aws

# Instalar los hooks en el repositorio Git local
pre-commit install
```

### 2.4 Probar el ejemplo básico

```bash
cd modules/secure-bucket/examples/basic

terraform init
terraform apply

terraform output
# bucket_id  = "example-basic-123456789012"
# bucket_arn = "arn:aws:s3:::example-basic-123456789012"

terraform destroy
```

### 2.5 Probar el ejemplo avanzado

```bash
cd ../advanced

terraform init
terraform apply

terraform output
# logs_bucket_id  = "example-adv-logs-123456789012"
# data_bucket_id  = "example-adv-data-123456789012"
# data_versioning = "Enabled"

terraform destroy
```

---

## Verificación final

### 3.1 Verificar terraform-docs

```bash
cd labs/lab26/aws

# Ver el README generado
  cat modules/secure-bucket/README.md
```

Debe contener tablas con todas las variables y outputs entre los marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->`.

### 3.2 Verificar pre-commit

```bash
# Descformatear un archivo intencionalmente
echo "   resource    \"aws_s3_bucket\"    \"test\"   {}" > /tmp/test_fmt.tf
cp /tmp/test_fmt.tf modules/secure-bucket/test_fmt.tf

# Intentar commitear — debe fallar
git add modules/secure-bucket/test_fmt.tf
git commit -m "test: unformatted file"
# terraform_fmt... Failed
# (el commit se rechaza)

# Limpiar
rm modules/secure-bucket/test_fmt.tf
```

### 3.3 Verificar versionado con Git tag

```bash
# Simular la publicación del módulo
cd labs/lab26/aws

# Crear un tag semántico
git tag -a v1.0.0 -m "Release v1.0.0: modulo secure-bucket"

# Ver el tag
git tag -l "v1.*"
# v1.0.0

# Ver detalles
git show v1.0.0
```

### 3.4 Probar el proyecto consumidor

```bash
cd consumer/

BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
terraform apply

terraform output
# bucket_id  = "consumer-app-123456789012"
# bucket_arn = "arn:aws:s3:::consumer-app-123456789012"
# versioning = "Enabled"

terraform destroy
```

> **Nota:** El consumidor usa `source = "../modules/secure-bucket"` (ruta local) porque estamos en un monorepo. En producción, el source sería `"git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0"` y el tag garantizaría la versión.

---

## 4. Reto: Crear un CHANGELOG y simular un release con breaking change

**Situación**: Has publicado `v1.0.0` del módulo. Ahora necesitas añadir una nueva funcionalidad (variable `expiration_days`) y luego hacer un breaking change (renombrar `bucket_name` a `name`). Quieres seguir el flujo correcto de versionado semántico.

**Tu objetivo**:

1. Crear un archivo `CHANGELOG.md` en la raíz del módulo con la estructura estándar de [Keep a Changelog](https://keepachangelog.com)
2. Añadir `expiration_days` como variable opcional al módulo → esto es `v1.1.0` (MINOR: nueva funcionalidad compatible)
3. Crear el tag `v1.1.0` con el mensaje apropiado
4. Renombrar `bucket_name` a `name` con un bloque `moved {}` en el módulo → esto es `v2.0.0` (MAJOR: cambio incompatible)
5. Actualizar el CHANGELOG con ambas versiones
6. Crear el tag `v2.0.0`

**Pistas**:
- El CHANGELOG tiene secciones: `## [Unreleased]`, `## [1.1.0] - 2026-04-04`, etc.
- Cada sección tiene categorías: `### Added`, `### Changed`, `### Removed`, `### Fixed`
- El tag `v1.1.0` se crea antes de hacer el breaking change
- El `moved {}` en variables no existe — el renombrado de variable requiere que el consumidor cambie su código (por eso es MAJOR)
- `git tag -a v1.1.0 -m "feat: add expiration_days"` crea un tag anotado

La solución está en la [sección 5](#5-solución-del-reto).

---

## 5. Solución del Reto

### Paso 1: Crear CHANGELOG.md

En `modules/secure-bucket/CHANGELOG.md`:

```markdown
# Changelog

Todos los cambios relevantes de este módulo se documentan aquí.
El formato sigue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Este proyecto usa [Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

## [2.0.0] - 2026-04-04

### Changed
- **BREAKING**: Renombrada variable `bucket_name` → `name` para alinearse
  con la convención de otros módulos corporativos.

### Migration
- Actualizar todas las invocaciones: `bucket_name = "..."` → `name = "..."`.
- El recurso S3 NO se destruye (misma configuración, solo cambia el nombre
  de la variable).

## [1.1.0] - 2026-04-04

### Added
- Variable `expiration_days` para configurar expiración automática de objetos.
  Default: `0` (desactivado).

## [1.0.0] - 2026-04-04

### Added
- Release inicial del módulo `secure-bucket`.
- Bucket S3 con bloqueo de acceso público (siempre activado).
- Versionado configurable (`enable_versioning`).
- Cifrado SSE-S3 configurable (`enable_encryption`).
- Logging de acceso configurable (`enable_access_logging`).
- Catálogo de ejemplos: `basic/` y `advanced/`.
- Documentación automatizada con terraform-docs.
```

### Paso 2: Añadir `expiration_days` (v1.1.0)

En `modules/secure-bucket/variables.tf`:

```hcl
variable "expiration_days" {
  type        = number
  description = "Dias tras los cuales los objetos expiran automaticamente. 0 = desactivado."
  default     = 0
}
```

En `modules/secure-bucket/main.tf`:

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.expiration_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "auto-expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.expiration_days
    }
  }
}
```

### Paso 3: Tag v1.1.0

```bash
git add modules/secure-bucket/
git commit -m "feat: add expiration_days to secure-bucket module"
git tag -a v1.1.0 -m "feat: add expiration_days variable (optional, default 0)"
```

### Paso 4: Renombrar `bucket_name` → `name` (v2.0.0)

En `modules/secure-bucket/variables.tf`, renombrar la variable **y actualizar la referencia en la validación**:

```hcl
variable "name" {    # Antes: variable "bucket_name"
  type        = string
  description = "Nombre del bucket S3. Debe ser globalmente unico."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name))  # Antes: var.bucket_name
    error_message = "El nombre del bucket solo puede contener minusculas, numeros, puntos y guiones (3-63 caracteres)."
  }
}
```

Actualizar todas las referencias en `main.tf` y `outputs.tf`:

```hcl
# main.tf
resource "aws_s3_bucket" "this" {
  bucket = var.name    # Antes: var.bucket_name
  tags   = merge(local.effective_tags, { Name = var.name })  # Antes: var.bucket_name
  # ...
}
```

Actualizar los ejemplos para que usen el nuevo nombre de variable:

```hcl
# examples/basic/main.tf
module "bucket" {
  source = "../../"
  name          = "example-basic-${data.aws_caller_identity.current.account_id}"  # Antes: bucket_name
  environment   = "lab"
  force_destroy = true
}

# examples/advanced/main.tf
module "logs_bucket" {
  source = "../../"
  name              = "example-adv-logs-${local.account_id}"  # Antes: bucket_name
  # ...
}

module "data_bucket" {
  source = "../../"
  name                  = "example-adv-data-${local.account_id}"  # Antes: bucket_name
  # ...
}
```

> **Nota:** `moved {}` no aplica a variables — solo a recursos y módulos. Renombrar una variable siempre es un breaking change porque el consumidor debe actualizar su código.

### Paso 5: Tag v2.0.0

```bash
git add modules/secure-bucket/
git commit -m 'feat!: rename bucket_name to name (BREAKING CHANGE)'
git tag -a v2.0.0 -m "BREAKING: rename bucket_name to name"
```

### Paso 6: Verificar tags

```bash
git tag -l "v*"
# v1.0.0
# v1.1.0
# v2.0.0

# Ver el historial con tags
git log --oneline --decorate
```

### Reflexión: ¿cuándo subir cada número?

| Cambio | Ejemplo | Versión |
|---|---|---|
| Nueva variable opcional | `expiration_days` con default | MINOR (v1.1.0) |
| Nuevo output | `versioning_status` | MINOR |
| Fix en la lógica de tags | Corregir merge duplicado | PATCH (v1.1.1) |
| Renombrar variable | `bucket_name` → `name` | MAJOR (v2.0.0) |
| Eliminar un output | Quitar `bucket_domain_name` | MAJOR |
| Cambiar default de variable | `enable_versioning: true → false` | MAJOR (cambia comportamiento) |

Regla simple: **si el consumidor tiene que cambiar su código, es MAJOR**.

---

## 6. Reto 2: Automatizar la validación de ejemplos con `terraform test`

**Situación**: Los ejemplos en `/examples` son documentación viva, pero nadie verifica que sigan funcionando cuando el módulo cambia. Quieres crear un test que valide automáticamente ambos ejemplos.

**Tu objetivo**:

1. Crear un directorio `tests/` dentro del módulo
2. Crear un test `examples_basic.tftest.hcl` que use `module { source = "./examples/basic" }` para ejecutar el ejemplo básico
3. Crear un test `examples_advanced.tftest.hcl` que ejecute el ejemplo avanzado
4. Verificar que ambos pasan con `terraform test`

**Pistas**:
- El `run` puede usar `module { source = "./examples/basic" }` para ejecutar un ejemplo como si fuera un módulo
- Los outputs del ejemplo están disponibles como `output.<name>` dentro del `run`
- Usa `command = apply` para crear los recursos reales (se destruyen automáticamente)
- Los ejemplos ya tienen `force_destroy = true` para facilitar la limpieza

La solución está en la [sección 7](#7-solución-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Crear los archivos de test

En `modules/secure-bucket/tests/examples_basic.tftest.hcl`:

```hcl
# Test que ejecuta el ejemplo basico para verificar que funciona

run "basic_example_works" {
  command = apply

  module {
    source = "./examples/basic"
  }

  assert {
    condition     = output.bucket_id != ""
    error_message = "El ejemplo basico debe crear un bucket"
  }

  assert {
    condition     = output.bucket_arn != ""
    error_message = "El ejemplo basico debe producir un ARN"
  }
}
```

En `modules/secure-bucket/tests/examples_advanced.tftest.hcl`:

```hcl
# Test que ejecuta el ejemplo avanzado para verificar que funciona

run "advanced_example_works" {
  command = apply

  module {
    source = "./examples/advanced"
  }

  assert {
    condition     = output.logs_bucket_id != ""
    error_message = "El ejemplo avanzado debe crear el bucket de logs"
  }

  assert {
    condition     = output.data_bucket_id != ""
    error_message = "El ejemplo avanzado debe crear el bucket de datos"
  }

  assert {
    condition     = output.data_versioning == "Enabled"
    error_message = "El bucket de datos debe tener versionado activado"
  }
}
```

### Paso 2: Ejecutar

```bash
cd modules/secure-bucket

terraform init
terraform test
```

```
tests/examples_advanced.tftest.hcl... in progress
  run "advanced_example_works"... pass
tests/examples_advanced.tftest.hcl... tearing down
tests/examples_advanced.tftest.hcl... pass

tests/examples_basic.tftest.hcl... in progress
  run "basic_example_works"... pass
tests/examples_basic.tftest.hcl... tearing down
tests/examples_basic.tftest.hcl... pass

Success! 2 passed, 0 failed.
```

### Reflexión: ejemplos como contrato

Al testear los ejemplos automáticamente, se convierten en un **contrato**: si el módulo cambia de forma que rompe un ejemplo, el test falla antes de publicar la nueva versión. Esto es especialmente útil con el flujo de pre-commit:

```
git commit
  ├─ terraform_fmt
  ├─ terraform_validate
  ├─ terraform_docs
  └─ terraform test (valida que los ejemplos siguen funcionando)
```

Cada ejemplo cubierto por un test es una garantía menos de que un consumidor va a encontrarse con un módulo roto.

---

## 8. Limpieza

Si desplegaste los ejemplos manualmente:

```bash
# Desde cada directorio de ejemplo
cd modules/secure-bucket/examples/basic && terraform destroy
cd ../advanced && terraform destroy

# Desde el consumidor
cd ../../consumer && terraform destroy
```

Si solo ejecutaste `terraform test`, la limpieza es automática.

Para eliminar los tags (si no quieres conservarlos):

```bash
git tag -d v1.0.0
git tag -d v1.1.0
git tag -d v2.0.0
```

---

## 9. LocalStack

Los ejemplos `basic` y `advanced` funcionan con LocalStack (S3 está completamente soportado en Community). Los hooks de pre-commit y terraform-docs no necesitan ningún proveedor.

Consulta [localstack/README.md](localstack/README.md) para más detalles.

---

## Buenas prácticas aplicadas

- **`terraform-docs` como fuente de verdad**: generar documentación automáticamente desde el código evita que el README quede desincronizado con las variables y outputs reales del módulo.
- **Hooks de pre-commit para calidad continua**: bloquear commits con código sin formatear o documentación desactualizada garantiza que el repositorio siempre esté en un estado publicable.
- **Versionado semántico en módulos**: usar tags `vMAJOR.MINOR.PATCH` permite a los consumidores fijar la versión exacta y actualizar de forma controlada, evitando cambios inesperados.
- **Catálogo de ejemplos (`/examples`)**: los ejemplos `basic` y `advanced` sirven como documentación ejecutable y como tests de integración de facto.
- **Separación entre módulo y consumidor**: el directorio `consumer/` demuestra el patrón real de uso sin contaminar el módulo con configuración específica del entorno.
- **CHANGELOG como contrato con los consumidores**: documentar los breaking changes en un CHANGELOG semántico permite a los equipos decidir cuándo migrar y qué cambios requiere la migración.

---

## Recursos

- [terraform-docs: Instalación y uso](https://terraform-docs.io/)
- [terraform-docs: Configuración `.terraform-docs.yml`](https://terraform-docs.io/user-guide/configuration/)
- [pre-commit: Framework](https://pre-commit.com/)
- [pre-commit-terraform: Hooks disponibles](https://github.com/antonbabenko/pre-commit-terraform)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- [Versionado Semántico](https://semver.org/lang/es/)
- [Terraform: Module Sources — Git](https://developer.hashicorp.com/terraform/language/modules/sources#github)
- [Terraform: Publishing Modules](https://developer.hashicorp.com/terraform/registry/modules/publish)
