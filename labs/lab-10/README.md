# Laboratorio 10: Arquitectura de State Splitting (Capas de Infraestructura)

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio dividirás un estado monolítico en capas independientes para reducir el **blast radius** (radio de impacto) ante errores o cambios. Aprenderás a publicar valores entre proyectos Terraform mediante `output` y a consumirlos desde otra capa con el data source `terraform_remote_state`, sin duplicar ni hardcodear ningún identificador de recursos.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Entender qué es el blast radius y por qué el estado monolítico lo amplifica
- Dividir un proyecto Terraform en capas independientes (red y cómputo)
- Publicar identificadores de recursos como `output` para que actúen como interfaz pública entre capas
- Leer el estado de otra capa con el data source `terraform_remote_state`
- Verificar experimentalmente que un error o destrucción en la capa de cómputo no afecta el estado de la capa de red
- Aplicar la convención de backends S3 separados por capa (AWS real) y backends locales por directorio (LocalStack)

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir en AWS
- LocalStack en ejecución — para la sección LocalStack

---

## Conceptos Clave

### Blast radius y el estado monolítico

En un proyecto Terraform donde toda la infraestructura (red, cómputo, bases de datos, DNS…) comparte un único archivo de estado, cualquier operación arriesgada tiene un **blast radius máximo**:

- Un `terraform destroy` accidental puede eliminar toda la infraestructura de una vez.
- Un error en el plan de la capa de cómputo bloquea también el despliegue de la capa de red, aunque esta no haya cambiado.
- Dos equipos trabajando sobre el mismo estado pueden pisarse mutuamente al hacer `apply` en paralelo (condición de carrera en el lock).

```
Estado monolítico (un solo tfstate)
┌─────────────────────────────────────────────┐
│  aws_vpc + aws_subnet                       │  ← Red
│  aws_security_group + aws_instance          │  ← Cómputo
│  aws_db_instance                            │  ← Base de datos
└─────────────────────────────────────────────┘
         Un error aquí afecta a todo ↑
```

### Arquitectura de capas (state splitting)

La solución es separar la infraestructura en proyectos Terraform independientes, cada uno con su propio estado. Cada capa solo gestiona los recursos de su dominio y expone una interfaz pública mínima a través de `output`.

```
Capa de Red (network/tfstate)          Capa de Cómputo (compute/tfstate)
┌──────────────────────────┐           ┌──────────────────────────────────┐
│  aws_vpc.main            │           │  data "terraform_remote_state"   │
│  aws_subnet.public       │  outputs  │    └── vpc_id (solo lectura)     │
│                          │ ────────► │  aws_security_group.app          │
│  output "vpc_id"         │           │                                  │
│  output "subnet_id"      │           │                                  │
└──────────────────────────┘           └──────────────────────────────────┘
      Estado aislado                         Estado aislado
```

Un error o destrucción en la capa de cómputo **no toca** el estado de la capa de red. El blast radius queda contenido al dominio afectado.

### `output` como interfaz pública entre capas

Los outputs de un proyecto Terraform se almacenan en su archivo de estado. Actúan como la **API pública** de esa capa: todo lo que otras capas necesiten saber debe estar en un output; lo que no se exporta permanece encapsulado.

```hcl
# network/outputs.tf — interfaz pública de la capa de red
output "vpc_id" {
  description = "ID de la VPC desplegada por la capa de red."
  value       = aws_vpc.main.id
}
```

### Data source `terraform_remote_state`

Permite leer los outputs del estado remoto de otro proyecto Terraform sin acceder a sus recursos ni a su código. Es de **solo lectura**: nunca modifica el estado que lee.

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"                           # o "local" en LocalStack

  config = {
    bucket = var.network_state_bucket      # bucket S3 de la capa de red
    key    = "lab10/network/terraform.tfstate"
    region = "us-east-1"
  }
}

