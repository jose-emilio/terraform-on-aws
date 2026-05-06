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

## Comparativa: Distribución de módulos

| Método | Ventajas | Desventajas | Caso de uso |
|---|---|---|---|
| Ruta local (`./modules/`) | Simple, sin setup | No versionable, solo un repo | Desarrollo, monorepo |
| Git tag (`?ref=v1.0.0`) | Versionado, gratis, privado | Init más lento, sin search | Empresas, repos privados |
| Terraform Registry | Search, docs auto, versionado | Solo GitHub público (o TFE/HCP) | Open source, HCP Terraform |
| S3/GCS bucket | Control total, privado | Manual, sin versionado integrado | Casos especiales |

## Prerrequisitos

- Git configurado
- Laboratorio 02 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- **Terraform >= 1.10** (necesario para `use_lockfile` en el backend S3 del consumer)
- AWS CLI configurado con credenciales válidas (para los ejemplos)
- Herramientas opcionales (se instalan durante el lab):
  - `terraform-docs` >= 0.23
  - `pre-commit` >= 3.0

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"

# Verificar versión de Terraform
terraform version
# Terraform v1.10.0+ requerido (backend `use_lockfile`)
```

## Estructura del proyecto

```
lab-26/
├── README.md                                          <- Esta guía
├── aws/
│   ├── .pre-commit-config.yaml                        <- Hooks de pre-commit
│   ├── consumer/
│   │   ├── aws.s3.tfbackend                           <- Parámetros del backend S3 (sin bucket)
│   │   └── main.tf                                    <- Proyecto que consume el módulo vía Git
│   └── modules/
│       └── secure-bucket/                             <- El módulo a publicar
│           ├── main.tf                                <- Bucket + bloqueo + versionado + cifrado + logging
│           ├── variables.tf                           <- Entradas documentadas
│           ├── outputs.tf                             <- Salidas documentadas
│           ├── README.md                              <- Docs con marcadores terraform-docs
│           ├── .terraform-docs.yml                    <- Configuración de terraform-docs
│           ├── .trivyignore                           <- Hallazgos Trivy suprimidos con justificación
│           └── examples/
│               ├── basic/
│               │   ├── main.tf                        <- Mínima configuración
│               │   ├── README.md
│               │   └── .trivyignore                   <- (replicado del módulo, leído por Trivy en este CWD)
│               └── advanced/
│                   ├── main.tf                        <- Con cifrado y logging
│                   ├── README.md
│                   └── .trivyignore                   <- (replicado del módulo, leído por Trivy en este CWD)
└── localstack/
    └── README.md                                      <- Notas sobre LocalStack
```

## Análisis del código

### Arquitectura del laboratorio

```
┌────────────────────────────────────────────────────────────────────┐
│                    Ciclo de gobernanza                             │
│                                                                    │
│  1. Desarrollar ──► modules/secure-bucket/                         │
│  2. Documentar  ──► terraform-docs (auto-genera tablas)            │
│  3. Validar     ──► pre-commit (fmt + validate + docs + trivy)     │
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

### El módulo: `secure-bucket`

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

### Documentación automatizada — `terraform-docs`

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

### Catálogo de ejemplos

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

### Pre-commit — Pipeline local

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

### Versionado semántico y Git tags

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

## Despliegue

### Instalar herramientas

**terraform-docs:**

```bash
# macOS (Homebrew, recomendado)
brew install terraform-docs
```

```bash
# Linux con Homebrew (linuxbrew)
brew install terraform-docs
```

```bash
# Linux sin gestor de paquetes — descarga del binario oficial
# Importante: ejecútalo desde un directorio temporal (/tmp). El tar.gz incluye
# un README.md que, extraído en otra ubicación, sobreescribiría archivos.
TFDOCS_VERSION=v0.23.0
cd /tmp
curl -sSLo terraform-docs.tar.gz \
  "https://terraform-docs.io/dl/${TFDOCS_VERSION}/terraform-docs-${TFDOCS_VERSION}-linux-amd64.tar.gz"
tar -xzf terraform-docs.tar.gz
chmod +x terraform-docs && sudo mv terraform-docs /usr/local/bin/
rm -f terraform-docs.tar.gz README.md LICENSE
cd -
```

