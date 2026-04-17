# Laboratorio 4: Orquestación de Identidades y Gestión de Ciclo de Vida

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 2 — Lenguaje HCL y Configuración Avanzada](../../modulos/modulo-02/README.md)


## Visión general

En este laboratorio crearás usuarios IAM de forma masiva usando `for_each`, buscarás la AMI de Ubuntu más reciente con un data source dinámico y configurarás un launch template con una estrategia de actualización blue-green mediante el meta-argumento `lifecycle`. El objetivo es dominar los mecanismos de iteración y control de ciclo de vida de Terraform.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Usar `for_each` con un `map` para crear múltiples recursos desde una única definición
- Acceder a `each.key` y `each.value` para personalizar cada recurso
- Consultar datos externos con data sources (`aws_ami`, `aws_caller_identity`)
- Aplicar `lifecycle { create_before_destroy = true }` para actualizaciones sin downtime
- Construir outputs de auditoría con expresiones `for`

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
- Laboratorio 2 completado (flujo básico de Terraform)
---

## Conceptos Clave

### Meta-argumento `for_each`

Mientras `count` crea recursos indexados por número, `for_each` los crea indexados por clave de un `map` o `set`. Esto permite referenciar cada instancia por nombre en lugar de por posición, lo que hace el estado más robusto ante eliminaciones intermedias.

```hcl
resource "aws_iam_user" "team" {
  for_each = var.iam_users   # map(object)

  name = each.key            # clave del map → nombre del usuario
  tags = {
    Department = each.value.department   # valor del map
  }
}
```

Terraform crea una instancia por cada entrada del map. En el estado, cada recurso se identifica como `aws_iam_user.team["alice"]`, `aws_iam_user.team["bob"]`, etc.

### Data Sources

Los data sources permiten consultar información existente en AWS sin gestionarla con Terraform. Se declaran con el bloque `data` y se referencian como `data.<tipo>.<nombre>.<atributo>`.

**`aws_ami`** busca imágenes de máquina en el catálogo de AWS aplicando filtros:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]  # AMIs oficiales de AWS

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}
```

Con `most_recent = true`, Terraform selecciona siempre la AMI más reciente que cumpla los filtros. El filtro de arquitectura `arm64` es necesario porque las instancias `t4g` usan procesadores AWS Graviton (ARM), y no son compatibles con AMIs `x86_64`.

**`aws_caller_identity`** devuelve información sobre las credenciales activas:

```hcl
data "aws_caller_identity" "current" {}
```

No requiere argumentos. Expone `account_id`, `user_id` y `arn`, útiles para outputs de auditoría o para construir ARNs dinámicamente.

### Meta-argumento `lifecycle`

El bloque `lifecycle` controla cómo Terraform gestiona la creación, actualización y destrucción de un recurso. Se define dentro del propio recurso.

```hcl
resource "aws_launch_template" "app" {
  ...
  lifecycle {
    create_before_destroy = true
  }
}
```

Por defecto, cuando un recurso debe ser reemplazado (porque un atributo inmutable cambia), Terraform lo destruye primero y luego crea el nuevo. Con `create_before_destroy = true` invierte el orden: crea el nuevo recurso, y solo cuando está listo destruye el antiguo. Esto es la base de una estrategia **blue-green** y evita tiempos de inactividad.

| Comportamiento | Sin `create_before_destroy` | Con `create_before_destroy` |
|---|---|---|
| Orden | Destruir → Crear | Crear → Destruir |
| Downtime | Sí (breve) | No |
| Uso típico | Recursos sin dependencias críticas | Launch templates, certificados, DNS |

### Expresión `for` en outputs

Permite transformar una colección en otra dentro de un output:

```hcl
output "iam_user_arns" {
  value = { for name, user in aws_iam_user.team : name => user.arn }
}
```

Esto genera un map `{ "alice" => "arn:...", "bob" => "arn:..." }`, mucho más legible que una lista de ARNs sin etiqueta.

---

## Estructura del proyecto

```
lab04/
├── aws/
│   ├── providers.tf   # Bloque terraform{} y provider{}
│   ├── variables.tf   # Map de usuarios IAM y nombre de aplicación
│   ├── main.tf        # Data sources, aws_iam_user y aws_launch_template
│   └── outputs.tf     # ARNs de usuarios, caller identity y launch template
└── localstack/
    ├── providers.tf   # Endpoints iam, ec2 y sts apuntando a LocalStack
    ├── variables.tf   # Idéntico al de aws/
    ├── main.tf        # Sin data aws_ami (limitación de LocalStack)
    └── outputs.tf     # Sin output de AMI
```

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`aws/providers.tf`**

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

**`aws/variables.tf`**

```hcl
variable "iam_users" {
  type = map(object({
    department  = string
    cost_center = string
  }))

  default = {
    "alice" = { department = "engineering", cost_center = "CC-100" }
    "bob"   = { department = "finance", cost_center = "CC-200" }
    "carol" = { department = "engineering", cost_center = "CC-100" }
  }
}

variable "app_name" {
  type    = string
  default = "corp-lab3"
}
```

**`aws/main.tf`**

```hcl
data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_iam_user" "team" {
  for_each = var.iam_users

  name = each.key

  tags = {
    Department = each.value.department
    CostCenter = each.value.cost_center
    ManagedBy  = "terraform"
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t4g.small"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.app_name
  }
}
```

**`aws/outputs.tf`**

```hcl
output "account_id" {
  description = "ID de la cuenta AWS activa"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "ARN de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.arn
}