# Acceder a los outputs de la capa de red:
local.vpc_id = data.terraform_remote_state.network.outputs.vpc_id
```

Si la capa de red no ha sido desplegada, el data source falla inmediatamente en la capa de cómputo, sin tocar ningún recurso existente ni bloquear el estado de red.

### Tabla comparativa: monolítico vs capas

| Aspecto | Estado monolítico | Arquitectura de capas |
|---|---|---|
| Blast radius ante un error | Toda la infraestructura en riesgo | Contenido a la capa afectada |
| Tiempo de `plan` | Crece con cada recurso añadido | Proporcional al tamaño de cada capa |
| Trabajo en equipo | Un lock bloquea a todos | Cada equipo trabaja en su capa |
| Granularidad de permisos | Un único rol con acceso a todo | Roles por capa (principio de mínimo privilegio) |
| Complejidad inicial | Baja (un solo directorio) | Moderada (múltiples proyectos) |

---

## Estructura del proyecto

```
lab10/
├── aws/
│   ├── network/
│   │   ├── providers.tf      # Backend S3 (parcial) + provider AWS
│   │   ├── variables.tf      # region, vpc_cidr
│   │   ├── main.tf           # aws_vpc + aws_subnet
│   │   ├── outputs.tf        # vpc_id, subnet_id, vpc_cidr
│   │   └── aws.s3.tfbackend  # key = "lab10/network/terraform.tfstate"
│   └── compute/
│       ├── providers.tf      # Backend S3 (parcial) + provider AWS
│       ├── variables.tf      # region, network_state_bucket, network_state_key
│       ├── main.tf           # terraform_remote_state + aws_security_group
│       ├── outputs.tf        # vpc_id, subnet_id, security_group_id
│       └── aws.s3.tfbackend  # key = "lab10/compute/terraform.tfstate"
└── localstack/
    ├── README.md             # Instrucciones específicas de LocalStack
    ├── network/
    │   ├── providers.tf      # Backend local + provider LocalStack
    │   ├── variables.tf      # region, vpc_cidr
    │   ├── main.tf           # Idéntico a aws/network/
    │   └── outputs.tf        # Idéntico a aws/network/
    └── compute/
        ├── providers.tf      # Backend local + provider LocalStack
        ├── variables.tf      # network_state_path (ruta relativa al tfstate de red)
        ├── main.tf           # terraform_remote_state (local) + aws_security_group
        └── outputs.tf        # Idéntico a aws/compute/
```

> **Nota sobre la estructura:** Este laboratorio tiene dos subdirectorios por entorno (`network/` y `compute/`) en lugar del archivo plano de laboratorios anteriores. Cada subdirectorio es un proyecto Terraform independiente con su propio `terraform init`.

---

## 1. Despliegue en AWS Real

### 1.1 Prerrequisito: bucket S3 del lab02

Las capas de red y cómputo almacenan sus estados en el bucket compartido del curso creado en el lab02, bajo claves distintas (`lab10/network/` y `lab10/compute/`).

```bash
# Exporta el nombre del bucket del lab02
export STATE_BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Verifica que el bucket existe y tiene versionado activo
aws s3api get-bucket-versioning --bucket $STATE_BUCKET
# {"Status": "Enabled"}
```

Si el bucket no existe, vuelve al lab02 y ejecuta `terraform apply` antes de continuar.

### 1.2 Código Terraform

**`aws/network/main.tf`** — Capa de Red:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "vpc-lab10"
    ManagedBy = "terraform"
    Layer     = "network"
  }
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, 1)

  tags = {
    Name      = "subnet-public-lab10"
    ManagedBy = "terraform"
    Layer     = "network"
  }
}
```

**`aws/network/outputs.tf`** — Interfaz pública de la capa de red:

```hcl
output "vpc_id" {
  description = "ID de la VPC desplegada por la capa de red."
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID de la subred pública."
  value       = aws_subnet.public.id
}

output "vpc_cidr" {
  description = "Bloque CIDR de la VPC."
  value       = aws_vpc.main.cidr_block
}
```

