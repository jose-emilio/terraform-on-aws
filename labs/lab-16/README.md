# Laboratorio 16 — Construcción de una Red Multi-AZ Robusta y Dinámica

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Implementar el plano maestro de una VPC profesional utilizando **funciones de cálculo dinámico** e **iteración**, creando una red lista para cargas de trabajo como EKS.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **`for_each`** | Meta-argumento que crea múltiples instancias de un recurso a partir de un mapa o conjunto, permitiendo referenciar cada instancia por su clave |
| **`cidrsubnet()`** | Función que calcula rangos de subred a partir de un CIDR base, eliminando errores de cálculo manual |
| **`merge()`** | Función que combina múltiples mapas en uno solo; las claves del último mapa prevalecen sobre las anteriores |
| **`lifecycle` / `postcondition`** | Bloque que valida propiedades del recurso **después** de crearlo o actualizarlo; falla el apply si la condición no se cumple |
| **Tags EKS** | Etiquetas `kubernetes.io/role/elb` y `kubernetes.io/role/internal-elb` que permiten a EKS descubrir automáticamente qué subredes usar para balanceadores públicos e internos |
| **Multi-AZ** | Distribución de recursos en múltiples zonas de disponibilidad para alta disponibilidad |
| **RFC 1918** | Rangos de IP privados: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- lab07/aws desplegado (bucket S3 con versionado habilitado)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
# Exportar el Account ID y nombre del bucket para usar en los comandos
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab16/
├── README.md                    ← Esta guía
├── aws/
│   ├── providers.tf             ← Backend S3 parcial
│   ├── variables.tf             ← Variables: región, CIDR, proyecto, entorno
│   ├── main.tf                  ← VPC + 6 subredes con for_each y cidrsubnet()
│   ├── outputs.tf               ← IDs, CIDRs y AZs
│   └── aws.s3.tfbackend         ← Parámetros del backend (sin bucket)
└── localstack/
    ├── README.md                ← Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    └── localstack.s3.tfbackend  ← Backend completo para LocalStack
```

## 1. Análisis del código antes de desplegar

Antes de ejecutar nada, revisemos las técnicas clave del código en `main.tf`.

### 1.1 Cálculo dinámico de CIDRs con `cidrsubnet()`

```hcl
cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.subnet_index)
```

La función `cidrsubnet(prefix, newbits, netnum)` calcula subredes automáticamente:

- **`prefix`**: el CIDR base de la VPC (`10.12.0.0/16`)
- **`newbits`**: bits adicionales para la subred (`8` → de `/16` a `/24` = 256 IPs por subred)
- **`netnum`**: número de la subred dentro del espacio disponible

Con el CIDR `10.12.0.0/16` y `newbits = 8`, el cálculo produce:

| Subred | `netnum` | CIDR resultante | IPs disponibles |
|---|---|---|---|
| public-1 | 0 | `10.12.0.0/24` | 251 |
| public-2 | 1 | `10.12.1.0/24` | 251 |
| public-3 | 2 | `10.12.2.0/24` | 251 |
| private-1 | 10 | `10.12.10.0/24` | 251 |
| private-2 | 11 | `10.12.11.0/24` | 251 |
| private-3 | 12 | `10.12.12.0/24` | 251 |

> **Nota:** AWS reserva 5 IPs por subred (red, router, DNS, reservada, broadcast), por eso 256 - 5 = 251 disponibles.

Los `netnum` de las subredes privadas (10, 11, 12) están separados intencionalmente de las públicas (0, 1, 2), dejando espacio para futuras subredes intermedias.

### 1.2 Iteración con `for_each`

```hcl
resource "aws_subnet" "this" {
  for_each = local.subnets
  # ...
}
```

En lugar de repetir 6 bloques `resource`, definimos un único recurso con `for_each` que itera sobre un mapa. Cada entrada del mapa tiene:

- **`az_index`**: índice de la AZ en la lista `local.azs`
- **`subnet_index`**: número para `cidrsubnet()`
- **`public`**: booleano que determina si la subred es pública

Terraform crea instancias identificadas por clave: `aws_subnet.this["public-1"]`, `aws_subnet.this["private-2"]`, etc. Esto es más robusto que `count` porque renombrar o reordenar subredes no fuerza la destrucción y recreación.

### 1.3 Tags dinámicos con `merge()`

```hcl
tags = merge(
  local.common_tags,                    # Tags base (Environment, ManagedBy, Project)
  { Name = "...", Tier = "..." },       # Tags específicos de la subred
  each.value.public ? {                 # Tags condicionales para EKS
    "kubernetes.io/role/elb" = "1"
  } : {
    "kubernetes.io/role/internal-elb" = "1"
  }
)
```

`merge()` combina tres mapas en uno:
1. **Tags comunes** definidos en `local.common_tags` — se aplican a todos los recursos
2. **Tags específicos** de cada subred (nombre y tier)
3. **Tags EKS** condicionales — las subredes públicas reciben `kubernetes.io/role/elb` y las privadas `kubernetes.io/role/internal-elb`

### 1.4 Postcondición para validar RFC 1918

```hcl
lifecycle {
  postcondition {
    condition = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", self.cidr_block))
    error_message = "El CIDR de la VPC debe pertenecer a un rango privado RFC 1918."
  }
}
```

La `postcondition` se evalúa **después** de que el recurso se crea o actualiza. Usa `self` para referenciar los atributos del propio recurso. Si alguien intenta desplegar con un CIDR público (por ejemplo `203.0.113.0/24`), Terraform abortará el apply con un mensaje descriptivo.

---

## 2. Despliegue

```bash
cd labs/lab16/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Revisa el plan antes de confirmar. Terraform creará **7 recursos**: 1 VPC + 6 subredes.