output "iam_user_arns" {
  description = "ARNs de los usuarios IAM creados"
  value       = { for name, user in aws_iam_user.team : name => user.arn }
}

output "launch_template_id" {
  description = "ID del launch template creado"
  value       = aws_launch_template.app.id
}

output "ami_id" {
  description = "ID de la AMI de Amazon Linux 2023 seleccionada"
  value       = data.aws_ami.al2023.id
}
```

### 1.2 Despliegue

Desde el directorio `lab03/aws/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

Durante el `plan`, Terraform mostrará los data sources resueltos y los 4 recursos a crear: 3 usuarios IAM (uno por entrada del map) y 1 launch template.

### 1.3 Verificación

Al finalizar `terraform apply`, los outputs mostrarán la auditoría completa:

```
Outputs:

account_id         = "123456789012"
ami_id             = "ami-0a1b2c3d4e5f67890"
caller_arn         = "arn:aws:iam::123456789012:user/jose-emilio"
iam_user_arns      = {
  "alice" = "arn:aws:iam::123456789012:user/alice"
  "bob"   = "arn:aws:iam::123456789012:user/bob"
  "carol" = "arn:aws:iam::123456789012:user/carol"
}
launch_template_id = "lt-0abc123def456..."
```

Verifica desde AWS CLI:

```bash
aws iam list-users
aws ec2 describe-launch-templates --filters "Name=tag:Name,Values=corp-lab3"
```

### 1.4 Simular una Actualización Blue-Green

Modifica el tipo de instancia en `variables.tf` o directamente en `main.tf` para forzar el reemplazo del launch template:

```bash
terraform plan -var='app_name=corp-lab3-v2'
```

Observa en el plan cómo Terraform indica `# aws_launch_template.app must be replaced` y que el orden será crear primero, destruir después:

```
  # aws_launch_template.app must be replaced
+/- resource "aws_launch_template" "app" {
      ~ name = "corp-lab3-..." -> (known after apply) # forces replacement
    }

Plan: 1 to add, 0 to change, 1 to destroy.
```

El símbolo `+/-` indica que se aplicará `create_before_destroy`.

### 1.5 Añadir un Usuario al Map

Añade una entrada al map en `variables.tf`:

```hcl
"dave" = { department = "ops", cost_center = "CC-300" }
```

Ejecuta `terraform plan`. Terraform solo creará el nuevo usuario sin tocar los existentes, a diferencia de `count` donde un cambio de índice podría recrear recursos.

---

## Verificación final

```bash
# Listar los usuarios IAM creados por for_each
aws iam list-users \
  --query 'Users[?contains(UserName,`corp-`)].UserName' \
  --output table

# Verificar el Launch Template fue creado correctamente
aws ec2 describe-launch-templates \
  --query 'LaunchTemplates[?contains(LaunchTemplateName,`lab4`)].{Name:LaunchTemplateName,Version:DefaultVersionNumber}' \
  --output table

# Confirmar la AMI de Ubuntu mas reciente seleccionada
terraform output ubuntu_ami_id
terraform output ubuntu_ami_name

# Verificar la identidad de despliegue
terraform output caller_arn
```

---

## 2. Limpieza

```bash
terraform destroy
```

> Los usuarios IAM sin políticas ni claves de acceso no generan costo, pero es buena práctica limpiar el entorno.

---

## 3. LocalStack

Este laboratorio puede ejecutarse íntegramente en LocalStack (con limitaciones en `aws_ami`). Consulta [localstack/README.md](localstack/README.md) para las instrucciones de despliegue local.

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `data "aws_ami"` | Resuelve la AMI arm64 de Amazon Linux 2023 más reciente | No soportado; se usa AMI ficticia |
| `data "aws_caller_identity"` | Devuelve identidad IAM real | Devuelve cuenta `000000000000` |
| Endpoints redirigidos | Por defecto (AWS) | `iam`, `ec2`, `sts` |
| Usuarios IAM creados | Reales en la cuenta | Solo en LocalStack |

---

## Buenas prácticas aplicadas

- **Prefiere `for_each` sobre `count`** cuando los recursos tienen identidad propia (usuarios, buckets, etc.). Con `count`, eliminar un elemento intermedio del array renumera los índices y Terraform recrea recursos innecesariamente.
- **Nunca hardcodees IDs de AMI.** Usan el formato `ami-XXXXXXXXX` y varían por región y con el tiempo. El data source `aws_ami` garantiza que siempre se usa la imagen correcta y actualizada.
- **Filtra por arquitectura cuando uses instancias Graviton.** Las instancias `t4g` usan ARM64; una AMI `x86_64` no arrancará en ellas. El filtro `architecture = arm64` evita este error silencioso.
- **Usa `lifecycle { create_before_destroy = true }` en recursos que otros dependen de ellos** (launch templates, certificados TLS, registros DNS). Evita que una actualización deje dependencias rotas durante el reemplazo.
- **Los outputs de auditoría son documentación viva.** Exponer `caller_arn` y `account_id` permite verificar en qué cuenta y con qué identidad se desplegó la infraestructura, lo que es especialmente valioso en entornos multi-cuenta.

---

## Recursos

- [Meta-argumento for_each](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
- [Data source aws_ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami)
- [Data source aws_caller_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity)
- [Meta-argumento lifecycle](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- [Expresiones for](https://developer.hashicorp.com/terraform/language/expressions/for)
- [Recurso aws_iam_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user)
- [Recurso aws_launch_template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template)