**`aws/compute/main.tf`** — Capa de Cómputo que consume la red:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.network_state_bucket
    key    = var.network_state_key
    region = var.region
  }
}

locals {
  vpc_id    = data.terraform_remote_state.network.outputs.vpc_id
  subnet_id = data.terraform_remote_state.network.outputs.subnet_id
}

resource "aws_security_group" "app" {
  name        = "app-lab10"
  description = "Security group de la capa de computo (Lab10)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "app-lab10"
    ManagedBy = "terraform"
    Layer     = "compute"
  }
}
```

### 1.3 Despliegue de la Capa de Red

```bash
# Desde lab-10/aws/network/

terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$STATE_BUCKET"

terraform plan
terraform apply
```

Los outputs mostrarán los identificadores que usará la capa de cómputo:

```
subnet_id = "subnet-0a1b2c3d4e5f67890"
vpc_cidr  = "10.0.0.0/16"
vpc_id    = "vpc-0a1b2c3d4e5f67890"
```

### 1.4 Despliegue de la Capa de Cómputo

```bash
# Desde lab-10/aws/compute/

terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$STATE_BUCKET"

terraform plan -var="network_state_bucket=$STATE_BUCKET"
terraform apply -var="network_state_bucket=$STATE_BUCKET"
```

Los outputs confirman que `vpc_id` y `subnet_id` son los mismos valores que exportó la capa de red:

```
security_group_id = "sg-0a1b2c3d4e5f67890"
subnet_id         = "subnet-0a1b2c3d4e5f67890"
vpc_id            = "vpc-0a1b2c3d4e5f67890"
```

### 1.5 Verificación del Aislamiento (Blast Radius)

Esta es la demostración central del laboratorio. Vas a destruir completamente la capa de cómputo y verificar que la capa de red no se ve afectada.

**Paso 1** — Destruye la capa de cómputo:

```bash
# Desde lab-10/aws/compute/

terraform destroy -var="network_state_bucket=$STATE_BUCKET"
```

Terraform destruye únicamente el security group. Confirma que el plan muestra:

```
Plan: 0 to add, 0 to change, 1 to destroy.
```

**Paso 2** — Verifica que la capa de red no fue afectada:

```bash
# Desde lab-10/aws/network/

terraform state list
```

Resultado esperado:

```
aws_subnet.public
aws_vpc.main
```

El estado de la capa de red permanece intacto. Ningún recurso fue destruido ni modificado.

**Paso 3** — Confirma que la VPC sigue existiendo en AWS:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:ManagedBy,Values=terraform" \
           "Name=tag:Layer,Values=network" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,State:State}' \
  --output table
```

La VPC aparece con `State = available`. El blast radius del destroy de cómputo quedó contenido.

**Paso 4** — Redespliega la capa de cómputo sin tocar la de red:

```bash
# Desde lab-10/aws/compute/

terraform apply -var="network_state_bucket=$STATE_BUCKET"
```

El security group se recrea referenciando el mismo `vpc_id` que ya existía. La capa de red nunca fue interrumpida.

### 1.6 Consultar el Estado Remoto Directamente

Puedes leer los outputs de la capa de red en cualquier momento sin necesidad de estar en el directorio de red:

```bash
# Desde lab-10/aws/compute/ (o cualquier directorio)

aws s3 cp s3://$STATE_BUCKET/lab10/network/terraform.tfstate - | \
  python3 -c "import sys,json; s=json.load(sys.stdin); \
  [print(k,'=',v['value']) for k,v in s['outputs'].items()]"
```

También puedes verificar que los dos estados son completamente independientes en S3:

```bash
aws s3 ls s3://$STATE_BUCKET/lab10/ --recursive
# lab10/network/terraform.tfstate
# lab10/compute/terraform.tfstate
```

---

## 2. Reto: Segunda Subred

