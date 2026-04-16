# Laboratorio 40 — Refactorización y Optimización del Rendimiento

[← Módulo 9 — Terraform Avanzado](../../modulos/modulo-09/README.md)


## Visión general

A medida que un proyecto de Terraform crece, aparecen tres problemas
recurrentes que este laboratorio ataca de frente:

1. **Deuda tecnica en el codigo**: recursos creados con `count` que son
   dificiles de mantener (indices numericos en lugar de claves semanticas,
   destruccion al reordenar la lista). El bloque `moved` permite migrar a
   `for_each` y a modulos sin tocar la infraestructura real.

2. **Inicializaciones lentas**: en equipos grandes, `terraform init` descarga
   los mismos providers repetidamente. `plugin_cache_dir` elimina esas
   descargas redundantes.

3. **Applies lentos en entornos grandes**: el flag `-parallelism` controla
   cuantos recursos gestiona Terraform en paralelo. Ajustarlo correctamente
   puede reducir el tiempo de un apply masivo a la mitad.

El laboratorio tambien introduce la arquitectura de **State Splitting**: dividir
un monolito de estado en proyectos independientes (red / aplicacion) conectados
mediante `terraform_remote_state`, el patron mas usado en equipos grandes para
escalar sin lock contention.

## Objetivos

- Desplegar recursos con `count` e identificar sus limitaciones operativas.
- Migrar de `count` a `for_each` usando bloques `moved` sin destruir ni recrear
  ningun recurso real.
- Extraer un conjunto de recursos hacia un módulo reutilizable y remapear sus
  direcciones en el estado con nuevos bloques `moved`.
- Configurar `plugin_cache_dir` en `~/.terraformrc` y medir la reduccion de
  tiempo en `terraform init`.
- Medir el tiempo de un apply masivo con `-parallelism=10` y compararlo con
  `-parallelism=30`.
- Dividir la infraestructura en dos proyectos independientes (`network/` y
  `app/`) con estados separados en S3.
- Conectar ambos proyectos con `data "terraform_remote_state"` para que `app/`
  consuma los outputs de `network/` sin parametros manuales.

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado
  habilitado.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
labs/lab40/aws/
│
├── workspaces/                    Pasos 1-4: refactorizacion + parallelism
│   ├── main.tf  (count → for_each → módulo)
│   ├── moved.tf (creado por el estudiante en cada fase)
│   └── modules/s3_workspace/
│
├── network/                       Paso 5a: capa de red (fuente de estado)
│   └── state key: lab40/network/terraform.tfstate
│       outputs: vpc_id, public_subnet_id, private_subnet_id, vpc_cidr
│
└── app/                           Paso 5b: capa de aplicacion (consumidor)
    └── state key: lab40/app/terraform.tfstate
        data "terraform_remote_state" → lee outputs de network/

Estado de refactorizacion del proyecto workspaces/
───────────────────────────────────────────────────────────────────
Fase 1 — count (estado inicial en el repositorio):

  aws_s3_bucket.workspace[0]            → entorno dev
  aws_s3_bucket.workspace[1]            → entorno staging
  aws_s3_bucket.workspace[2]            → entorno prod
  (+ versioning, public_access_block, ssm_parameter x3 cada uno)

Fase 2 — for_each + moved (Paso 2):

  aws_s3_bucket.workspace["dev"]        ← moved from [0]
  aws_s3_bucket.workspace["staging"]    ← moved from [1]
  aws_s3_bucket.workspace["prod"]       ← moved from [2]

Fase 3 — módulo + moved (Paso 3):

  module.workspace["dev"].aws_s3_bucket.this     ← moved from workspace["dev"]
  module.workspace["staging"].aws_s3_bucket.this ← moved from workspace["staging"]
  module.workspace["prod"].aws_s3_bucket.this    ← moved from workspace["prod"]

Arquitectura de State Splitting (Paso 5):

  ┌─────────────────────────┐        ┌──────────────────────────────────┐
  │  network/               │        │  app/                            │
  │  ─────────────────────  │        │  ──────────────────────────────  │
  │  aws_vpc.main           │        │  data "terraform_remote_state"   │
  │  aws_subnet.public      │───────►│    .network.outputs.vpc_id       │
  │  aws_subnet.private     │        │                                  │
  │  aws_internet_gateway   │        │  aws_security_group.app          │
  │  aws_route_table        │        │  aws_ssm_parameter.vpc_id        │
  │                         │        │  aws_ssm_parameter.public_subnet │
  │  S3 state:              │        │  aws_ssm_parameter.vpc_cidr      │
  │  lab40/network/...      │        │                                  │
  └─────────────────────────┘        │  S3 state:                       │
                                     │  lab40/app/...                   │
                                     └──────────────────────────────────┘
```

## Conceptos clave

### Por que `count` se queda corto

`count` asigna un indice numerico a cada instancia del recurso. El problema
aparece cuando la lista cambia:

```hcl
variable "environments" {
  default = ["dev", "staging", "prod"]
}

resource "aws_s3_bucket" "workspace" {
  count  = length(var.environments)
  bucket = "mi-bucket-${var.environments[count.index]}"
}
```

Si eliminas `"staging"` de la lista:

```
ANTES: [dev=0, staging=1, prod=2]
DESPUES: [dev=0, prod=1]           ← prod pasa de indice 2 a indice 1

Plan: destroy workspace[2] (prod antiguo)
      update  workspace[1] (ahora prod, antes staging)
