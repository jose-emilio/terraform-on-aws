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
                    S3 (tfstate) + DynamoDB (lock)
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

### Thumbprint del OIDC Provider

El thumbprint es el hash SHA-1 del certificado raíz de la CA que firma el TLS de
`token.actions.githubusercontent.com`. AWS lo usa para validar la identidad del
IdP. El valor `6938fd4d98bab03faadb97b34396831e3780aea1` corresponde a DigiCert
High Assurance EV Root CA.

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
│   ├── main.tf               # OIDC provider + IAM role + política inline
│   ├── outputs.tf            # ARN del rol y del OIDC provider
│   └── aws.s3.tfbackend      # Configuración parcial del backend S3
├── pipeline/
│   └── terraform-ci.yml      # Workflow GitHub Actions (security-scan → plan → apply)
├── policies/
│   ├── s3_encryption.rego    # Política OPA/Rego: S3 debe usar SSE-KMS
│   └── fixtures/
│       ├── bad_s3.tf         # Buckets con cifrado ausente/incorrecto para probar s3_encryption.rego
│       └── bad_sg.tf         # Security groups permisivos para probar sg_no_public_ingress.rego
└── README.md
```

## Despliegue en AWS real

```bash
cd labs/lab15/aws

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
checkov --directory labs/lab15/aws --framework terraform

# Trivy
brew install trivy   # macOS; en Linux: descarga el binario de GitHub Releases
trivy config labs/lab15/aws

# Conftest + política Rego (instalar una sola vez)
brew install conftest  # o descarga el binario de GitHub Releases https://github.com/aquasecurity/trivy/releases/

# Probar la política s3_encryption con los fixtures incluidos
conftest test labs/lab15/policies/fixtures/bad_s3.tf \
  --policy labs/lab15/policies/ \
  --parser hcl2 \
  --all-namespaces