Otras opciones: `go install github.com/terraform-docs/terraform-docs@v0.23.0` si tienes Go, o el paquete oficial vía [terraform-docs.io](https://terraform-docs.io/user-guide/installation/).

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
# v0.23.0

pre-commit --version
# pre-commit 3.x.x
```

### Generar documentación

```bash
cd labs/lab-26/aws/modules/secure-bucket

terraform-docs markdown table \
  --output-file README.md \
  --output-mode inject \
  .
```

Verifica que el README del módulo ahora tiene las tablas de variables y outputs entre los marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->`.

### Configurar pre-commit

`pre-commit install` engancha los hooks al repositorio Git **donde se encuentre el `cd`**. Si lo ejecutas dentro de `labs/lab-26/aws`, Git localiza el repo padre (el del curso) y los hooks dispararían en cada commit a cualquier lab — no es lo que queremos.

Para simular el escenario real (un repositorio independiente del módulo `secure-bucket`), creamos un sandbox aislado en `/tmp` y copiamos solo lo necesario:

```bash
# Desde labs/lab-26/aws
SANDBOX=/tmp/secure-bucket-sandbox
rm -rf "$SANDBOX" && mkdir -p "$SANDBOX"

# Copiamos el módulo, los ejemplos y el .pre-commit-config.yaml
cp -r modules "$SANDBOX/"
cp .pre-commit-config.yaml "$SANDBOX/"

cd "$SANDBOX"

# Inicializamos un repo Git nuevo (simula el repo del módulo publicable)
git init -q -b main
git add .
git commit -q -m "chore: initial import of secure-bucket"

# Instalamos los hooks de pre-commit
pre-commit install

# Pre-descargamos los entornos de los hooks (la primera ejecución es lenta)
pre-commit run --all-files
```

La primera ejecución típicamente falla por dos motivos esperables:

**1) `terraform_docs` Failed — "files were modified by this hook"**

El hook ha regenerado las tablas dentro del `README.md` del módulo (los marcadores `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` se rellenan). Esto es deseable: el hook protege contra docs desincronizadas. Basta con re-staging y volver a ejecutar:

```bash
git add modules/secure-bucket/README.md
pre-commit run --all-files
```

**2) `terraform_trivy` Failed — `AWS-0132` (HIGH)**

Trivy detecta que el bucket no usa `SSE-KMS` con clave gestionada por el cliente. Es un hallazgo real: el módulo cifra con `SSE-S3` (AES256). En gobernanza hay dos respuestas posibles:

- **Arreglar**: añadir `var.kms_key_arn` y permitir SSE-KMS condicional. Mejora futura, fuera del alcance del lab.
- **Suprimir conscientemente**: documentar la decisión en un `.trivyignore` con justificación. Es lo que se hace aquí.

El módulo incluye un archivo `.trivyignore` con el suprimido y la razón:

```bash
cat modules/secure-bucket/.trivyignore
# AWS-0132   ← suprimido con justificación al lado
```

> **Importante — ubicación del `.trivyignore`:** Trivy busca este archivo **solo en el directorio actual de trabajo** (no recursivamente en padres). El hook `terraform_trivy` lanza Trivy una vez por cada directorio con `.tf`, así que necesitamos copias del archivo en los tres directorios donde Trivy entra:
>
> ```
> modules/secure-bucket/.trivyignore                     ← scan #1 (módulo)
> modules/secure-bucket/examples/basic/.trivyignore      ← scan #2
> modules/secure-bucket/examples/advanced/.trivyignore   ← scan #3
> ```
>
> Las copias en los ejemplos son necesarias porque cuando Trivy escanea `examples/basic/` sigue el `module { source = "../../" }` y vuelve a reportar `AWS-0132` en `../../main.tf` desde un CWD distinto. La alternativa (un único `.trivyignore` y `--args=--ignorefile=...` en el hook) requiere scripting porque el CWD cambia en cada invocación.

Tras la segunda ejecución todos los hooks pasan:

