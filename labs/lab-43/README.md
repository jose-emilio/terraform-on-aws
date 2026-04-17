# Laboratorio 43 — Canalización CI de IaC con CodeBuild y ECR

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 10 — CI/CD y Automatización con Terraform](../../modulos/modulo-10/README.md)


## Visión general

En cualquier pipeline de Infraestructura como Código a escala, la herramienta
más peligrosa no es el entorno de producción — es el momento entre que un
ingeniero escribe `terraform apply` y el momento en que alguien revisa ese plan.
Sin un motor de validación automático que actúe como primera línea de defensa,
los errores lógicos y las misconfiguraciones de seguridad llegan a los entornos
de producción.

Este laboratorio construye ese motor: un **runner de IaC** que convierte cada
push de código en un proceso estructurado en cuatro fases donde la calidad
estructural se valida antes de generar el plan, y las herramientas de seguridad
siempre producen sus informes independientemente del resultado. El runner corre
dentro de una imagen Docker custom alojada en ECR que empaqueta exactamente las
mismas versiones de Terraform, TFLint, Trivy y Checkov en cada ejecución,
garantizando reproducibilidad total.

El pipeline combina dos patrones complementarios: **Fail Fast** para las
validaciones estructurales (formato, sintaxis, linting), que abortan en el
primer error sin malgastar ciclos de cómputo, y **Collect and Fail** para las
herramientas de seguridad (Trivy y Checkov), que siempre se ejecutan ambas y
publican sus informes JUnit en CodeBuild Reports antes de decidir el estado
final del build.

El trigger es completamente automático: cada `git push` a la rama `main` del
repositorio CodeCommit dispara el build via EventBridge, sin intervención manual.

## Objetivos

- Diseñar y construir un Dockerfile multi-stage con Terraform, TFLint, Trivy y
  Checkov con versiones exactas pinneadas, verificando la integridad SHA-256 de
  cada binario durante el build de la imagen.

- Alojar la imagen en un repositorio Amazon ECR con `image_tag_mutability = "IMMUTABLE"`
  y escaneo automático de vulnerabilidades activado en cada push.

- Configurar un repositorio Amazon CodeCommit como fuente del código Terraform,
  con un trigger automático via EventBridge que lanza el build en cada push a `main`.

- Configurar un proyecto CodeBuild que usa la imagen custom con
  `image_pull_credentials_type = "SERVICE_ROLE"` y un buildspec que vive en el
  propio repositorio CodeCommit junto al código Terraform.

- Implementar una estrategia de validación combinada: Fail Fast para formato,
  sintaxis y linting (abortar en el primer error) y Collect and Fail para las
  herramientas de seguridad (Trivy y Checkov siempre se ejecutan ambas,
  capturando exit codes individuales y fallando al final con un mensaje unificado).

- Publicar los resultados de Trivy y Checkov como informes JUnit estructurados
  en la pestaña **Reports** de CodeBuild, con los permisos IAM necesarios en el
  rol de servicio, de forma que los hallazgos de ambas herramientas sean visibles
  en cada build sin necesidad de filtrar logs de CloudWatch.

- Demostrar el comportamiento del pipeline con dos versiones del código Terraform
  objetivo: una con un bucket S3 público (falla en post_build con hallazgos en
  los informes de seguridad) y otra con todos los controles de seguridad
  (completa el ciclo hasta generar el tfplan).

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI v2 configurado con perfil `default` y permisos de administrador.
- Docker instalado y en ejecución (para construir y publicar la imagen).
- Git con credenciales HTTPS configuradas para CodeCommit (o helper de AWS CLI).
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado
  habilitado (necesario para el backend S3 del estado de este laboratorio).

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
export REGION="us-east-1"
```

## Arquitectura

```
Flujo del pipeline:
───────────────────────────────────────────────────────────────────────────────

  Desarrollador
      │
      │  git push origin main
      ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  CodeCommit  lab43-terraform-code                                        │
  │  ├── main.tf          (codigo Terraform a validar)                       │
  │  ├── .tflint.hcl      (configuracion del linter)                         │
  │  └── buildspec.yml    (logica del pipeline)                              │
  └─────────────────────────────┬────────────────────────────────────────────┘
                                 │ evento referenceUpdated (rama main)
                                 ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  EventBridge Rule  lab43-on-push-main                                    │
  │  ├── source      - aws.codecommit                                        │
  │  ├── detail-type - CodeCommit Repository State Change                    │
  │  └── target      - lab43-iac-runner (CodeBuild)                          │
  └─────────────────────────────┬────────────────────────────────────────────┘
                                 │ codebuild:StartBuild (rol events)
                                 ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  CodeBuild Project  lab43-iac-runner                                     │
  │                                                                          │
  │  ┌─ Fase install ────────────────────────────────────────────────────┐   │
  │  │  Imagen - ECR lab43/iac-runner:latest (custom, herramientas IaC)  │   │
  │  │  Verifica - terraform, tflint, trivy, checkov  [on-failure:ABORT] │   │
  │  └───────────────────────────────────────────────────────────────────┘   │
  │           │                                                              │
  │           ▼                                                              │
  │  ┌─ Fase pre_build  ─────────────────────────────────────────────────┐   │
  │  │  [1/5] terraform fmt -check  ── Fail Fast  [on-failure: ABORT]    │   │
  │  │  [2/5] terraform validate    ── Fail Fast                         │   │
  │  │  [3/5] tflint                ── Fail Fast                         │   │
  │  └───────────────────────────────────────────────────────────────────┘   │
  │           │ (solo si pre_build paso)                                     │
  │           ▼                                                              │
  │  ┌─ Fase build ──────────────────────────────────────────────────────┐   │
  │  │  terraform plan -out=tfplan.bin  [on-failure: ABORT]              │   │
  │  │  terraform show tfplan.bin > tfplan.txt                           │   │
  │  └───────────────────────────────────────────────────────────────────┘   │
  │           │ (post_build siempre se ejecuta)                              │
  │           ▼                                                              │
  │  ┌─ Fase post_build ─────────────────────────────────────────────────┐   │
  │  │  [4/5] trivy   → results/trivy-results.xml  ─┐  [on-failure:      │   │
  │  │  [5/5] checkov → results/results_junitxml.xml ┤   CONTINUE]       │   │
  │  │                  Collect and Fail: ambas siempre se ejecutan      │   │
  │  │                  exit 1 al final si SECURITY_FAILED > 0           │   │
  │  └───────────────────────────────────────────────────────────────────┘   │
  │           │                                                              │
  │           ▼                                                              │
  │  Artefactos → S3 artifacts/<BUILD_UUID>/plan.zip                         │
  │  Informes  → CodeBuild Reports (JUnit Trivy + Checkov, siempre subidos)  │
  └──────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  S3 Bucket  lab43-pipeline-<ACCOUNT>                                     │
  │  └── artifacts/<BUILD_UUID>/plan  (tfplan + tfplan.txt comprimidos)      │
  └──────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  CodeBuild Reports                                                       │
  │  ├── lab43-iac-runner-trivy-report    → hallazgos de Trivy por build      │
  │  └── lab43-iac-runner-checkov-report  → checks de Checkov por build      │
  │      Ambos se suben aunque el build falle (patron Collect and Fail)      │
  └──────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  ECR  lab43/iac-runner                                                   │
  │  ├── :latest           (apunta al build mas reciente)                    │
  │  ├── :20260410         (tag por fecha, inmutable)                        │
  │  └── scan_on_push = true                                                 │
  └──────────────────────────────────────────────────────────────────────────┘

