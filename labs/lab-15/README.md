# Laboratorio 15 — Blindaje del Pipeline DevSecOps

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 4 — Seguridad e IAM con Terraform](../../modulos/modulo-04/README.md)


## Visión general

Las llaves de acceso permanentes (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
almacenadas en secretos de CI/CD son credenciales de larga vida: si se filtran,
el atacante dispone de acceso indefinido. Este laboratorio elimina ese riesgo
sustituyendo las llaves estáticas por **identidades efímeras OIDC**: GitHub
Actions obtiene un token firmado en cada ejecución, lo intercambia por credenciales
temporales de STS y estas expiran automáticamente al finalizar el job.

Además, el pipeline incorpora dos capas de análisis de seguridad estático:
**Checkov/Trivy** para detectar configuraciones IaC inseguras y **OPA/Rego** para
aplicar políticas de compliance personalizable (ej. "todos los buckets S3 deben
usar SSE-KMS").

## Objetivos

- Crear un proveedor OIDC en IAM para `token.actions.githubusercontent.com`.
- Definir un rol IAM con Trust Policy restringida a un repositorio y ref específicos.
- Integrar Checkov y Trivy en el pipeline como gates de seguridad bloqueantes.
- Escribir y ejecutar una política OPA/Rego que verifique cifrado en buckets S3.
- Comprender el flujo completo: token OIDC → `AssumeRoleWithWebIdentity` → credenciales STS temporales.

## Requisitos previos

- Terraform ≥ 1.10 instalado (requerido para lock nativo de S3).
- AWS CLI configurado con perfil `default`.
- Repositorio GitHub propio donde puedas crear workflows.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado (el lock nativo de S3 usa un fichero `.tflock` en el mismo bucket, sin necesidad de DynamoDB).

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
GitHub Actions Job
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  1. Runner solicita token OIDC firmado por GitHub       │
│        │                                                │
│  2. aws-actions/configure-aws-credentials               │
│        │  POST https://sts.amazonaws.com                │
│        │  Action: AssumeRoleWithWebIdentity             │
│        │  Token: <jwt firmado por GitHub>               │
│        ▼                                                │
│  3. IAM valida:                                         │
│        - aud == "sts.amazonaws.com"                     │
│        - sub == "repo:<org>/<repo>:<ref>"               │
│        - Emisor == token.actions.githubusercontent.com  │
│        │                                                │
│  4. STS devuelve credenciales temporales (1h)           │
│        │                                                │
│  5. terraform plan / apply con credenciales efímeras    │
│                                                         │
│  ┌─── Antes del plan ───────────────────────────────┐   │
│  │  checkov --directory aws/                        │   │
│  │  trivy config aws/                               │   │
│  │  conftest test aws/*.tf --policy policies/       │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                          │
                    ┌─────▼──────┐
                    │    AWS     │
                    │  IAM Role  │◄── Trust: OIDC Provider
                    │  (efímero) │    (token.actions.githubusercontent.com)
                    └─────┬──────┘
                          │ permisos mínimos
                          ▼
                    S3 (tfstate + lock nativo .tflock)
```

## Conceptos clave

### OIDC (OpenID Connect) para CI/CD

OIDC es una capa de identidad sobre OAuth 2.0. GitHub actúa como **Identity
Provider (IdP)**: firma un JSON Web Token (JWT) por cada job con claims que
identifican el repositorio, la rama y el workflow. AWS actúa como **Service
Provider**: verifica la firma contra el JWKS publicado en
`https://token.actions.githubusercontent.com/.well-known/openid-configuration`
y emite credenciales STS temporales si la Trust Policy lo permite.

**Ventaja clave**: las credenciales tienen TTL de 1 hora y nunca se almacenan.
No hay secreto que filtrar en GitHub.

### Trust Policy y el claim `sub`

El claim `sub` en el JWT de GitHub sigue el formato:
```
repo:<org>/<repositorio>:<ref>
```

Ejemplos:
- `repo:mi-org/mi-repo:ref:refs/heads/main` — sólo la rama `main`
- `repo:mi-org/mi-repo:*` — cualquier rama o tag
- `repo:mi-org/mi-repo:environment:production` — sólo el entorno `production`

La condición `StringLike` en la Trust Policy permite usar `*` como comodín.

### Checkov vs Trivy

| Herramienta | Enfoque | Checks destacados |
|-------------|---------|-------------------|
| Checkov | Compliance (CIS, NIST, PCI-DSS...) | MFA en root, rotación de llaves, cifrado |
| Trivy | Seguridad IaC (sucesor de tfsec) | SGs permisivos, S3 público, IMDSv1 |

Ambas se ejecutan **sin credenciales AWS** — analizan el código estático.

### OPA/Rego para IaC

Open Policy Agent (OPA) permite expresar políticas de compliance como código
Rego. `conftest` es la CLI que aplica políticas Rego a ficheros de configuración
(HCL, JSON, YAML). En este laboratorio la política `s3_encryption.rego` deniega
cualquier bucket S3 sin SSE-KMS.

#### Política `policies/s3_encryption.rego`

El fichero define tres reglas bajo el paquete `terraform.s3`:

| Regla | Tipo | Condición que activa |
|-------|------|----------------------|
| `s3-encryption` | `deny` | Existe un `aws_s3_bucket` sin ningún `aws_s3_bucket_server_side_encryption_configuration` asociado |
| `s3-kms-only` | `deny` | Existe una config de cifrado cuyo `sse_algorithm` no es `aws:kms` (p.ej. `AES256`) |
| `s3-bucket-key` | `warn` | El cifrado es `aws:kms` pero `bucket_key_enabled` está ausente, lo que incrementa el coste de llamadas a KMS |

El helper `bucket_has_encryption` vincula cada bucket con su config de cifrado
buscando que el campo `bucket` de la config contenga el nombre del recurso Terraform
(`contains(entry.bucket, bucket_name)`). Esto es necesario porque el parser HCL2
de conftest no resuelve referencias — representa `aws_s3_bucket.X.id` como el
string literal `"${aws_s3_bucket.X.id}"`.

Las reglas usan `some config_name` para declarar explícitamente la variable de
iteración antes de usarla como clave de objeto, requisito de OPA en modo v1-compatible.

#### Fixture `policies/fixtures/bad_s3.tf`

Contiene tres buckets que cubren los tres escenarios de fallo posibles:

```
aws_s3_bucket "no_encryption"          ← sin ninguna config de cifrado
                                            → FAIL [s3-encryption]

aws_s3_bucket "aes_encryption"         ← tiene config, pero con AES256
aws_s3_bucket_server_side_encryption_configuration "aes"
  sse_algorithm = "AES256"                 → FAIL [s3-kms-only]

aws_s3_bucket "kms_no_key"             ← tiene config con aws:kms
aws_s3_bucket_server_side_encryption_configuration "kms_no_key"
  sse_algorithm = "aws:kms"
  # bucket_key_enabled ausente              → WARN [s3-bucket-key]
```

El fixture no se despliega — su único propósito es verificar que la política
detecta cada tipo de incumplimiento de forma aislada.

## Estructura del proyecto

```
lab15/
├── aws/
│   ├── providers.tf          # Terraform + provider AWS
│   ├── variables.tf          # region, project, github_org, github_repo, allowed_ref
│   ├── main.tf               # OIDC provider + IAM role + PowerUserAccess attachment
│   ├── outputs.tf            # ARN del rol y del OIDC provider
│   └── aws.s3.tfbackend      # Configuración parcial del backend S3
├── pipeline/
│   ├── terraform-ci.yml      # Workflow GitHub Actions (security-scan → plan → apply)
│   └── terraform/            # Ejemplo Terraform de partida que el alumno copia a su repo
│       ├── main.tf           # KMS key mínimo - pasa todos los gates de seguridad
│       └── aws.s3.tfbackend  # Backend del demo
├── policies/
│   ├── s3_encryption.rego    # Política OPA/Rego: S3 debe usar SSE-KMS
│   └── fixtures/
│       ├── bad_s3.tf         # Buckets con cifrado ausente/incorrecto para probar s3_encryption.rego
│       └── bad_sg.tf         # Security groups permisivos para probar sg_no_public_ingress.rego
└── README.md
```

## Despliegue en AWS real

```bash
cd labs/lab-15/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan \
  -var="github_org=<tu-org-o-usuario>" \
  -var="github_repo=<nombre-del-repo>"

terraform apply \
  -var="github_org=<tu-org-o-usuario>" \
  -var="github_repo=<nombre-del-repo>"
```

Para restringir a la rama `main` únicamente:
```bash
terraform apply \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>" \
  -var="allowed_ref=ref:refs/heads/main"
```

## Verificación final

### OIDC Provider creado

```bash
# Listar proveedores OIDC de la cuenta
aws iam list-open-id-connect-providers

# Inspeccionar el proveedor de GitHub
OIDC_ARN=$(terraform output -raw oidc_provider_arn)
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
# Esperado: url=token.actions.githubusercontent.com, ClientIDList=[sts.amazonaws.com]
```

### Rol IAM

```bash
ROLE_ARN=$(terraform output -raw github_actions_role_arn)
ROLE_NAME=$(terraform output -raw github_actions_role_name)

aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.{Arn:Arn,AssumeRolePolicyDocument:AssumeRolePolicyDocument}'

# Verificar que la Trust Policy contiene la condición StringLike sobre sub
aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

### Verificar la Trust Policy del rol

`sts:AssumeRoleWithWebIdentity` lo controla la **Trust Policy** del rol (política
de recurso), no políticas de identidad. La forma correcta de verificarlo es
inspeccionarla directamente:

```bash
# Ver la Trust Policy completa
aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument'

# Confirmar las condiciones OIDC (aud + sub)
aws iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
# Esperado:
# {
#   "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
#   "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:*" }
# }
```

### Escaneo estático local (sin pipeline)

```bash
# Checkov
pip install checkov
checkov --directory . --framework terraform

# Trivy
brew install trivy   # macOS; en Linux: descarga el binario de GitHub Releases
trivy config .

# Conftest + política Rego (instalar una sola vez)
brew install conftest

# Probar la política s3_encryption con los fixtures incluidos
conftest test ../policies/fixtures/bad_s3.tf \
  --policy ../policies/ \
  --parser hcl2 \
  --all-namespaces

# Validar código propio (p.ej. lab-13 que sí tiene S3)
conftest test *.tf \
  --policy ../policies/ \
  --parser hcl2 \
  --all-namespaces
```

## Prueba de la federación OIDC con GitHub Actions

Una vez desplegada la infraestructura, la forma más directa de verificar que
la federación OIDC funciona de extremo a extremo es ejecutar un workflow real
en el repositorio GitHub que configuraste como entrada. Este apartado te guía
paso a paso.

### Cómo funciona el intercambio

Antes de crear el workflow, conviene entender qué ocurre internamente:

```
Runner de GitHub                GitHub OIDC IdP             AWS STS
      │                               │                        │
      │ 1. Solicitar token OIDC       │                        │
      │──────────────────────────────►│                        │
      │                               │                        │
      │ 2. JWT firmado (sub, aud...)  │                        │
      │◄──────────────────────────────│                        │
      │                               │                        │
      │ 3. AssumeRoleWithWebIdentity (JWT + RoleArn)           │
      │───────────────────────────────────────────────────────►│
      │                               │                        │
      │                               │  4. Verificar firma JWT│
      │                               │◄───────────────────────│
      │                               │  contra JWKS público   │
      │                               │                        │
      │                               │  5. Validar claims:    │
      │                               │  aud == sts.amazonaws  │
      │                               │  sub == repo:org/repo:*│
      │                               │                        │
      │ 6. Credenciales temporales (AccessKeyId, TTL 1h)       │
      │◄───────────────────────────────────────────────────────│
      │                               │                        │
      │ 7. aws sts get-caller-identity (con creds temporales)  │
      │───────────────────────────────────────────────────────►│
```

El JWT que emite GitHub contiene un claim `sub` con el formato:
- `repo:<org>/<repo>:ref:refs/heads/<rama>` — desde una rama
- `repo:<org>/<repo>:environment:<nombre>` — desde un entorno de GitHub

La Trust Policy del rol IAM valida ese `sub` con `StringLike`. Si no coincide,
STS devuelve `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

### Paso 1 — Crear el entorno `production` en GitHub

Si has restringido el rol con `allowed_ref = "environment:production"` (en
lugar del default `"*"`), antes de poder asumirlo necesitas que exista el
entorno en GitHub.

1. Ve a tu repositorio → **Settings** → **Environments** → **New environment**
2. Nombre: `production`
3. Opcional: activa **Required reviewers** para añadir aprobación manual

> Si tu Trust Policy usa `allowed_ref = "*"` en lugar de `environment:production`,
> omite este paso — el workflow funcionará desde cualquier rama.

### Paso 2 — Añadir el secreto `AWS_ROLE_ARN`

El ARN del rol creado por Terraform debe estar disponible en el workflow como secreto.

Obtén el valor:

```bash
terraform output -raw github_actions_role_arn
# Ejemplo: arn:aws:iam::510547572113:role/lab15-github-actions
```

En GitHub: **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**:

| Campo | Valor |
|---|---|
| Name | `AWS_ROLE_ARN` |
| Secret | el ARN del output anterior |

### Paso 3 — Crear el workflow de prueba

Desde la consola de GitHub, crea el fichero `.github/workflows/test-oidc.yml` en tu repositorio con el
siguiente contenido:

```yaml
name: Test OIDC Federation

on:
  workflow_dispatch:

permissions:
  id-token: write   # Imprescindible: sin esto GitHub no emite el token OIDC
  contents: read

jobs:
  test-oidc:
    runs-on: ubuntu-latest
    environment: production   # Hace que sub = repo:<org>/<repo>:environment:production

    steps:
      # ── Paso A: decodificar el JWT antes de enviarlo a AWS ────────────────
      # Permite ver los claims exactos (sub, aud, iss) que recibirá la Trust Policy.
      # Útil para diagnosticar si configure-aws-credentials falla.
      - name: Decodificar claims del token OIDC
        run: |
          TOKEN=$(curl -s \
            -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com")
          echo "$TOKEN" | python3 -c "
          import sys, json, base64
          t = json.load(sys.stdin)['value'].split('.')[1]
          t += '=' * (4 - len(t) % 4)
          claims = json.loads(base64.b64decode(t))
          print(json.dumps(claims, indent=2))
          "

      # ── Paso B: intercambiar el JWT por credenciales temporales de AWS ────
      # La action envía el JWT a STS. AWS verifica la firma contra el JWKS
      # público de GitHub y valida los claims contra la Trust Policy del rol.
      - name: Obtener credenciales temporales via OIDC
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1
          role-session-name: GitHubActions-OIDC-Test

      # ── Paso C: inspeccionar las credenciales temporales ─────────────────
      # configure-aws-credentials inyecta tres variables de entorno:
      #   AWS_ACCESS_KEY_ID     → visible (ASIA = temporal, AKIA = permanente)
      #   AWS_SECRET_ACCESS_KEY → enmascarado automáticamente por la action (---)
      #   AWS_SESSION_TOKEN     → enmascarado automáticamente por la action (---)
      - name: Inspeccionar credenciales temporales
        run: |
          echo "=== Fuente de credenciales ==="
          aws configure list

          echo ""
          echo "=== Access Key ID (ASIA = temporal, AKIA = permanente) ==="
          echo "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"

          echo ""
          echo "=== Secret y Token (enmascarados por configure-aws-credentials) ==="
          echo "AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
          echo "AWS_SESSION_TOKEN: $AWS_SESSION_TOKEN"

          echo ""
          echo "=== Identidad y nombre de sesión ==="
          aws sts get-caller-identity
```

**Por qué `permissions: id-token: write` es imprescindible**: por defecto los
workflows de GitHub no tienen acceso al endpoint de tokens OIDC. Sin este
permiso, `ACTIONS_ID_TOKEN_REQUEST_TOKEN` está vacío y `configure-aws-credentials`
se queda esperando indefinidamente hasta hacer timeout.

**Por qué `environment: production`**: cuando un job declara `environment`,
GitHub incluye el nombre del entorno en el claim `sub` del JWT:
`repo:<org>/<repo>:environment:production`. Sin esta declaración, el `sub` sería
`repo:<org>/<repo>:ref:refs/heads/main`, que no coincidiría con la Trust Policy
si fue desplegada con `allowed_ref = environment:production`.

### Paso 4 — Ejecutar el workflow y leer el output

Haz push del fichero y ve a **Actions** → **Test OIDC Federation** →
**Run workflow** → **Run workflow**.

**Output esperado del Paso A** (claims del JWT):

```json
{
  "aud": "sts.amazonaws.com",
  "iss": "https://token.actions.githubusercontent.com",
  "sub": "repo:<org>/<repo>:environment:production",
  "repository": "<org>/<repo>",
  "ref": "refs/heads/main",
  "event_name": "workflow_dispatch",
  ...
}
```

Los tres claims que AWS valida contra la Trust Policy son:
- `iss` — debe coincidir con la URL del OIDC provider registrado en IAM
- `aud` — debe ser `sts.amazonaws.com` (condición `StringEquals`)
- `sub` — debe coincidir con el patrón de la condición `StringLike`

**Output esperado del Paso C**:

```
=== Fuente de credenciales ===
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                <not set>             None    None
access_key     ****************XXXX              env
secret_key     ****************XXXX              env
    region                us-east-1              env    AWS_REGION

=== Access Key ID (ASIA = temporal, AKIA = permanente) ===
AWS_ACCESS_KEY_ID: ASIAIOSFODNN7EXAMPLE

=== Secret y Token (enmascarados por configure-aws-credentials) ===
AWS_SECRET_ACCESS_KEY: ***
AWS_SESSION_TOKEN: ***

=== Identidad y nombre de sesión ===
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:GitHubActions-OIDC-Test",
    "Account": "510547572113",
    "Arn": "arn:aws:sts::510547572113:assumed-role/lab15-github-actions/GitHubActions-OIDC-Test"
}
```

Tres indicadores que confirman que la federación OIDC funciona correctamente:

| Indicador | Qué demuestra |
|---|---|
| `ASIA...` en el Key ID | Credencial temporal de STS — no es una llave permanente de IAM (`AKIA`) |
| `***` en secret y token | `configure-aws-credentials` los registra como valores enmascarados con `core.setSecret()` — no filtrables en logs aunque el workflow los imprima explícitamente |
| `assumed-role/lab15-github-actions/GitHubActions-OIDC-Test` en el ARN | El rol correcto fue asumido y la sesión lleva el nombre definido en `role-session-name` — útil para auditar en CloudTrail |

Las credenciales tienen un TTL de 1 hora desde la asunción. Pasado ese tiempo,
cualquier llamada a la API devuelve `ExpiredTokenException` y el workflow debe
ejecutarse de nuevo para obtener credenciales frescas.

### Diagnóstico de errores comunes

| Error | Causa más probable | Solución |
|---|---|---|
| Step bloqueado / timeout | Falta `permissions: id-token: write` | Añadir el bloque `permissions` al workflow |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | El `sub` del token no coincide con la Trust Policy | Verificar `github_org`, `github_repo` y `allowed_ref` con `terraform output` y redesplegar |
| `ExpiredTokenException` | Las credenciales caducaron (TTL 1h) | Ejecutar el workflow de nuevo |

Para comparar el `sub` real con la Trust Policy en cualquier momento:

```bash
# Ver qué sub espera la Trust Policy
aws iam get-role \
  --role-name lab15-github-actions \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike'

# El sub real lo muestra el Paso A del workflow en el log de Actions
```

---

## Despliegue del pipeline DevSecOps

Una vez verificada la federación OIDC, el siguiente paso del lab es activar el
pipeline completo de [`pipeline/terraform-ci.yml`](pipeline/terraform-ci.yml).
Combina los tres jobs del flujo DevSecOps:

1. **`security-scan`** — Checkov + Trivy + Conftest (sin credenciales AWS).
2. **`terraform-plan`** — en pull requests **y** en push a `main`, con OIDC y entorno `aws-readonly`. En el push a main genera el `tfplan` que reutiliza el job de apply.
3. **`terraform-apply`** — solo en push a `main`, descarga el `tfplan` del job anterior y lo aplica con OIDC y aprobación manual en `aws-production`.

### Paso 1 — Crear los entornos `aws-readonly` y `aws-production`

En GitHub: **Settings** → **Environments** → **New environment**. Crea dos:

| Entorno | Uso | Recomendación |
|---|---|---|
| `aws-readonly` | `terraform plan` en pull requests | Sin reviewers — automático |
| `aws-production` | `terraform apply` tras merge a `main` | **Required reviewers** activado |

> El workflow de test OIDC del apartado anterior usaba el entorno `production`
> (más simple). Este pipeline usa dos entornos distintos para separar lectura
> y escritura: alinea el `allowed_ref` del rol con los `sub` que GitHub emitirá
> (`repo:<org>/<repo>:environment:aws-readonly` y `:environment:aws-production`).

### Paso 2 — Ajustar el `allowed_ref` del rol IAM

La Trust Policy debe aceptar los dos entornos. La forma más simple es usar `*`
y dejar que GitHub Environments haga el control de aprobación, pero si quieres
restricción estricta:

```bash
terraform apply \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>" \
  -var='allowed_ref=environment:aws-*'
```

### Paso 3 — Preparar el repo de pruebas y activar el pipeline

GitHub Actions solo ejecuta workflows ubicados en `.github/workflows/` **del
repo configurado en `github_org`/`github_repo`** (el que la Trust Policy del
rol autoriza a asumir credenciales). No copies nada a este repo del curso —
todo va al tuyo.

El pipeline está escrito para trabajar sobre una estructura genérica:

```
<tu-repo>/
├── .github/workflows/
│   └── terraform-ci.yml      ← el pipeline (de lab-15/pipeline/)
├── terraform/                ← código Terraform a desplegar (TF_DIR)
│   ├── main.tf
│   └── aws.s3.tfbackend
└── policies/                 ← políticas OPA/Rego (--policy)
    └── *.rego
```

Como punto de partida, dentro de [`pipeline/terraform/`](pipeline/terraform/)
del lab tienes un **ejemplo mínimo y seguro** (clave KMS + rotación automática)
diseñado para pasar todos los gates del pipeline sin intervención. Puedes
sustituirlo después por tu propia infraestructura.

Si aún no tienes un repo de pruebas, clónalo en `/tmp/` y trabaja desde ahí:

```bash
# Sustituye <tu-org>/<tu-repo> por los valores que pasaste a Terraform
cd /tmp
git clone git@github.com:<tu-org>/<tu-repo>.git
cd <tu-repo>

# Ajusta esto a la ruta absoluta de tu clon local del curso
export LAB_REPO="$HOME/path/al/curso/terraform-on-aws"

# 1. Copiar el workflow
mkdir -p .github/workflows
cp $LAB_REPO/labs/lab-15/pipeline/terraform-ci.yml .github/workflows/terraform-ci.yml

# 2. Copiar las políticas OPA (puedes empezar con las del lab y añadir más)
mkdir -p policies
cp $LAB_REPO/labs/lab-15/policies/*.rego policies/

# 3. Copiar el ejemplo Terraform mínimo de partida
mkdir -p terraform
cp $LAB_REPO/labs/lab-15/pipeline/terraform/* terraform/

git add .github/workflows/terraform-ci.yml policies/ terraform/
git commit -m "Activar pipeline DevSecOps de lab-15"
git push
```

A partir de aquí, cualquier cambio en `terraform/**` o `policies/**` dispara
el pipeline. Cuando quieras desplegar tu propia infraestructura, sustituye
los `*.tf` de `terraform/` por tu código (manteniendo la coherencia con el
backend declarado en `aws.s3.tfbackend`).

#### Probar los dos flujos del pipeline

Para ver con tus propios ojos el comportamiento condicional de los jobs (que
ya viste documentado en la sección anterior), prueba los dos escenarios:

**A. Push directo a `main`** — dispara el flujo completo (security-scan →
plan → apply con aprobación):

```bash
# Edita un fichero dentro de terraform/ para forzar el trigger del pipeline
echo "# trigger inicial" >> terraform/main.tf
git add terraform/main.tf
git commit -m "Trigger inicial del pipeline"
git push origin main
```

En la pestaña **Actions** del repo verás:
- ✅ `security-scan`
- ✅ `terraform-plan` (corre en push a main para generar el `tfplan`)
- ⏸ `terraform-apply` — pausa esperando aprobación en `aws-production`. Apruébalo manualmente y observa el `terraform apply tfplan`.

**B. Crear una rama, push y abrir PR contra `main`** — dispara solo
security-scan + plan (apply queda esperando al merge):

```bash
git checkout -b feature/probar-pr
echo "# cambio en una rama feature" >> terraform/main.tf
git add terraform/main.tf
git commit -m "Probar el flujo de PR"
git push origin feature/probar-pr
# Abre la PR desde la UI de GitHub o con: gh pr create --base main
```

En el run del PR:
- ✅ `security-scan`
- ✅ `terraform-plan` (el reviewer puede inspeccionar el log antes de aprobar)
- ⏭ `terraform-apply` — *skipped* (no es un push a main, todavía no toca aplicar)

Cuando mergees la PR, GitHub dispara un nuevo run sobre `main` que sí
ejecutará apply (con su pausa de aprobación).

> **¿Pipeline no se dispara?** Suele ser por el filtro `paths:` del workflow:
> si tu commit no toca `terraform/**` ni `policies/**`, GitHub no lanza el
> workflow. Verifica con `git diff --name-only origin/main...HEAD`.

### Paso 4 — Permisos del rol

El rol IAM tiene adjunta la política gestionada `PowerUserAccess`
([aws/main.tf:65-93](aws/main.tf)), que concede acceso a casi todos los
servicios AWS (S3, KMS, EC2, Lambda, etc.) salvo IAM, Organizations y
Account settings. Permite que el pipeline despliegue casi cualquier
infraestructura sin tener que ampliar la policy cada vez que cambias el demo.

> ⚠️ **PowerUserAccess no es producción.** Es una decisión didáctica para
> simplificar el lab. En producción se aplica el **principio de mínimo
> privilegio**: una policy inline restringida a los ARNs y acciones concretas
> que el rol necesita para gestionar sus recursos. Ver el [Reto](#reto--sustituir-poweruseraccess-por-una-policy-de-mínimo-privilegio)
> para hacer ese ejercicio de fortificación.

> El **workflow de prueba OIDC** del apartado anterior es independiente: sigue
> sirviendo para depurar la federación de forma aislada sin ejecutar Terraform
> ni los gates de seguridad.

---

## Ejercicio guiado — Tu primera política Rego

La política `s3_encryption.rego` ya existe y funciona. Ahora vas a escribir tú
una segunda política desde cero para aprender la estructura de Rego.

### Objetivo

Crear `policies/sg_no_public_ingress.rego` que deniegue cualquier Security Group
que permita tráfico de entrada desde `0.0.0.0/0` (todo Internet IPv4) o `::/0`
(todo Internet IPv6).

### Anatomía de una política Rego

Un fichero Rego tiene tres partes:

```
package <nombre>          ← namespace que agrupa las reglas

<regla> contains msg if { ← cabecera: tipo + variable de salida
    <condición 1>         ← cuerpo: todas deben ser verdaderas
    <condición 2>         ← (AND implícito entre líneas)
    msg := "texto"        ← construir el mensaje de error
}
```

- **`deny contains msg if`**: regla que acumula mensajes de error en un conjunto.
  Si el cuerpo es verdadero para alguna combinación de variables, añade `msg` al conjunto.
- **`warn contains msg if`**: igual pero produce advertencias, no fallos.
- **`[_]`**: iterador anónimo — recorre todos los elementos de un array u objeto.
- **`some x`**: declara `x` como variable de iteración sobre las claves de un objeto.

### Cómo conftest ve el HCL

Antes de escribir la política, necesitas saber cómo conftest transforma el HCL.
El parser HCL2 convierte cada bloque `resource` en un mapa de arrays:

```hcl
# Código Terraform original
resource "aws_security_group" "mi_sg" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Se convierte en este JSON (que Rego ve como `input`):

```json
{
  "resource": {
    "aws_security_group": {
      "mi_sg": [
        {
          "ingress": [
            { "cidr_blocks": ["0.0.0.0/0"] }
          ]
        }
      ]
    }
  }
}
```

El nivel extra de array (los `[...]` alrededor del objeto) es específico del
parser HCL2 — requiere dos iteraciones: una para la clave del mapa y otra para
desenvolver el array.

### Paso 1 — Estructura básica del fichero

Crea `labs/lab-15/policies/sg_no_public_ingress.rego` con el paquete, el
import del syntax v1 (compatibilidad con versiones de OPA anteriores a la 1.0)
y el conjunto de CIDRs prohibidos:

```rego
package terraform.security_groups

import rego.v1

public_cidrs := {"0.0.0.0/0", "::/0"}
```

`public_cidrs` es un **conjunto** Rego (llaves `{}`). El operador `in` comprueba
pertenencia, lo que evita duplicar la regla para IPv4 e IPv6.

### Paso 2 — Primera regla: SGs con ingress inline IPv4

```rego
deny contains msg if {
    some sg_name                                              # (1)
    sg_entries := input.resource.aws_security_group[sg_name] # (2)
    sg         := sg_entries[_]                              # (3)
    ingress    := sg.ingress[_]                              # (4)
    cidr       := ingress.cidr_blocks[_]                     # (5)
    cidr in public_cidrs                                     # (6)
    msg := sprintf(
        "FAIL [sg-no-public-ingress]: Security group '%s' permite ingreso desde '%s'.",
        [sg_name, cidr],
    )
}
```

Línea por línea:

1. `some sg_name` — declara la variable que iterará sobre los nombres de recurso.
2. `sg_entries` — obtiene el array asociado al nombre (p.ej. `[{ingress: [...]}]`).
3. `sg` — desenvuelve el array con `[_]`, dando el objeto con los atributos del SG.
4. `ingress` — itera sobre los bloques `ingress` del SG (también es array).
5. `cidr` — itera sobre cada CIDR del bloque ingress.
6. `cidr in public_cidrs` — condición de fallo: el CIDR está en el conjunto prohibido.

### Paso 3 — Segunda regla: SGs con ingress inline IPv6

Añade una regla idéntica pero para `ipv6_cidr_blocks`:

```rego
deny contains msg if {
    some sg_name
    sg_entries := input.resource.aws_security_group[sg_name]
    sg         := sg_entries[_]
    ingress    := sg.ingress[_]
    cidr       := ingress.ipv6_cidr_blocks[_]
    cidr in public_cidrs
    msg := sprintf(
        "FAIL [sg-no-public-ingress-ipv6]: Security group '%s' permite ingreso IPv6 desde '%s'.",
        [sg_name, cidr],
    )
}
```

### Paso 4 — Tercera regla: `aws_security_group_rule` independiente

Terraform permite definir reglas de SG como recursos separados. Hay que cubrirlos:

```rego
deny contains msg if {
    some rule_name
    rule_entries := input.resource.aws_security_group_rule[rule_name]
    rule         := rule_entries[_]
    rule.type    == "ingress"
    cidr         := rule.cidr_blocks[_]
    cidr in public_cidrs
    msg := sprintf(
        "FAIL [sg-rule-no-public-ingress]: Regla de SG '%s' permite ingreso desde '%s'.",
        [rule_name, cidr],
    )
}
```

La condición `rule.type == "ingress"` filtra solo las reglas de entrada — las
de salida (`egress`) no son un problema de exposición pública.

### Paso 5 — Verificar con el fixture

El fichero `policies/fixtures/bad_sg.tf` contiene cuatro recursos diseñados para
cubrir cada escenario:

```
aws_security_group "open_ipv4"   cidr_blocks      = ["0.0.0.0/0"]  → FAIL [sg-no-public-ingress]
aws_security_group "open_ipv6"   ipv6_cidr_blocks = ["::/0"]        → FAIL [sg-no-public-ingress-ipv6]
aws_security_group_rule "open_rule" cidr_blocks   = ["0.0.0.0/0"]  → FAIL [sg-rule-no-public-ingress]
aws_security_group "restricted"  cidr_blocks      = ["10.0.0.0/8"] → sin fallos (1 passed)
```

Ejecuta:

```bash
conftest test labs/lab-15/policies/fixtures/bad_sg.tf \
  --policy labs/lab-15/policies/ \
  --parser hcl2 \
  --all-namespaces
```

Salida esperada:

```
FAIL - bad_sg.tf - terraform.security_groups - FAIL [sg-no-public-ingress]: Security group 'open_ipv4' permite ingreso desde '0.0.0.0/0'.
FAIL - bad_sg.tf - terraform.security_groups - FAIL [sg-no-public-ingress-ipv6]: Security group 'open_ipv6' permite ingreso IPv6 desde '::/0'.
FAIL - bad_sg.tf - terraform.security_groups - FAIL [sg-rule-no-public-ingress]: Regla de SG 'open_rule' permite ingreso desde '0.0.0.0/0'.

3 tests, 1 passed, 0 warnings, 3 failures, 0 exceptions
```

El `restricted` produce el "1 passed" — su CIDR `10.0.0.0/8` no está en `public_cidrs`.

---

## Reto — Sustituir PowerUserAccess por una policy de mínimo privilegio

El rol del lab tiene `PowerUserAccess`, lo que es cómodo para el demo pero
sería inaceptable en producción: si las credenciales temporales se filtraran,
el atacante podría tocar prácticamente cualquier servicio de la cuenta.

Tu tarea es sustituir el `aws_iam_role_policy_attachment` actual por una
**policy inline de mínimo privilegio** que conceda exactamente lo que el demo
del pipeline (`pipeline/terraform/main.tf`) necesita y nada más:

- `s3:Get*/Put*/List*/Delete*` solo sobre el bucket de estado (con condition
  de prefijo si quieres ser aún más estricto).
- Permisos KMS para gestionar la CMK del demo (CreateKey, CreateAlias,
  Describe/Get/Put policy, EnableKeyRotation, TagResource, ScheduleKeyDeletion...).
- `iam:GetRole`, `iam:GetOpenIDConnectProvider` y similares para el refresh
  del estado del propio lab-15.

**Requisito**: nada de políticas gestionadas AWS (`ReadOnlyAccess`,
`PowerUserAccess`, etc.). Todo en `data.aws_iam_policy_document` declarando
acciones y recursos concretos.

#### Prueba

```bash
ROLE_NAME=$(terraform output -raw github_actions_role_name)

# 1. Confirmar que PowerUserAccess ya no está adjunto
aws iam list-attached-role-policies --role-name "$ROLE_NAME"
# Esperado: lista vacía o sin "PowerUserAccess"

# 2. Confirmar que la policy inline existe con los statements esperados
aws iam list-role-policies --role-name "$ROLE_NAME"
# Esperado: ["lab15-terraform-permissions"] (o el nombre que le hayas dado)

aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name lab15-terraform-permissions \
  --query 'PolicyDocument.Statement[].Sid'
# Esperado: nombres de tus statements (TerraformStateS3, KMSManagement, IAMReadOnly, etc.)

# 3. Re-ejecutar el pipeline en tu repo de pruebas. El plan y el apply del
#    demo (KMS) deben seguir funcionando. Si añades un recurso fuera del
#    alcance de la policy (ej. un aws_s3_bucket), el apply debe fallar con
#    AccessDenied — eso prueba que el principio funciona.
```

## Solución

<details>
<summary>Sustituir PowerUserAccess por una policy inline mínima</summary>

**Paso 1 — Eliminar el attachment de PowerUserAccess en `aws/main.tf`**:

Borra el recurso `aws_iam_role_policy_attachment.github_actions_poweruser`.

**Paso 2 — Declarar la policy inline con los statements mínimos**:

```hcl
data "aws_iam_policy_document" "terraform_permissions" {
  # Estado de Terraform en S3
  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::terraform-state-labs-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::terraform-state-labs-${data.aws_caller_identity.current.account_id}/*",
    ]
  }

  # Gestión de la CMK del demo del pipeline.
  # KMS no soporta ARNs específicos en CreateKey/CreateAlias - hay que usar "*".
  statement {
    sid    = "KMSManagement"
    effect = "Allow"
    actions = [
      "kms:CreateKey", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy",
      "kms:GetKeyRotationStatus", "kms:EnableKeyRotation", "kms:DisableKeyRotation",
      "kms:UpdateKeyDescription",
      "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags",
      "kms:ListAliases", "kms:ListKeys",
      "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  # IAM read-only para el refresh del estado del propio lab-15
  statement {
    sid    = "IAMReadOnly"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  # STS para que aws_caller_identity funcione
  statement {
    sid       = "STSCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name   = "${var.project}-terraform-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.terraform_permissions.json
}
```

**Paso 3 — Aplicar y verificar**:

```bash
terraform apply -var="github_org=<tu-org>" -var="github_repo=<tu-repo>"
```

**Por qué algunos statements usan `resources = ["*"]`**: muchas acciones
KMS de creación (`CreateKey`, `CreateAlias`) no admiten ARNs específicos
porque el recurso aún no existe en el momento de la llamada. IAM requiere
`"*"` para esos casos. Donde sí se puede (S3 buckets concretos), se usa el
ARN específico.

**Si añades nuevos recursos al demo**: cuando sustituyes `pipeline/terraform/`
por código que use otros servicios (RDS, EC2, Lambda...), el apply fallará
con `AccessDenied` hasta que añadas los statements correspondientes a esta
policy. Esto es el principio funcionando — vas concediendo permisos
deliberadamente, no por defecto.

</details>

## Limpieza

```bash
cd labs/lab-15/aws
terraform destroy \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>"
```

## Buenas prácticas aplicadas

- **Sin credenciales estáticas**: el rol IAM sólo es asumible via OIDC, nunca con `AWS_ACCESS_KEY_ID`.
- **Lock nativo de S3**: Terraform ≥ 1.10 gestiona el lock con un fichero `.tflock` en el propio bucket — sin dependencia de DynamoDB.
- **Restricción por repositorio y ref**: la condición `StringLike` en `sub` evita que otros repositorios asuman el rol.
- **Separación de entornos GitHub**: `aws-readonly` para `plan` (automático) y `aws-production` para `apply` (con aprobación manual). El claim `sub` del JWT incluye el entorno, lo que permitiría incluso usar dos roles distintos en AWS.
- **Plan reutilizado en apply**: el `terraform apply` consume el `tfplan` generado por el job de plan en el mismo run — sin re-plan ni "plan drift" entre validación y ejecución.
- **Seguridad desplazada a la izquierda**: Checkov y Trivy ejecutan antes del `plan` — un fallo de seguridad bloquea el pipeline sin consumir llamadas a AWS.
- **Política como código**: OPA/Rego permite versionar, revisar y reutilizar reglas de compliance igual que el código de infraestructura.
- **PowerUserAccess solo para el lab**: el rol del pipeline tiene una política gestionada amplia para simplificar el aprendizaje, pero el [Reto](#reto--sustituir-poweruseraccess-por-una-policy-de-mínimo-privilegio) muestra cómo sustituirla por una policy inline de mínimo privilegio — patrón obligatorio en producción.

## Recursos

- [Configurar OIDC de GitHub en AWS — Documentación oficial](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [Checkov — Reglas para Terraform](https://www.checkov.io/5.Policy%20Index/terraform.html)
- [Trivy — Documentación](https://trivy.dev/)
- [OPA/Rego — Documentación](https://www.openpolicyagent.org/docs/policy-language)
- [Conftest — Testing con OPA](https://www.conftest.dev/)
