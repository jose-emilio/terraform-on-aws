# Laboratorio 9: Gestión de Entornos con Workspaces

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio gestionarás entornos Dev y Prod desde una sola base de código usando workspaces de Terraform. Aprenderás a derivar configuración dinámica con `terraform.workspace`, a validar inconsistencias de forma declarativa con el bloque `check {}` y a proteger el plan con `lifecycle { precondition }`.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear y navegar entre workspaces de Terraform (`new`, `select`, `list`)
- Leer `terraform.workspace` para seleccionar configuración diferenciada (CIDR, instance_type) según el entorno
- Detectar inconsistencias con un bloque `check {}` que emite advertencias sin abortar
- Abortar el plan ante condiciones peligrosas con `lifecycle { precondition }`
- Entender la diferencia entre `check` (informativo) y `precondition` (obligatorio)
- Usar archivos `.tfvars` por entorno para separar la configuración de las variables

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir en AWS
- Laboratorio 7 completado (bucket S3 con versionado habilitado)
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### `terraform.workspace`

`terraform.workspace` es una cadena de solo lectura que devuelve el nombre del workspace activo. Está disponible en cualquier expresión HCL: locals, resources, outputs y bloques de validación.

```hcl
locals {
  env = terraform.workspace   # "default", "dev" o "prod"
}
```

El workspace `default` existe siempre y no puede eliminarse. Por convenio, este laboratorio trata `default` igual que `dev`.

### Workspaces y estado

Cada workspace tiene su propio archivo de estado, completamente aislado del resto. Con un backend local, los estados se almacenan en:

```
terraform.tfstate                    # workspace default
terraform.tfstate.d/dev/terraform.tfstate
terraform.tfstate.d/prod/terraform.tfstate
```

Con el backend S3, la `key` se prefija automáticamente con el nombre del workspace:

```
terraform-state-labs-<ACCOUNT_ID>/lab09/terraform.tfstate          # workspace default
terraform-state-labs-<ACCOUNT_ID>/env:/dev/lab09/terraform.tfstate
terraform-state-labs-<ACCOUNT_ID>/env:/prod/lab09/terraform.tfstate
```

Cada workspace tiene su propio objeto en S3, todos bajo el mismo bucket compartido del curso.

### Configuración dinámica con `lookup()`

Combinando un mapa de configuración con `lookup()`, una sola base de código sirve para todos los entornos:

```hcl
locals {
  config = {
    dev  = { vpc_cidr = "10.0.0.0/16", instance_type = "t3.micro" }
    prod = { vpc_cidr = "10.1.0.0/16", instance_type = "t3.small" }
  }
  env_config    = lookup(local.config, terraform.workspace, local.config["dev"])
  instance_type = local.env_config.instance_type
}
```

### Bloque `check {}`

Disponible desde Terraform 1.5. Evalúa aserciones declarativas y emite **advertencias** si fallan, pero **no aborta** el plan ni el apply. Útil para detectar configuraciones que merecen atención pero no son bloqueantes.

```hcl
check "nombre_descriptivo" {
  assert {
    condition     = <expresión booleana>
    error_message = "Mensaje de advertencia."
  }
}
```

> El bloque `check` puede contener múltiples `assert`. Cada uno se evalúa de forma independiente.

### `lifecycle { precondition }`

A diferencia de `check`, un `precondition` **sí aborta** el plan si la condición falla. Se declara dentro del bloque `lifecycle` de un recurso y se evalúa antes de planificar ese recurso.

```hcl
resource "aws_vpc" "main" {
  # ...
  lifecycle {
    precondition {
      condition     = <expresión booleana>
      error_message = "Error bloqueante."
    }
  }
}
```

### Tabla comparativa

| Característica | `check {}` | `lifecycle { precondition }` |
|---|---|---|
| Disponibilidad | Terraform 1.5+ | Terraform 1.2+ |
| Efecto si falla | Advertencia (continúa) | Error (aborta el plan) |
| Ámbito | Global al módulo | Ligado a un recurso concreto |
| Cuándo se evalúa | Post-plan / post-apply | Antes de planificar el recurso |
| Uso recomendado | Validaciones informativas | Invariantes de seguridad |

---

## Estructura del proyecto