```

Terraform destruye el bucket de `prod` real porque su indice cambio.
Con `for_each` la clave es el nombre del entorno, no su posicion — eliminar
`staging` no afecta a `prod`.

### Bloque `moved`

`moved` le indica a Terraform que un recurso que existia en una direccion
de estado ahora se encuentra en otra. Terraform actualiza el estado sin
destruir ni recrear el recurso en AWS:

```hcl
moved {
  from = aws_s3_bucket.workspace[0]    # direccion antigua (count)
  to   = aws_s3_bucket.workspace["dev"] # direccion nueva (for_each)
}
```

**Reglas del bloque `moved`**:

| Regla | Detalle |
|---|---|
| Se evalua durante `plan` | Terraform mueve la direccion en el estado antes de calcular diferencias |
| No modifica AWS | Solo actualiza el fichero `.tfstate` — ningun recurso se toca |
| Acumulativo | Una vez que un `moved` se ha aplicado a todos los entornos, puede eliminarse del codigo |
| Encadenable | `moved` puede apuntar a otro `moved` (util al refactorizar en varias fases) |

**Cuando NO usar `moved`**:
- Si cambias el tipo de recurso (`aws_s3_bucket` → `aws_s3_bucket_v2`): usa `import` + `destroy`.
- Si cambias la región o la cuenta: los recursos son distintos, no hay movimiento posible.

### `plugin_cache_dir`

Por defecto, cada directorio de Terraform descarga los providers en su
propio `.terraform/providers/`. En un monorepo con 10 proyectos que usen
`hashicorp/aws`, se descargan 10 copias del mismo binario.

`plugin_cache_dir` define un directorio compartido donde Terraform almacena
los providers una sola vez. Todos los proyectos leen desde ese cache:

```hcl
# ~/.terraformrc
plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"
```

O mediante variable de entorno (util en CI/CD):

```bash
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
```

**Impacto real**:

| Escenario | Sin cache | Con cache |
|---|---|---|
| Primera inicializacion | ~8 s (descarga) | ~8 s (descarga y guarda) |
| Segunda inicializacion | ~8 s (descarga de nuevo) | < 1 s (copia local) |
| Init en CI con 5 proyectos | ~40 s | ~10 s (1 descarga + 4 copias) |

### Flag `-parallelism`

Terraform construye un grafo de dependencias y ejecuta en paralelo todos
los recursos que no tienen dependencias entre si. `-parallelism` limita
cuantos nodos del grafo se procesan simultaneamente:

```bash
terraform apply -parallelism=10  # default: 10 workers en paralelo
terraform apply -parallelism=30  # 30 workers — util con muchos recursos independientes
```

**Cuando aumentar `-parallelism`**:
- Tienes muchos recursos sin dependencias entre si (SSM params, S3 buckets
  de distintos entornos, etc.).
- El apply se queda "esperando" aunque haya recursos listos para crearse.

**Cuando NO aumentarlo**:
- Con recursos que tienen muchas dependencias: el cuello de botella es el
  grafo, no el numero de workers.
- Con APIs que tienen rate limiting agresivo (algunos servicios AWS limitan
  las llamadas por segundo): aumentar el paralelismo puede provocar
  throttling y reintentos que alargan el tiempo total.

### `terraform_remote_state`

Permite que un proyecto de Terraform lea los outputs de otro proyecto
directamente desde su fichero de estado en S3, sin parametros manuales:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "terraform-state-labs-123456789012"
    key    = "lab40/network/terraform.tfstate"
    region = "us-east-1"
  }
}

# Usar los outputs del otro proyecto:
resource "aws_security_group" "app" {
  vpc_id = data.terraform_remote_state.network.outputs.vpc_id
}
```

**El contrato entre proyectos**: los `output` del proyecto fuente (`network/`)
son la API publica. Eliminar o renombrar un output rompe el proyecto consumidor
(`app/`). Trata los outputs de proyectos compartidos como una interfaz publica —
deprecalos antes de eliminarlos.

**Alternativa: AWS SSM Parameter Store**. En lugar de leer el estado remoto
directamente, el proyecto fuente escribe sus IDs en SSM y el consumidor los
lee con `data "aws_ssm_parameter"`. Ventaja: desacopla los proyectos del
backend de Terraform. Desventaja: requiere un paso extra de escritura.

## Estructura del proyecto

```
lab40/
├── aws/
│   ├── workspaces/                    # Pasos 1-4
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── main.tf                    # version inicial con count
│   │   ├── moved.tf                   # creado por el estudiante (ver Pasos 2-3)
│   │   ├── outputs.tf
│   │   ├── aws.s3.tfbackend
│   │   └── modules/
│   │       └── s3_workspace/          # módulo pre-escrito, usado en Paso 3
│   │           ├── main.tf
│   │           ├── variables.tf
│   │           └── outputs.tf
│   ├── network/                       # Paso 5a
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── aws.s3.tfbackend
│   └── app/                           # Paso 5b
│       ├── providers.tf
│       ├── variables.tf
│       ├── main.tf
│       ├── outputs.tf
│       └── aws.s3.tfbackend
└── README.md
```

---

## Paso 1 — Desplegar la infraestructura inicial con `count`

```bash
cd labs/lab40/aws/workspaces

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform apply
```

El apply crea **32 recursos**: 12 recursos de workspace (3 entornos × 4 recursos
cada uno: bucket + versioning + public_access_block + ssm_parameter) mas 20
parámetros SSM de configuración.

Observa las direcciones de estado con indices numericos:

```bash
terraform state list | grep workspace
# aws_s3_bucket.workspace[0]
# aws_s3_bucket.workspace[1]
# aws_s3_bucket.workspace[2]
# aws_s3_bucket_versioning.workspace[0]
# aws_s3_bucket_versioning.workspace[1]
# ...
```

**El problema del indice numerico**: si quisieras eliminar el entorno `staging`
de la lista `["dev", "staging", "prod"]`, Terraform reasignaria los indices y
**destruiria el bucket de `prod`** (que pasaria a ser el indice 1). Es el
comportamiento que vamos a eliminar en el Paso 2.

---

## Paso 2 — Migrar de `count` a `for_each` con bloques `moved`

### 2a — Modificar `main.tf`

Sustituye los cuatro bloques de recursos con `count` por sus equivalentes con
`for_each`. El nombre del recurso no cambia en ninguno de ellos.