```bash
pre-commit run --all-files
# Terraform fmt............................................Passed
# Terraform validate.......................................Passed
# Terraform docs...........................................Passed
# Terraform validate with trivy............................Passed
```

> **Nota:** Si Trivy imprime *"Unable to derive number of available CPU cores"*, es un aviso inocuo (Trivy no detecta el límite de CPU del host). Puedes silenciarlo añadiendo `--hook-config=--parallelism-ci-cpu-cores=N` (donde `N` = nº de cores) al hook `terraform_trivy` del `.pre-commit-config.yaml`.

A partir de aquí, todos los `git commit` posteriores en el sandbox pasarán por los hooks. Las pruebas de "Verificar pre-commit" más abajo (commit con archivo desformateado) se ejecutan dentro de este sandbox. Cuando termines puedes borrarlo con `rm -rf /tmp/secure-bucket-sandbox`.

### Probar el ejemplo básico

```bash
cd modules/secure-bucket/examples/basic

terraform init
terraform apply

terraform output
# bucket_id  = "example-basic-123456789012"
# bucket_arn = "arn:aws:s3:::example-basic-123456789012"

terraform destroy
```

### Probar el ejemplo avanzado

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

### Verificar terraform-docs

```bash
# Ver el README generado
more ../../README.md
```

Debe contener tablas con todas las variables y outputs entre los marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->`.

### Verificar pre-commit

Dentro del sandbox creado en "Configurar pre-commit" (`/tmp/secure-bucket-sandbox`):

```bash
cd /tmp/secure-bucket-sandbox

# Crear un archivo .tf desformateado intencionalmente
printf '   resource    "aws_s3_bucket"    "test"   {}\n' \
  > modules/secure-bucket/test_fmt.tf

# Intentar commitear — debe fallar
git add modules/secure-bucket/test_fmt.tf
git commit -m "test: unformatted file"
```

Salida esperada:

```
Terraform fmt............................................Failed
- hook id: terraform_fmt
- files were modified by this hook
Terraform validate.......................................Passed
Terraform docs...........................................Failed
- hook id: terraform_docs
- files were modified by this hook
Terraform validate with trivy............................Failed
- hook id: terraform_trivy
- exit code: 1

main.tf (terraform)
Tests: 12 (SUCCESSES: 0, FAILURES: 12)
Failures: 12 (HIGH: 12, CRITICAL: 0)

AWS-0086 (HIGH): No public access block so not blocking public acls
AWS-0087 (HIGH): No public access block so not blocking public policies
AWS-0091 (HIGH): No public access block so not blocking public acls (ignore)
AWS-0093 (HIGH): No public access block so not restricting public buckets
```

Lo que ocurre:

- **`terraform_fmt` Failed**: el archivo tiene espaciado incorrecto. El hook lo **reformatea** (modifica el archivo) y reporta fallo para que vuelvas a hacer staging del cambio.
- **`terraform_validate` Passed**: la sintaxis HCL del recurso vacío es válida (`resource "aws_s3_bucket" "test" {}` es legal aunque inútil).
- **`terraform_docs` Failed**: al añadir un nuevo recurso `aws_s3_bucket.test`, terraform-docs detecta que la tabla del README del módulo ya no está sincronizada y la regenera.
- **`terraform_trivy` Failed**: el recurso vacío introduce 4 misconfigs nuevos (`AWS-0086`, `AWS-0087`, `AWS-0091`, `AWS-0093`) porque **no tiene su `aws_s3_bucket_public_access_block` asociado**. Cada misconfig se reporta tres veces (una por cada invocación de Trivy: módulo + 2 ejemplos), de ahí los 12 failures totales.

> **Lo que demuestra esto:** un commit con un solo recurso S3 sin proteger es exactamente el tipo de regresión de seguridad que el hook está pensado para frenar. En el módulo "real" cada bucket viene con su `public_access_block` adyacente; el recurso de prueba no, y Trivy lo detecta. Es el caso de uso canónico de pre-commit + Trivy.

El commit queda rechazado. Limpia el archivo y vuelve al estado anterior:

```bash
rm modules/secure-bucket/test_fmt.tf

# Restaurar el README del módulo (terraform_docs lo modificó)
git checkout -- modules/secure-bucket/README.md