Imagen Docker multi-stage:
────────────────────────────────────────────────────────────────────────────

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  Stage 1 (downloader) — alpine:3.21                                      │
  │                                                                          │
  │  curl + unzip + gnupg                                                    │
  │  ├── Descarga terraform_1.14.8_linux_amd64.zip → SHA256 ✓                │
  │  ├── Descarga tflint_0.52.0_linux_amd64.zip    → SHA256 ✓                │
  │  ├── Descarga trivy_0.69.3_Linux-64bit.tar.gz  → SHA256 ✓                │
  │  ├── Descarga trivy contrib/junit.tpl           → embebida en imagen      │
  │  └── Instala plugin TFLint AWS v0.31.0         → pre-instalado           │
  └──────────────────────────────┬───────────────────────────────────────────┘
                                 │ COPY --from=downloader
                                 ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  Stage 2 (runner) — python:3.12-slim-bookworm                            │
  │                                                                          │
  │  apt - upgrade + git, ca-certificates                                    │
  │  pip - checkov==3.2.231                                                  │
  │  /usr/local/bin/terraform  (copiado del stage 1)                         │
  │  /usr/local/bin/tflint     (copiado del stage 1)                         │
  │  /usr/local/bin/trivy      (copiado del stage 1)                         │
  │  /usr/local/share/trivy-junit.tpl  (plantilla JUnit embebida)            │
  │  /root/.tflint.d/plugins/  (plugin AWS pre-instalado del stage 1)        │
  │                                                                          │
  │  Sin - curl, gnupg, gcc, make, build-essential                           │
  │  Usuario - runner (no root)                                              │
  └──────────────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### Imagen Docker multi-stage y surface de ataque

El patrón multi-stage divide el proceso en dos contenedores:

1. **Stage downloader**: Contiene todas las herramientas necesarias para
   descargar y verificar los binarios (`curl`, `unzip`, `gnupg`). Es el entorno
   de construcción.

2. **Stage runner**: Solo recibe los binarios verificados mediante
   `COPY --from=downloader`. No hereda ninguna herramienta de construcción.
   Es el entorno de ejecución.

El resultado es una imagen de producción donde un atacante que consiguiera
ejecutar código arbitrario en el contenedor no encontraría `curl` para descargar
payloads ni `gcc` para compilarlos. La superficie de ataque es mínima.

### Verificación SHA-256 de binarios

Cada herramienta se descarga y verifica contra su suma SHA-256 publicada por
el mantenedor. Si alguien intercepta la descarga y modifica el binario (ataque
de supply chain), el hash calculado no coincidirá con el publicado y el build
de la imagen fallará con un error explícito:

```
sha256sum: WARNING: 1 computed checksum did NOT match
```

El build de la imagen falla antes de que el binario malicioso llegue al
stage final. Esta verificación es la primera defensa de la supply chain del
runner.

### Plugin TFLint pre-instalado en la imagen

TFLint requiere el plugin `terraform-aws` para validar reglas específicas de AWS.
Por defecto, `tflint --init` lo descarga de GitHub en cada build, lo que puede
fallar por rate limiting en cuentas sin token.

Para evitar este problema, el plugin se descarga y verifica en el stage
`downloader` y se copia al stage `runner` en `/root/.tflint.d/plugins/`. Cuando
el buildspec ejecuta `tflint --init`, TFLint detecta que el plugin ya está
instalado y lo omite:

```
All plugins are already installed
```

Esto elimina la dependencia de GitHub en tiempo de ejecución y acelera el build.

### ECR: IMMUTABLE tags y scan on push

**`image_tag_mutability = "IMMUTABLE"`**:
Una vez publicado `iac-runner:latest` con el digest `sha256:abc123...`, es
imposible sobrescribir ese tag con un digest diferente. Cualquier intento de
`docker push` al mismo tag retorna un error:

```
tag invalid: The image tag 'latest' already exists in the 'lab43/iac-runner'
repository and cannot be overwritten because the repository is immutable.
```

Para actualizar la imagen hay que usar un tag nuevo con fecha (`:20260410`) y
después borrar el tag `latest` antes de publicarlo de nuevo. Esto garantiza
que CodeBuild siempre descarga exactamente el binario que se publicó con ese
tag — sin sorpresas silenciosas.

**`scan_on_push = true`**:
Cada `docker push` activa automáticamente un análisis de vulnerabilidades de
Amazon Inspector contra la base de datos CVE. Los resultados son accesibles
desde:
- Consola de ECR → repositorio → Tags → Scan findings
- AWS CLI: `aws ecr describe-image-scan-findings ...`
- EventBridge: los hallazgos CRITICAL y HIGH generan eventos que se pueden
  enrutar a SNS para alertas.

### CodeCommit + EventBridge: trigger automático

El código Terraform a validar vive en un repositorio CodeCommit. Cada `git push`
a la rama `main` emite un evento `referenceUpdated` de tipo
`CodeCommit Repository State Change`. Una regla de EventBridge filtra ese evento
por repositorio y rama, y lanza el build de CodeBuild automáticamente usando un
rol de servicio con permiso `codebuild:StartBuild`.

El resultado: el desarrollador hace `git push` y el pipeline arranca sin
intervención manual. No hay scripts de CI externos. No hay webhooks que mantener.
La integración es nativa a la plataforma AWS.

### Buildspec en el repositorio del código

El `buildspec.yml` vive en el mismo repositorio CodeCommit que el código Terraform.
CodeBuild lo lee directamente del repositorio clonado, sin necesidad de embeberlo
en la configuración del proyecto.

Esta decisión tiene una implicación de seguridad importante: los administradores
del pipeline **confían en que el código del repositorio incluye un buildspec
correcto**. Si un desarrollador modifica el buildspec, puede alterar las
validaciones. En entornos donde se necesite garantizar inmutabilidad del buildspec,
la alternativa es embeberlo en el proyecto CodeBuild y bloquearlo mediante
permisos IAM.

### Buildspec: fases y estrategia de validación

El buildspec define cuatro fases con dos patrones distintos según el tipo
de validación:

| Fase | Propósito | Estrategia | on-failure |
|------|-----------|------------|------------|
| `install` | Verificar imagen custom | Fail Fast | ABORT |
| `pre_build` pasos 1-3 | Formato, sintaxis, linting | Fail Fast | ABORT |
| `build` | Generar el plan | Fail Fast | ABORT |
| `post_build` pasos 4-5 | Seguridad (Trivy + Checkov) | Collect and Fail | CONTINUE |

### Fail Fast para los pasos de calidad estructural

Los primeros tres pasos abortan inmediatamente en caso de error. No tiene
sentido analizar la seguridad de un fichero mal formateado o con errores
de sintaxis, y el tiempo ahorrado es significativo:

```
[1/5] terraform fmt -check   (~1s)    → Primer filtro, coste mínimo
[2/5] terraform validate     (~5s)    → Necesita init (descarga proveedor)
[3/5] tflint                 (~10s)   → Plugin AWS pre-instalado en imagen
```

### Collect and Fail para las herramientas de seguridad

Los pasos 4 y 5 usan un patrón diferente: **ambas herramientas siempre se
ejecutan**, aunque la primera encuentre errores. La razón es que Trivy y
Checkov analizan aspectos distintos y sus hallazgos son independientes —
detener el pipeline en Trivy oculta los hallazgos de Checkov que el equipo
necesita ver para corregir el código de una vez.

**Por qué en `post_build` y no en `pre_build`**: CodeBuild procesa la sección
`reports` del buildspec solo cuando `post_build` completa su ciclo de vida
normalmente. Si las herramientas de seguridad vivieran en `pre_build` con
`on-failure: ABORT`, un `exit 1` terminaría el proceso del agente antes de
que procesara los ficheros JUnit, por lo que los informes nunca se publicarían.
`post_build` con `on-failure: CONTINUE` garantiza que el agente complete la
fase — incluyendo la subida de los informes — y después marque el build como
`FAILED`.

El mecanismo es sencillo: las variables de bash persisten entre comandos de
una misma fase porque CodeBuild ejecuta la fase completa como un único
script. El operador `||` impide el abort inmediato y registra el fallo:

```bash
SECURITY_FAILED=0
trivy   ... || SECURITY_FAILED=1   # falla → registra, continúa
checkov ... || SECURITY_FAILED=1   # falla → registra, continúa
[ $SECURITY_FAILED -eq 0 ] || exit 1   # fallo unificado al final
                                       # (on-failure: CONTINUE permite que los
                                       #  informes se suban antes de FAILED)
```

La ventaja operacional es clara: en cada build, los informes de **ambas**
herramientas están disponibles en CodeBuild Reports, independientemente de
cuál haya fallado. El equipo ve el cuadro completo de problemas y puede
corregirlos todos antes del siguiente push, en lugar de descubrirlos uno
a uno en builds sucesivos.

### image_pull_credentials_type = "SERVICE_ROLE"

CodeBuild puede autenticarse con ECR de dos formas:

- **`CODEBUILD`** (por defecto): Usa credenciales internas gestionadas por
  AWS. Sólo funciona para imágenes ECR en la misma cuenta y región.