La capa de red actual despliega una sola subred pública. Tu tarea es añadir una segunda subred con un CIDR diferente y actualizar la capa de cómputo para que cree un segundo security group asociado a esa nueva subred.

### Requisitos

1. En `network/main.tf`, añade un recurso `aws_subnet.private` con `cidrsubnet(var.vpc_cidr, 8, 2)` y el tag `Name = "subnet-private-lab10"`.

2. En `network/outputs.tf`, añade el output `private_subnet_id` que exponga el ID de la nueva subred.

3. En `compute/main.tf`, añade un segundo security group `aws_security_group.internal` que referencie la nueva subred usando `data.terraform_remote_state.network.outputs.private_subnet_id`. Asocia el security group a la misma VPC.

4. Aplica los cambios en ambas capas **en orden** (primero red, luego cómputo) y verifica que los outputs de cómputo muestran el ID del nuevo security group.

### Criterios de Éxito

- La capa de red despliega dos subredes con CIDRs `10.0.1.0/24` y `10.0.2.0/24`.
- La capa de cómputo despliega dos security groups, cada uno asociado a la misma VPC.
- El output de red `private_subnet_id` es accesible desde la capa de cómputo vía `terraform_remote_state`.
- Puedes destruir y redesplegar la capa de cómputo sin afectar la capa de red.