# Validar código propio (p.ej. lab13 que sí tiene S3)
conftest test labs/lab13/aws/*.tf \
  --policy labs/lab15/policies/ \
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

El rol fue desplegado con la restricción por entorno (Reto 1). Antes de poder
asumir el rol, necesitas que exista el entorno en GitHub.

1. Ve a tu repositorio → **Settings** → **Environments** → **New environment**
2. Nombre: `production`
3. Opcional: activa **Required reviewers** para añadir aprobación manual

> Si tu Trust Policy usa `allowed_ref = "*"` en lugar de `environment:production`,
> omite este paso — el workflow funcionará desde cualquier rama.

### Paso 2 — Añadir el secreto `AWS_ROLE_ARN`

El ARN del rol creado por Terraform debe estar disponible en el workflow como secreto.

Obtén el valor:

```bash
cd labs/lab15/aws
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

Crea el fichero `.github/workflows/test-oidc.yml` en tu repositorio con el
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
| `InvalidIdentityToken` | El thumbprint del OIDC provider no coincide | Recrear el `aws_iam_openid_connect_provider` con `terraform taint` |
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

Crea `labs/lab15/policies/sg_no_public_ingress.rego` con el paquete y el
conjunto de CIDRs prohibidos:

```rego
package terraform.security_groups

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
conftest test labs/lab15/policies/fixtures/bad_sg.tf \
  --policy labs/lab15/policies/ \
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

## Retos

### Reto 1 — Restringir el rol al entorno `production` de GitHub

Por defecto el rol acepta cualquier ref (`allowed_ref = "*"`). Añade soporte
para restringir también por **entorno de GitHub** (el claim `sub` incluye
`environment:<nombre>` cuando el workflow declara `environment:`).

**Objetivo**: el rol sólo debe ser asumible desde el entorno `production` del
repositorio autorizado, no desde ninguna rama directamente.

**Pista**: el claim `sub` en ese caso tiene la forma
`repo:<org>/<repo>:environment:production`.

#### Prueba

```bash
# Comprueba que la Trust Policy actualizada contiene el entorno
aws iam get-role \
  --role-name lab15-github-actions \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike'
# Esperado: {"token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:environment:production"}
```

---

### Reto 2 — Añadir permiso de sólo lectura sobre EC2 al rol

El rol actual sólo puede operar sobre S3 y DynamoDB (para el estado de
Terraform). Extiéndelo para que pueda ejecutar `terraform plan` en
infraestructuras que incluyan recursos EC2, añadiendo los permisos de lectura
necesarios (`ec2:Describe*`).

**Requisito**: no usar políticas gestionadas AWS (`ReadOnlyAccess`); define los
permisos con granularidad mínima en la política inline existente.

#### Prueba

```bash
ROLE_NAME=$(terraform output -raw github_actions_role_name)

# Verificar que el nuevo statement aparece en la política inline
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name lab15-terraform-permissions \
  --query 'PolicyDocument.Statement[?Sid==`EC2ReadOnly`]'
# Esperado: statement con Action ["ec2:Describe*"] y Effect "Allow"
```

## Soluciones

<details>
<summary>Reto 1 — Restringir al entorno production</summary>

Actualiza `variables.tf` para documentar el nuevo formato y aplica con:

```bash
terraform apply \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>" \
  -var='allowed_ref=environment:production'
```

La variable `allowed_ref` ya se incluye directamente en el claim `sub`:
`repo:<org>/<repo>:environment:production`. El recurso `aws_iam_openid_connect_provider`
y la Trust Policy no cambian — sólo el valor de `allowed_ref`.

**Por qué funciona**: la condición `StringLike` en la Trust Policy compara el
claim `sub` del JWT con el patrón `repo:<org>/<repo>:<allowed_ref>`. Si el
workflow declara `environment: production`, GitHub emite el token con
`sub = repo:<org>/<repo>:environment:production`, que coincide exactamente con
el patrón. Si el job no declara entorno, `sub` será `repo:<org>/<repo>:ref:refs/heads/<rama>`
y la condición fallará — el rol no se asumirá.

**Verificación**:
```bash
aws iam get-role \
  --role-name lab15-github-actions \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

Resultado esperado:
```json
{
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
  },
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:environment:production"
  }
}
```

</details>

<details>
<summary>Reto 2 — Permisos EC2 mínimos en la política inline</summary>

Añade un statement en `data.aws_iam_policy_document.terraform_permissions` en
`main.tf`:

```hcl
statement {
  sid    = "EC2ReadOnly"
  effect = "Allow"
  actions = [
    "ec2:DescribeInstances",
    "ec2:DescribeInstanceTypes",
    "ec2:DescribeImages",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeSubnets",
    "ec2:DescribeVpcs",
    "ec2:DescribeVolumes",
    "ec2:DescribeKeyPairs",
    "ec2:DescribeAvailabilityZones",
    "ec2:DescribeTags",
    "ec2:DescribeInternetGateways",
    "ec2:DescribeRouteTables",
    "ec2:DescribeNetworkInterfaces",
    "ec2:DescribeInstanceAttribute",
  ]
  resources = ["*"]  # Las acciones Describe* de EC2 no admiten recursos específicos
}
```

Luego aplica:
```bash
terraform apply \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>"
```

**Por qué `resources = ["*"]`**: las acciones `ec2:Describe*` son operaciones
de lista/lectura que operan sobre la API regional — no hay un ARN de recurso
específico que se pueda restringir. IAM requiere `"*"` para estas acciones.
Esto es diferente de las acciones que operan sobre un recurso concreto (ej.
`ec2:StartInstances` acepta ARN de instancia).

**Verificación** (los permisos de identidad sí son evaluables con `simulate-principal-policy`):
```bash
aws iam simulate-principal-policy \
  --policy-source-arn "$(terraform output -raw github_actions_role_arn)" \
  --action-names "ec2:DescribeInstances" \
  --resource-arns "*"
# Esperado: EvalDecision: allowed
```

</details>

## Limpieza

```bash
cd labs/lab15/aws
terraform destroy \
  -var="github_org=<tu-org>" \
  -var="github_repo=<tu-repo>"
```

## Buenas prácticas aplicadas

- **Sin credenciales estáticas**: el rol IAM sólo es asumible via OIDC, nunca con `AWS_ACCESS_KEY_ID`.
- **Lock nativo de S3**: Terraform ≥ 1.10 gestiona el lock con un fichero `.tflock` en el propio bucket — sin dependencia de DynamoDB.
- **Principio de mínimo privilegio**: la política inline limita acciones a S3 del estado + IAM read-only.
- **Restricción por repositorio y ref**: la condición `StringLike` en `sub` evita que otros repositorios asuman el rol.
- **Seguridad desplazada a la izquierda**: Checkov y Trivy ejecutan antes del `plan` — un fallo de seguridad bloquea el pipeline sin consumir llamadas a AWS.
- **Política como código**: OPA/Rego permite versionar, revisar y reutilizar reglas de compliance igual que el código de infraestructura.
- **Entorno de aprobación**: el job `terraform-apply` requiere aprobación manual en el entorno `aws-production` de GitHub.

## Recursos

- [Configurar OIDC de GitHub en AWS — Documentación oficial](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [Checkov — Reglas para Terraform](https://www.checkov.io/5.Policy%20Index/terraform.html)
- [Trivy — Documentación](https://trivy.dev/)
- [OPA/Rego — Documentación](https://www.openpolicyagent.org/docs/policy-language)
- [Conftest — Testing con OPA](https://www.conftest.dev/)
