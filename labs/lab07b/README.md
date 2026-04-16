# Laboratorio 7b — HCP Terraform como Backend Remoto

[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio configurarás **HCP Terraform** como backend de
estado y motor de ejecución remota para un proyecto Terraform real que despliega
infraestructura en AWS. A diferencia del lab07, donde gestionabas tu propio bucket S3 y
tabla DynamoDB, aquí delgas toda la operación del estado a la plataforma SaaS de
HashiCorp: cifrado, versionado, locking y auditoría de runs están incluidos sin
infraestructura adicional que mantener.

El laboratorio cubre el ciclo completo: registro de cuenta, creación de organización y
workspace, configuración de la confianza OIDC entre HCP Terraform y AWS IAM (sin
credenciales estáticas), migración del bloque `backend` local al bloque `cloud {}`, y
ejecución de un plan y un apply observando los resultados tanto en el terminal como en
la UI de HCP Terraform.

## Objetivos

- Registrar una cuenta gratuita en HCP Terraform y crear una organización
- Crear un workspace en modo **CLI-driven**
- Configurar la autenticación entre HCP Terraform y AWS mediante **OIDC Dynamic
  Provider Credentials** — sin claves de acceso estáticas en el workspace
- Crear el IAM OIDC Identity Provider y el IAM Role con la trust policy correcta
- Reemplazar el bloque `backend "s3"` por el bloque `cloud {}` y ejecutar `terraform init`
  para migrar el estado
- Comprender la diferencia entre modo de ejecución **Remote** (plan y apply en agentes
  de HCP) y **Local** (solo estado remoto)
- Observar el historial de runs, el estado versionado y los logs desde la UI de
  HCP Terraform
- Gestionar variables Terraform directamente desde la UI sin modificar el código

## Requisitos previos

- Cuenta de correo electrónico válida para el registro en HCP Terraform
- AWS CLI configurado con credenciales válidas (`aws sts get-caller-identity`)
- Terraform >= 1.1 instalado (versión mínima que soporta el bloque `cloud {}`)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
export TFC_ORG="terraform-labs-${ACCOUNT_ID}"   # nombre de tu organización HCP
export TFC_WORKSPACE="lab07b-dev"               # nombre del workspace
```

## Dependencias entre pasos

| Paso | Requiere | Variables que genera |
|------|----------|----------------------|
| Paso 1 — Registrar cuenta y organización | Correo electrónico | `TFC_ORG`, `TFC_TOKEN` |
| Paso 2 — Crear project, workspace y configurar OIDC | Paso 1 | `TFC_PROJECT`, `TFC_WORKSPACE`, `OIDC_ROLE_ARN` |
| Paso 3 — Configurar bloque `cloud {}` | Paso 1, Paso 2 | — |
| Paso 4 — Migrar estado y desplegar | Paso 3 | `VPC_ID`, `SUBNET_ID` |
| Paso 5 — Explorar la UI | Paso 4 | — |
| Reto 1 | Paso 4 | — |
| Reto 2 | Paso 4 | — |
| Reto 3 | Paso 4 | — |

## Arquitectura

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         TERRAFORM CLOUD (HCP)                                ║
║                                                                              ║
║  ┌─────────────────────────────────────────────────────────────────────┐     ║
║  │  Organización: terraform-labs-<ACCOUNT_ID>                          │     ║
║  │                                                                     │     ║
║  │  ┌───────────────────────────┐   ┌───────────────────────────┐      │     ║
║  │  │  Workspace: lab07b-dev    │   │  Workspace: lab07b-prod   │      │     ║
║  │  │  (Reto 3)                 │   │  Execution: Remote        │      │     ║
║  │  │  Execution: Remote        │   │  Variables: AWS creds     │      │     ║
║  │  │  Variables: AWS creds     │   │  Estado: versionado       │      │     ║
║  │  │  Estado: versionado       │   └───────────────────────────┘      │     ║
║  │  └───────────────────────────┘                                      │     ║
║  │                    │  state / runs / vars                           │     ║
║  └────────────────────┼────────────────────────────────────────────────┘     ║
╚═══════════════════════╪══════════════════════════════════════════════════════╝
                        │  terraform plan / apply
                        │  (ejecutado en agentes HCP o local según modo)
                        ▼
╔═══════════════════════════════════════════════════════╗
║                    AWS (us-east-1)                    ║
║                                                       ║
║  ┌──────────────────────────────────────────────┐     ║
║  │  VPC: lab07b-vpc  (10.0.0.0/16)              │     ║
║  │                                              │     ║
║  │  ┌────────────────────┐                      │     ║
║  │  │  Subnet pública    │                      │     ║
║  │  │  10.0.1.0/24       │                      │     ║
║  │  └────────────────────┘                      │     ║
║  │                                              │     ║
║  │  Internet Gateway                            │     ║
║  │  Route Table (0.0.0.0/0 → IGW)               │     ║
║  └──────────────────────────────────────────────┘     ║
╚═══════════════════════════════════════════════════════╝
```

El bloque `cloud {}` en `providers.tf` es el único punto de unión entre el código local y
la plataforma HCP. Terraform CLI se autentica con el token generado en el Paso 1 y delega
la ejecución y el almacenamiento del estado al workspace configurado.

## Conceptos clave

### HCP Terraform vs. Terraform OSS

Terraform Open Source gestiona el estado localmente o en un backend remoto que tú
configuras y mantienes (S3, GCS, Azure Blob…). HCP Terraform es la capa SaaS de
HashiCorp que incluye:

| Característica | Terraform OSS + S3 | HCP Terraform (Free) |
|---|---|---|
| Almacenamiento de estado | Bucket S3 (gestionas tú) | Gestionado por HCP |
| State locking | DynamoDB o lockfile | Nativo, automático |
| Historial de estados | Versiones S3 | UI con diff entre versiones |
| Ejecución remota | No (solo local) | Sí (agentes HCP) |
| Variables sensibles | `terraform.tfvars` o env vars | Vault interno del workspace |
| Auditoría de runs | No | Log completo por run |
| RBAC | No | Teams + permisos por workspace |

El plan **Free** de HCP Terraform incluye: organizaciones ilimitadas, 500 recursos
gestionados, runs remotos, estado versionado y un usuario. Es suficiente para todos los
ejercicios de este laboratorio.

### Tipos de workspace

HCP Terraform soporta tres formas de conectar un workspace con el código fuente:

- **CLI-driven**: el desarrollador ejecuta `terraform plan/apply` desde su terminal. El
  CLI envía el código al workspace y la ejecución ocurre en los agentes de HCP. Es el
  modo más parecido al flujo local y el que usamos en este laboratorio.
- **VCS-driven**: el workspace está conectado a un repositorio Git (GitHub, GitLab…).
  Cada push a la rama configurada dispara automáticamente un plan. El apply puede ser
  manual o automático.
- **API-driven**: el código se sube mediante la API de HCP, típicamente desde un pipeline
  CI/CD personalizado.

### Bloque `cloud {}` vs. `backend "remote"`

A partir de Terraform 1.1, el bloque `cloud {}` reemplaza al bloque `backend "remote"`,
que quedó deprecado. Las diferencias prácticas:

```hcl
# ❌ Forma antigua — deprecada desde TF 1.1
terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "mi-org"
    workspaces {
      name = "mi-workspace"
    }
  }
}

# ✅ Forma moderna
terraform {
  cloud {
    organization = "mi-org"
    workspaces {
      name = "mi-workspace"
    }
  }
}
```

El bloque `cloud {}` también soporta `tags` en lugar de `name` para seleccionar
dinámicamente un workspace según las etiquetas asignadas — útil cuando se gestiona
múltiples workspaces con la misma configuración.

### Modos de ejecución

Cada workspace tiene un **Execution Mode** que determina dónde se ejecuta el plan y el
apply:

- **Remote** (por defecto): Terraform CLI serializa el directorio de trabajo y lo envía
  a HCP. Los agentes de HCP ejecutan `terraform plan` y `terraform apply`. Las variables
  de entorno configuradas en el workspace (incluidas las credenciales AWS) son inyectadas
  automáticamente. Los logs se transmiten en tiempo real al terminal local y quedan
  almacenados en HCP.
- **Local**: el plan y el apply se ejecutan en la máquina local, pero el estado se lee y
  escribe en HCP. Es útil cuando necesitas acceso a recursos de red privada o herramientas
  locales durante la ejecución.

### Variables en HCP Terraform

El workspace tiene su propio almacén de variables, separado de los ficheros locales:

- **Terraform variables**: equivalen a `TF_VAR_nombre`. Se pasan al plan como inputs.
  Pueden marcarse como *Sensitive* para que no aparezcan en los logs.
- **Environment variables**: se inyectan en el entorno del proceso Terraform durante la
  ejecución. Con autenticación OIDC se usan para `TFC_AWS_PROVIDER_AUTH` y
  `TFC_AWS_RUN_ROLE_ARN` — **nunca** para `AWS_ACCESS_KEY_ID` ni `AWS_SECRET_ACCESS_KEY`.

### OIDC Dynamic Provider Credentials

La forma tradicional de autenticar HCP Terraform contra AWS es almacenar
`AWS_ACCESS_KEY_ID` y `AWS_SECRET_ACCESS_KEY` como variables de entorno en el workspace.
Esto funciona, pero presenta dos problemas:

1. **Credenciales de larga duración**: una clave de acceso es válida indefinidamente hasta
   que se rota manualmente. Si se filtra (logs, historial de runs, error de configuración),
   el atacante tiene acceso permanente.
2. **Gestión operativa**: rotar claves en múltiples workspaces es una tarea manual propensa
   a errores.

**OIDC (OpenID Connect) Dynamic Provider Credentials** resuelve ambos problemas. El flujo
es el siguiente:

```
HCP Terraform (agente)
        │
        │  1. Genera un JWT firmado por HCP
        │     con claims sobre la organización,
        │     workspace y fase del run
        │
        ▼
AWS STS (AssumeRoleWithWebIdentity)
        │
        │  2. Verifica el JWT contra el
        │     OIDC Identity Provider de AWS
        │     (app.terraform.io)
        │
        │  3. Comprueba las condiciones
        │     de la trust policy del rol IAM
        │
        ▼
Credenciales temporales STS
(válidas 1 hora, rotación automática)
        │
        ▼
Provider AWS usa las credenciales
para desplegar infraestructura
```

Las credenciales STS generadas son **temporales** (TTL de 1 hora), se rotan
automáticamente en cada run y nunca se almacenan en el workspace. No hay ningún secreto
que gestionar ni rotar.

**Componentes IAM necesarios:**

- **IAM OIDC Identity Provider**: registra `app.terraform.io` como fuente de identidad
  de confianza en la cuenta AWS. Incluye el thumbprint TLS del certificado raíz del
  servidor.
- **IAM Role con trust policy**: permite que el OIDC provider asuma el rol, con
  condiciones que acotan exactamente qué workspace (y opcionalmente qué fase del run:
  `plan` o `apply`) puede hacerlo.

**Variables de control en el workspace:**

| Variable | Tipo | Valor | Descripción |
|----------|------|-------|-------------|
| `TFC_AWS_PROVIDER_AUTH` | Environment | `true` | Activa Dynamic Provider Credentials |
| `TFC_AWS_RUN_ROLE_ARN` | Environment | ARN del rol | Rol que asumirá el agente HCP |

### API Token

Para que el CLI se autentique contra HCP existen tres tipos de token:

| Tipo | Scope | Uso típico |
|------|-------|------------|
| **User token** | Todos los workspaces del usuario | Desarrollo local |
| **Team token** | Workspaces del equipo | CI/CD compartido |
| **Organization token** | Toda la organización | Automatización admin |

`terraform login` genera y almacena automáticamente un **user token** en
`~/.terraform.d/credentials.tfrc.json`.

## Estructura objetivo

> El repositorio parte vacío. Los ficheros siguientes se crean paso a paso durante el laboratorio.

```
lab07b/
└── aws/
    ├── providers.tf    Provider AWS ~6.0, bloque cloud {} apuntando a HCP
    ├── variables.tf    Variables: región, entorno, cidr_vpc, cidr_subnet
    ├── main.tf         VPC + subnet pública + IGW + route table
    └── outputs.tf      VPC ID, subnet ID, IGW ID
```

> El IAM OIDC Identity Provider y el IAM Role se crean manualmente desde la consola de
> AWS en el Paso 2 — no forman parte del estado de Terraform de este laboratorio.

---

## Paso 1 — Registrar cuenta y crear organización

### Crear la cuenta en HCP Terraform

1. Abre [app.terraform.io](https://app.terraform.io) en el navegador.
2. Pulsa **Create an account**.
3. Introduce nombre de usuario, correo electrónico y contraseña. Acepta los términos.
4. Verifica el correo electrónico con el enlace que recibirás.
5. Tras la verificación, la plataforma presenta automáticamente la pantalla
   **Create an API token**. Introduce una descripción (p.ej. `lab07b-token`) y define
   la **fecha de expiración** del token.

   > La fecha de expiración es una buena práctica de seguridad: un token sin expiración
   > es válido indefinidamente y si se filtra (historial de shell, portapapeles, logs)
   > otorga acceso permanente a la cuenta. Para un laboratorio puntual es suficiente con
   > 7 días; en entornos de equipo se recomienda 30-90 días con rotación automatizada.

6. Pulsa **Generate token** y **copia el valor generado** — la UI solo lo muestra
   una vez.

### Autenticar el CLI con el token generado

Con el token copiado, ejecuta `terraform login` desde el terminal:

```bash
terraform login
```

El CLI pedirá confirmación antes de abrir el navegador:

```
Terraform will request an API token for app.terraform.io using your browser.

If login is successful, Terraform will store the token in plain text in
the following file for use by subsequent commands:
    ~/.terraform.d/credentials.tfrc.json

Do you want to proceed?
  Only 'yes' will be accepted to confirm.

  Enter a value: yes
```

Introduce `yes`. El CLI abrirá el navegador en la página de tokens de HCP e indicará
que pegues el token en el terminal:

```
---------------------------------------------------------------------------------

Terraform must now open a web browser to the tokens page for app.terraform.io.

If a browser does not open this automatically, open the following URL to proceed:
    https://app.terraform.io/app/settings/tokens?source=terraform-login

---------------------------------------------------------------------------------

Generate a token using your browser, and copy-paste it into this prompt.

Terraform will store the token in plain text in the following file
for use by subsequent commands:
    ~/.terraform.d/credentials.tfrc.json

Token for app.terraform.io:
  Enter a value:
```

Pega el token que copiaste en el paso anterior y pulsa Enter. Salida esperada:

```
Retrieved token for user <tu-usuario>


---------------------------------------------------------------------------------

                                          -
                                          -----                           -
                                          ---------                      --
                                          ---------  -                -----
                                           ---------  ------        -------
                                             -------  ---------  ----------
                                                ----  ---------- ----------
                                                  --  ---------- ----------
   Welcome to HCP Terraform!                       -  ---------- -------
                                                      ---  ----- ---
   Documentation: terraform.io/docs/cloud             --------   -
                                                      ----------
                                                      ----------
                                                       ---------
                                                           -----
                                                               -


   New to HCP Terraform? Follow these steps to instantly apply an example configuration:

   $ git clone https://github.com/hashicorp/tfc-getting-started.git
   $ cd tfc-getting-started
   $ scripts/setup.sh
```

El token queda almacenado en `~/.terraform.d/credentials.tfrc.json` y será usado
automáticamente por cualquier comando `terraform` que necesite comunicarse con HCP.

### Crear la organización

Una organización es el contenedor raíz en HCP. Todos los workspaces, equipos y políticas
pertenecen a una organización.

1. En la sección de Organizations del menú principal selecciona **Create organization** y elige **Personal**
2. Cuando se pida el nombre de la organización, usa `terraform-labs-<ACCOUNT_ID>` (o
   cualquier nombre único — los nombres de organización son globales en HCP).
2. Introduce tu correo electrónico como dirección de notificaciones.
3. Pulsa **Create organization**.

```bash
# Guarda el nombre de tu organización en la variable de entorno
export TFC_ORG="<nombre-de-tu-organización>"
```

### Verificar la autenticación del CLI

Confirma que el token quedó almacenado correctamente:

```bash
cat ~/.terraform.d/credentials.tfrc.json
```

```json
{
  "credentials": {
    "app.terraform.io": {
      "token": "REDACTED"
    }
  }
}
```

---

## Paso 2 — Crear workspace y configurar OIDC

### Crear el project

En HCP Terraform, un **project** es un agrupador de workspaces dentro de una
organización. Permite organizar los workspaces por equipo, aplicación o entorno y
aplicar permisos de acceso a nivel de proyecto en lugar de workspace a workspace.

1. En la UI de HCP, selecciona tu organización.
2. En el menú lateral, pulsa **Projects** → **+ New project**.
3. **Name**: `lab07b`.
4. **Description**: `Proyecto para el Laboratorio 7b — HCP Terraform como Backend Remoto`.
5. Pulsa **Create**.

> El proyecto `Default Project` existe en todas las organizaciones y es donde se asignan
> los workspaces si no se especifica otro. Para este laboratorio creamos un proyecto
> propio para ilustrar la separación de recursos, y porque el claim `sub` del JWT OIDC
> incluye el nombre del proyecto — lo que permite acotar la trust policy del rol IAM
> a workspaces de un proyecto concreto.

### Crear el workspace CLI-driven

1. Dentro del proyecto `lab07b`, pulsa **+ New workspace**.
2. Elige **CLI-driven workflow**.
3. **Name**: `lab07b-dev`.
4. **Description**: `Laboratorio 7b — VPC sencilla desplegada desde CLI`.
5. Verifica que el campo **Project** muestra `lab07b`.
7. En **Settings → Tags** y añade las etiquetas:

   | Clave | Valor |
   |-------|-------|
   | `lab07b` | Sin valor |
   | `environment` | `dev` |
   | `cloud` | `aws` |

   > Las etiquetas del workspace permiten agrupar y filtrar workspaces en la UI y
   > son el mecanismo que usa el bloque `cloud { workspaces { tags = [...] } }` para
   > seleccionar dinámicamente el workspace destino en lugar de fijarlo por nombre
   > (útil cuando se gestionan múltiples entornos con la misma configuración, como se
   > verá en el Reto 3).

6. Pulsa **Create workspace**.

### Crear el IAM OIDC Identity Provider desde la consola AWS

Abre la **consola de AWS → IAM → Identity providers → Add provider**.

1. **Provider type**: selecciona **OpenID Connect**.
2. **Provider URL**: introduce `https://app.terraform.io` y pulsa **Get thumbprint**.
3. **Audience**: introduce `aws.workload.identity`.
   Esta es la audiencia que HCP Terraform incluye en el JWT que firma para cada run.
   Debe coincidir exactamente — es el primer filtro que AWS aplica antes de evaluar
   la trust policy del rol.
4. Pulsa **Add provider**.

Una vez creado, la consola mostrará el detalle del Identity Provider. Copia el valor
del campo **ARN** — lo necesitarás para construir la trust policy del rol en el
siguiente paso. Tiene el formato:

```
arn:aws:iam::<ACCOUNT_ID>:oidc-provider/app.terraform.io
```

### Crear el IAM Role desde la consola AWS

> **Requisito previo:** el Identity Provider `app.terraform.io` debe existir antes de
> crear el rol. En el formulario de creación del rol, el campo **Identity provider**
> solo lista los proveedores OIDC ya registrados en la cuenta — si el IdP no está
> creado, `app.terraform.io` no aparecerá en el desplegable.

Abre la **consola de AWS → IAM → Roles → Create role**.

**Paso 1 — Trusted entity type:**

1. Selecciona **Custom trust policy**.
2. Sustituye el contenido del editor por la siguiente política, reemplazando los dos
   valores marcados con el ARN del IdP que copiaste en el paso anterior y el nombre
   de tu organización HCP:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "<ARN_DEL_IDP>"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "app.terraform.io:aud": "aws.workload.identity"
                },
                "StringLike": {
                    "app.terraform.io:sub": "organization:<TU_ORG>:project:*:workspace:*:run_phase:*"
                }
            }
        }
    ]
}
```

Los wildcards `*` en `project` y `workspace` permiten que cualquier workspace de tu
organización asuma este rol. En un entorno real se acotan a proyecto y workspace
concretos para aplicar el principio de mínimo privilegio; para este laboratorio la
amplitud es suficiente y simplifica la configuración.

3. Pulsa **Next**.

**Paso 2 — Permisos:**

Busca y selecciona la política **AdministratorAccess**.

> ⚠️ **Solo para laboratorio**: en producción nunca se conceden permisos de administrador
> a un rol de CI/CD. Lo correcto es definir una política de mínimo privilegio con
> únicamente las acciones que Terraform necesita para los recursos que gestiona. Para
> este laboratorio se usa `AdministratorAccess` por practicidad, ya que el conjunto de
> acciones varía según los recursos que se despliegan en cada reto.

**Paso 3 — Name, review and create:**

- **Role name**: `lab07b-terraform-cloud-role`
- **Description**: `Rol asumido por HCP Terraform via OIDC para desplegar recursos.`
- Pulsa **Create role**.

**Copia el ARN del rol creado.**

### Configurar las variables de control OIDC en el workspace de HCP Terraform

Con el rol creado, vuelve a la **consola de HCP Terraform** y configura las variables
que activan Dynamic Provider Credentials en el workspace:

1. Ve a `app.terraform.io` → tu organización → workspace `lab07b-dev` → **Variables**.
2. Pulsa **+ Add variable** → selecciona **Environment variable**.
3. Añade las dos variables siguientes:

| Key | Value | Sensitive |
|-----|-------|-----------|
| `TFC_AWS_PROVIDER_AUTH` | `true` | No |
| `TFC_AWS_RUN_ROLE_ARN` | ARN del rol (p.ej. `arn:aws:iam::123456789012:role/lab07b-terraform-cloud-role`) | No |

Estas son las **únicas** variables de entorno que necesita el workspace — no hay ninguna
clave de acceso que gestionar ni rotar.

> **Cómo funciona en tiempo de run:** cuando HCP Terraform arranca un run, el agente
> detecta `TFC_AWS_PROVIDER_AUTH=true`, genera un JWT firmado con los claims del
> workspace (`organization`, `workspace`, `run_phase`) y llama a
> `sts:AssumeRoleWithWebIdentity` con ese token. AWS verifica la firma contra el OIDC
> Identity Provider registrado, evalúa las condiciones `StringEquals` (audiencia) y
> `StringLike` (claim `sub`) de la trust policy y, si todo coincide, devuelve
> credenciales STS temporales válidas durante 1 hora. El provider AWS las recibe
> automáticamente sin que el operador haya tocado ninguna clave.

### Flujo de autenticación OIDC

```
  DESARROLLADOR                  TERRAFORM CLOUD                         AWS
       │                               │                                  │
       │  terraform apply              │                                  │
       ├──────────────────────────────►│                                  │
       │                               │                                  │
       │                     ┌─────────┴───────────┐                      │
       │                     │  Agente HCP genera  │                      │
       │                     │  JWT firmado con:   │                      │
       │                     │  · aud: aws.workload│                      │
       │                     │    .identity        │                      │
       │                     │  · sub: org/project │                      │
       │                     │    /workspace/phase │                      │
       │                     └─────────┬───────────┘                      │
       │                               │                                  │
       │                               │  AssumeRoleWithWebIdentity       │
       │                               │  · RoleArn: TFC_AWS_RUN_ROLE_ARN │
       │                               │  · WebIdentityToken: <JWT>       │
       │                               ├─────────────────────────────────►│
       │                               │                                  │
       │                               │                    ┌─────────────┴──────────┐
       │                               │                    │  AWS STS verifica:     │
       │                               │                    │  1. Firma del JWT      │
       │                               │                    │     contra el IdP      │
       │                               │                    │     (app.terraform.io) │
       │                               │                    │  2. aud == "aws.       │
       │                               │                    │     workload.          │
       │                               │                    │     identity"          │
       │                               │                    │  3. sub coincide con   │
       │                               │                    │     StringLike de la   │
       │                               │                    │     trust policy       │
       │                               │                    └─────────────┬──────────┘
       │                               │                                  │
       │                               │  Credenciales STS temporales     │
       │                               │  · AccessKeyId (TTL: 1 hora)     │
       │                               │  · SecretAccessKey               │
       │                               │  · SessionToken                  │
       │                               │◄─────────────────────────────────┤
       │                               │                                  │
       │                     ┌─────────┴───────────┐                      │
       │                     │  Provider AWS usa   │                      │
       │                     │  las credenciales   │                      │
       │                     │  para desplegar     │                      │
       │                     │  la infraestructura │                      │
       │                     └─────────┬───────────┘                      │
       │                               │                                  │
       │                               │  ec2:CreateVpc, etc.             │
       │                               ├─────────────────────────────────►│
       │                               │                                  │
       │                               │  Recursos creados                │ 
       │                               │◄─────────────────────────────────┤
       │                               │                                  │
       │  Apply complete!              │                                  │
       │◄──────────────────────────────┤                                  │
       │                               │                                  │