```
lab09/
├── aws/
│   ├── providers.tf      # Requiere Terraform >= 1.5, backend "s3" {}
│   ├── variables.tf      # region, is_prod
│   ├── main.tf           # locals, check {}, aws_vpc con precondition, aws_subnet
│   ├── outputs.tf        # workspace, vpc_id, cidr, instance_type, is_prod
│   ├── aws.s3.tfbackend  # key = "lab09/terraform.tfstate" + locking nativo S3
│   ├── dev.tfvars        # is_prod = false
│   └── prod.tfvars       # is_prod = true
└── localstack/
    ├── providers.tf           # Endpoints apuntando a LocalStack (ec2), backend "s3" {}
    ├── variables.tf           # is_prod
    ├── main.tf                # Idéntico al de aws/
    ├── outputs.tf             # Idéntico al de aws/
    ├── localstack.s3.tfbackend # Config completa del backend para LocalStack
    ├── dev.tfvars
    └── prod.tfvars
```

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`aws/main.tf`** — Muestra el código completo:

```hcl
locals {
  env = terraform.workspace

  config = {
    default = { vpc_cidr = "10.0.0.0/16", subnet_cidr = "10.0.1.0/24", instance_type = "t3.micro" }
    dev     = { vpc_cidr = "10.0.0.0/16", subnet_cidr = "10.0.1.0/24", instance_type = "t3.micro" }
    prod    = { vpc_cidr = "10.1.0.0/16", subnet_cidr = "10.1.1.0/24", instance_type = "t3.small" }
  }

  env_config    = lookup(local.config, local.env, local.config["default"])
  vpc_cidr      = local.env_config.vpc_cidr
  subnet_cidr   = local.env_config.subnet_cidr
  instance_type = local.env_config.instance_type

  tags = {
    Environment = local.env
    ManagedBy   = "terraform"
  }
}

check "is_prod_workspace_consistency" {
  assert {
    condition     = var.is_prod == (terraform.workspace == "prod")
    error_message = "Posible inconsistencia: is_prod=${var.is_prod} en workspace '${terraform.workspace}'. Verifica que estás en el entorno correcto."
  }
}

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "vpc-${local.env}" })

  lifecycle {
    precondition {
      condition     = !(var.is_prod && terraform.workspace != "prod")
      error_message = "Seguridad: is_prod=true solo está permitido en el workspace 'prod'. Workspace activo: '${terraform.workspace}'."
    }
  }
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = local.subnet_cidr

  tags = merge(local.tags, { Name = "subnet-${local.env}" })
}
```

### 1.2 Inicialización

```bash
# Desde lab09/aws/
export BUCKET=terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

Verifica que el workspace activo es `default`:

```bash
terraform workspace list
# * default
```

### 1.3 Despliegue en Dev

```bash
terraform workspace new dev
# Created and switched to workspace "dev"!

terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

Los outputs mostrarán:

```
workspace     = "dev"
vpc_cidr      = "10.0.0.0/16"
subnet_cidr   = "10.0.1.0/24"
instance_type = "t3.micro"
is_prod       = false
```

### 1.4 Despliegue en Prod

```bash
terraform workspace new prod
# Created and switched to workspace "prod"!

terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

Los outputs mostrarán valores distintos:

```
workspace     = "prod"
vpc_cidr      = "10.1.0.0/16"
subnet_cidr   = "10.1.1.0/24"
instance_type = "t3.small"
is_prod       = true
```

Los dos entornos tienen estados completamente independientes. Verifica que ambas VPCs existen en paralelo:

```bash
aws ec2 describe-vpcs --filters "Name=tag:ManagedBy,Values=terraform" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Env:Tags[?Key==`Environment`]|[0].Value}' \
  --output table
```

### 1.5 Listado y navegación de workspaces

```bash
terraform workspace list
#   default
#   dev
# * prod       ← asterisco indica el workspace activo

terraform workspace show
# prod