---

**`aws_s3_bucket.workspace`**

```hcl
# ANTES:
resource "aws_s3_bucket" "workspace" {
  count  = length(var.environments)
  bucket = "${var.project}-ws-${var.environments[count.index]}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project}-ws-${var.environments[count.index]}"
    Environment = var.environments[count.index]
    Project     = var.project
    ManagedBy   = "terraform"
  }
}

# DESPUES:
resource "aws_s3_bucket" "workspace" {
  for_each = toset(var.environments)
  bucket   = "${var.project}-ws-${each.key}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project}-ws-${each.key}"
    Environment = each.key
    Project     = var.project
    ManagedBy   = "terraform"
  }
}
```

---

**`aws_s3_bucket_versioning.workspace`**

```hcl
# ANTES:
resource "aws_s3_bucket_versioning" "workspace" {
  count  = length(var.environments)
  bucket = aws_s3_bucket.workspace[count.index].id

  versioning_configuration {
    status = "Enabled"
  }
}

# DESPUES:
resource "aws_s3_bucket_versioning" "workspace" {
  for_each = toset(var.environments)
  bucket   = aws_s3_bucket.workspace[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}
```

---

**`aws_s3_bucket_public_access_block.workspace`**

```hcl
# ANTES:
resource "aws_s3_bucket_public_access_block" "workspace" {
  count  = length(var.environments)
  bucket = aws_s3_bucket.workspace[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DESPUES:
resource "aws_s3_bucket_public_access_block" "workspace" {
  for_each = toset(var.environments)
  bucket   = aws_s3_bucket.workspace[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

**`aws_ssm_parameter.workspace_bucket`**

```hcl
# ANTES:
resource "aws_ssm_parameter" "workspace_bucket" {
  count = length(var.environments)
  name  = "/${var.project}/${var.environments[count.index]}/bucket-name"
  type  = "String"
  value = aws_s3_bucket.workspace[count.index].bucket

  tags = {
    Project     = var.project
    Environment = var.environments[count.index]
    ManagedBy   = "terraform"
  }
}

# DESPUES:
resource "aws_ssm_parameter" "workspace_bucket" {
  for_each = toset(var.environments)
  name     = "/${var.project}/${each.key}/bucket-name"
  type     = "String"
  value    = aws_s3_bucket.workspace[each.key].bucket

  tags = {
    Project     = var.project
    Environment = each.key
    ManagedBy   = "terraform"
  }
}
```

---

El bloque `aws_ssm_parameter.config` (los 20 parámetros de configuración) no
cambia — ya usa `for_each` desde el principio.

### 2b — Crear `moved.tf` con los bloques de redireccion

> **¿Se puede usar un bucle en `moved`?** No. Los bloques `moved` son
> declaraciones estaticas — no admiten `for_each`, `count` ni ninguna
> expresion dinamica. Terraform los evalua antes de construir el grafo
> de dependencias, en una fase donde las expresiones aun no se han
> resuelto. Cualquier intento como `for_each = toset(var.environments)`
> dentro de un bloque `moved` produce un error de sintaxis inmediato.
>
> En la practica no es un problema: los `moved` son un esfuerzo puntual
> de refactorizacion que se escribe una sola vez y se elimina tras el
> apply. HashiCorp los diseño deliberadamente estaticos para que sean
> legibles, auditables en pull request y no dependan del estado de
> las variables en el momento de la evaluacion.

Crea el fichero `moved.tf` en el mismo directorio y añade un bloque `moved`
por cada recurso y entorno:

```hcl
# ── Fase 2: count → for_each ──────────────────────────────────────────────────

moved {
  from = aws_s3_bucket.workspace[0]
  to   = aws_s3_bucket.workspace["dev"]
}
moved {
  from = aws_s3_bucket.workspace[1]
  to   = aws_s3_bucket.workspace["staging"]
}
moved {
  from = aws_s3_bucket.workspace[2]
  to   = aws_s3_bucket.workspace["prod"]
}

moved {
  from = aws_s3_bucket_versioning.workspace[0]
  to   = aws_s3_bucket_versioning.workspace["dev"]
}
moved {
  from = aws_s3_bucket_versioning.workspace[1]
  to   = aws_s3_bucket_versioning.workspace["staging"]
}
moved {
  from = aws_s3_bucket_versioning.workspace[2]
  to   = aws_s3_bucket_versioning.workspace["prod"]
}

moved {
  from = aws_s3_bucket_public_access_block.workspace[0]
  to   = aws_s3_bucket_public_access_block.workspace["dev"]
}
moved {
  from = aws_s3_bucket_public_access_block.workspace[1]
  to   = aws_s3_bucket_public_access_block.workspace["staging"]
}
moved {
  from = aws_s3_bucket_public_access_block.workspace[2]
  to   = aws_s3_bucket_public_access_block.workspace["prod"]
}

moved {
  from = aws_ssm_parameter.workspace_bucket[0]
  to   = aws_ssm_parameter.workspace_bucket["dev"]
}
moved {
  from = aws_ssm_parameter.workspace_bucket[1]
  to   = aws_ssm_parameter.workspace_bucket["staging"]
}
moved {
  from = aws_ssm_parameter.workspace_bucket[2]
  to   = aws_ssm_parameter.workspace_bucket["prod"]
}
```

### 2c — Actualizar `outputs.tf`

Los dos outputs que referencian los recursos de workspace usan splat expression
(`[*]`), que solo funciona con `count`. Sustituyelos por expresiones `for`:

```hcl
output "workspace_bucket_names" {
  description = "Nombres de los buckets de workspace por entorno"
  value       = [for ws in aws_s3_bucket.workspace : ws.bucket]
}