- **`SERVICE_ROLE`**: Usa las credenciales del rol de servicio del proyecto.
  Requiere que el rol tenga los permisos ECR explícitamente en su política.
  Funciona para ECR de cualquier cuenta (cross-account) y hace los permisos
  completamente visibles y auditables en `iam.tf`.

Este laboratorio usa `SERVICE_ROLE` para que los permisos sean explícitos y
el alumno pueda ver exactamente qué necesita CodeBuild para pull de imágenes.

### Informes de test nativos: CodeBuild Reports

CodeBuild Reports es una funcionalidad nativa que permite publicar resultados
de validaciones en formato estructurado directamente en la consola de CodeBuild,
sin herramientas externas. Los resultados aparecen en la pestaña **Reports**
del proyecto con un resumen visual de checks pasados y fallados y el detalle
de cada uno.

El runner genera informes JUnit de **ambas** herramientas de seguridad:

**Trivy** no soporta `--format junit` de forma nativa: requiere una plantilla
Go embebida en la imagen (`/usr/local/share/trivy-junit.tpl`). Al igual que
tfsec, se ejecuta dos veces dentro del bloque Collect and Fail: la primera
para texto legible en los logs, la segunda para JUnit con `|| true` para no
alterar `SECURITY_FAILED`. El flag `--include-non-failures` incluye también
los checks que pasan, para que CodeBuild Reports muestre el cuadro completo:

```bash
trivy config --severity MEDIUM,HIGH,CRITICAL --include-non-failures . || SECURITY_FAILED=1
trivy config --format template --template "@/usr/local/share/trivy-junit.tpl" --output results/trivy-results.xml --severity MEDIUM,HIGH,CRITICAL --include-non-failures . 2>/dev/null || true
```

**Checkov** soporta múltiples formatos en un único comando, lo que es más
eficiente:

```bash
checkov -d . --framework terraform --compact \
    --output cli \
    --output junitxml --output-file-path results/ || SECURITY_FAILED=1
```

El bloque `reports:` del buildspec indica a CodeBuild qué ficheros recoger:

```yaml
reports:
  trivy-report:
    files:
      - "results/trivy-results.xml"
    file-format: JUNITXML
  checkov-report:
    files:
      - "results/results_junitxml.xml"
    file-format: JUNITXML
```

CodeBuild crea automáticamente dos report groups en la primera ejecución:
`lab43-iac-runner-trivy-report` y `lab43-iac-runner-checkov-report`.

**El papel crítico de `on-failure: CONTINUE`**: CodeBuild procesa la sección
`reports` solo cuando `post_build` completa su ciclo de vida. Con
`on-failure: CONTINUE`, el `exit 1` del fallo unificado es registrado como
comando fallado, pero la fase sigue ejecutando el cierre del ciclo de vida —
en ese cierre el agente lee los ficheros JUnit y los sube a los report groups
antes de marcar el build como `FAILED`. Sin `on-failure: CONTINUE`, el agente
terminaría abruptamente y los informes nunca aparecerían en la pestaña Reports.

Para publicar informes, el rol de CodeBuild necesita cinco acciones sobre
el report group (ver `aws/iam.tf`):

```
codebuild:CreateReportGroup     — crea el grupo en la primera ejecución
codebuild:CreateReport          — crea un informe por build
codebuild:UpdateReport          — marca el informe como completado
codebuild:BatchPutTestCases     — escribe los casos de test individuales
codebuild:BatchPutCodeCoverages — requerida por el agente aunque no se usen
                                  coverage reports; su ausencia puede causar
                                  fallos silenciosos en el upload del JUnit
```

## Estructura del proyecto

```
labs/lab43/
├── aws/                     ── Infraestructura del pipeline (Terraform)
│   ├── providers.tf         ── Provider AWS ~> 6.0, backend S3
│   ├── variables.tf         ── Versiones pinneadas, nombres de recursos
│   ├── main.tf              ── CodeCommit, EventBridge, ECR, S3, CloudWatch, CodeBuild
│   ├── iam.tf               ── Roles de servicio CodeBuild y EventBridge + politicas inline
│   ├── outputs.tf           ── URLs, ARNs, comandos de operacion
│   └── aws.s3.tfbackend     ── Configuracion parcial del backend
│
├── docker/
│   └── Dockerfile           ── Multi-stage: downloader Alpine + runner Python
│
├── buildspec.yml            ── Logica del pipeline (unica copia, compartida)
│
└── terraform-target/
    ├── insecure/            ── Codigo con bucket S3 publico (falla el pipeline)
    │   ├── main.tf
    │   └── .tflint.hcl
    └── secure/              ── Codigo con todos los controles (pasa el pipeline)
        ├── main.tf
        └── .tflint.hcl
```

---

## Paso 1 — Desplegar la infraestructura con Terraform

```bash
cd labs/lab43/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan
terraform apply
```

Terraform crea:
- Repositorio CodeCommit `lab43-terraform-code` (fuente del código Terraform)
- Regla EventBridge `lab43-on-push-main` (trigger automático en push a main)
- Repositorio ECR `lab43/iac-runner` (IMMUTABLE, scan on push)
- S3 bucket `lab43-pipeline-<ACCOUNT_ID>` (artefactos del build)
- Grupo de CloudWatch Logs `/aws/codebuild/lab43-iac-runner`
- Rol IAM `lab43-codebuild-role` con políticas inline para ECR, S3, CodeCommit y Logs
- Rol IAM `lab43-events-role` con permiso para lanzar CodeBuild
- Proyecto CodeBuild `lab43-iac-runner`

Captura los valores de salida:
```bash
terraform output ecr_repository_url
terraform output codecommit_repo_url_http
terraform output pipeline_bucket_name
terraform output codebuild_project_name
```

---

## Paso 2 — Construir y publicar la imagen custom en ECR

Desde el directorio raíz del repositorio (`terraform-on-aws/`):

```bash
export ECR_URL=$(terraform output -raw ecr_repository_url)
export IMAGE_VERSION=$(date +%Y%m%d)

# Login en ECR
aws ecr get-login-password --region ${REGION} \
  | docker login --username AWS --password-stdin ${ECR_URL}

# Construir la imagen (multi-stage con versiones pinneadas)
docker build \
  --build-arg TERRAFORM_VERSION=1.14.8 \
  --build-arg TFLINT_VERSION=0.52.0 \
  --build-arg TFLINT_AWS_PLUGIN_VERSION=0.31.0 \
  --build-arg TRIVY_VERSION=0.69.3 \
  --build-arg CHECKOV_VERSION=3.2.231 \
  -t ${ECR_URL}:latest \
  -t ${ECR_URL}:${IMAGE_VERSION} \
  ../docker/
```

Durante el build, el output del Dockerfile debería mostrar la verificación de
cada herramienta al final del stage `runner`:

```
=== Verificando herramientas del runner ===
Terraform v1.14.8
tflint version 0.52.0
Trivy Version: 0.69.3
checkov, version 3.2.231
=== Todas las herramientas verificadas correctamente ===
```

```bash
# Publicar en ECR (tag por fecha primero, luego latest)
docker push ${ECR_URL}:${IMAGE_VERSION}
docker push ${ECR_URL}:latest
```

> **Nota sobre immutabilidad**: `image_tag_mutability = "IMMUTABLE"` significa
> que si intentas publicar el tag `latest` por segunda vez sin borrarlo primero,
> ECR rechazará el push. Para actualizar la imagen, elimina el tag existente con
> `aws ecr batch-delete-image --repository-name lab43/iac-runner --image-ids imageTag=latest`
> y vuelve a publicar con el tag nuevo.

---

## Paso 3 — Verificar el escaneo de vulnerabilidades

Tras el push, ECR activa automáticamente el escaneo. Puede tardar 1-2 minutos:

```bash
# Comprobar el estado del escaneo
aws ecr describe-image-scan-findings \
  --repository-name lab43/iac-runner \
  --image-id imageTag=latest \
  --region ${REGION} \
  --query "imageScanStatus"

# Ver los hallazgos por severidad
aws ecr describe-image-scan-findings \
  --repository-name lab43/iac-runner \
  --image-id imageTag=latest \
  --region ${REGION} \
  --query "imageScanFindings.findingSeverityCounts"
```

El resultado típico de una imagen basada en `python:3.12-slim-bookworm` con
`apt-get upgrade` y las herramientas instaladas:

