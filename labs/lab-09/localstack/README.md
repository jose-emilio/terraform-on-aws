# Laboratorio 9: LocalStack: Gestión de Entornos con Workspaces

![Terraform on AWS](../../../images/lab-banner.svg)


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
- Laboratorio 1 completado (entorno configurado)
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

Con el backend S3 (lab02), la `key` se prefija automáticamente con el nombre del workspace: `env:/dev/lab09/terraform.tfstate`.

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

## Estructura del Laboratorio

```
lab09/
├── aws/
│   ├── providers.tf      # Requiere Terraform >= 1.5
│   ├── variables.tf      # region, is_prod
│   ├── main.tf           # locals, check {}, aws_vpc con precondition, aws_subnet
│   ├── outputs.tf        # workspace, vpc_id, cidr, instance_type, is_prod
│   ├── dev.tfvars        # is_prod = false
│   └── prod.tfvars       # is_prod = true
└── localstack/
    ├── providers.tf      # Endpoints apuntando a LocalStack (ec2)
    ├── variables.tf      # is_prod
    ├── main.tf           # Idéntico al de aws/
    ├── outputs.tf        # Idéntico al de aws/
    ├── dev.tfvars
    └── prod.tfvars
```

---

## 1. Despliegue en LocalStack

### 1.1 Diferencias en `localstack/providers.tf`

El provider apunta al endpoint EC2 de LocalStack. El comportamiento de workspaces, `check {}` y `precondition` es idéntico al de AWS real ya que operan sobre el estado local y la lógica de Terraform, no sobre la API de AWS.

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost.localstack.cloud:4566"
  }
}
```

### 1.2 Despliegue

Asegúrate de que LocalStack esté en ejecución:

```bash
localstack status
```

El flujo es idéntico a la sección AWS real:

```bash
# Desde lab09/localstack/
terraform fmt
terraform init -backend-config=localstack.s3.tfbackend

terraform workspace new dev
terraform apply -var-file=dev.tfvars

terraform workspace new prod
terraform apply -var-file=prod.tfvars
```

### 1.3 Verificación

```bash
aws --endpoint-url=http://localhost.localstack.cloud:4566 ec2 describe-vpcs \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table
```

### 1.4 Demostración del `check` y `precondition` en LocalStack

Los comportamientos son idénticos a AWS real — las validaciones de `check` y `precondition` no realizan llamadas a la API. Repite los mismos comandos de las secciones 1.6 y 1.7 desde el directorio `localstack/`.

### 1.5 Destruir los Recursos

```bash
terraform workspace select prod
terraform destroy -var-file=prod.tfvars

terraform workspace select dev
terraform destroy -var-file=dev.tfvars

terraform workspace select default
terraform workspace delete dev
terraform workspace delete prod
```

---

## 2. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| VPC con CIDR diferenciado | Infraestructura real, costes por recursos | Simulada, sin coste |
| Estado por workspace | Archivo local o S3 (lab02) | S3 en LocalStack (lab02) |
| Bloque `check {}` | Idéntico — no llama a la API | Idéntico |
| `lifecycle { precondition }` | Idéntico — no llama a la API | Idéntico |
| Verificación de VPCs | `aws ec2 describe-vpcs` | `aws --endpoint-url=... ec2 describe-vpcs` |

---

## 3. Buenas Prácticas

- **Usa workspaces para entornos del mismo proyecto, no como sustituto de repositorios separados.** Los workspaces comparten el mismo código; si los entornos divergen significativamente en infraestructura, considera directorios separados o módulos.
- **Usa archivos `.tfvars` por workspace.** `dev.tfvars` y `prod.tfvars` en el repositorio hacen explícita la configuración de cada entorno y evitan pasar flags en la línea de comandos.
- **No uses el workspace `default` para producción.** Es fácil olvidar cambiar de workspace. Reserva `default` para pruebas puntuales o usa siempre workspaces nombrados.
- **Combina `check` y `precondition` según la criticidad.** `check` para inconsistencias que merecen atención pero no son bloqueantes; `precondition` para invariantes de seguridad que nunca deben violarse.
- **El estado de cada workspace es independiente pero el código es compartido.** Un `terraform destroy` en el workspace `dev` no afecta al workspace `prod`. Sin embargo, un cambio en el código afecta a todos los workspaces en el próximo `plan`.
- **En backends remotos, el workspace se refleja en la `key` del estado.** Con el backend S3 de lab02, el estado de `prod` se almacena en `env:/prod/<key>`. Documenta esta convención en el equipo.

---

## 4. Reto: Añadir un Tercer Entorno

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

## 5. Solución del Reto

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

### Limpieza

```bash
terraform workspace select staging
terraform destroy -var-file=staging.tfvars

terraform workspace select default
terraform workspace delete staging
```

---

## 6. Recursos Adicionales

- [Workspaces - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/state/workspaces)
- [Bloque `check` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/validate)
- [Condiciones de ciclo de vida (`precondition`)](https://developer.hashicorp.com/terraform/language/validate)
- [Referencia `terraform.workspace`](https://developer.hashicorp.com/terraform/language/state/workspaces#current-workspace-interpolation)
- [Recurso aws_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc)
- [Recurso aws_subnet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet)