# Quitar el archivo del staging
git reset HEAD modules/secure-bucket/test_fmt.tf 2>/dev/null || true
```

> **Lección clave:** un solo archivo desformateado dispara una cascada de validaciones. El commit se rechaza no porque alguno sea "más importante" que otro, sino porque **cualquier hook que modifique archivos** falla por diseño — la idea es forzarte a revisar y re-añadir los cambios al staging antes de commitear.

### Verificar versionado con Git tag

Seguimos en el sandbox (`/tmp/secure-bucket-sandbox`), que es el repo que representa al módulo publicable:

```bash
cd /tmp/secure-bucket-sandbox

# Crear un tag semántico
git tag -a v1.0.0 -m "Release v1.0.0: modulo secure-bucket"

# Ver el tag
git tag -l "v1.*"
# v1.0.0

# Ver detalles
git show v1.0.0
```

### Probar el proyecto consumidor consumiendo el módulo por tag

El consumer vive en el repo del curso, **no en el sandbox**. El objetivo de este paso es cerrar el ciclo de gobernanza: ahora que el sandbox tiene `v1.0.0` etiquetado, el consumer debe **fetchear el módulo por tag** desde el sandbox — exactamente como lo haría en producción contra GitHub.

Para esa demostración usamos el protocolo `git::file://` de Terraform (cualquier repo Git local sirve como remoto):

#### Paso 1: Apuntar el consumer al sandbox por tag

Edita `aws/consumer/main.tf` y cambia el `source` del módulo:

```hcl
module "app_bucket" {
  # Antes (desarrollo en monorepo):
  # source = "../modules/secure-bucket"

  # Ahora (consumiendo el módulo publicado en el sandbox):
  source = "git::file:///tmp/secure-bucket-sandbox//modules/secure-bucket?ref=v1.0.0"

  bucket_name       = "consumer-app-${data.aws_caller_identity.current.account_id}"
  # ... (el resto igual)
}
```

> **Sintaxis:** la doble barra `//` separa la URL del repo de la subruta dentro del repo. El sandbox es un repo Git cuyo subdirectorio `modules/secure-bucket/` es el módulo. `?ref=v1.0.0` fija el tag.

#### Paso 2: Init + apply

```bash
cd ~/terraform-on-aws/labs/lab-26/aws/consumer
# (o la ruta donde tengas clonado el curso)

BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# -upgrade fuerza a refetchear el módulo (necesario si ya hiciste init antes con la ruta local)
terraform init -upgrade \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

En la salida de `init` verás algo como:

```
Initializing modules...
Downloading git::file:///tmp/secure-bucket-sandbox?ref=v1.0.0 for app_bucket...
- app_bucket in .terraform/modules/app_bucket/modules/secure-bucket
```

Esto confirma que Terraform clonó el sandbox y se posicionó en el commit del tag `v1.0.0`.

```bash
terraform apply

terraform output
# bucket_id  = "consumer-app-123456789012"
# bucket_arn = "arn:aws:s3:::consumer-app-123456789012"
# versioning = "Enabled"

terraform destroy
```

#### Paso 3: Restaurar el consumer al modo monorepo

Tras la prueba, devuelve el `source` a la ruta local para no romper el flujo del Reto (que sigue editando los archivos del repo del curso) y para que el siguiente que abra el lab no se encuentre el `git::file://` apuntando a un sandbox que ya no existe:

```bash
cd ~/terraform-on-aws/labs/lab-26/aws/consumer
git checkout -- main.tf
```

> **Por qué este paso es importante:** sin él, el tag `v1.0.0` creado en "Verificar versionado con Git tag" sería puro ceremonial — nunca se usa. Con él, queda demostrada la cadena **publicar → versionar → consumir por `?ref=`**, que es justamente el punto del lab. En un escenario real, `git::file:///tmp/...` se sustituye por `git::https://github.com/<org>/terraform-aws-secure-bucket.git?ref=v1.0.0` y todo lo demás funciona idéntico.

---

## Retos

### Reto 1 — Crear un CHANGELOG y simular un release con breaking change