```json
{
    "INFORMATIONAL": 0,
    "LOW": 0,
    "MEDIUM": 2,
    "HIGH": 3,
    "CRITICAL": 0
}
```

Los hallazgos MEDIUM y algunos HIGH corresponden a CVEs en paquetes del sistema
base de Debian para los que no existe aún backport disponible en Bookworm (por
ejemplo `nghttp2`, `dpkg`, `tar` o `libcap2`). El Dockerfile ya incluye
`apt-get upgrade` para aplicar todos los parches disponibles en el momento del
build. Los CVEs residuales se revisan periódicamente: cuando Debian publica el
backport, el siguiente build los elimina automáticamente.

---

## Paso 4 — Configurar el repositorio CodeCommit y subir el codigo

El pipeline espera que el repositorio CodeCommit contenga el código Terraform
y el `buildspec.yml`. Primero configura las credenciales HTTPS de CodeCommit:

```bash
export CODECOMMIT_URL=$(terraform output -raw codecommit_repo_url_http)

# Configurar el helper de credenciales de AWS para CodeCommit
git config --global credential.helper \
  '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

Clona el repositorio vacío y sube el código:

```bash
# Clonar el repositorio vacío
git clone ${CODECOMMIT_URL} /tmp/terraform-code

# Para el código inseguro (Paso 5):
cp -r ../terraform-target/insecure/. /tmp/terraform-code/
cp ../buildspec.yml /tmp/terraform-code/

cd /tmp/terraform-code
git add .
git commit -m "feat: add insecure terraform code for pipeline demo"
# El repositorio esta vacio: push -u origin HEAD:main garantiza que el branch
# remoto se llame 'main' independientemente del nombre del branch local.
git push -u origin HEAD:main
# El build se dispara automaticamente via EventBridge
```

> **El push es el trigger**: EventBridge detecta el evento `referenceUpdated`
> en la rama `main` y lanza CodeBuild automáticamente. No es necesario ejecutar
> `aws codebuild start-build` manualmente.

---

## Paso 5 — Demostrar el Fail Fast con codigo inseguro

El build se lanza automáticamente tras el push del paso anterior. Sigue los logs:

```bash
cd /ruta/a/terraform-on-aws

export PROJECT_NAME=$(cd labs/lab43/aws && terraform output -raw codebuild_project_name)

# Seguir los logs en tiempo real
aws logs tail /aws/codebuild/${PROJECT_NAME} --follow --region ${REGION}
```

**Resultado esperado**: Las fases `install`, `pre_build` y `build` completan
correctamente (el código tiene formato válido, pasa la validación de sintaxis y
TFLint, y genera el plan). El build falla en la fase `post_build`, paso 4/5,
donde Trivy detecta las misconfiguraciones del bucket S3 inseguro:

```
main.tf (terraform)
===================
Tests: 7 (SUCCESSES: 0, FAILURES: 7)
Failures: 7 (MEDIUM: 1, HIGH: 6, CRITICAL: 0)

AWS-0086 (HIGH): No public access block so not blocking public acls
════════════════════════════════════════
S3 buckets should block public ACLs on buckets and any objects they contain.
See https://avd.aquasec.com/misconfig/aws-0086
────────────────────────────────────────
 main.tf:53-60
────────────────────────────────────────
  53 ┌ resource "aws_s3_bucket" "datos" {
  54 │   bucket = "mi-datos-lab43-insecure"
  55 │
  56 │   tags = {
  57 │     Environment = "lab"
  58 │     ManagedBy   = "terraform"
  59 │   }
  60 └ }
────────────────────────────────────────

AWS-0090 (MEDIUM): Bucket does not have versioning enabled
════════════════════════════════════════
See https://avd.aquasec.com/misconfig/aws-0090
────────────────────────────────────────
 main.tf:53-60
────────────────────────────────────────

AWS-0092 (HIGH): Bucket has a public ACL: "public-read"
════════════════════════════════════════
Buckets should not have ACLs that allow public access
See https://avd.aquasec.com/misconfig/aws-0092
────────────────────────────────────────
 main.tf:82
   via main.tf:80-85 (aws_s3_bucket_acl.datos)
