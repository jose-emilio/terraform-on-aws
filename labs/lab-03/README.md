# Laboratorio 3: Infraestructura Parametrizada y Dinámica

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 2 — Lenguaje HCL y Configuración Avanzada](../../modulos/modulo-02/README.md)


## Visión general

En este laboratorio crearás una red base en AWS usando variables con tipos complejos, la función `cidrsubnet()` para calcular subredes automáticamente y bloques dinámicos para generar reglas de firewall. El objetivo es eliminar el _hardcoding_ de valores y escribir infraestructura reutilizable y validada.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Definir variables con tipos complejos (`object`, `list`) y validaciones personalizadas
- Usar `cidrsubnet()` para dividir un bloque CIDR en subredes sin hardcodear IPs
- Implementar bloques `dynamic` para generar recursos repetitivos desde una lista
- Aplicar `terraform fmt` para mantener el estilo estándar de la comunidad

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
- Laboratorio 2 completado (flujo básico de Terraform)
---

## Conceptos Clave

### Variables con Tipos Complejos

Terraform permite definir variables con tipos estructurados usando `object`. Esto agrupa parámetros relacionados en una sola variable y permite validarlos de forma centralizada.

```hcl
variable "network_config" {
  type = object({
    name       = string
    cidr_block = string
    env        = string
  })
}
```

Las **validaciones** usan el bloque `validation` con una condición booleana y un mensaje de error. Si la condición es `false`, Terraform rechaza el valor antes de planificar.

```hcl
  validation {
    condition     = can(regex("^corp-[a-z0-9-]+$", var.network_config.name))
    error_message = "El nombre debe seguir el estándar corporativo: 'corp-' seguido de letras minúsculas, números o guiones."
  }
```

- `can()` devuelve `true` si la expresión no produce un error (útil con `regex()`)
- `regex()` aplica una expresión regular; lanza error si no hay coincidencia

### Función `cidrsubnet()`

Divide un bloque CIDR en subredes más pequeñas de forma automática:

```
cidrsubnet(prefix, newbits, netnum)
```

| Parámetro | Descripción |
|---|---|
| `prefix` | Bloque CIDR base (p. ej. `"10.0.0.0/16"`) |
| `newbits` | Bits adicionales para la máscara de subred |
| `netnum` | Número de subred (índice) |

Ejemplo con `cidrsubnet("10.0.0.0/16", 8, 0)`:
- Nueva máscara: `/16 + 8 = /24`
- Resultado: `10.0.0.0/24`

Con `netnum = 1` → `10.0.1.0/24`, con `netnum = 2` → `10.0.2.0/24`, etc.

Combinado con `count.index`, permite crear N subredes sin escribir ninguna IP manualmente.

### Bloque `dynamic`

Genera bloques de configuración repetitivos a partir de una colección. Evita duplicar código cuando el número de bloques es variable.

```hcl
dynamic "ingress" {
  for_each = var.firewall_rules
  content {
    from_port = ingress.value.port
    to_port   = ingress.value.port
    protocol  = "tcp"
    ...
  }
}
```

- `for_each` itera sobre la colección
- `content` define la estructura de cada bloque generado
- Dentro de `content`, se accede al elemento actual con `<etiqueta>.value`

### Comando `terraform fmt`

Formatea todos los archivos `.tf` del directorio actual al estilo estándar de la comunidad (indentación, alineación de `=`, etc.):

```bash
terraform fmt
```

Para ver qué archivos serían modificados sin aplicar cambios:

```bash
terraform fmt -check -diff
```

> Es buena práctica ejecutar `terraform fmt` antes de cada commit para mantener el código consistente.

---

## Estructura del proyecto

```
lab03/
├── aws/
│   ├── providers.tf   # Bloques terraform{} y provider{}
│   ├── variables.tf   # Variables con tipos object y validaciones
│   ├── main.tf        # Recursos: VPC, subredes y security group
│   └── outputs.tf     # Bloques output{}
└── localstack/
    ├── providers.tf   # Igual pero con endpoint ec2 local
    ├── variables.tf   # Idéntico al de aws/
    ├── main.tf        # Idéntico al de aws/
    └── outputs.tf     # Idéntico al de aws/
```

Esta estructura sigue la nomenclatura estándar recomendada por HashiCorp: cada fichero tiene una responsabilidad única. `providers.tf` es el único que difiere entre entornos; el resto es compartido.

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`aws/providers.tf`**

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}
```

**`aws/variables.tf`**

```hcl
variable "network_config" {
  type = object({
    name       = string
    cidr_block = string
    env        = string
  })

  default = {
    name       = "corp-lab2"
    cidr_block = "10.0.0.0/16"
    env        = "dev"
  }

  validation {
    condition     = can(regex("^corp-[a-z0-9-]+$", var.network_config.name))
    error_message = "El nombre debe seguir el estándar corporativo: 'corp-' seguido de letras minúsculas, números o guiones."
  }

  validation {
    condition     = contains(["dev", "staging", "prod"], var.network_config.env)
    error_message = "El entorno debe ser 'dev', 'staging' o 'prod'."
  }
}