output "workspace_bucket_arns" {
  description = "ARNs de los buckets de workspace por entorno"
  value       = [for ws in aws_s3_bucket.workspace : ws.arn]
}
```

Los outputs `config_parameter_count` y `account_id` no cambian.

### 2d — Aplicar la migracion

```bash
terraform plan
```

El plan debe mostrar exclusivamente movimientos de estado. **Si ves `destroy`
o `create` para los recursos de workspace, hay un error en los bloques `moved`
o en la refactorizacion del codigo — no apliques hasta resolverlo.**

```
Terraform will perform the following actions:

  # aws_s3_bucket.workspace[0] has moved to aws_s3_bucket.workspace["dev"]
    resource "aws_s3_bucket" "workspace" {
        id   = "lab40-ws-dev-123456789012"
        tags = {
            "Environment" = "dev"
            "ManagedBy"   = "terraform"
            "Name"        = "lab40-ws-dev"
            "Project"     = "lab40"
        }
        # (15 unchanged attributes hidden)

        # (3 unchanged blocks hidden)
    }

  # aws_s3_bucket.workspace[1] has moved to aws_s3_bucket.workspace["staging"]
    resource "aws_s3_bucket" "workspace" {
        id   = "lab40-ws-staging-123456789012"
        # (15 unchanged attributes hidden)
        # (3 unchanged blocks hidden)
    }

  # aws_s3_bucket.workspace[2] has moved to aws_s3_bucket.workspace["prod"]
    resource "aws_s3_bucket" "workspace" {
        id   = "lab40-ws-prod-123456789012"
        # (15 unchanged attributes hidden)
        # (3 unchanged blocks hidden)
    }

  # (9 moved blocks adicionales para versioning, public_access_block y ssm_parameter)

Plan: 0 to add, 0 to change, 0 to destroy.
```

```bash
terraform apply
```

```bash
# Confirmar las nuevas direcciones en el estado
terraform state list | grep workspace
# aws_s3_bucket.workspace["dev"]
# aws_s3_bucket.workspace["staging"]
# aws_s3_bucket.workspace["prod"]
# aws_s3_bucket_versioning.workspace["dev"]
# ...
```

Los buckets reales en AWS no se han modificado — solo han cambiado sus
direcciones en el estado de Terraform.

> **¿Eliminar `moved.tf` ahora?** Los bloques del Paso 2 ya cumplieron su
> función y pueden eliminarse. Sin embargo, en el Paso 3 volverás a necesitar
> el fichero para añadir los bloques de extracción al módulo. Lo más práctico
> es conservarlo y limpiar los bloques de la Fase 2 al finalizar el Paso 3,
> cuando el fichero ya no sea necesario en absoluto.

---

## Paso 3 — Extraer recursos hacia el módulo `s3_workspace`

El módulo está pre-escrito en [aws/workspaces/modules/s3_workspace/](aws/workspaces/modules/s3_workspace/).
Encapsula el bucket, el versionado, el bloqueo de acceso publico y el
parametro SSM para un entorno dado.

### 3a — Sustituir recursos sueltos por el módulo en `main.tf`

Elimina los cuatro bloques de recursos que migraste en el Paso 2 y
sustitúyelos por una única llamada al módulo con `for_each`:

```hcl
# ELIMINAR estos cuatro bloques:
resource "aws_s3_bucket" "workspace" { ... }
resource "aws_s3_bucket_versioning" "workspace" { ... }
resource "aws_s3_bucket_public_access_block" "workspace" { ... }
resource "aws_ssm_parameter" "workspace_bucket" { ... }

# SUSTITUIR por:
module "workspace" {
  for_each = toset(var.environments)
  source   = "./modules/s3_workspace"

  project     = var.project
  environment = each.key
  account_id  = data.aws_caller_identity.current.account_id
}
```

El módulo acepta tres variables (`project`, `environment`, `account_id`) que
se corresponden con lo que declaraste en
[aws/workspaces/modules/s3_workspace/variables.tf](aws/workspaces/modules/s3_workspace/variables.tf).
Internamente crea los mismos cuatro recursos que acabas de eliminar, con los
mismos nombres y valores — de ahi que los bloques `moved` del Paso 3b puedan
redirigir las direcciones sin recrear nada.

El resto de `main.tf` no cambia: el `data "aws_caller_identity"` y el bloque
`aws_ssm_parameter.config` (los 20 parámetros de configuración) permanecen
intactos.

### 3b — Añadir los bloques `moved` de módulo en `moved.tf`

Estos bloques encadenan con los del Paso 2: redirigen desde las direcciones
`for_each` sueltas hacia las direcciones dentro del módulo.

```hcl
# ── Fase 3: recursos sueltos → módulo ────────────────────────────────────────

moved {
  from = aws_s3_bucket.workspace["dev"]
  to   = module.workspace["dev"].aws_s3_bucket.this
}
moved {
  from = aws_s3_bucket.workspace["staging"]
  to   = module.workspace["staging"].aws_s3_bucket.this
}
moved {
  from = aws_s3_bucket.workspace["prod"]
  to   = module.workspace["prod"].aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_versioning.workspace["dev"]
  to   = module.workspace["dev"].aws_s3_bucket_versioning.this
}
moved {
  from = aws_s3_bucket_versioning.workspace["staging"]
  to   = module.workspace["staging"].aws_s3_bucket_versioning.this
}
moved {
  from = aws_s3_bucket_versioning.workspace["prod"]
  to   = module.workspace["prod"].aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_public_access_block.workspace["dev"]
  to   = module.workspace["dev"].aws_s3_bucket_public_access_block.this
}
moved {
  from = aws_s3_bucket_public_access_block.workspace["staging"]
  to   = module.workspace["staging"].aws_s3_bucket_public_access_block.this
}
moved {
  from = aws_s3_bucket_public_access_block.workspace["prod"]
  to   = module.workspace["prod"].aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_ssm_parameter.workspace_bucket["dev"]
  to   = module.workspace["dev"].aws_ssm_parameter.bucket_name
}
moved {
  from = aws_ssm_parameter.workspace_bucket["staging"]
  to   = module.workspace["staging"].aws_ssm_parameter.bucket_name
}
moved {
  from = aws_ssm_parameter.workspace_bucket["prod"]
  to   = module.workspace["prod"].aws_ssm_parameter.bucket_name
}
```

### 3c — Actualizar `outputs.tf`

Los outputs que actualizaste en el Paso 2c iteran sobre `aws_s3_bucket.workspace`
y acceden a sus atributos directos (`ws.bucket`, `ws.arn`). Ahora iteran sobre
`module.workspace`, cuyos valores expuestos son los outputs del módulo
(`bucket_name`, `bucket_arn`), no los atributos del recurso S3.

```hcl
# ANTES (Paso 2c — iteraba sobre el recurso directo):
output "workspace_bucket_names" {
  description = "Nombres de los buckets de workspace por entorno"
  value       = [for ws in aws_s3_bucket.workspace : ws.bucket]
}