terraform workspace select dev
# Switched to workspace "dev".
```

### 1.6 Demostración del bloque `check` (advertencia)

El bloque `check` detecta inconsistencias informativas. Pruébalo pasando `is_prod=false` en el workspace `prod`:

```bash
terraform workspace select prod
terraform plan -var-file=dev.tfvars   # is_prod=false en workspace prod
```

Terraform muestra el plan completo **y al final la advertencia**:

```
╷
│ Warning: Check block assertion failed
│
│   on main.tf line 22, in check "is_prod_workspace_consistency":
│    22:     condition = var.is_prod == (terraform.workspace == "prod")
│
│ Posible inconsistencia: is_prod=false en workspace 'prod'.
│ Verifica que estás en el entorno correcto.
╵
```

El plan **continúa y puede aplicarse**. El `check` es informativo, no bloqueante.

### 1.7 Demostración del `precondition` (aborta el plan)

El `precondition` protege el caso peligroso: `is_prod=true` fuera del workspace `prod`. Pruébalo en el workspace `dev`:

```bash
terraform workspace select dev
terraform plan -var-file=prod.tfvars   # is_prod=true en workspace dev
```

Terraform aborta antes de generar el plan:

```
╷
│ Error: Resource precondition failed
│
│   on main.tf line 48, in resource "aws_vpc" "main":
│    48:       condition = !(var.is_prod && terraform.workspace != "prod")
│
│ Seguridad: is_prod=true solo está permitido en el workspace 'prod'.
│ Workspace activo: 'dev'.
╵
```

No se crea ningún recurso. Esta es la diferencia clave entre `check` y `precondition`.

---

## 2. Reto: Añadir un Tercer Entorno

El laboratorio despliega dos entornos (`dev` y `prod`). Tu tarea es añadir un tercero llamado `staging` usando exactamente los mismos mecanismos que ya has visto.

### Requisitos

1. Añade `staging` al mapa `local.config` en `main.tf` con estos valores:
   - `vpc_cidr`: `10.2.0.0/16`
   - `subnet_cidr`: `10.2.1.0/24`
   - `instance_type`: `t3.small`

2. Crea el archivo `staging.tfvars` con el valor correcto para `is_prod`.

3. Crea el workspace `staging`, despliega y verifica que los outputs muestran los valores esperados.

4. Comprueba qué hace el bloque `check` existente cuando ejecutas `terraform plan -var-file=prod.tfvars` en el workspace `staging`. ¿Qué comportamiento observas y por qué?

### Criterios de éxito

- El workspace `staging` despliega una VPC con CIDR `10.2.0.0/16`.
- Los tres workspaces tienen estados independientes.
- Puedes explicar el comportamiento del bloque `check` en el punto 4.

[Ver solución →](#6-solución-del-reto)

---

## 3. Solución del Reto

<a name="6-solución-del-reto"></a>

> Intenta resolver el reto antes de leer esta sección.

### Paso 1 — Añadir `staging` a `local.config`

En `main.tf`, añade la entrada `staging` al mapa:

```hcl
config = {
  default = { vpc_cidr = "10.0.0.0/16", subnet_cidr = "10.0.1.0/24", instance_type = "t3.micro" }
  dev     = { vpc_cidr = "10.0.0.0/16", subnet_cidr = "10.0.1.0/24", instance_type = "t3.micro" }
  staging = { vpc_cidr = "10.2.0.0/16", subnet_cidr = "10.2.1.0/24", instance_type = "t3.small" }
  prod    = { vpc_cidr = "10.1.0.0/16", subnet_cidr = "10.1.1.0/24", instance_type = "t3.small" }
}
```

No hay que cambiar la línea de `lookup()`: el tercer argumento (`local.config["default"]`) ya actúa como fallback para cualquier workspace no listado.

### Paso 2 — Crear `staging.tfvars`

```hcl
is_prod = false
```

`staging` no es producción.

### Paso 3 — Despliegue

```bash
terraform workspace new staging
terraform apply -var-file=staging.tfvars
```

Output esperado:

```
workspace     = "staging"
vpc_cidr      = "10.2.0.0/16"
subnet_cidr   = "10.2.1.0/24"
instance_type = "t3.small"
is_prod       = false
```

### Paso 4 — Comportamiento del `check` con `prod.tfvars` en workspace `staging`

```bash
terraform plan -var-file=prod.tfvars   # is_prod=true en workspace staging
```

El bloque `check` evalúa `var.is_prod == (terraform.workspace == "prod")`, es decir `true == false` → condición falla → **advertencia**, pero el plan no se aborta.

El `precondition` evalúa `!(var.is_prod && terraform.workspace != "prod")`, es decir `!(true && true)` = `false` → **aborta el plan**.

El resultado: el `precondition` corta la ejecución antes de que el `check` llegue a mostrarse. Esto ilustra la prioridad de evaluación: las validaciones bloqueantes (`precondition`) actúan antes que las informativas (`check`).

---

## 4. Limpieza

**AWS real:**

```bash
terraform workspace select prod
terraform destroy -var-file=prod.tfvars