variable "firewall_rules" {
  type = list(object({
    port        = number
    description = string
  }))

  default = [
    { port = 22, description = "SSH" },
    { port = 80, description = "HTTP" },
    { port = 443, description = "HTTPS" },
  ]
}
```

**`aws/main.tf`**

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.network_config.cidr_block

  tags = {
    Name = var.network_config.name
    Env  = var.network_config.env
  }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.network_config.cidr_block, 8, count.index)
  availability_zone = "us-east-1${["a", "b"][count.index]}"

  tags = {
    Name = "${var.network_config.name}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.network_config.cidr_block, 8, count.index + 10)
  availability_zone = "us-east-1${["a", "b"][count.index]}"

  tags = {
    Name = "${var.network_config.name}-private-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_security_group" "main" {
  name        = "${var.network_config.name}-sg"
  description = "Security group para ${var.network_config.name}"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.firewall_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_config.name}-sg"
  }
}
```

**`aws/outputs.tf`**

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_cidrs" {
  value = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  value = aws_subnet.private[*].cidr_block
}

output "security_group_id" {
  value = aws_security_group.main.id
}
```

### 1.2 Formatear el Código

Antes de desplegar, aplica el formateador estándar:

```bash
terraform fmt
```

Si el código ya está bien formateado, el comando no produce salida. Si hay cambios, muestra los archivos modificados:

```
providers.tf
variables.tf
main.tf
outputs.tf
```

Para verificar sin modificar:

```bash
terraform fmt -check -diff
```

### 1.3 Despliegue

Desde el directorio `lab02/aws/`:

```bash
terraform init
terraform plan
terraform apply
```

Durante el `plan`, Terraform mostrará los 5 recursos a crear: 1 VPC, 2 subredes públicas, 2 subredes privadas y 1 security group con 3 reglas de ingress generadas dinámicamente.

### 1.4 Verificar las Validaciones

Prueba que las validaciones funcionan pasando un valor inválido:

```bash
terraform plan -var='network_config={"name":"invalid_name","cidr_block":"10.0.0.0/16","env":"dev"}'
```

Salida esperada:

```
╷
│ Error: Invalid value for variable
│
│   on variables.tf line 1:
│    1: variable "network_config" {
│
│ El nombre debe seguir el estándar corporativo: 'corp-' seguido de letras minúsculas, números o guiones.
╵
```

### 1.5 Verificación

Al finalizar `terraform apply`, los outputs mostrarán los CIDRs calculados automáticamente:

```
Outputs:

private_subnet_cidrs = [
  "10.0.10.0/24",
  "10.0.11.0/24",
]
public_subnet_cidrs = [
  "10.0.0.0/24",
  "10.0.1.0/24",
]
security_group_id = "sg-0abc123..."
vpc_id            = "vpc-0abc123..."
```

Verifica desde AWS CLI:

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=corp-lab2"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=<VPC_ID>"
```

---

## Verificación final

```bash
# Obtener el VPC ID creado
VPC_ID=$(terraform output -raw vpc_id)
echo "VPC ID: ${VPC_ID}"

# Verificar las subredes calculadas con cidrsubnet()
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table

# Verificar los security groups con reglas dinamicas
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[*].{Name:GroupName,Rules:IpPermissions[*].FromPort}' \
  --output table

# Confirmar que los outputs son correctos
terraform output
```

---

## 2. Limpieza

```bash
terraform destroy
```

> Los recursos de red (VPC, subredes, security groups) no generan costo por sí mismos en AWS, pero es buena práctica limpiar el entorno al terminar el laboratorio.

---

## 3. LocalStack

Este laboratorio puede ejecutarse íntegramente en LocalStack. Consulta [localstack/README.md](localstack/README.md) para las instrucciones de despliegue local.

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Endpoint redirigido | Por defecto (AWS) | `ec2 = "http://localhost.localstack.cloud:4566"` |
| Credenciales | Credenciales IAM reales | `test` / `test` |
| Costo | Sin costo (recursos de red) | Gratuito |
| Uso recomendado | Staging / producción | Desarrollo y pruebas |

---

## Buenas prácticas aplicadas

- **Separa el código en ficheros por responsabilidad**: `providers.tf`, `variables.tf`, `main.tf` y `outputs.tf`. Es la nomenclatura estándar recomendada por HashiCorp y facilita la navegación en proyectos grandes.
- **Usa `terraform fmt` siempre** antes de hacer commit. Muchos equipos lo integran como hook de pre-commit.
- **Centraliza la configuración en variables `object`** en lugar de tener múltiples variables sueltas. Facilita pasar toda la configuración de red como un único parámetro.
- **Usa `cidrsubnet()` siempre** para calcular subredes. Hardcodear CIDRs es propenso a errores y dificulta cambiar el bloque base.
- **Los bloques `dynamic` son para colecciones variables.** Si siempre tienes exactamente N bloques fijos, es más legible escribirlos explícitamente.
- **Valida las entradas** con `validation` para detectar errores de configuración antes de que Terraform contacte a AWS.

---

## Recursos

- [Tipos de variables en Terraform](https://developer.hashicorp.com/terraform/language/expressions/types)
- [Validaciones de variables](https://developer.hashicorp.com/terraform/language/values/variables#custom-validation-rules)
- [Función cidrsubnet()](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
- [Bloques dynamic](https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks)
- [terraform fmt](https://developer.hashicorp.com/terraform/cli/commands/fmt)
- [Recurso aws_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc)
- [Recurso aws_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group)