**Situación**: Has publicado `v1.0.0` del módulo en el sandbox (paso "Verificar versionado con Git tag"). Ahora, como mantenedor del módulo, necesitas añadir una nueva funcionalidad (variable `expiration_days`) y luego hacer un breaking change (renombrar `bucket_name` a `name`). Quieres seguir el flujo correcto de versionado semántico.

> **Dónde se hace el reto:** **todas las modificaciones del módulo van al sandbox** (`/tmp/secure-bucket-sandbox`), no al repo del curso. El sandbox representa el repo del módulo publicable; los tags, commits y CHANGELOG viven allí. El repo del curso queda intacto como "estado inicial v1.0.0" — esto evita contaminar tags del monorepo y refleja el flujo real (un equipo de plataforma mantiene el módulo, otros equipos lo consumen). La migración del consumer (Paso 6 de este reto) sí toca el repo del curso, porque el consumer vive ahí.

**Tu objetivo**:

1. Crear un archivo `CHANGELOG.md` en la raíz del módulo con la estructura estándar de [Keep a Changelog](https://keepachangelog.com)
2. Añadir `expiration_days` como variable opcional al módulo → esto es `v1.1.0` (MINOR: nueva funcionalidad compatible)
3. Crear el tag `v1.1.0` con el mensaje apropiado
4. Renombrar `bucket_name` a `name` con un bloque `moved {}` en el módulo → esto es `v2.0.0` (MAJOR: cambio incompatible)
5. Actualizar el CHANGELOG con ambas versiones
6. Crear el tag `v2.0.0` y migrar el consumer del repo del curso al nuevo tag

**Pistas**:
- El CHANGELOG tiene secciones: `## [Unreleased]`, `## [1.1.0] - 2026-04-04`, etc.
- Cada sección tiene categorías: `### Added`, `### Changed`, `### Removed`, `### Fixed`
- El tag `v1.1.0` se crea antes de hacer el breaking change
- El `moved {}` en variables no existe — el renombrado de variable requiere que el consumidor cambie su código (por eso es MAJOR)
- `git tag -a v1.1.0 -m "feat: add expiration_days"` crea un tag anotado

### Reto 2 — Automatizar la validación de ejemplos con `terraform test`

**Situación**: Los ejemplos en `/examples` son documentación viva, pero nadie verifica que sigan funcionando cuando el módulo cambia. Quieres crear un test que valide automáticamente ambos ejemplos.

> **Dónde se hace este reto:** igual que el Reto 1, **dentro del sandbox** (`/tmp/secure-bucket-sandbox`). Los tests son un artefacto del repo del módulo: validan su contrato y viajan con él en cada release. Mantenerlos en el sandbox conserva el "rol de mantenedor" iniciado en el Reto 1.

**Tu objetivo**:

1. Crear un directorio `tests/` dentro del módulo (en el sandbox)
2. Crear un test `examples_basic.tftest.hcl` que use `module { source = "./examples/basic" }` para ejecutar el ejemplo básico
3. Crear un test `examples_advanced.tftest.hcl` que ejecute el ejemplo avanzado
4. Verificar que ambos pasan con `terraform test`

**Pistas**:
- El `run` puede usar `module { source = "./examples/basic" }` para ejecutar un ejemplo como si fuera un módulo
- Los outputs del ejemplo están disponibles como `output.<name>` dentro del `run`
- Usa `command = apply` para crear los recursos reales (se destruyen automáticamente)
- Los ejemplos ya tienen `force_destroy = true` para facilitar la limpieza

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Crear un CHANGELOG y simular un release con breaking change</strong></summary>

### Solución al Reto 1 — Crear un CHANGELOG y simular un release con breaking change

> Todos los pasos del 1 al 5 se ejecutan **dentro del sandbox** (`cd /tmp/secure-bucket-sandbox`). Solo el paso 6 (migración del consumer) toca el repo del curso.

#### Paso 1: Crear CHANGELOG.md



```bash
cd /tmp/secure-bucket-sandbox
```

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

#### Paso 2: Añadir `expiration_days` (v1.1.0)

En `modules/secure-bucket/variables.tf`:

```hcl
variable "expiration_days" {
  type        = number
  description = "Días tras los cuales los objetos expiran automáticamente. 0 = desactivado."
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

#### Paso 3: Tag v1.1.0

Sigues en el sandbox. El primer `git commit` casi seguro fallará en `terraform_docs` porque la nueva variable `expiration_days` aún no aparece en el bloque auto-generado del `README.md`. Es el flujo normal "intento 1 falla → re-staging → intento 2 pasa":

**Intento 1 — falla en `terraform_docs`:**

```bash
git add modules/secure-bucket/
git commit -m "feat: add expiration_days to secure-bucket module"
# ...
# Terraform docs..............................Failed
# - hook id: terraform_docs
# - files were modified by this hook
```

El hook ha **regenerado** `modules/secure-bucket/README.md` añadiendo `expiration_days` a la tabla. Eso es exactamente lo que queremos.

**Intento 2 — añade el README modificado y vuelve a commitear:**

```bash
git add modules/secure-bucket/README.md
git commit -m "feat: add expiration_days to secure-bucket module"
# Terraform fmt...............................Passed
# Terraform validate..........................Passed
# Terraform docs..............................Passed
# Terraform validate with trivy...............Passed
# [main abcdef1] feat: add expiration_days to secure-bucket module
```

Una vez que el commit pasa, etiqueta:

```bash
git tag -a v1.1.0 -m "feat: add expiration_days variable (optional, default 0)"
```

> **Nota:** este patrón "fallo → re-add → re-commit" se repite cada vez que un cambio en `.tf` impacta a la documentación generada. En el Paso 5 (rename de variable) ocurrirá lo mismo.

#### Paso 4: Renombrar `bucket_name` → `name` (v2.0.0)

En `modules/secure-bucket/variables.tf`, renombrar la variable **y actualizar la referencia en la validación**:

```hcl
variable "name" {    # Antes: variable "bucket_name"
  type        = string
  description = "Nombre del bucket S3. Debe ser globalmente único."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name))  # Antes: var.bucket_name
    error_message = "El nombre del bucket solo puede contener minúsculas, números, puntos y guiones (3-63 caracteres)."
  }
}
```

Actualizar las dos referencias en `main.tf` (en `outputs.tf` no hay nada que cambiar — sus outputs referencian al recurso `aws_s3_bucket.this.*`, no a `var.bucket_name`):

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

También los ejemplos de uso del propio README del módulo (`modules/secure-bucket/README.md`, líneas con `bucket_name = ...`) hay que actualizarlos. Cuando el hook `terraform_docs` regenere el bloque entre `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` reflejará el rename en la tabla de variables, pero los ejemplos manuales en español se actualizan a mano.

Verifica dentro del sandbox que no quedan referencias a `bucket_name` antes de hacer commit:

```bash
grep -rn "bucket_name" modules/secure-bucket/ || echo "OK: ninguna referencia en el módulo"
```

> **Nota 1:** `moved {}` no aplica a variables — solo a recursos y módulos. Renombrar una variable siempre es un breaking change porque el consumidor debe actualizar su código.
>
> **Nota 2:** El `consumer/main.tf` del repo del curso **todavía** usa `bucket_name = ...`, y eso es correcto en este momento — su `?ref` apunta a `v1.0.0`/`v1.1.0`, donde la variable aún se llama así. La migración del consumer al nuevo tag se hace en el Paso 6.

#### Paso 5: Tag v2.0.0

Sigues en el sandbox. Igual que en el Paso 3, el primer commit fallará en `terraform_docs` (la tabla del README aún tiene `bucket_name`, hay que regenerarla con `name`):

```bash
# Intento 1
git add modules/secure-bucket/
git commit -m 'feat!: rename bucket_name to name (BREAKING CHANGE)'
# Terraform docs.......................Failed (regenera README)