output "workspace_bucket_arns" {
  description = "ARNs de los buckets de workspace por entorno"
  value       = [for ws in aws_s3_bucket.workspace : ws.arn]
}

# DESPUÉS (Paso 3c — itera sobre el módulo y usa sus outputs):
output "workspace_bucket_names" {
  description = "Nombres de los buckets de workspace por entorno"
  value       = [for ws in module.workspace : ws.bucket_name]
}

output "workspace_bucket_arns" {
  description = "ARNs de los buckets de workspace por entorno"
  value       = [for ws in module.workspace : ws.bucket_arn]
}
```

Los nombres `bucket_name` y `bucket_arn` son los outputs declarados en
[modules/s3_workspace/outputs.tf](aws/workspaces/modules/s3_workspace/outputs.tf).
Si usas `ws.bucket` o `ws.arn` aqui, Terraform falla con
`This object does not have an attribute named "bucket"` porque el módulo
no expone atributos del recurso directamente — solo sus outputs declarados.

### 3d — Aplicar la extracción

Al introducir el bloque `module` en `main.tf`, Terraform necesita instalar
el módulo local antes de poder ejecutar el plan. Sin este paso, el plan
falla con `Module not installed`:

```bash
terraform init
# Esperado:
# Initializing modules...
# - workspace in modules/s3_workspace
```

```bash
terraform plan
```

La salida debe mostrar solo movimientos de estado hacia las direcciones del
módulo. **Cero destroy, cero create.**

```
Plan: 0 to add, 0 to change, 0 to destroy.
```

```bash
terraform apply

# Confirmar nuevas direcciones
terraform state list | grep module
# module.workspace["dev"].aws_s3_bucket.this
# module.workspace["dev"].aws_s3_bucket_versioning.this
# module.workspace["dev"].aws_s3_bucket_public_access_block.this
# module.workspace["dev"].aws_ssm_parameter.bucket_name
# module.workspace["staging"]...
# module.workspace["prod"]...
```

Todos los bloques `moved` de ambas fases ya cumplieron su función. Elimina
el fichero `moved.tf` — un `terraform plan` posterior debe mostrar
`No changes` sin necesitar ningun bloque de redireccion:

```bash
rm moved.tf
terraform plan
# Esperado: No changes. Your infrastructure matches the configuration.
```

---

## Paso 4 — `plugin_cache_dir` y medicion de `-parallelism`

### 4a — Configurar `plugin_cache_dir`

Terraform **no expande variables de shell** en `~/.terraformrc`, por lo que
escribir `"$HOME/..."` no funciona — el valor queda literalmente como `$HOME`
y el cache se ignora. El metodo mas fiable es la variable de entorno, que si
expande el shell antes de pasarsela a Terraform:

```bash
# Crear el directorio de cache
mkdir -p ~/.terraform.d/plugin-cache

# Exportar la variable en la shell actual
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"

# Para que persista entre sesiones, añadirla al perfil de la shell
echo 'export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"' >> ~/.bashrc
# o en zsh:
echo 'export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"' >> ~/.zshrc
```

Si prefieres usar `~/.terraformrc`, usa la ruta absoluta sin variables:

```hcl
# ~/.terraformrc — usa la ruta absoluta, NO variables de shell
plugin_cache_dir = "/home/<tu-usuario>/.terraform.d/plugin-cache"
```

**Medir el impacto**:

```bash
# Primera inicializacion: descarga providers y los guarda en el cache
time terraform init \
  -upgrade \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"
# Salida: "Installing hashicorp/aws v6.39.0..."
# Tiempo: ~6s
```

```bash
# Limpiar SOLO el directorio .terraform — conservar el lock file.
# El lock file fija la version exacta del provider; sin el, Terraform debe
# contactar el registro para resolverla y vuelve a descargar el binario
# aunque este en cache. Este es el escenario realista: un clon nuevo del
# repositorio donde .terraform.lock.hcl está versionado en git pero
# .terraform/ no existe.
rm -rf .terraform
```

```bash
# Segunda inicializacion: Terraform lee la version del lock file,
# la encuentra en cache y copia el binario sin descargarlo.
time terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"
# Salida: "Using previously-installed hashicorp/aws v6.39.0"
# Tiempo: ~2s
```

### 4b — Medir el impacto de `-parallelism`

El proyecto tiene 20 parámetros SSM de configuración sin dependencias entre
si — candidatos ideales para la paralelizacion. Primero destruye y recrea
solo esos recursos para tener una medicion limpia:

```bash
# Destruir los 20 parametros de config para la prueba
terraform destroy \
  -target='aws_ssm_parameter.config' \
  --auto-approve

# Medir con 10 workers (valor por defecto)
time terraform apply \
  -target='aws_ssm_parameter.config' \
  -parallelism=10 \
  --auto-approve

# Destruir de nuevo para repetir la prueba
terraform destroy \
  -target='aws_ssm_parameter.config' \
  --auto-approve