```

En ningún momento el desarrollador ni el workspace almacenan credenciales AWS de larga
duración. Las credenciales STS expiran automáticamente al finalizar el run.

---

## Paso 3 — Configurar el bloque `cloud {}` y migrar el estado

### Código Terraform del laboratorio

Crea los ficheros en `labs/lab07b/aws/`:

**`providers.tf`:**

```hcl
terraform {
  required_version = ">= 1.1"

  # El bloque cloud {} sustituye a backend "s3" del lab07.
  # La autenticación usa el token almacenado por "terraform login".
  # No hay credenciales en el código — el token vive en ~/.terraform.d/credentials.tfrc.json
  cloud {
    organization = "REEMPLAZA_CON_TU_ORG"

    workspaces {
      name = "lab07b-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Lab       = "lab07b"
      ManagedBy = "terraform"
    }
  }
}
```

> Sustituye `"REEMPLAZA_CON_TU_ORG"` por el nombre de tu organización HCP antes de
> ejecutar `terraform init`. El nombre de la organización es sensible a mayúsculas.

**`variables.tf`:**

```hcl
variable "region" {
  description = "Región AWS donde desplegar los recursos."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "cidr_vpc" {
  description = "Bloque CIDR de la VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "cidr_subnet" {
  description = "Bloque CIDR de la subnet pública."
  type        = string
  default     = "10.0.1.0/24"
}
```

**`main.tf`:**

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.cidr_vpc
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "lab07b-vpc-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.cidr_subnet
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"

  tags = {
    Name        = "lab07b-subnet-public-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab07b-igw-${var.environment}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "lab07b-rt-public-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

**`outputs.tf`:**

```hcl
output "vpc_id" {
  description = "ID de la VPC desplegada."
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID de la subnet pública."
  value       = aws_subnet.public.id
}

output "igw_id" {
  description = "ID del Internet Gateway."
  value       = aws_internet_gateway.main.id
}
```

### Inicializar y migrar el estado

```bash
cd labs/lab07b/aws

terraform init
```

Salida esperada:

```
Initializing HCP Terraform...

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.40.0...
- Installed hashicorp/aws v6.40.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

HCP Terraform has been successfully initialized!

You may now begin working with HCP Terraform. Try running "terraform plan" to
see any changes that are required for your infrastructure.

If you ever set or change modules or Terraform Settings, run "terraform init"
again to reinitialize your working directory.
```

> Si el directorio contiene un `terraform.tfstate` local de una ejecución previa,
> `terraform init` ofrecerá migrarlo al workspace de HCP. Responde `yes` para transferir
> el estado existente. Una vez migrado, el fichero local puede eliminarse con seguridad.

---

## Paso 4 — Desplegar la infraestructura

### Plan remoto

```bash
terraform plan
```

El CLI serializa el directorio de trabajo, lo envía al workspace de HCP y los logs del
plan se transmiten en tiempo real al terminal:

```
Running plan in HCP Terraform. Output will stream here. Pressing Ctrl-C
will stop streaming the logs, but will not stop the plan running remotely.

Preparing the remote plan...

To view this run in a browser, visit:
https://app.terraform.io/app/terraform-labs-774126907062/lab07b-dev/runs/run-LRaASBFEhxyrwS6J

Waiting for the plan to start...

Terraform v1.14.8
on linux_amd64
Initializing plugins and modules...

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the
following symbols:
  + create

Terraform will perform the following actions:

  # aws_internet_gateway.main will be created
  + resource "aws_internet_gateway" "main" {
      + arn      = (known after apply)
      + id       = (known after apply)
      + owner_id = (known after apply)
      + region   = "us-east-1"
      + tags     = {
          + "Name" = "lab07b-igw-dev"
        }
      + tags_all = {
          + "Lab"       = "lab07b"
          + "ManagedBy" = "terraform"
          + "Name"      = "lab07b-igw-dev"
        }
      + vpc_id   = (known after apply)
    }

  # aws_route_table.public will be created
  + resource "aws_route_table" "public" {
      + arn              = (known after apply)
      + id               = (known after apply)
      + owner_id         = (known after apply)
      + propagating_vgws = (known after apply)
      + region           = "us-east-1"
      + route            = [
          + {
              + cidr_block                 = "0.0.0.0/0"
              + gateway_id                 = (known after apply)
                # (11 unchanged attributes hidden)
            },
        ]
      + tags             = {
          + "Name" = "lab07b-rt-public-dev"
        }
      + tags_all         = {
          + "Lab"       = "lab07b"
          + "ManagedBy" = "terraform"
          + "Name"      = "lab07b-rt-public-dev"
        }
      + vpc_id           = (known after apply)
    }

  # aws_route_table_association.public will be created
  + resource "aws_route_table_association" "public" {
      + id             = (known after apply)
      + region         = "us-east-1"
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_subnet.public will be created
  + resource "aws_subnet" "public" {
      + arn                                            = (known after apply)
      + assign_ipv6_address_on_creation                = false
      + availability_zone                              = "us-east-1a"
      + availability_zone_id                           = (known after apply)
      + cidr_block                                     = "10.0.1.0/24"
      + enable_dns64                                   = false
      + enable_resource_name_dns_a_record_on_launch    = false
      + enable_resource_name_dns_aaaa_record_on_launch = false
      + id                                             = (known after apply)
      + ipv6_cidr_block                                = (known after apply)
      + ipv6_cidr_block_association_id                 = (known after apply)
      + ipv6_native                                    = false
      + map_public_ip_on_launch                        = true
      + owner_id                                       = (known after apply)
      + private_dns_hostname_type_on_launch            = (known after apply)
      + region                                         = "us-east-1"
      + tags                                           = {
          + "Environment" = "dev"
          + "Name"        = "lab07b-subnet-public-dev"
        }
      + tags_all                                       = {
          + "Environment" = "dev"
          + "Lab"         = "lab07b"
          + "ManagedBy"   = "terraform"
          + "Name"        = "lab07b-subnet-public-dev"
        }
      + vpc_id                                         = (known after apply)
    }

  # aws_vpc.main will be created
  + resource "aws_vpc" "main" {
      + arn                                  = (known after apply)
      + cidr_block                           = "10.0.0.0/16"
      + default_network_acl_id               = (known after apply)
      + default_route_table_id               = (known after apply)
      + default_security_group_id            = (known after apply)
      + dhcp_options_id                      = (known after apply)
      + enable_dns_hostnames                 = true
      + enable_dns_support                   = true
      + enable_network_address_usage_metrics = (known after apply)
      + id                                   = (known after apply)
      + instance_tenancy                     = "default"
      + ipv6_association_id                  = (known after apply)
      + ipv6_cidr_block                      = (known after apply)
      + ipv6_cidr_block_network_border_group = (known after apply)
      + main_route_table_id                  = (known after apply)
      + owner_id                             = (known after apply)
      + region                               = "us-east-1"
      + tags                                 = {
          + "Environment" = "dev"
          + "Name"        = "lab07b-vpc-dev"
        }
      + tags_all                             = {
          + "Environment" = "dev"
          + "Lab"         = "lab07b"
          + "ManagedBy"   = "terraform"
          + "Name"        = "lab07b-vpc-dev"
        }
    }

Plan: 5 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + igw_id    = (known after apply)
  + subnet_id = (known after apply)
  + vpc_id    = (known after apply)

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't guarantee to take exactly these actions if
you run "terraform apply" now.
```

Fíjate en la línea `To view this run in a browser`. Abre esa URL para ver el run en la
UI de HCP mientras se ejecuta.

### Apply remoto

```bash
terraform apply
```

Con el modo de ejecución **Remote**, el apply también corre en los agentes de HCP.
Terraform pedirá confirmación en el terminal y, tras aceptar, mostrará la URL de
seguimiento antes de comenzar la ejecución:

```
Do you want to perform these actions in workspace "lab07b-dev"?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

```
Running apply in HCP Terraform. Output will stream here. Pressing Ctrl-C
will cancel the remote apply if it's still pending. If the apply started it
will stop streaming the logs, but will not stop the apply running remotely.

Preparing the remote apply...

To view this run in a browser, visit:
https://app.terraform.io/app/terraform-labs-774126907062/lab07b-dev/runs/run-wnMVLvkxGZa2rwms

Waiting for the plan to start...
```

Salida tras el apply exitoso:

```
aws_vpc.main: Creating...
aws_vpc.main: Creation complete after 2s [id=vpc-0xxxxxxxxxxxxxxxxx]
aws_internet_gateway.main: Creating...
aws_subnet.public: Creating...
aws_subnet.public: Creation complete after 1s [id=subnet-0xxxxxxxxxxxxxxxxx]
aws_internet_gateway.main: Creation complete after 1s [id=igw-0xxxxxxxxxxxxxxxxx]
aws_route_table.public: Creating...
aws_route_table.public: Creation complete after 1s [id=rtb-0xxxxxxxxxxxxxxxxx]
aws_route_table_association.public: Creating...
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-0xxxxxxxxxxxxxxxxx]

Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

igw_id    = "igw-0xxxxxxxxxxxxxxxxx"
subnet_id = "subnet-0xxxxxxxxxxxxxxxxx"
vpc_id    = "vpc-0xxxxxxxxxxxxxxxxx"
```

Captura los outputs en variables de entorno para usarlos en los pasos siguientes:

```bash
VPC_ID=$(terraform output -raw vpc_id)
SUBNET_ID=$(terraform output -raw subnet_id)
echo "VPC    : $VPC_ID"
echo "Subnet : $SUBNET_ID"
```

---

## Paso 5 — Explorar la UI de HCP Terraform

### Vista Runs

En `https://app.terraform.io/app/<TU_ORG>/workspaces/lab07b-dev/runs` verás el
historial completo de ejecuciones. Cada run muestra:

- Estado: **Applied**, **Planned**, **Errored**, **Discarded**
- Quién lo inició y desde qué fuente (CLI, VCS, API)
- Timestamp de inicio y duración
- El plan completo y los logs del apply
- Los cambios de estado entre la versión anterior y la actual

Abre el run del apply que acabas de ejecutar y explora las pestañas **Plan** y **Apply**
para ver los logs completos tal como los vieron los agentes de HCP.

### Vista States

En `https://app.terraform.io/app/<TU_ORG>/workspaces/lab07b-dev/states` verás todas
las versiones del estado. Cada apply genera una nueva versión. Haz clic en cualquier
versión para ver el contenido completo del estado y el **diff** respecto a la versión
anterior — qué recursos se añadieron, modificaron o eliminaron.

```bash
# También puedes leer el estado remoto desde el CLI sin descargarlo localmente
terraform show
```

### Vista Variables

En `https://app.terraform.io/app/<TU_ORG>/workspaces/lab07b-dev/variables` puedes
añadir, editar y eliminar variables sin tocar el código. Las variables Sensitive aparecen
como `****` — no se pueden leer, solo sobreescribir.

Prueba a añadir una Terraform variable:

1. Pulsa **+ Add variable** → **Terraform variable**
2. Key: `environment`, Value: `dev`
3. Deja Sensitive desactivado
4. Pulsa **Save variable**

En el próximo plan, esta variable sobreescribirá el valor por defecto definido en
`variables.tf` sin necesidad de un fichero `.tfvars`.

### Vista Settings → Execution Mode

En **Settings → General** puedes cambiar el Execution Mode del workspace entre
**Remote** y **Local**. El cambio es inmediato y no requiere `terraform init`. En Local,
el siguiente `terraform plan` correrá en tu máquina pero el estado seguirá leyéndose y
escribiéndose en HCP.

### Vista Settings → Notifications

En **Settings → Notifications** puedes configurar alertas automáticas que HCP Terraform
enviará cuando ocurran eventos en el workspace. Es útil para mantener informado al
equipo sin tener que monitorizar la UI manualmente.

**Tipos de destino disponibles:**

| Destino | Descripción |
|---------|-------------|
| **Email** | Notifica a los miembros de la organización seleccionados |
| **Slack** | Publica un mensaje en un canal via Incoming Webhook |
| **Microsoft Teams** | Publica en un canal via Incoming Webhook |
| **Webhook** | Envía un HTTP POST a una URL arbitraria con el payload del evento |

**Eventos configurables:**

| Evento | Cuándo se dispara |
|--------|-------------------|
| `Created` | Se crea un nuevo run |
| `Planning` | El plan comienza a ejecutarse |
| `Needs Attention` | El plan completó pero requiere confirmación manual |
| `Applying` | El apply comienza a ejecutarse |
| `Completed` | El apply finalizó correctamente |
| `Errored` | El plan o el apply terminó con error |

Para explorar la sección:

1. Ve a **Settings → Notifications → Create a notification**.
2. Selecciona **Email** como destino.
3. En **Triggers**, activa **Completed** y **Errored**.
4. En **Recipients**, añade tu dirección de correo.
5. Pulsa **Create notification** — HCP enviará un correo de prueba para verificar
   la configuración.

> En un entorno de equipo, las notificaciones de tipo **Needs Attention** son
> especialmente relevantes en workspaces con **Auto Apply** desactivado: alertan a los
> revisores de que hay un plan pendiente de aprobación sin que tengan que consultar
> la UI periódicamente.

---

## Verificación final

```bash
# Verifica que los recursos existen en AWS
aws ec2 describe-vpcs \
  --filters "Name=tag:Lab,Values=lab07b" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Estado:State}' \
  --output table

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table

aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[].{ID:InternetGatewayId,Estado:Attachments[0].State}' \
  --output table
```

| Recurso | ID esperado | Estado |
|---------|-------------|--------|
| VPC | `vpc-0xxxxxxxxxxxxxxxxx` | `available` |
| Subnet pública | `subnet-0xxxxxxxxxxxxxxxxx` | `available` |
| Internet Gateway | `igw-0xxxxxxxxxxxxxxxxx` | `attached` |

---

## Retos

### Reto 1 — Cambiar el modo de ejecución a Local

Cambia el workspace `lab07b-dev` a modo de ejecución **Local** desde la UI
(**Settings → General → Execution Mode → Local**) y ejecuta de nuevo `terraform plan`.

Observa las diferencias:
- El plan se ejecuta en tu máquina, no en los agentes de HCP.
- En la UI del workspace no aparece un nuevo run en la vista Runs.
- El estado sigue leyéndose y escribiéndose en HCP.

**Pregunta:** ¿En qué escenarios es útil el modo Local frente al modo Remote?

**Pistas:**
- El modo Local es útil cuando el código necesita acceder a recursos de red privada
  (p.ej. un endpoint privado de RDS) que no son accesibles desde los agentes de HCP.
- También es útil durante el desarrollo cuando se quiere iterar rápidamente sin
  consumir tiempo de agente remoto.

---

### Reto 2 — Variable de entorno vs. variable Terraform

Actualmente la región está definida en `variables.tf` con un valor por defecto
(`us-east-1`). El objetivo de este reto es sobreescribirla **desde la UI del workspace**
sin modificar ningún fichero.

1. En la UI, ve a **Variables** y añade una **Terraform variable**:
   - Key: `region`, Value: `eu-west-1`
2. Ejecuta `terraform plan` y observa que el plan propone recrear los recursos en
   `eu-west-1`.
3. **No apliques el plan** — pulsa **Discard** en la UI o interrumpe el apply con Ctrl-C.
4. Elimina la variable del workspace para dejar la configuración en `us-east-1`.

**Pregunta:** ¿Qué diferencia hay entre definir `region` como variable Terraform y como
variable de entorno `TF_VAR_region` en el workspace?

---

### Reto 3 — Segundo workspace para producción

HCP Terraform permite gestionar múltiples entornos (dev, prod) con la misma
configuración usando workspaces separados.

1. Crea un segundo workspace `lab07b-prod` en la UI con las mismas credenciales AWS.
2. Modifica el bloque `cloud {}` en `providers.tf` para usar `tags` en lugar de `name`:

```hcl
cloud {
  organization = "<TU_ORG>"

  workspaces {
    tags = ["lab07b"]
  }
}
```

3. Asigna la etiqueta de cadena `lab07b` a ambos workspaces desde la UI
   (**Settings → Tags → Add tag**). Introduce `lab07b` como texto plano — **no** uses
   el formato clave-valor; el filtro `tags` del bloque `cloud {}` solo reconoce
   etiquetas de cadena simple.
4. Ejecuta `terraform init` — al cambiar de `name` a `tags` en el bloque `cloud {}`,
   el CLI necesita reinicializarse para descubrir los workspaces asociados a esa etiqueta:

   ```bash
   terraform init
   ```

5. Ejecuta `terraform workspace list` para ver los workspaces disponibles.
6. Selecciona `lab07b-prod` con `terraform workspace select lab07b-prod` y despliega
   con un `cidr_vpc` diferente (`10.1.0.0/16`).

**Pistas:**
- Con `tags` en lugar de `name`, el CLI preguntará qué workspace usar en cada ejecución
  si hay más de uno con ese tag.
- Puedes fijar el workspace activo con la variable de entorno
  `TF_WORKSPACE=lab07b-prod`.

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Modo Local vs. Remote</strong></summary>

### Solución al Reto 1

**Cuándo usar modo Local:**

- El código de Terraform necesita invocar proveedores que requieren conectividad de red
  privada (endpoints VPC, servidores on-premise).
- Se usan herramientas locales en `null_resource` o `local-exec` que no están
  disponibles en los agentes de HCP.
- Durante el desarrollo activo, el ciclo plan-apply-fix es más rápido sin la latencia
  de serializar y enviar el directorio a HCP.

**Cuándo usar modo Remote:**

- Entornos de equipo donde varios desarrolladores pueden lanzar plans/applies: Remote
  garantiza que todos usan la misma versión de Terraform y los mismos providers.
- Pipelines CI/CD: el apply se puede aprobar desde la UI por un revisor.
- Cuando se quiere auditoría completa de runs con logs persistentes en HCP.

Para volver al modo Remote tras el reto:
1. UI → **Settings → General → Execution Mode → Remote** → Save.
2. El siguiente `terraform plan` volverá a ejecutarse en los agentes de HCP.

</details>

<details>
<summary><strong>Solución al Reto 2 — Variable de entorno vs. variable Terraform</strong></summary>

### Solución al Reto 2

**Cómo llegar a las Variables del workspace:**

1. Abre `app.terraform.io` e inicia sesión.
2. En el menú lateral, selecciona tu organización → **Projects & workspaces**.
3. Localiza el proyecto `lab07b` y pulsa sobre el workspace `lab07b-dev`.
4. En el menú superior del workspace, pulsa **Variables**.
5. En la sección **Workspace Variables**, pulsa **+ Add variable**.
6. Selecciona **Terraform variable** (no Environment variable).
7. Rellena:
   - **Key**: `region`
   - **Value**: `eu-west-1`
   - Deja **Sensitive** desactivado — la región no es un dato sensible.
8. Pulsa **Save variable**.

> **Requisito:** el workspace debe estar en modo de ejecución **Remote** para poder
> definir variables desde la UI. Con el modo Local, la sección Variables queda
> deshabilitada en la interfaz. Si completaste el Reto 1 y cambiaste el workspace a
> Local, vuelve a **Settings → General → Execution Mode → Remote** antes de continuar.

Ejecuta `terraform plan` desde el terminal. El plan propone recrear todos los recursos
en `eu-west-1` porque la variable del workspace sobreescribe el default del código:

```
  # aws_subnet.public must be replaced
  ~ resource "aws_subnet" "public" {
      ~ availability_zone = "us-east-1a" -> "eu-west-1a"
      ...
    }
```

**No ejecutes el apply** — pulsa **Discard run** en la UI o interrumpe con Ctrl-C.

Para eliminar la variable y restaurar el default:

1. En **Variables**, localiza la fila `region`.
2. Pulsa el icono de papelera → **Delete variable** → confirma.
3. El siguiente plan usará el valor por defecto de `variables.tf` (`us-east-1`).

---

Cuando se define `region` como **Terraform variable** en el workspace (Key: `region`,
Value: `eu-west-1`), HCP pasa el valor al plan exactamente igual que si estuviera en un
fichero `.tfvars`. El plan ve `var.region = "eu-west-1"` y planifica los recursos en esa
región.

Si se usara `TF_VAR_region` como **Environment variable**, el efecto es idéntico porque
el provider AWS lee la variable de la misma forma. La diferencia es de organización:

| Mecanismo | Visible en el plan | Cifrable como Sensitive |
|---|---|---|
| `variable "region"` con default | Sí, valor en el código | No aplica |
| Terraform variable en workspace | Sí, valor en la UI | Sí (oculta en logs) |
| Environment variable `TF_VAR_region` | Sí | Sí (si se marca Sensitive) |

</details>

<details>
<summary><strong>Solución al Reto 3 — Segundo workspace para producción</strong></summary>

### Solución al Reto 3

**`providers.tf` modificado con `tags`:**

```hcl
terraform {
  required_version = ">= 1.1"

  cloud {
    organization = "<TU_ORG>"

    workspaces {
      tags = ["lab07b"]
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Lab       = "lab07b"
      ManagedBy = "terraform"
    }
  }
}
```

Después de modificar el bloque `cloud {}`, ejecuta `terraform init` para que el CLI
recargue la configuración del workspace.

**Seleccionar workspace y desplegar prod:**

```bash
# Lista los workspaces disponibles con el tag "lab07b"
terraform workspace list

# Selecciona prod
terraform workspace select lab07b-prod
terraform apply \
  -var="cidr_vpc=10.1.0.0/16" \
  -var="cidr_subnet=10.1.1.0/24" \
  -var="environment=prod"
```

**Verificar que los dos workspaces tienen estados independientes:**

```bash
# Estado de dev
terraform workspace select lab07b-dev
terraform show

# Estado de prod
terraform workspace select lab07b-prod
terraform show
```

Cada workspace tiene su propio fichero de estado en HCP — modificar o destruir prod no
afecta a dev.

**Limpieza de prod:**

```bash
terraform workspace select lab07b-prod
terraform destroy
```

</details>

---

## Limpieza

### 1. Destruir la infraestructura en AWS

Asegúrate de estar en el workspace `lab07b-dev` antes de destruir. Si completaste el
Reto 3, destruye también `lab07b-prod`:

```bash
cd labs/lab07b/aws

# Destruye dev
terraform workspace select lab07b-dev
terraform destroy
```

Salida esperada:

```
aws_route_table_association.public: Destroying...
aws_route_table_association.public: Destruction complete after 0s
aws_route_table.public: Destroying...
aws_internet_gateway.main: Destroying...
aws_route_table.public: Destruction complete after 1s
aws_internet_gateway.main: Destruction complete after 1s
aws_subnet.public: Destroying...
aws_subnet.public: Destruction complete after 1s
aws_vpc.main: Destroying...
aws_vpc.main: Destruction complete after 1s

Destroy complete! Resources: 5 destroyed.
```

### 2. Eliminar los workspaces en HCP

> Eliminar un workspace **no destruye** la infraestructura en AWS — solo el estado y el
> historial de runs en HCP. Ejecuta siempre `terraform destroy` antes de este paso.

Para cada workspace (`lab07b-dev` y, si existe, `lab07b-prod`):

1. En la UI, selecciona el workspace.
2. Ve a **Settings → Destruction and Deletion**.
3. En la sección **Delete workspace**, pulsa el botón, escribe el nombre del workspace
   para confirmar y pulsa **Delete workspace**.

### 3. Eliminar el IAM Role y el OIDC Identity Provider

Estos recursos se crearon manualmente en el Paso 2 y no forman parte del estado de
Terraform — hay que eliminarlos también manualmente desde la consola de AWS.

**Eliminar el IAM Role:**

1. Abre **AWS Console → IAM → Roles**.
2. Busca `lab07b-terraform-cloud-role`.
3. Selecciónalo → **Delete** → escribe el nombre para confirmar → **Delete**.

**Eliminar el OIDC Identity Provider:**

1. Abre **AWS Console → IAM → Identity providers**.
2. Selecciona `app.terraform.io`.
3. Pulsa **Delete** → confirma.

### 4. Revocar el API token

1. Ve a `app.terraform.io` → icono de usuario → **User Settings → Tokens**.
2. Localiza el token generado durante el laboratorio y pulsa **Revoke**.

Para eliminar también las credenciales locales del CLI:

```bash
terraform logout
```

---

## Solución de problemas

### `Error: Failed to request discovery document`

**Causa:** el token almacenado en `~/.terraform.d/credentials.tfrc.json` ha caducado o
fue revocado.

**Solución:**

```bash
terraform logout
terraform login
```

---

### `Error: No workspaces found matching the provided tags`

**Causa:** el bloque `cloud {}` usa `tags` pero ningún workspace tiene ese tag asignado,
o el tag está mal escrito.

**Solución:**
1. En la UI ve a **Settings → Tags** del workspace y verifica que el tag coincide
   exactamente con el valor del bloque `cloud {}`.
2. Alternativamente, usa `name` en lugar de `tags` para evitar ambigüedades.

---

### `Error: organization not found`

**Causa:** el nombre de la organización en el bloque `cloud {}` no coincide con el nombre
real en HCP Terraform. Los nombres son sensibles a mayúsculas.

**Solución:**

1. Abre [app.terraform.io](https://app.terraform.io) en el navegador.
2. En la esquina superior izquierda, haz clic en el nombre de la organización para abrir
   el menú desplegable.
3. Selecciona **Organization Settings** (rueda dentada junto al nombre).
4. En la sección **General**, copia el valor exacto del campo **Name**.
5. Actualiza el bloque `cloud {}` en `providers.tf` con ese nombre.

---

### Plan correcto pero apply bloqueado esperando confirmación

**Causa:** el workspace tiene **Auto apply** desactivado (configuración por defecto).
El apply remoto queda en estado **Needs confirmation** hasta que alguien lo aprueba en
la UI.

**Solución A — aprobar desde la UI:**
1. Abre la URL del run que aparece en los logs del terminal.
2. Pulsa **Confirm & Apply**.

**Solución B — habilitar Auto apply:**
1. UI → **Settings → General → Auto Apply** → activar.
2. Los siguientes applies se aprobarán automáticamente sin confirmación manual.

---

### `AccessDenied` durante el apply a pesar de usar `AdministratorAccess`

**Causa:** la política `AdministratorAccess` no está correctamente adjunta al rol OIDC,
o la trust policy contiene un typo en el nombre de la organización o del workspace.

**Diagnóstico — verificar permisos del rol (AWS Console):**

1. Abre la [Consola de IAM](https://console.aws.amazon.com/iam/) → **Roles**.
2. Busca y abre el rol `lab07b-terraform-cloud-role`.
3. Abre la pestaña **Permissions** y comprueba que aparece
   **AdministratorAccess** en la lista de políticas adjuntas.

**Diagnóstico — verificar la trust policy (AWS Console):**

1. En el mismo rol, abre la pestaña **Trust relationships**.
2. Revisa el JSON y comprueba que los valores de las condiciones `StringEquals` y
   `StringLike` coinciden exactamente con tu organización y workspace en HCP Terraform.

**Solución A — si falta AdministratorAccess:**

1. En la pestaña **Permissions** del rol, haz clic en **Add permissions →
   Attach policies**.
2. Busca `AdministratorAccess`, márcala y pulsa **Add permissions**.

**Solución B — si la trust policy tiene un typo:**

1. En la pestaña **Trust relationships**, haz clic en **Edit trust policy**.
2. Corrige los valores de `StringEquals` (organización) y `StringLike` (workspace)
   y guarda con **Update policy**.
3. Lanza de nuevo el `terraform apply` desde el terminal; HCP Terraform obtendrá
   nuevas credenciales temporales con la trust policy corregida.