────────────────────────────────────────
  80   resource "aws_s3_bucket_acl" "datos" {
  81     bucket = aws_s3_bucket.datos.id
  82 [   acl    = "public-read" # CRITICO: expone todos los objetos a internet
  84     depends_on = [aws_s3_bucket_ownership_controls.datos]
  85   }
────────────────────────────────────────

AWS-0132 (HIGH): Bucket does not encrypt data with a customer managed key.
════════════════════════════════════════
See https://avd.aquasec.com/misconfig/aws-0132
────────────────────────────────────────
 main.tf:53-60
────────────────────────────────────────

... (AWS-0087, AWS-0091, AWS-0093 — HIGH — también fallidos)
```

A continuación, `SECURITY_FAILED` valdrá `1` y el buildspec ejecutará igualmente
el paso 5/5 (Checkov). Ambas herramientas completan su análisis y generan sus
ficheros JUnit en `results/`. Al final, el `exit 1` del fallo unificado marca el
build como `FAILED` pero, gracias a `on-failure: CONTINUE`, el agente de
CodeBuild completa el ciclo de vida de `post_build` y sube los informes a los
report groups antes de cerrar el contenedor. Esto es el patrón Collect and Fail
en acción.

Para confirmar que el build falló:

```bash
BUILD_ID=$(aws codebuild list-builds-for-project \
  --project-name ${PROJECT_NAME} \
  --region ${REGION} \
  --query "ids[0]" --output text)

aws codebuild batch-get-builds \
  --ids ${BUILD_ID} \
  --region ${REGION} \
  --query "builds[0].{status:buildStatus,fase:currentPhase}"
```

```json
{
    "status": "FAILED",
    "fase": "POST_BUILD"
}
```

**Consultar los informes en CodeBuild Reports**:

Aunque el build falló, CodeBuild ha subido los informes JUnit de **ambas**
herramientas gracias al patrón Collect and Fail. Puedes consultarlos desde
la CLI o desde la consola (pestaña **Reports** del proyecto `lab43-iac-runner`):

```bash
# Informe de Trivy
TRIVY_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-trivy-report"
TRIVY_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${TRIVY_GROUP}" \
  --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports \
  --report-arns "${TRIVY_REPORT}" \
  --region ${REGION} \
  --query "reports[0].testSummary"

# Informe de Checkov
CHECKOV_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-checkov-report"
CHECKOV_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${CHECKOV_GROUP}" \
  --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports \
  --report-arns "${CHECKOV_REPORT}" \
  --region ${REGION} \
  --query "reports[0].testSummary"
```

Resultado aproximado (código inseguro, ambas herramientas):

```
trivy   → { "total": 7,  "statusCounts": { "FAILED": 7 } }
checkov → { "total": 42, "statusCounts": { "SUCCEEDED": 33, "FAILED": 9 } }
```

Consultar los casos fallados de cualquiera de los dos informes:

```bash
aws codebuild describe-test-cases \
  --report-arn "${TRIVY_REPORT}" \
  --region ${REGION} \
  --filter status=FAILED \
  --query "testCases[*].{check:name,mensaje:message}" \
  --output table
```

---

## Paso 6 — Ejecutar el pipeline con codigo seguro

Sube el directorio `secure/` al repositorio CodeCommit y espera el trigger automático:

```bash
cd /tmp/terraform-code

# Reemplazar el contenido con el codigo seguro
rm -rf *  .tflint.hcl
cp -r /ruta/a/terraform-on-aws/labs/lab43/terraform-target/secure/. .
cp /ruta/a/terraform-on-aws/labs/lab43/buildspec.yml .

git add .
git commit -m "fix: replace insecure bucket with compliant secure configuration"
git push -u origin HEAD:main
# El build se dispara automaticamente via EventBridge

cd -
```

Sigue los logs:

```bash
aws logs tail /aws/codebuild/${PROJECT_NAME} --follow --region ${REGION}
```

**Resultado esperado**: Las tres validaciones de `pre_build` pasan, la fase
`build` genera el plan, y la fase `post_build` no encuentra hallazgos de
seguridad. La salida muestra:

```
===================================================================
FASE PRE_BUILD - Validaciones estructurales (Fail Fast)
===================================================================
[1/5] PASS - El formato del codigo es correcto
[2/5] PASS - La sintaxis y los tipos son correctos
[3/5] PASS - No se encontraron errores logicos con TFLint

===================================================================
FASE BUILD - Generacion del plan
===================================================================
Terraform used the selected providers to generate the following execution plan.

  + resource "aws_kms_alias" "s3"
  + resource "aws_kms_key" "s3"
  + resource "aws_s3_bucket" "datos"
  + resource "aws_s3_bucket" "logs"
  + resource "aws_s3_bucket_logging" "datos"
  + resource "aws_s3_bucket_public_access_block" "datos"
  + resource "aws_s3_bucket_public_access_block" "logs"
  + resource "aws_s3_bucket_server_side_encryption_configuration" "datos"
  + resource "aws_s3_bucket_server_side_encryption_configuration" "logs"
  + resource "aws_s3_bucket_versioning" "datos"
  + resource "aws_s3_bucket_versioning" "logs"

Plan: 11 to add, 0 to change, 0 to destroy.
FASE BUILD - COMPLETADA - Plan generado correctamente

===================================================================
FASE POST_BUILD - Validaciones de seguridad (Collect and Fail)
===================================================================
[4/5] trivy completado (resultado pendiente de comprobacion final)
[5/5] checkov completado (resultado pendiente de comprobacion final)
SEGURIDAD OK - Todas las validaciones pasaron
```

El código seguro incluye:
- **CMK KMS** (`aws_kms_key.s3`): clave de cifrado gestionada por el cliente con
  rotación anual automática, necesaria para cumplir `aws-s3-encryption-customer-key`.
- **Bucket de logs** (`aws_s3_bucket.logs`): receptor separado de los logs de
  acceso del bucket principal, necesario para `aws-s3-enable-bucket-logging`.
- **Supresión de falsos positivos**: el bucket de logs no puede loguearse a sí
  mismo ni necesita CMK propia — los checks correspondientes se suprimen con
  `# trivy:ignore:` en la línea del resource y `# checkov:skip=` dentro del bloque.

**Comparar el informe de este build con el del build fallido**:

```bash
# Informe de Trivy del build exitoso — debe mostrar 0 checks fallados
TRIVY_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-trivy-report"
TRIVY_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${TRIVY_GROUP}" \
  --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports \
  --report-arns "${TRIVY_REPORT}" \
  --region ${REGION} \
  --query "reports[0].testSummary"

# Informe de Checkov del build exitoso — debe mostrar 0 checks fallados
CHECKOV_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-checkov-report"
CHECKOV_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${CHECKOV_GROUP}" \
  --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports \
  --report-arns "${CHECKOV_REPORT}" \
  --region ${REGION} \
  --query "reports[0].testSummary"
```

```json
{
    "total": 52,
    "statusCounts": {
        "SUCCEEDED": 52
    }
}
```

El resultado anterior corresponde al informe de Trivy. Trivy evalúa 52 checks sobre el código Terraform, incluyendo controles de IAM, KMS y S3. El informe de Checkov mostrará un total diferente ya que cubre un conjunto de políticas distinto.

---

## Paso 7 — Recuperar el artefacto tfplan

```bash
export BUCKET_NAME=$(cd labs/lab43/aws && terraform output -raw pipeline_bucket_name)

# Obtener el ID del ultimo build
BUILD_ID=$(aws codebuild list-builds-for-project \
  --project-name ${PROJECT_NAME} \
  --region ${REGION} \
  --query "ids[0]" --output text)

# El BUILD_ID tiene el formato "lab43-iac-runner:UUID".
# La carpeta en S3 usa solo el UUID (la parte despues de los dos puntos).
BUILD_UUID=${BUILD_ID#*:}

# Descargar el artefacto
# CodeBuild lo almacena como artifacts/<UUID>/plan (sin extension)
aws s3 cp \
  s3://${BUCKET_NAME}/artifacts/${BUILD_UUID}/plan \
  /tmp/tfplan.zip

unzip /tmp/tfplan.zip -d /tmp/tfplan-output/

# Ver el plan en texto legible
cat /tmp/tfplan-output/tfplan.txt

# El binario tfplan.bin puede usarse con terraform show para mas detalle
# (requiere que el proveedor AWS este inicializado localmente)
```

> **Sobre el contenido del artefacto**: El zip contiene dos ficheros:
> - `tfplan.bin` — plan binario de Terraform, usado como entrada de `terraform apply`
> - `tfplan.txt` — representación textual legible del plan, generada con `terraform show`

---

## Verificación final

```bash
# ── 1. Repositorio CodeCommit ────────────────────────────────────────────────
aws codecommit get-repository \
  --repository-name lab43-terraform-code \
  --region ${REGION} \
  --query "repositoryMetadata.{nombre:repositoryName,url:cloneUrlHttp}"

# ── 2. Regla EventBridge ─────────────────────────────────────────────────────
aws events describe-rule \
  --name lab43-on-push-main \
  --region ${REGION} \
  --query "{nombre:Name,estado:State,fuente:EventPattern}"

# ── 3. Repositorio ECR ───────────────────────────────────────────────────────
aws ecr describe-repositories \
  --repository-names lab43/iac-runner \
  --region ${REGION} \
  --query "repositories[0].{nombre:repositoryName,mutabilidad:imageTagMutability,escaneo:imageScanningConfiguration.scanOnPush}"

# ── 4. Imagenes publicadas en ECR ────────────────────────────────────────────
aws ecr list-images \
  --repository-name lab43/iac-runner \
  --region ${REGION}

# ── 5. Historial de builds del proyecto ──────────────────────────────────────
aws codebuild list-builds-for-project \
  --project-name ${PROJECT_NAME} \
  --region ${REGION} \
  --query "ids"

# ── 6. Estado del ultimo build ────────────────────────────────────────────────
aws codebuild batch-get-builds \
  --ids ${BUILD_ID} \
  --region ${REGION} \
  --query "builds[0].{status:buildStatus,iniciado:startTime,fase:currentPhase}"

# ── 7. Fases detalladas de un build (util para diagnostico) ──────────────────
aws codebuild batch-get-builds \
  --ids ${BUILD_ID} \
  --region ${REGION} \
  --query "builds[0].phases[*].{fase:phaseType,estado:phaseStatus,duracion:durationInSeconds}"

# ── 8. Rol IAM del runner ─────────────────────────────────────────────────────
aws iam get-role \
  --role-name lab43-codebuild-role \
  --query "Role.{nombre:RoleName,arn:Arn,creado:CreateDate}"

# ── 9. Rol IAM de EventBridge ────────────────────────────────────────────────
aws iam get-role \
  --role-name lab43-events-role \
  --query "Role.{nombre:RoleName,arn:Arn,creado:CreateDate}"

# ── 10. Artefactos en S3 ──────────────────────────────────────────────────────
aws s3 ls s3://${BUCKET_NAME}/artifacts/ --recursive --human-readable

# ── 11. CodeBuild Reports — los dos report groups creados automáticamente ─────
aws codebuild list-report-groups \
  --region ${REGION} \
  --query "reportGroups[?contains(@,'${PROJECT_NAME}')]"
# Esperado: dos entradas — trivy-report y checkov-report

# ── 12. Resumen del último informe de Trivy ───────────────────────────────────
TRIVY_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-trivy-report"
TRIVY_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${TRIVY_GROUP}" --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports --report-arns "${TRIVY_REPORT}" \
  --region ${REGION} \
  --query "reports[0].{estado:status,total:testSummary.total,resultado:testSummary.statusCounts}"

# ── 13. Resumen del último informe de Checkov ─────────────────────────────────
CHECKOV_GROUP="arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/${PROJECT_NAME}-checkov-report"
CHECKOV_REPORT=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "${CHECKOV_GROUP}" --region ${REGION} \
  --query "reports[0]" --output text)

aws codebuild batch-get-reports --report-arns "${CHECKOV_REPORT}" \
  --region ${REGION} \
  --query "reports[0].{estado:status,total:testSummary.total,resultado:testSummary.statusCounts}"
```

---

## Retos

### Reto 1 — Caché S3 de providers de Terraform

Cada build descarga los providers de Terraform desde el registro público de
HashiCorp, aunque no haya cambiado nada en el código. En pipelines activos
esto suma minutos innecesarios por build y genera tráfico de red saliente
repetitivo. Tu tarea es configurar la caché S3 nativa de CodeBuild para que
los binarios de los providers se descarguen una sola vez y se reutilicen en
builds posteriores, midiendo la mejora real en tiempo de ejecución.

1. En `aws/main.tf`: añade un bloque `cache` al recurso `aws_codebuild_project`
   apuntando al bucket de artefactos existente, y una variable de entorno
   `TF_PLUGIN_CACHE_DIR` con la ruta del directorio de caché.
2. En `aws/iam.tf`: amplía la política `codebuild-s3` para que el rol de
   servicio pueda leer y escribir objetos en el prefijo de caché del bucket.
3. En `buildspec.yml`: añade dos cambios:
   - En la fase `install`, antes de `terraform version`, crea el directorio
     de caché para que Terraform no falle al leer la variable de entorno:
     `'[ -n "${TF_PLUGIN_CACHE_DIR}" ] && mkdir -p "${TF_PLUGIN_CACHE_DIR}" || true'`
   - Al final del fichero, fuera de `phases`, declara el bloque `cache.paths`
     para que CodeBuild persista el directorio en S3 al finalizar el build.
4. Despliega los cambios, ejecuta dos builds consecutivos con el mismo código
   y compara la duración de la fase `pre_build` entre ambos. La caché S3 solo
   afecta a `PRE_BUILD`: el init de `build` ya era rápido porque comparte el
   directorio `TF_PLUGIN_CACHE_DIR` poblado por el primer init dentro del mismo
   build.

---

### Reto 2 — Alertas de fallo via EventBridge + SNS

El pipeline falla silenciosamente: el build queda en estado `FAILED` en la
consola de CodeBuild pero el equipo no recibe ninguna notificación. Tu tarea
es añadir la infraestructura de alertas necesaria para que cada build fallido
envíe un correo automático al equipo. Los builds exitosos no deben generar
ningún mensaje. La solución debe usar únicamente servicios administrados de
AWS y no requerir ningún servidor adicional.

1. En `aws/variables.tf`: añade una variable `alert_email` con validación de
   formato de correo electrónico.
2. En `aws/main.tf`: crea un `aws_sns_topic`, una `aws_sns_topic_subscription`
   de tipo `email`, una `aws_sns_topic_policy` que permita a
   `events.amazonaws.com` publicar (con condición `aws:SourceAccount`), una
   `aws_cloudwatch_event_rule` que filtre eventos `CodeBuild Build State Change`
   con `build-status = FAILED` para el proyecto de este lab, y un
   `aws_cloudwatch_event_target` que enrute los eventos al topic.
3. En `aws/outputs.tf`: expón el ARN del SNS Topic.
4. Despliega con `terraform apply`, confirma la suscripción en el correo que
   recibirás de AWS, lanza un build fallido y verifica que llega la alerta.

---

## Soluciones

<details>
<summary>Reto 1 — Caché S3 de providers de Terraform</summary>

### Por qué existe el problema

Cuando CodeBuild ejecuta `terraform init`, Terraform descarga los binarios del
provider AWS desde `registry.terraform.io`. El provider AWS pesa típicamente
entre 300 y 500 MB. En cada build este proceso se repite desde cero porque
el sistema de ficheros del contenedor CodeBuild es efímero: se destruye al
finalizar el build y se recrea desde la imagen Docker en el siguiente.

El resultado: en un proyecto con 10 builds diarios se descargan ~3 GB de
binarios idénticos al día, y cada `terraform init` añade entre 30 y 90
segundos al tiempo de build.

### Cómo funciona la caché S3 de CodeBuild

CodeBuild puede persistir directorios entre builds usando S3 como almacén
de caché. El flujo es:

```
Build N:
  1. CodeBuild descarga la caché de S3 → /tmp/tf-plugin-cache/ (vacía en el primer build)
  2. terraform init descarga el provider → /tmp/tf-plugin-cache/registry.terraform.io/...
  3. Al finalizar, CodeBuild comprime /tmp/tf-plugin-cache/ y lo sube a S3

Build N+1:
  1. CodeBuild descarga la caché de S3 → /tmp/tf-plugin-cache/ (con el provider ya descargado)
  2. terraform init detecta el provider en caché → lo omite
  3. Al finalizar, sube la caché actualizada (sin cambios si el provider no cambió)
```

Terraform usa la variable de entorno `TF_PLUGIN_CACHE_DIR` para localizar
el directorio de caché. Si el directorio existe y contiene el binario correcto
del provider, `terraform init` lo enlaza en lugar de descargarlo.

### Cambio 1: variable de entorno en el proyecto CodeBuild (`aws/main.tf`)

En el bloque `environment` del recurso `aws_codebuild_project.iac_runner`,
añade la variable de entorno y el bloque `cache`:

```hcl
resource "aws_codebuild_project" "iac_runner" {
  # ... resto de atributos sin cambios ...

  environment {
    # ... variables existentes sin cambios ...

    # Directorio de caché de providers. CodeBuild descarga el contenido de S3
    # a esta ruta antes del build y lo sube de vuelta al terminar.
    environment_variable {
      name  = "TF_PLUGIN_CACHE_DIR"
      value = "/tmp/tf-plugin-cache"
    }
  }

  # Configuración de la caché S3. CodeBuild gestiona automáticamente
  # la subida y descarga del directorio especificado en el buildspec.
  cache {
    type     = "S3"
    location = "${aws_s3_bucket.pipeline.bucket}/cache"
  }

  # ... resto del recurso sin cambios ...
}
```

El prefijo `cache/` del bucket de artefactos ya existente reutiliza la
infraestructura S3 sin necesidad de un bucket adicional. Terraform no crea
el objeto en S3 — CodeBuild lo gestiona automáticamente.

### Cambio 2: permisos S3 para la caché (`aws/iam.tf`)

La política `codebuild-s3` actual solo permite `s3:PutObject` sobre el prefijo
`artifacts/*`. La caché usa el prefijo `cache/*` y necesita operaciones de
lectura además de escritura. Añade un statement a la política existente:

```hcl
data "aws_iam_policy_document" "codebuild_s3" {
  # statement existente: AllowWriteArtifacts
  statement {
    sid     = "AllowWriteArtifacts"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.pipeline.arn}/artifacts/*"]
  }

  # statement existente: AllowBucketMetadata
  statement {
    sid    = "AllowBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.pipeline.arn]
  }

  # NUEVO: permisos para la caché de providers
  # CodeBuild necesita leer la caché al inicio del build y escribirla al final.
  # GetObject y GetObjectVersion son necesarios porque el bucket tiene
  # versionado habilitado y CodeBuild puede solicitar versiones específicas.
  statement {
    sid    = "AllowReadWriteCache"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]

    resources = ["${aws_s3_bucket.pipeline.arn}/cache/*"]
  }
}
```

### Cambio 3: directorio de caché y paths en el buildspec

Dos modificaciones en el buildspec:

**3a — Crear el directorio en la fase `install`**, antes de `terraform version`.
Terraform lee `TF_PLUGIN_CACHE_DIR` desde el primer comando y falla con un
error si el directorio no existe:

```yaml
# En install, antes de "terraform version":
- '[ -n "${TF_PLUGIN_CACHE_DIR}" ] && mkdir -p "${TF_PLUGIN_CACHE_DIR}" || true'
```

El guard `[ -n ... ] || true` hace que la línea sea inocua si la variable no
está definida — el buildspec funciona sin cambios en builds que no usen caché.

**3b — Declarar los paths al final del buildspec**, fuera de `phases`, para
que CodeBuild sepa qué directorio persistir en S3 al finalizar el build:

```yaml
# Al final del buildspec, fuera de phases:
cache:
  paths:
    - '/tmp/tf-plugin-cache/**/*'
```

El path `/tmp/tf-plugin-cache/**/*` usa el patrón glob de CodeBuild: `**/*`
captura todos los ficheros y subdirectorios recursivamente. Terraform organiza
los providers en subdirectorios por namespace, tipo y versión, por lo que la
recursión es necesaria:

```
/tmp/tf-plugin-cache/
└── registry.terraform.io/
    └── hashicorp/
        └── aws/
            └── 6.x.x/
                └── linux_amd64/
                    └── terraform-provider-aws_v6.x.x_x5
```

### Verificar que la caché se restaura correctamente

Al arrancar el build, antes de entrar en cualquier fase, el agente de
CodeBuild descarga y descomprime la caché de S3. Busca estas tres líneas
al principio de los logs del contenedor — aparecen antes del primer comando
del buildspec:

```
[Container] ... Expanded cache path /tmp/tf-plugin-cache/**/*
[Container] ... Downloading S3 cache...
[Container] ... Unarchiving cache...
```

Si el bloque `cache:` no está en el buildspec o el directorio no existe, el
agente mostrará en su lugar:

```
[Container] ... Cache is not defined in the buildspec
[Container] ... Skip cache due to: no paths specified to be cached
```

### Verificar la mejora

La caché S3 solo afecta al init de `pre_build [2/5]`: es el primero en
ejecutarse en cada build y sin caché descarga los providers desde el
registro. El init de `build` ya era rápido en ambos casos porque
`TF_PLUGIN_CACHE_DIR` apunta al mismo directorio que el primer init dejó
poblado durante ese mismo build.

Compara la línea de tiempo del paso `[2/5]` entre el primer build (sin caché)
y el segundo (con caché) en los logs de CloudWatch:

```
# Build 1 — sin caché
[2/5] PASS - La sintaxis y los tipos son correctos (38412ms)

# Build 2 — con caché
[2/5] PASS - La sintaxis y los tipos son correctos (423ms)
```

Confirma también que la caché se subió a S3:

```bash
aws s3 ls s3://${BUCKET_NAME}/cache/ --recursive --human-readable
# Esperado: un fichero de más de 100 MB con el directorio de providers
```

### Por qué no usar `terraform providers mirror`

Una alternativa sería ejecutar `terraform providers mirror` durante el build
de la imagen Docker para incluir los providers directamente en la imagen. El
problema es que los providers están fuertemente acoplados a la versión de
Terraform y a la arquitectura del sistema — si cambias la versión de Terraform
o el tipo de instancia de CodeBuild, necesitas reconstruir la imagen completa.

La caché S3 es más flexible: los providers se actualizan automáticamente
cuando cambias la versión en el fichero `required_providers`, sin tocar la
imagen Docker ni el repositorio ECR.

</details>

<details>
<summary>Reto 2 — Alertas de fallo via EventBridge + SNS</summary>

### Arquitectura de la solución

El flujo de alertas usa únicamente servicios administrados de AWS y no
requiere ningún servidor adicional:

```
CodeBuild (build FAILED)
    │
    │  evento "CodeBuild Build State Change"
    ▼
EventBridge (regla: source=aws.codebuild, build-status=FAILED,
             project-name=<nombre-del-proyecto>)
    │
    │  enruta el evento
    ▼
SNS Topic (iac-runner-alerts)
    │
    │  suscripción email
    ▼
Correo al equipo con build-id, project-name y build-status
```

La regla EventBridge filtra explícitamente por el nombre del proyecto para
que solo los builds de este pipeline generen alertas, evitando ruido de
otros proyectos CodeBuild de la cuenta.

### Por qué necesita una `aws_sns_topic_policy`

Por defecto, un SNS Topic solo acepta publicaciones de entidades IAM dentro
de la cuenta. EventBridge publica en SNS usando el principal de servicio
`events.amazonaws.com`, que no es una entidad IAM — necesita una política de
recurso explícita en el topic. Sin ella, EventBridge recibirá un error
`AuthorizationError` y el correo nunca llegará.

La condición `aws:SourceAccount` en la política es una protección estándar
contra el "confused deputy problem": si no la incluyes, cualquier cuenta de
AWS que envíe eventos a EventBridge podría potencialmente publicar en tu topic.
Con `aws:SourceAccount`, solo los eventos de tu propia cuenta pueden activar
la publicación.

### Variable `alert_email` en `aws/variables.tf`

```hcl
variable "alert_email" {
  type        = string
  description = <<-EOT
    Dirección de correo electrónico que recibirá las alertas de fallo del
    pipeline. AWS enviará un correo de confirmación de suscripción al
    desplegar; la suscripción no estará activa hasta que se confirme.
  EOT

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "Debe ser una dirección de correo electrónico válida (ej: equipo@empresa.com)."
  }
}
```

### Recursos en `aws/main.tf`

Añade el siguiente bloque al final del fichero:

```hcl
# ═══════════════════════════════════════════════════════════════════════════════
# SNS — Topic de alertas del pipeline de IaC
# ═══════════════════════════════════════════════════════════════════════════════
#
# El topic actúa como bus de mensajes entre EventBridge (productor) y el
# equipo (consumidor via email). La suscripción de tipo "email" requiere
# confirmación manual: AWS envía un correo con un enlace que el destinatario
# debe clicar antes de que la suscripción quede activa.

resource "aws_sns_topic" "alerts" {
  name         = "${var.project}-iac-runner-alerts"
  display_name = "IaC Runner — Alertas de fallo"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pipeline-failure-alerts"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Política de recurso del SNS Topic:
# Permite a events.amazonaws.com publicar mensajes desde la cuenta actual.
# La condición aws:SourceAccount es obligatoria para evitar el confused-deputy
# problem: sin ella, cualquier cuenta que publique a EventBridge podría
# activar esta suscripción.
data "aws_iam_policy_document" "sns_alerts_policy" {
  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_alerts_policy.json
}

# ═══════════════════════════════════════════════════════════════════════════════
# EventBridge — Regla de alerta en fallo del pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# CodeBuild emite eventos "CodeBuild Build State Change" para cada transición
# de estado: IN_PROGRESS, SUCCEEDED, FAILED, STOPPED. La regla filtra:
#   - source = "aws.codebuild"         → solo eventos de CodeBuild
#   - build-status = "FAILED"          → solo builds fallidos (no SUCCEEDED)
#   - project-name = nombre del proyecto → solo este pipeline, no otros
#
# El doble filtro (estado + proyecto) garantiza que no hay ruido: un fallo en
# otro proyecto de la cuenta no genera alertas en este pipeline.

resource "aws_cloudwatch_event_rule" "codebuild_failed" {
  name        = "${var.project}-on-build-failed"
  description = "Alerta cuando el pipeline de validación de IaC falla."

  event_pattern = jsonencode({
    source      = ["aws.codebuild"]
    detail-type = ["CodeBuild Build State Change"]
    detail = {
      build-status = ["FAILED"]
      project-name = [aws_codebuild_project.iac_runner.name]
    }
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_cloudwatch_event_target" "sns_alerts" {
  rule = aws_cloudwatch_event_rule.codebuild_failed.name
  arn  = aws_sns_topic.alerts.arn
  # EventBridge no necesita un rol IAM para publicar en SNS cuando se usa
  # una política de recurso en el topic. El rol IAM solo es necesario si el
  # target requiere credenciales (como CodeBuild o una función Lambda).
}
```

### Output en `aws/outputs.tf`

```hcl
output "alerts_topic_arn" {
  description = "ARN del SNS Topic que recibe alertas de fallo del pipeline."
  value       = aws_sns_topic.alerts.arn
}
```

### Desplegar y confirmar la suscripción

```bash
cd labs/lab43/aws

terraform apply -var="alert_email=tu@email.com"
```

Inmediatamente después del apply, AWS envía un correo con el asunto
`AWS Notification - Subscription Confirmation`. Es obligatorio abrir ese
correo y clicar el enlace `Confirm subscription` — hasta que se confirme,
la suscripción queda en estado `PendingConfirmation` y los mensajes no llegan.

Verifica el estado de la suscripción en la consola de SNS o con la CLI:

```bash
TOPIC_ARN=$(terraform output -raw alerts_topic_arn)

aws sns list-subscriptions-by-topic \
  --topic-arn "${TOPIC_ARN}" \
  --query "Subscriptions[0].SubscriptionArn" \
  --output text
# Esperado: arn:aws:sns:us-east-1:123456789012:lab43-iac-runner-alerts:...
# (si devuelve "PendingConfirmation", confirma primero el correo)
```

### Probar la alerta con un build fallido

Sube el código `insecure/` al repositorio CodeCommit. EventBridge disparará
la alerta automáticamente cuando el build falle:

```bash
cd /tmp/terraform-code
rm -rf * .tflint.hcl
cp -r /ruta/a/terraform-on-aws/labs/lab43/terraform-target/insecure/. .
cp /ruta/a/terraform-on-aws/labs/lab43/buildspec.yml .
git add .
git commit -m "test(reto2): codigo inseguro para verificar alerta de fallo"
git push -u origin HEAD:main
```

Cuando el build falle (en la fase `post_build`, tras detectar hallazgos de
Trivy o Checkov), EventBridge capturará el evento y publicará en SNS. El
correo llegará en menos de un minuto con el cuerpo del evento JSON completo,
similar a:

```json
{
  "version": "0",
  "source": "aws.codebuild",
  "detail-type": "CodeBuild Build State Change",
  "detail": {
    "build-status": "FAILED",
    "project-name": "lab43-iac-runner",
    "build-id": "arn:aws:codebuild:us-east-1:123456789012:build/lab43-iac-runner:abc-123",
    "current-phase": "POST_BUILD",
    "current-phase-context": "[{Message:Error in phase: POST_BUILD}]",
    "completed-phase": "POST_BUILD",
    "completed-phase-status": "FAILED"
  }
}
```

### Verificar que los builds exitosos no generan alertas

Sube el código `secure/` y confirma que no recibes correo:

```bash
cd /tmp/terraform-code
rm -rf * .tflint.hcl
cp -r /ruta/a/terraform-on-aws/labs/lab43/terraform-target/secure/. .
cp /ruta/a/terraform-on-aws/labs/lab43/buildspec.yml .
git add .
git commit -m "test(reto2): codigo seguro no debe generar alerta"
git push -u origin HEAD:main
```

El build completará con `SUCCEEDED`. Puedes verificar en la consola de
EventBridge → Rules → `lab43-on-build-failed` → Monitoring que la regla
se evaluó y no encontró coincidencias para este evento.

### Verificar la política SNS con la CLI

Confirma que la política del topic permite correctamente la publicación de
EventBridge y que la condición `aws:SourceAccount` está en su lugar:

```bash
aws sns get-topic-attributes \
  --topic-arn "${TOPIC_ARN}" \
  --query "Attributes.Policy" \
  --output text | python3 -m json.tool
```

La salida debe mostrar el `Principal` con `"Service": "events.amazonaws.com"`
y la condición `aws:SourceAccount` apuntando al ID de tu cuenta.

</details>

---

## Limpieza

> Los recursos de este laboratorio tienen coste si se dejan activos:
> CodeBuild cobra por minuto de build, ECR cobra por GB almacenado,
> CodeCommit cobra por usuario activo.

```bash
# 1. Eliminar las imagenes del repositorio ECR antes del destroy.
#    Terraform no puede eliminar un repositorio ECR que contiene imagenes
#    si no tiene force_delete = true.
aws ecr batch-delete-image \
  --repository-name lab43/iac-runner \
  --image-ids imageTag=latest imageTag=$(date +%Y%m%d) \
  --region ${REGION}

# 2. El bucket S3 tiene force_destroy = true, por lo que terraform destroy
#    lo eliminará aunque contenga objetos.

# 3. El repositorio CodeCommit se elimina junto con el resto de recursos.
#    Si tiene contenido, Terraform lo elimina igualmente.

# 4. Destruir toda la infraestructura
cd labs/lab43/aws
terraform destroy
```

## Solución de problemas

**Error: `ResourceNotFoundException` al hacer push a ECR**

El repositorio aún no se ha desplegado con Terraform, o el nombre del repositorio
en la URL no coincide con el nombre del recurso `aws_ecr_repository.iac_runner`.
Verifica con:
```bash
aws ecr describe-repositories --region ${REGION}
```

**Error: `tag invalid: The image tag 'latest' already exists`**

El repositorio tiene `image_tag_mutability = "IMMUTABLE"`. No puedes
sobrescribir un tag existente. Elimina el tag con:
```bash
aws ecr batch-delete-image \
  --repository-name lab43/iac-runner \
  --image-ids imageTag=latest \
  --region ${REGION}
```
Y vuelve a publicar con `docker push`.

**Error en CodeBuild: `CannotPullContainerError`**

El rol de servicio de CodeBuild no tiene permisos para pull de ECR, o la imagen
referenciada en el proyecto no existe todavía. Verifica:
1. Que la imagen existe en ECR: `aws ecr list-images --repository-name lab43/iac-runner`
2. Que el rol tiene las políticas `codebuild-ecr` en `iam.tf`
3. Que el proyecto usa `image_pull_credentials_type = "SERVICE_ROLE"`

**El push a CodeCommit no dispara el build**

Comprueba que:
1. La regla EventBridge `lab43-on-push-main` está en estado `ENABLED`
2. El push fue a la rama `main` (no a otra rama)
3. El rol EventBridge `lab43-events-role` tiene el permiso `codebuild:StartBuild`

```bash
aws events describe-rule --name lab43-on-push-main --region ${REGION}
```

**Error: `GRC: Error cloning remote repository`**

CodeBuild no puede clonar el repositorio CodeCommit. Verifica que:
1. El rol `lab43-codebuild-role` tiene la política `codebuild-codecommit` con `codecommit:GitPull`
2. El repositorio existe y la URL en el proyecto CodeBuild es correcta

**tflint falla con `Plugin not found`**

El fichero `.tflint.hcl` no está incluido en el repositorio CodeCommit, o hace
referencia a una versión del plugin diferente a la pre-instalada en la imagen.
Verifica que el `.tflint.hcl` del código hace referencia a la misma versión
del plugin que `TFLINT_AWS_PLUGIN_VERSION` en el Dockerfile.

---

## Buenas prácticas aplicadas

- **Imagen Docker multi-stage**: el stage `downloader` descarga y verifica los
  binarios; el stage `runner` solo recibe los binarios verificados. Las herramientas
  de construcción (`curl`, `gnupg`) no están presentes en la imagen final, reduciendo
  la superficie de ataque.

- **SHA-256 en cada binario**: verificar el hash antes de instalar protege contra
  ataques de supply chain. Si el binario es alterado en tránsito, el build de la
  imagen falla con un error explícito antes de que el binario llegue al runner.

- **Plugin TFLint pre-instalado**: instalar el plugin AWS en el stage `downloader`
  y copiarlo al stage `runner` elimina la dependencia de GitHub en tiempo de
  ejecución, evita rate limiting y acelera cada build.

- **`image_tag_mutability = IMMUTABLE`**: un tag publicado no puede ser
  sobrescrito. CodeBuild siempre descarga exactamente el binario que se publicó
  con ese tag — sin sorpresas silenciosas por sobreescritura.

- **Trigger automático via EventBridge**: la regla filtra por repositorio y rama
  exactos, evitando builds no deseados. El rol de EventBridge solo tiene
  `codebuild:StartBuild` sobre el proyecto específico — mínimo privilegio.

- **Patrón Fail Fast**: los validadores están ordenados por coste computacional
  ascendente. Un error de formato aborta en ~1 segundo sin ejecutar Checkov.
  Cada fase usa `on-failure: ABORT` para no acumular estados intermedios.

- **buildspec.yml como única fuente**: un solo `buildspec.yml` en la raíz del lab
  se copia al repositorio CodeCommit en cada demo. No hay copias divergentes por
  variante de código (insecure/secure).

- **Artefacto `tfplan.bin` en S3**: el plan binario queda almacenado como
  evidencia auditable del build. Junto con `tfplan.txt`, permite revisión humana
  y trazabilidad completa antes de cualquier `terraform apply`.

## Recursos

- [Amazon ECR — Image tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html)
- [Amazon ECR — Lifecycle policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)
- [AWS CodeBuild — Build specification reference](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
- [AWS CodeBuild — Use a custom image](https://docs.aws.amazon.com/codebuild/latest/userguide/sample-ecr.html)
- [AWS CodeCommit — Getting started](https://docs.aws.amazon.com/codecommit/latest/userguide/getting-started.html)
- [Amazon EventBridge — CodeCommit events](https://docs.aws.amazon.com/codecommit/latest/userguide/monitoring-events.html)
- [TFLint — Documentation](https://github.com/terraform-linters/tflint)
- [Trivy — Documentation](https://trivy.dev/)
- [Checkov — Documentation](https://www.checkov.io/1.Welcome/Quick%20Start.html)
- [Terraform — Resource: aws_codebuild_project](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codebuild_project)
- [Terraform — Resource: aws_codecommit_repository](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codecommit_repository)
- [Terraform — Resource: aws_cloudwatch_event_rule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule)