# Medir con 30 workers
time terraform apply \
  -target='aws_ssm_parameter.config' \
  -parallelism=30 \
  --auto-approve
```

Anota los tiempos del campo `real` de cada `time` y comparalos. El impacto
varia segun la latencia de la API de SSM, la carga del endpoint regional y
la maquina local — los resultados son distintos en cada entorno. Lo relevante
no es el valor absoluto sino la **diferencia relativa** entre ambas ejecuciones.

> **Si no ves mejora o los tiempos son similares**: con solo 20 recursos y
> baja latencia a la API, el cuello de botella puede estar en el propio
> round-trip a AWS y no en el numero de workers. El beneficio de aumentar
> `-parallelism` es mas apreciable cuanto mayor es el numero de recursos
> independientes (50, 100 o mas) y cuanto mas rapida es la API en responder.
> Con valores muy altos (>50) puedes encontrar throttling de la API de SSM,
> que eleva el tiempo total por los reintentos.

---

## Paso 5 — State Splitting con `terraform_remote_state`

### 5a — Desplegar el proyecto `network/`

El proyecto `network/` es la **fuente de verdad** de la infraestructura de
red. Sus outputs seran consumidos por `app/` mediante `terraform_remote_state`.

```bash
cd ../network

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform apply
```

Verifica los outputs que `app/` consumira:

```bash
terraform output
# igw_id            = "igw-0abc..."
# private_subnet_id = "subnet-0abc..."
# public_subnet_id  = "subnet-0xyz..."
# region            = "us-east-1"
# vpc_cidr          = "10.39.0.0/16"
# vpc_id            = "vpc-0abc..."
```

Estos outputs están escritos en el fichero de estado en S3 bajo la clave
`lab40/network/terraform.tfstate`. El proyecto `app/` los leer de ahi.

### 5b — Desplegar el proyecto `app/`

El proyecto `app/` no conoce los IDs de red — los lee del estado remoto de
`network/` en tiempo de plan.

```bash
cd ../app

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan \
  -var="state_bucket=${BUCKET}"
```

Observa como Terraform resuelve los valores del `data "terraform_remote_state"`
antes de calcular el plan:

```
data.terraform_remote_state.network: Reading...
data.terraform_remote_state.network: Read complete after 1s

Terraform will perform the following actions:
  # aws_security_group.app will be created
    + resource "aws_security_group" "app" {
        + vpc_id = "vpc-0abc..."   ← leido del estado remoto de network/
        ...
      }
  # aws_ssm_parameter.vpc_id will be created
    + resource "aws_ssm_parameter" "vpc_id" {
        + value = "vpc-0abc..."    ← leido del estado remoto de network/
      }
  ...
```

```bash
terraform apply \
  -var="state_bucket=${BUCKET}"
```

### 5c — Verificar la conexión entre proyectos

```bash
# Ver los outputs de app/ — incluyen los valores leidos del estado remoto
terraform output

# Verificar que el security group se creo en el VPC correcto
SG_ID=$(terraform output -raw security_group_id)
VPC_FROM_REMOTE=$(terraform output -raw vpc_id_from_remote_state)

aws ec2 describe-security-groups \
  --group-ids "${SG_ID}" \
  --query "SecurityGroups[0].VpcId" \
  --output text
# Debe coincidir con: ${VPC_FROM_REMOTE}

# Ver los parametros SSM propagados desde network/
aws ssm get-parameters-by-path \
  --path "/lab40/app/network/" \
  --query "Parameters[*].{Name:Name,Value:Value}" \
  --output table
```

### 5d — Simular una actualización en `network/` y propagar el cambio

Añade una etiqueta nueva al VPC en `network/main.tf`:

```hcl
resource "aws_vpc" "main" {
  ...
  tags = {
    ...
    CostCenter = "platform"   # etiqueta nueva
  }
}
```

```bash
cd ../network
terraform apply
```

En `app/`, el plan detecta que los outputs de `network/` no han cambiado
(el `vpc_id` sigue siendo el mismo) y no propone ningun cambio:

```bash
cd ../app
terraform plan -var="state_bucket=${BUCKET}"
# Esperado: No changes.
```

> **Limitacion importante del State Splitting**: los dos proyectos son
> independientes para Terraform, pero los recursos de `app/` tienen una
> **dependencia real** sobre los recursos de `network/` que Terraform no
> puede gestionar automáticamente entre estados distintos.
>
> Por ejemplo, si intentaras cambiar el bloque CIDR del VPC en `network/`
> (`cidr_block` es inmutable — AWS obliga a destruir y recrear el VPC),
> el `terraform destroy` de `network/` **fallaria** porque el security group
> de `app/` sigue asociado al VPC y AWS no permite eliminarlo mientras tenga
> recursos dependientes.
>
> El orden correcto en ese escenario seria:
> 1. `cd app/ && terraform destroy` — eliminar primero los recursos de `app/`
> 2. `cd network/ && terraform apply` — recrear el VPC con el nuevo CIDR
> 3. `cd app/ && terraform apply` — redesplegar `app/` sobre el nuevo VPC
>
> Esta es la principal razon por la que los outputs del proyecto fuente deben
> tratarse como una API estable: cambios que impliquen la recreacion de un
> recurso compartido requieren coordinacion explicita entre proyectos, algo
> que un monolito de estado gestionaría automáticamente.

---

## Verificación final

```bash
# 1. Confirmar que los tres buckets de workspace existen y tienen versionado
aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'lab40')].Name" \
  --output table

# 2. Verificar que el state splitting funciona: network/ y app/ tienen estados separados
BUCKET=$(cd network && terraform output -raw state_bucket)
aws s3 ls "s3://${BUCKET}/" --recursive | grep terraform.tfstate