[Ver solución →](#3-solución-del-reto-segunda-subred)

---

## 3. Solución del Reto: Segunda Subred

> Intenta resolver el reto antes de leer esta sección.

### Paso 1 — Añadir la subred privada en `network/main.tf`

```hcl
resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, 2)

  tags = {
    Name      = "subnet-private-lab10"
    ManagedBy = "terraform"
    Layer     = "network"
  }
}
```

### Paso 2 — Exportar el nuevo ID en `network/outputs.tf`

```hcl
output "private_subnet_id" {
  description = "ID de la subred privada."
  value       = aws_subnet.private.id
}
```

### Paso 3 — Aplicar la capa de red

```bash
# Desde network/
terraform apply
```

El plan muestra `1 to add` (la nueva subred). Los recursos existentes no cambian.

### Paso 4 — Añadir el segundo security group en `compute/main.tf`

```hcl
resource "aws_security_group" "internal" {
  name        = "internal-lab10"
  description = "Security group interno de la capa de computo (Lab10)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "internal-lab10"
    ManagedBy = "terraform"
    Layer     = "compute"
  }
}
```

En `compute/outputs.tf`, añade:

```hcl
output "internal_security_group_id" {
  description = "ID del Security Group interno."
  value       = aws_security_group.internal.id
}
```

### Paso 5 — Aplicar la capa de cómputo

```bash
# Desde compute/
# AWS real:
terraform apply -var="network_state_bucket=$STATE_BUCKET"
```

El plan muestra `1 to add` (el nuevo security group). El security group existente no cambia y la capa de red no es tocada.

### Verificación Final

```bash
terraform output
# internal_security_group_id = "sg-xxxxxxxx"
# security_group_id          = "sg-yyyyyyyy"
# subnet_id                  = "subnet-xxxxxxxx"
# vpc_id                     = "vpc-xxxxxxxx"
```

Ambos security groups están en la misma VPC. La separación de capas permitió añadir la nueva subred y el nuevo security group sin ningún riesgo de afectar los recursos existentes de la capa de red.

---

## 4. Reto Adicional: Regla de Ingreso Basada en el CIDR de la VPC

La capa de red ya exporta `vpc_cidr` como output, pero la capa de cómputo no lo consume: solo usa `vpc_id` y `subnet_id`. El security group actual solo tiene una regla de salida (`egress`), lo que significa que no admite tráfico entrante de ningún origen.

Tu tarea es leer el CIDR de la VPC desde el estado de la capa de red y usarlo para añadir una regla de ingreso al security group que permita todo el tráfico interno de la VPC — **sin modificar ningún archivo de la capa de red**.

### Requisitos

1. En `compute/main.tf`, añade `vpc_cidr` al bloque `locals` leyéndolo desde `data.terraform_remote_state.network.outputs.vpc_cidr`.

2. Añade un bloque `ingress` al recurso `aws_security_group.app` que use `local.vpc_cidr` como fuente de tráfico permitido (todos los puertos y protocolos dentro de la VPC).

3. En `compute/outputs.tf`, añade un output `vpc_cidr` que exponga el CIDR consumido desde la capa de red.

4. Aplica el cambio **únicamente en la capa de cómputo** y verifica que los outputs `vpc_cidr` de ambas capas muestran el mismo valor.

### Criterios de Éxito

- El plan de la capa de cómputo muestra `1 to change` (el security group actualizado con la regla de ingreso).
- El plan de la capa de red muestra `No changes` — no se ha tocado ningún archivo de red.
- El output `vpc_cidr` de la capa de cómputo coincide exactamente con el de la capa de red.
- Destruir y redesplegar la capa de cómputo no afecta al estado de la capa de red.

[Ver solución →](#5-solución-del-reto-adicional)

---

## 5. Solución del Reto Adicional

> Intenta resolver el reto antes de leer esta sección.

### Paso 1 — Añadir `vpc_cidr` al bloque `locals` en `compute/main.tf`

```hcl
locals {
  vpc_id    = data.terraform_remote_state.network.outputs.vpc_id
  subnet_id = data.terraform_remote_state.network.outputs.subnet_id
  vpc_cidr  = data.terraform_remote_state.network.outputs.vpc_cidr
}
```

El output `vpc_cidr` ya existe en la capa de red desde el inicio del laboratorio. Solo hay que referenciarlo.

### Paso 2 — Añadir el bloque `ingress` al security group en `compute/main.tf`

```hcl
resource "aws_security_group" "app" {
  name        = "app-lab10"
  description = "Security group de la capa de computo (Lab10)"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
    description = "Trafico interno de la VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "app-lab10"
    ManagedBy = "terraform"
    Layer     = "compute"
  }
}
```

### Paso 3 — Añadir el output `vpc_cidr` en `compute/outputs.tf`

```hcl
output "vpc_cidr" {
  description = "CIDR de la VPC consumido desde la capa de red."
  value       = local.vpc_cidr
}
```

### Paso 4 — Aplicar solo la capa de cómputo

```bash
# Desde compute/

terraform apply -var="network_state_bucket=$STATE_BUCKET"
```

El plan debe mostrar exactamente:

```
  # aws_security_group.app will be updated in-place
  ~ resource "aws_security_group" "app" {
      + ingress {
          + cidr_blocks = ["10.0.0.0/16"]
          + description = "Trafico interno de la VPC"
          + from_port   = 0
          + protocol    = "-1"
          + to_port     = 0
        }
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

### Paso 5 — Verificar que ambas capas muestran el mismo CIDR

```bash
# Desde compute/
terraform output vpc_cidr
# "10.0.0.0/16"

# Desde network/
terraform output vpc_cidr
# "10.0.0.0/16"
```

Los valores coinciden. La capa de cómputo leyó el CIDR directamente del estado de la capa de red mediante `terraform_remote_state`, sin duplicar ningún valor en el código. Si la capa de red cambiara el CIDR de la VPC en el futuro, la capa de cómputo lo recogería automáticamente en el siguiente `apply`, sin necesidad de modificar ningún archivo de cómputo.

### Verificación del Aislamiento

Confirma que la capa de red no fue modificada:

```bash
# Desde network/
terraform plan
# No changes. Your infrastructure matches the configuration.
```

---

## 6. Verificación del despliegue

```bash
# Verificar que la capa de red esta desplegada
cd labs/lab-10/aws/network
terraform output vpc_id
terraform output subnet_id

# Verificar que la capa de computo consume el estado de red
cd ../compute
terraform output security_group_id

# Confirmar que terraform_remote_state lee correctamente los outputs de red
terraform console <<'EOF'
data.terraform_remote_state.network.outputs.vpc_id
EOF

# Verificar que no hay cambios pendientes en ninguna capa
cd ../network && terraform plan -detailed-exitcode
cd ../compute && terraform plan -detailed-exitcode -var="network_state_bucket=$STATE_BUCKET"
```

---

## 7. Limpieza

Destruye en orden inverso: primero cómputo (que depende de red), luego red.

> Si intentas destruir la capa de red antes que la de cómputo, el security group huérfano seguirá asociado a la VPC e impedirá su eliminación. Destruye siempre de hoja a raíz.

```bash
# Primero la capa de computo
cd lab-10/aws/compute/
terraform destroy -var="network_state_bucket=$STATE_BUCKET"

# Luego la capa de red
cd ../network/
terraform destroy
```

---

## 8. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

En LocalStack se usa backend local en lugar de S3 para la capa de remote state. El concepto de aislamiento por capas (red y cómputo independientes) es idéntico.

---

## 9. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Backend de la capa de red | S3 (`lab10/network/terraform.tfstate`) | Local (`network/terraform.tfstate`) |
| Backend de la capa de cómputo | S3 (`lab10/compute/terraform.tfstate`) | Local (`compute/terraform.tfstate`) |
| `terraform_remote_state` (cómputo) | `backend = "s3"` + variables de bucket | `backend = "local"` + ruta relativa |
| Bucket S3 previo necesario | Sí | No |
| Verificar VPCs | `aws ec2 describe-vpcs` | `aws --endpoint-url=... ec2 describe-vpcs` |
| Aislamiento de estados | Archivos separados en S3 | Archivos separados en disco |
| Comportamiento del blast radius | Idéntico | Idéntico |

---

## Buenas prácticas aplicadas

- **Define la granularidad de las capas según la frecuencia de cambio y el equipo responsable.** La capa de red cambia poco y la gestiona el equipo de plataforma; la capa de cómputo cambia frecuentemente y la gestiona el equipo de aplicaciones. Esta división es natural y reduce la fricción.
- **Usa outputs con `description` detallada.** Los outputs son la API pública de tu capa; documéntalos como si fueran un contrato de interfaz. Otras capas dependen de ellos y no deben necesitar leer tu código para entenderlos.
- **No uses `terraform_remote_state` para pasar secretos.** Los valores leídos aparecen en el plan en texto plano. Para secretos, usa AWS Secrets Manager o Parameter Store y léelos con el data source correspondiente.
- **Destruye siempre de hoja a raíz.** Las capas superiores (cómputo) referencian recursos de las capas inferiores (red). Si destruyes la red primero, dejarás recursos huérfanos que impedirán la eliminación de la VPC.
- **Un único bucket S3 puede alojar los estados de varias capas usando claves distintas.** La convención `<proyecto>/<capa>/terraform.tfstate` mantiene el orden sin multiplicar los buckets.
- **El data source `terraform_remote_state` es solo lectura.** Nunca puede modificar el estado que lee. Es seguro usarlo en pipelines de solo lectura (auditorías, dashboards) sin riesgo de alterar la infraestructura.
- **Considera SSM Parameter Store o HCP Terraform como alternativas.** Para equipos grandes, pasar valores entre capas a través del estado S3 puede ser sustituido por almacenar los outputs clave en SSM Parameter Store, lo que desacopla aún más los proyectos y simplifica los permisos IAM.

---

## Recursos

- [Data source `terraform_remote_state`](https://developer.hashicorp.com/terraform/language/state/remote-state-data)
- [Backend S3 - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Backend local - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/backend/local)
- [Outputs - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/values/outputs)
- [Recurso aws_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc)
- [Recurso aws_subnet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet)
- [Recurso aws_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group)
- [Función `cidrsubnet()`](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