terraform workspace select dev
terraform destroy -var-file=dev.tfvars

terraform workspace select default
terraform workspace delete dev
terraform workspace delete prod
```

Verifica que los objetos de estado han desaparecido del bucket:

```bash
aws s3 ls s3://$BUCKET/lab09/ --recursive
aws s3 ls "s3://$BUCKET/env:/" --recursive
```

> Si necesitas volver al backend local, usa `terraform init -migrate-state` para migrar el estado de vuelta al disco antes de destruir el backend de LocalStack.

**Workspace de staging** (si completaste el reto):

```bash
terraform workspace select staging
terraform destroy -var-file=staging.tfvars

terraform workspace select default
terraform workspace delete staging
```

---

## 5. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

El comportamiento de workspaces, `check {}` y `precondition` es idéntico al de AWS real. Requiere que el bucket de estado de `lab07/localstack/` esté desplegado previamente.

---

## 6. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| VPC con CIDR diferenciado | Infraestructura real, costes por recursos | Simulada, sin coste |
| Backend de estado | S3 (`terraform-state-labs-<ACCOUNT_ID>`) + locking nativo | S3 LocalStack (`terraform-state-labs`) + locking nativo |
| Estado por workspace | `env:/dev/lab09/terraform.tfstate` en S3 | `env:/dev/lab09/terraform.tfstate` en LocalStack S3 |
| Bloque `check {}` | Idéntico — no llama a la API | Idéntico |
| `lifecycle { precondition }` | Idéntico — no llama a la API | Idéntico |
| Verificación de VPCs | `aws ec2 describe-vpcs` | `aws --endpoint-url=... ec2 describe-vpcs` |
| Init | `terraform init -backend-config=aws.s3.tfbackend -backend-config="bucket=..."` | `terraform init -backend-config=localstack.s3.tfbackend` |

---

## Verificación final

```bash
# Ver los workspaces existentes
terraform workspace list
# Esperado: default, dev, prod

# Verificar el workspace activo
terraform workspace show
# Esperado: prod (o dev segun el contexto)

# Comprobar que los recursos del workspace prod tienen el CIDR correcto
aws ec2 describe-vpcs \
  --filters "Name=tag:Workspace,Values=prod" \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock}' \
  --output table

# Comprobar que el check {} no lanza UNKNOWN en el workspace dev
terraform workspace select dev
terraform plan -detailed-exitcode
```

---

## Buenas prácticas aplicadas

- **Usa workspaces para entornos del mismo proyecto, no como sustituto de repositorios separados.** Los workspaces comparten el mismo código; si los entornos divergen significativamente en infraestructura, considera directorios separados o módulos.
- **Usa archivos `.tfvars` por workspace.** `dev.tfvars` y `prod.tfvars` en el repositorio hacen explícita la configuración de cada entorno y evitan pasar flags en la línea de comandos.
- **No uses el workspace `default` para producción.** Es fácil olvidar cambiar de workspace. Reserva `default` para pruebas puntuales o usa siempre workspaces nombrados.
- **Combina `check` y `precondition` según la criticidad.** `check` para inconsistencias que merecen atención pero no son bloqueantes; `precondition` para invariantes de seguridad que nunca deben violarse.
- **El estado de cada workspace es independiente pero el código es compartido.** Un `terraform destroy` en el workspace `dev` no afecta al workspace `prod`. Sin embargo, un cambio en el código afecta a todos los workspaces en el próximo `plan`.
- **En backends remotos, el workspace se refleja en la `key` del estado.** Con el backend S3 de lab07, el estado de `prod` se almacena en `env:/prod/<key>`. Documenta esta convención en el equipo.

---

## Recursos

- [Workspaces - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/state/workspaces)
- [Bloque `check` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/validate)
- [Condiciones de ciclo de vida (`precondition`)](https://developer.hashicorp.com/terraform/language/validate)
- [Referencia `terraform.workspace`](https://developer.hashicorp.com/terraform/language/state/workspaces#current-workspace-interpolation)
- [Recurso aws_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc)
- [Recurso aws_subnet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet)