# 3. Comprobar que remote_state lee el VPC correcto desde app/
cd app
VPC_FROM_REMOTE=$(terraform output -raw vpc_id_from_remote_state)
VPC_DIRECT=$(cd ../network && terraform output -raw vpc_id)
echo "Remote: ${VPC_FROM_REMOTE} | Direct: ${VPC_DIRECT}"
# Ambos deben coincidir

# 4. Verificar el cache de providers
ls ~/.terraform.d/plugin-cache/
```

---

## Retos

### Reto 1 — Añadir un cuarto entorno sin downtime

Ahora que los workspaces usan `for_each` y el módulo `s3_workspace`, añadir
un entorno nuevo es trivial — pero el reto esta en hacerlo correctamente.

**Objetivo**: añade el entorno `"hotfix"` a la lista `var.environments` y
verifica que Terraform solo crea recursos nuevos sin tocar los existentes.

1. Modifica `variables.tf` para incluir `"hotfix"` en la lista.
2. Ejecuta `terraform plan`.
3. Confirma que el plan muestra exactamente 4 recursos nuevos (`add`) y
   cero destrucciones para los entornos existentes.
4. Aplica y verifica con `terraform state list`.

**Por que funciona sin `moved`**: al usar `for_each` con el nombre del entorno
como clave, añadir `"hotfix"` crea nuevas instancias sin renombrar las
existentes. Con `count`, añadir un elemento al principio de la lista habria
destruido y recreado todos los recursos siguientes.

---

### Reto 2 — Romper la dependencia de `terraform_remote_state`

`terraform_remote_state` acopla `app/` al backend de Terraform de `network/`.
Si el equipo de red migra a un backend diferente (HCP Terraform, GCS...), el
proyecto `app/` deja de funcionar hasta que se actualice su configuración.

**Objetivo**: refactoriza el proyecto `app/` para que en lugar de usar
`terraform_remote_state`, lea los valores de red desde SSM Parameter Store.

1. En `network/main.tf`, añade tres recursos `aws_ssm_parameter` que escriban
   `vpc_id`, `public_subnet_id` y `vpc_cidr` en las rutas:
   - `/lab40/network/vpc-id`
   - `/lab40/network/public-subnet-id`
   - `/lab40/network/vpc-cidr`

2. En `app/main.tf`, sustituye el bloque `data "terraform_remote_state"` por
   tres bloques `data "aws_ssm_parameter"`.

3. Actualiza todas las referencias de
   `data.terraform_remote_state.network.outputs.*`
   por `data.aws_ssm_parameter.<nombre>.value`.

4. Elimina la variable `state_bucket` de `app/variables.tf` (ya no hace falta).

5. Aplica ambos proyectos y verifica que el security group sigue estando en
   el mismo VPC.

**Ventaja de este patron**: `app/` ya no necesita acceso al bucket de estado
de `network/`. Solo necesita permisos de lectura en SSM — un permiso mucho
mas granular y auditables.

---

## Soluciones

<details>
<summary>Reto 1 — Añadir un cuarto entorno sin downtime</summary>

**Modificar `variables.tf`**:

```hcl
variable "environments" {
  type    = list(string)
  default = ["dev", "staging", "prod", "hotfix"]
}
```

**Ejecutar plan**:

```bash
terraform plan
```

Salida esperada:

```
Terraform will perform the following actions:

  # module.workspace["hotfix"].aws_s3_bucket.this will be created
  + resource "aws_s3_bucket" "this" { ... }

  # module.workspace["hotfix"].aws_s3_bucket_public_access_block.this will be created
  + resource "aws_s3_bucket_public_access_block" "this" { ... }

  # module.workspace["hotfix"].aws_s3_bucket_versioning.this will be created
  + resource "aws_s3_bucket_versioning" "this" { ... }

  # module.workspace["hotfix"].aws_ssm_parameter.bucket_name will be created
  + resource "aws_ssm_parameter" "bucket_name" { ... }

Plan: 4 to add, 0 to change, 0 to destroy.
```

Los 12 recursos existentes (dev, staging, prod) no aparecen en el plan —
`for_each` los ignora completamente porque sus claves no han cambiado.

```bash
terraform apply

terraform state list | grep hotfix
# module.workspace["hotfix"].aws_s3_bucket.this
# module.workspace["hotfix"].aws_s3_bucket_public_access_block.this
# module.workspace["hotfix"].aws_s3_bucket_versioning.this
# module.workspace["hotfix"].aws_ssm_parameter.bucket_name
```

</details>

<details>
<summary>Reto 2 — Desacoplar app/ de terraform_remote_state mediante SSM</summary>

**1. Añadir SSM parameters en `network/main.tf`**:

```hcl
resource "aws_ssm_parameter" "vpc_id" {
  name        = "/lab40/network/vpc-id"
  type        = "String"
  value       = aws_vpc.main.id
  description = "ID del VPC principal — publicado para consumo por otros proyectos"
  tags        = { Project = var.project, ManagedBy = "terraform", Layer = "network" }
}

resource "aws_ssm_parameter" "public_subnet_id" {
  name        = "/lab40/network/public-subnet-id"
  type        = "String"
  value       = aws_subnet.public.id
  description = "ID de la subnet publica"
  tags        = { Project = var.project, ManagedBy = "terraform", Layer = "network" }
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name        = "/lab40/network/vpc-cidr"
  type        = "String"
  value       = aws_vpc.main.cidr_block
  description = "CIDR del VPC principal"
  tags        = { Project = var.project, ManagedBy = "terraform", Layer = "network" }
}
```

```bash
cd aws/network && terraform apply
```

**2. Refactorizar `app/main.tf`**:

Hay tres cambios en este fichero:

- Eliminar el bloque `data "terraform_remote_state" "network"`.
- Añadir tres bloques `data "aws_ssm_parameter"` en su lugar.
- Actualizar todas las referencias de `data.terraform_remote_state.network.outputs.*`
  por `data.aws_ssm_parameter.<nombre>.value`.

El resultado completo de `app/main.tf` debe quedar asi:

```hcl
# ANTES — eliminar este bloque completo:
# data "terraform_remote_state" "network" {
#   backend = "s3"
#   config  = { bucket = ..., key = ..., region = ... }
# }