# Intento 2 — añade el README modificado por el hook
git add modules/secure-bucket/README.md
git commit -m 'feat!: rename bucket_name to name (BREAKING CHANGE)'
# Todos los hooks pasan

git tag -a v2.0.0 -m "BREAKING: rename bucket_name to name"
```

Verifica los tres tags y el historial:

```bash
git tag -l "v*"
# v1.0.0
# v1.1.0
# v2.0.0

git log --oneline --decorate
```

#### Paso 6: Migrar el consumer al nuevo tag (repo del curso)

Hasta aquí todo era trabajo del **mantenedor del módulo** en el sandbox. Ahora cambia el sombrero al **equipo consumidor**: ellos ven `v2.0.0` publicado, leen el `CHANGELOG.md` que dice "BREAKING: rename `bucket_name` → `name`" y aplican la migración en su código.

En este lab el consumer vive en el repo del curso. La migración consiste en bumpear el `?ref=` y renombrar el argumento del módulo:

```bash
cd ~/terraform-on-aws/labs/lab-26/aws/consumer
```

Edita `main.tf`:

```hcl
module "app_bucket" {
  # Bump del tag: v1.0.0 → v2.0.0
  source = "git::file:///tmp/secure-bucket-sandbox//modules/secure-bucket?ref=v2.0.0"