Verifica los outputs:

```bash
terraform output
# vpc_id             = "vpc-0abc123..."
# vpc_cidr           = "10.12.0.0/16"
# availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
# subnet_cidrs       = {
#   "private-1" = "10.12.10.0/24"
#   "private-2" = "10.12.11.0/24"
#   "private-3" = "10.12.12.0/24"
#   "public-1"  = "10.12.0.0/24"
#   "public-2"  = "10.12.1.0/24"
#   "public-3"  = "10.12.2.0/24"
# }
```

---

## Verificación final

### 3.1 Verificar la VPC

```bash
aws ec2 describe-vpcs \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

### 3.2 Verificar las subredes y su distribución por AZ

```bash
aws ec2 describe-subnets \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Subnets[*].[Tags[?Key==`Name`].Value|[0],AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Deberías ver 6 subredes distribuidas en 3 AZs, con las públicas marcadas con `MapPublicIpOnLaunch = True`.

### 3.3 Verificar tags EKS

```bash
aws ec2 describe-subnets \
  --filters Name=tag:Project,Values=lab16 \
  --query 'Subnets[].{Name: Tags[?Key==`Name`].Value|[0], ELB: Tags[?Key==`kubernetes.io/role/elb`].Value|[0], InternalELB: Tags[?Key==`kubernetes.io/role/internal-elb`].Value|[0], Cluster: Tags[?Key==`kubernetes.io/cluster/lab16`].Value|[0]}' \
  --output table
```

Las subredes públicas deben tener `ELB = 1` y las privadas `InternalELB = 1`. Todas deben tener `Cluster = shared`.

---

## 4. Probar la postcondición RFC 1918

Intenta desplegar con un CIDR público para verificar que la postcondición funciona:

```bash
terraform apply -var="vpc_cidr=203.0.113.0/24"
```

Terraform rechazará el apply con este error:

```
│ Error: Resource postcondition failed
│
│   on main.tf line XX, in resource "aws_vpc" "main":
│
│ El CIDR de la VPC debe pertenecer a un rango privado RFC 1918 (10.0.0.0/8, 172.16.0.0/12 o 192.168.0.0/16).
```

> **Nota:** La postcondición se evalúa *después* de crear el recurso. En este caso AWS creará la VPC (cualquier CIDR RFC 1918 o no es válido en AWS), pero Terraform marcará el apply como fallido y en el siguiente `apply` con un CIDR correcto, la VPC se actualizará o recreará.

---

## 5. Reto: Ampliar la red con subredes de base de datos

**Situación**: El equipo de base de datos necesita 3 subredes privadas adicionales dedicadas exclusivamente a RDS, aisladas de las subredes de aplicación existentes.

**Tu objetivo**:

1. Añadir 3 subredes `database-1`, `database-2` y `database-3` al mapa `local.subnets`
2. Usar `subnet_index` 20, 21 y 22 para separarlas de las subredes de aplicación
3. Asignar el tag `Tier = "database"` (en vez de `"private"`)
4. **No** incluir tags de EKS en estas subredes (las bases de datos no necesitan descubrimiento de Kubernetes)
5. Añadir un nuevo output `database_subnet_ids` con los IDs de las subredes de base de datos
6. Al finalizar, `terraform apply` debe crear las 3 subredes adicionales sin modificar las 6 existentes

**Pistas**:
- Solo necesitas modificar `local.subnets` y la lógica condicional de tags en `main.tf`
- Puedes añadir una tercera condición al operador ternario usando otra expresión condicional anidada, o cambiar la lógica para usar un `lookup` en un mapa de tags por tier
- ¿Cómo verificas que las nuevas subredes no afectaron a las existentes?

La solución está en la [sección 6](#6-solución-del-reto).

---

## 6. Solución del Reto

### Paso 1: Ampliar el mapa de subredes

Añade las 3 subredes de base de datos a `local.subnets` en `main.tf`:

```hcl
locals {
  subnets = {
    "public-1"    = { az_index = 0, subnet_index = 0,  public = true,  tier = "public" }
    "public-2"    = { az_index = 1, subnet_index = 1,  public = true,  tier = "public" }
    "public-3"    = { az_index = 2, subnet_index = 2,  public = true,  tier = "public" }
    "private-1"   = { az_index = 0, subnet_index = 10, public = false, tier = "private" }
    "private-2"   = { az_index = 1, subnet_index = 11, public = false, tier = "private" }
    "private-3"   = { az_index = 2, subnet_index = 12, public = false, tier = "private" }
    "database-1"  = { az_index = 0, subnet_index = 20, public = false, tier = "database" }
    "database-2"  = { az_index = 1, subnet_index = 21, public = false, tier = "database" }
    "database-3"  = { az_index = 2, subnet_index = 22, public = false, tier = "database" }
  }

  # Mapa de tags EKS por tier
  eks_tags = {
    "public" = {
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${var.project_name}"  = "shared"
    }
    "private" = {
      "kubernetes.io/role/internal-elb"           = "1"
      "kubernetes.io/cluster/${var.project_name}"  = "shared"
    }
    "database" = {} # Sin tags EKS
  }
}
```

### Paso 2: Actualizar los tags de las subredes

Reemplaza la lógica condicional de tags por un `lookup` en el mapa:

```hcl
resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[each.value.az_index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value.subnet_index)

  map_public_ip_on_launch = each.value.public

  tags = merge(
    local.common_tags,
    {
      Name = "${var.project_name}-${each.key}"
      Tier = each.value.tier
    },
    lookup(local.eks_tags, each.value.tier, {})
  )
}
```

### Paso 3: Añadir el output

Añade en `outputs.tf`:

```hcl
output "database_subnet_ids" {
  description = "IDs de las subredes de base de datos"
  value = {
    for key, subnet in aws_subnet.this :
    key => subnet.id if local.subnets[key].tier == "database"
  }
}
```

### Paso 4: Aplicar y verificar

```bash
terraform plan
# Plan: 3 to add, 0 to change, 0 to destroy.

terraform apply
```

Verifica que las 6 subredes originales no fueron modificadas (0 to change) y las 3 nuevas se crearon correctamente:

```bash
aws ec2 describe-subnets \
  --filters Name=tag:Project,Values=lab16 Name=tag:Tier,Values=database \
  --query 'Subnets[*].[Tags[?Key==`Name`].Value|[0],AvailabilityZone,CidrBlock]' \
  --output table
```

---

## 7. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** No destruyas el bucket S3, ya que es un recurso compartido entre laboratorios (lab02).

---

## 8. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

---

## Buenas prácticas aplicadas

- **`cidrsubnet()` para calcular subredes dinámicamente**: calcular los bloques CIDR de las subredes a partir del CIDR de la VPC usando `cidrsubnet()` garantiza que no hay solapamientos y que el código escala sin modificación cuando cambia el número de AZs.
- **`for_each` sobre AZs disponibles**: iterar sobre `data.aws_availability_zones.available.names` en lugar de hardcodear `["us-east-1a", "us-east-1b"]` hace el código portable entre regiones sin modificación.
- **Tags de discovery para EKS**: los tags `kubernetes.io/role/elb` y `kubernetes.io/role/internal-elb` son requeridos por EKS para descubrir automáticamente las subnets donde crear los Load Balancers.
- **Postcondición para validar RFC 1918**: una postcondición que verifica que el CIDR de la VPC pertenece al espacio privado (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) detecta errores de configuración antes de que lleguen a producción.
- **Subredes públicas y privadas separadas**: la separación en subredes públicas (con `map_public_ip_on_launch = true`) y privadas (sin IP pública) permite aplicar diferentes políticas de seguridad en cada capa.
- **Internet Gateway separado del NAT Gateway**: el IGW da acceso a Internet a las subredes públicas; el NAT Gateway da salida a Internet a las subredes privadas sin exponer una IP pública a los recursos.

---

## Recursos

- [Terraform: `cidrsubnet()` Function](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
- [Terraform: `for_each` Meta-Argument](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
- [Terraform: `merge()` Function](https://developer.hashicorp.com/terraform/language/functions/merge)
- [Terraform: Custom Conditions (Preconditions & Postconditions)](https://developer.hashicorp.com/terraform/language/validate)
- [AWS: VPC Subnet Basics](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html)
- [EKS: Subnet Discovery Tags](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html)