# DESPUES — sustituir por estos tres data sources:
data "aws_ssm_parameter" "vpc_id" {
  name = "/lab40/network/vpc-id"
}

data "aws_ssm_parameter" "public_subnet_id" {
  name = "/lab40/network/public-subnet-id"
}

data "aws_ssm_parameter" "vpc_cidr" {
  name = "/lab40/network/vpc-cidr"
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "Trafico HTTP/HTTPS de entrada para la capa de aplicacion"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value   # antes: data.terraform_remote_state.network.outputs.vpc_id

  tags = {
    Name      = "${var.project}-app-sg"
    Project   = var.project
    ManagedBy = "terraform"
    Layer     = "app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP publico"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS publico"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente"
}

resource "aws_ssm_parameter" "vpc_id" {
  name        = "/${var.project}/app/network/vpc-id"
  type        = "String"
  value       = data.aws_ssm_parameter.vpc_id.value   # antes: data.terraform_remote_state.network.outputs.vpc_id
  description = "ID del VPC — propagado desde SSM de network/"
  tags        = { Project = var.project, ManagedBy = "terraform", Source = "ssm" }
}

resource "aws_ssm_parameter" "public_subnet_id" {
  name        = "/${var.project}/app/network/public-subnet-id"
  type        = "String"
  value       = data.aws_ssm_parameter.public_subnet_id.value   # antes: data.terraform_remote_state.network.outputs.public_subnet_id
  description = "ID de la subnet publica — propagado desde SSM de network/"
  tags        = { Project = var.project, ManagedBy = "terraform", Source = "ssm" }
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name        = "/${var.project}/app/network/vpc-cidr"
  type        = "String"
  value       = data.aws_ssm_parameter.vpc_cidr.value   # antes: data.terraform_remote_state.network.outputs.vpc_cidr
  description = "CIDR del VPC — propagado desde SSM de network/"
  tags        = { Project = var.project, ManagedBy = "terraform", Source = "ssm" }
}
```

**3. Eliminar la variable `state_bucket` de `app/variables.tf`** y sus usos
en `outputs.tf`.

**4. Aplicar**:

```bash
cd aws/app
terraform apply   # sin -var="state_bucket=..."

# Verificar que el SG sigue en el mismo VPC
terraform output vpc_id_from_remote_state
# Este output ya no existe; usa:
aws ec2 describe-security-groups \
  --group-ids "$(terraform output -raw security_group_id)" \
  --query "SecurityGroups[0].VpcId" \
  --output text
```

**Comparativa de los dos patrones**:

| | `terraform_remote_state` | SSM Parameter Store |
|---|---|---|
| Requiere acceso al backend | Si (S3, credenciales) | No |
| Permisos necesarios | Lectura en S3 | `ssm:GetParameter` |
| Latencia | ~1 s (lectura S3) | ~50 ms (API SSM) |
| Desacoplamiento | Bajo (dependencia del backend) | Alto |
| Visibilidad | Solo en Terraform | Cualquier herramienta AWS |
| Coste extra | No | Minimo (SSM Standard es gratis) |

</details>

---

## Limpieza

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

# 1. Destruir el proyecto app/
cd labs/lab40/aws/app
terraform destroy -var="state_bucket=${BUCKET}"

# 2. Destruir el proyecto network/
cd ../network
terraform destroy

# 3. Destruir el proyecto workspaces/
cd ../workspaces
terraform destroy

# 4. Limpiar el fichero moved.tf creado durante el laboratorio
rm -f moved.tf
```

---

## Buenas prácticas aplicadas

- **`moved` como documentacion de historial**: aunque los bloques `moved` pueden
  eliminarse una vez aplicados, conservarlos brevemente (con un comentario de
  fecha) ayuda al equipo a entender que refactorizaciones se han producido y
  cuando.
- **Nombres semanticos en `for_each`**: usar el nombre del entorno como clave
  (`"dev"`, `"prod"`) en lugar de indices hace que los mensajes de plan sean
  autoexplicativos: `module.workspace["prod"]` es inequivoco; `workspace[2]` no.
- **`plugin_cache_dir` en todos los entornos**: configura el cache tanto en
  las maquinas de los desarrolladores como en los agentes de CI/CD. El ahorro
  de tiempo se acumula en cada pipeline.
- **`-parallelism` con moderacion**: el valor optimo depende del numero de
  recursos independientes y de los rate limits de la API. Mide antes de subir;
  valores muy altos pueden provocar throttling y empeorar el tiempo total.
- **Outputs como contrato publico en State Splitting**: trata los `output` de
  un proyecto fuente como una API publica. Antes de eliminar un output, verifica
  que ningun consumidor lo referencia — usa `grep` o busqueda en el repositorio.
- **Separacion de capas de estado**: un estado por capa logica (red, datos,
  aplicacion) reduce la blast radius de un `terraform destroy` accidental y
  permite que equipos distintos trabajen en paralelo sin lock contention.

---

## Recursos

- [Bloque moved — Terraform Docs](https://developer.hashicorp.com/terraform/language/block/moved)
- [Refactoring — mover recursos entre modulos](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [plugin_cache_dir — Terraform CLI Configuration](https://developer.hashicorp.com/terraform/cli/config/config-file#plugin_cache_dir)
- [Command: plan -parallelism](https://developer.hashicorp.com/terraform/cli/commands/plan#parallelism-n)
- [terraform_remote_state — Data Source](https://developer.hashicorp.com/terraform/language/state/remote-state-data)
- [count vs for_each — cuando usar cada uno](https://developer.hashicorp.com/terraform/language/meta-arguments/count#when-to-use-for_each-instead-of-count)