  name              = "consumer-app-${data.aws_caller_identity.current.account_id}"  # Antes: bucket_name
  environment       = "production"
  enable_versioning = true
  enable_encryption = true
  force_destroy     = true
  # ...
}
```

Refetchea el módulo desde el nuevo tag y aplica:

```bash
terraform init -upgrade \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
terraform plan
```

> **Lo que demuestra esto:** el consumidor controla **cuándo** adopta una versión MAJOR. Hasta que no bumpea el `?ref=`, su código sigue corriendo contra `v1.0.0` (con `bucket_name`) sin verse afectado por el breaking change que hizo el mantenedor. Es exactamente el contrato que el versionado semántico promete.

Cuando termines, restaura el consumer al estado del repo:

```bash
git checkout -- main.tf
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

</details>

<details>
<summary><strong>Solución al Reto 2 — Automatizar la validación de ejemplos con `terraform test`</strong></summary>

### Solución al Reto 2 — Automatizar la validación de ejemplos con `terraform test`

> Todos los pasos se ejecutan **dentro del sandbox**:
>
> ```bash
> cd /tmp/secure-bucket-sandbox
> ```

#### Paso 1: Crear los archivos de test

En `modules/secure-bucket/tests/examples_basic.tftest.hcl`:

```hcl
# Test que ejecuta el ejemplo básico para verificar que funciona

run "basic_example_works" {
  command = apply

  module {
    source = "./examples/basic"
  }

  assert {
    condition     = output.bucket_id != ""
    error_message = "El ejemplo básico debe crear un bucket"
  }

  assert {
    condition     = output.bucket_arn != ""
    error_message = "El ejemplo básico debe producir un ARN"
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

#### Paso 2: Ejecutar

`terraform test` se invoca **desde la raíz del módulo** (donde están los `.tf` y la carpeta `examples/`). El `init` descarga los providers necesarios para los ejemplos:

```bash
cd /tmp/secure-bucket-sandbox/modules/secure-bucket

terraform init
terraform test
```

> **Nota:** Si el módulo no tiene un `providers.tf` propio (caso habitual cuando se publica), `terraform init` se queja. Puedes añadir un `providers.tf` mínimo (solo `required_providers`) o ejecutar el test desde un directorio que sí lo tenga (ej: `examples/basic/`) y referenciar el módulo con `source = "../../"`.

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

#### Paso 3: Integrar `terraform test` en el pipeline de pre-commit

`pre-commit-terraform` no incluye un hook `terraform_test` ya hecho. Para engancharlo, se añade un **hook local** al `.pre-commit-config.yaml` del sandbox.

Decisión clave — **¿en qué stage?**: `terraform test` con `command = apply` crea recursos reales, tarda ~30–60 s y cuesta dinero. Ejecutarlo en **cada `git commit`** es excesivo. Lo idiomático es `pre-push`: se dispara antes de empujar a remoto (entonces el coste sí se justifica).

Edita `/tmp/secure-bucket-sandbox/.pre-commit-config.yaml` y añade al final:

```yaml
  # --- Tests de integración (lentos) ---
  # Se ejecutan solo en `git push`, no en cada commit.
  - repo: local
    hooks:
      - id: terraform-test
        name: terraform test (examples)
        entry: bash -c 'cd modules/secure-bucket && terraform test'
        language: system
        pass_filenames: false
        files: ^modules/secure-bucket/.*\.tf$
        stages: [pre-push]
```

Activa el stage de `pre-push` (la primera vez):

```bash
cd /tmp/secure-bucket-sandbox
pre-commit install --hook-type pre-push
```

Pruébalo manualmente sin tener que hacer push real:

```bash
pre-commit run terraform-test --all-files --hook-stage pre-push
# terraform test (examples)................................Passed
```

Ahora cuando hagas `git push`:

```
git push origin main
  └─ terraform test (examples) ── ¿Ejemplos siguen funcionando? ── FAIL → push rechazado
```

> **Por qué `pre-push` y no `pre-commit`:**
> - **`pre-commit`**: ideal para validaciones rápidas (fmt, validate, docs, trivy) que tardan <2 s. Tirar `terraform test` aquí te bloquea durante 30 s en cada commit, hace que la gente desactive los hooks (`--no-verify`) y pierdes toda la red de seguridad.
> - **`pre-push`**: ideal para tests de integración (`terraform test`, `terratest`, etc.). Se paga el coste solo cuando hay intención real de publicar.
> - **Alternativa `stages: [manual]`**: el hook nunca corre en automático, pero sí cuando ejecutas `pre-commit run terraform-test --all-files --hook-stage manual`. Útil si prefieres dispararlo desde CI en vez de localmente.

### Reflexión: ejemplos como contrato

Al testear los ejemplos automáticamente, se convierten en un **contrato**: si el módulo cambia de forma que rompe un ejemplo, el test falla antes de publicar la nueva versión. Con la integración del Paso 3 el flujo completo queda:

```
git commit
  ├─ terraform_fmt          (rápido)
  ├─ terraform_validate     (rápido)
  ├─ terraform_docs         (rápido)
  └─ terraform_trivy        (rápido)

git push
  └─ terraform test         (lento — solo aquí)
```

Cada ejemplo cubierto por un test es una garantía menos de que un consumidor va a encontrarse con un módulo roto.

</details>

---

## Limpieza

Si desplegaste los ejemplos manualmente:

```bash
# Desde cada directorio de ejemplo
cd modules/secure-bucket/examples/basic && terraform destroy
cd ../advanced && terraform destroy

# Desde el consumidor
cd ../../consumer && terraform destroy
```

Si solo ejecutaste `terraform test`, la limpieza es automática.

Para eliminar el sandbox de pre-commit y los tags creados en él:

```bash
# Borra el repositorio sandbox completo (y los tags v1.0.0, v1.1.0, v2.0.0
# se van con él, porque son locales a ese repo)
rm -rf /tmp/secure-bucket-sandbox
```

> **Nota:** No es necesario borrar tags en el repo del curso, porque "Verificar versionado con Git tag" los crea en el sandbox aislado, no en el repo padre.

---

## LocalStack

Los ejemplos `basic` y `advanced` funcionan con LocalStack (S3 está completamente soportado en Community). Los hooks de pre-commit y terraform-docs no necesitan ningún proveedor.

Consulta [localstack/README.md](localstack/README.md) para más detalles.

---

## Buenas prácticas aplicadas

- **`terraform-docs` como fuente de verdad**: generar documentación automáticamente desde el código evita que el README quede desincronizado con las variables y outputs reales del módulo.
- **Hooks de pre-commit para calidad continua**: bloquear commits con código sin formatear o documentación desactualizada garantiza que el repositorio siempre esté en un estado publicable.
- **Pinear la versión de los hooks (`rev:`)**: fijar la revisión de cada repositorio en `.pre-commit-config.yaml` evita que actualizaciones del hook (a veces con cambios de comportamiento) rompan los commits sin previo aviso. Actualizar con `pre-commit autoupdate` cuando se quiera adoptar una nueva versión.
- **Análisis de seguridad con Trivy**: usar `terraform_trivy` (sucesor de `tfsec`) en pre-commit detecta misconfiguraciones antes del push y permite filtrar por severidad (`--severity HIGH,CRITICAL`) para no bloquear con avisos menores.
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
