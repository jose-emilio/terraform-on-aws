# Laboratorio 6: Auditoría Dinámica y Conectividad Externa

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 2 — Lenguaje HCL y Configuración Avanzada](../../modulos/modulo-02/README.md)


## Visión general

En este laboratorio usarás Terraform exclusivamente como herramienta de consulta: sin crear infraestructura AWS, extraerás información de una cuenta activa usando data sources y generarás un reporte de auditoría en disco mediante una plantilla. El objetivo es dominar el uso de data sources para el descubrimiento dinámico de recursos existentes.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Obtener la identidad del caller y la región activa con `aws_caller_identity` y `aws_region`
- Localizar recursos existentes por tag con `aws_vpc` y `aws_subnets`
- Consultar instancias EC2 en ejecución con `aws_instances`
- Referenciar políticas IAM por nombre con `aws_iam_policy`
- Listar zonas de disponibilidad con `aws_availability_zones`
- Filtrar colecciones con la cláusula `if` dentro de expresiones `for`
- Generar un reporte de auditoría exportable con `templatefile()` y `local_file` (provider `hashicorp/local`)
- Proteger información sensible en outputs con `sensitive = true`

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
---

## Conceptos Clave

### Data Sources de solo lectura

A diferencia de los laboratorios anteriores donde los data sources complementaban recursos, en este laboratorio son el elemento central: no se crea ningún recurso AWS. Terraform ejecuta `plan` y `apply` consultando la API de AWS en modo lectura y expone los resultados como outputs.

Este patrón es útil para:
- Auditar el estado de una cuenta sin riesgo de modificarla
- Generar inventarios de infraestructura existente
- Obtener IDs dinámicamente para pasarlos a otros módulos

### `aws_region`

Devuelve información sobre la región activa del provider sin necesidad de argumentos:

```hcl
data "aws_region" "current" {}
```

Expone `name` (p. ej. `"us-east-1"`) y `description` (p. ej. `"US East (N. Virginia)"`). Permite construir ARNs dinámicamente con `data.aws_region.current.name` en lugar de hardcodear la región.

### `aws_vpc` con filtros por tag

Localiza una VPC existente aplicando filtros sobre sus atributos o tags:

```hcl
data "aws_vpc" "production" {
  filter {
    name   = "tag:Env"
    values = ["production"]
  }
}
```

El prefijo `tag:` en el nombre del filtro indica que se filtra por el valor de un tag. Si el filtro devuelve más de una VPC, Terraform lanza un error; si no devuelve ninguna, también. Esto garantiza que el resultado es siempre exactamente uno.

### `aws_subnets`

Devuelve la lista de IDs de todas las subredes que cumplen los filtros indicados:

```hcl
data "aws_subnets" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }
}
```

El atributo resultante `ids` es una lista de strings con los IDs de las subredes encontradas.

### `aws_instances`

Consulta instancias EC2 existentes aplicando filtros. Devuelve listas paralelas de `ids` e `private_ips` que pueden combinarse con una expresión `for`:

```hcl
data "aws_instances" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}
```

Para construir un map `id → ip` a partir de las listas paralelas:

```hcl
instance_private_ips = {
  for i, id in data.aws_instances.production.ids :
  id => data.aws_instances.production.private_ips[i]
}
```

### `aws_iam_policy`

Localiza una política IAM por nombre sin hardcodear su ARN, que varía entre particiones de AWS (`aws`, `aws-cn`, `aws-us-gov`):

```hcl
data "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"
}
```

El atributo `arn` devuelve el ARN completo, listo para usarse en `aws_iam_role_policy_attachment` u otros recursos.

### `aws_availability_zones`

Lista las zonas de disponibilidad de la región configurada en el provider:

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}
```

El filtro `state = "available"` excluye zonas en mantenimiento o con incidencias activas.

### Expresión `for` con cláusula `if`

La cláusula `if` dentro de una expresión `for` actúa como un filtro, equivalente a un `WHERE` en SQL:

```hcl
primary_az_names = [
  for az in data.aws_availability_zones.available.names : az
  if contains(var.primary_az_suffixes, substr(az, -1, 1))
]
```

- `substr(az, -1, 1)` extrae el último carácter del nombre de la AZ (el sufijo: `"a"`, `"b"`, etc.)
- `contains(lista, valor)` devuelve `true` si el valor está en la lista
- Solo se incluyen en el resultado las AZs cuyo sufijo está en `var.primary_az_suffixes`

### `sensitive = true` en outputs

Marca un output como sensible para que Terraform oculte su valor en los logs:

```hcl
output "caller_arn" {
  value     = data.aws_caller_identity.current.arn
  sensitive = true
}
```

En la salida de `terraform apply` aparecerá como `<sensitive>`. Para consultarlo:

```bash
terraform output caller_arn
```

> `sensitive = true` protege el valor en logs y en la salida estándar, pero `terraform.tfstate` sigue almacenándolo en texto plano. Para proteger el estado usa un backend remoto con cifrado (S3 + KMS).

### `local_file` — escritura de archivos en disco

`local_file` pertenece al provider `hashicorp/local`, que viene incluido en Terraform sin necesidad de declararlo explícitamente. A diferencia de los recursos del provider AWS, **no crea nada en la nube**: escribe un archivo en el sistema de archivos local donde se ejecuta Terraform.

```hcl
resource "local_file" "audit_report" {
  filename = "${path.module}/audit_report.txt"
  content  = templatefile("${path.module}/../audit_report.tftpl", { ... })
}
```

- `filename` — ruta absoluta o relativa (usando `path.module`) del archivo a generar
- `content` — contenido del archivo como string; aquí se combina con `templatefile()` para renderizar la plantilla

Cuando se ejecuta `terraform destroy`, Terraform elimina el archivo. Es el único recurso que aparece en el `plan` de este laboratorio (`Plan: 1 to add`), ya que los data sources de AWS no se contabilizan como recursos.

> `local_file` es útil para generar reportes, ficheros de configuración o inventarios como artefacto del propio `apply`. En pipelines CI/CD, el archivo generado puede archivarse como artefacto del job.

---

## Estructura del proyecto

```
lab06/
├── audit_report.tftpl   # Plantilla del reporte de auditoría compartida
├── aws/
│   ├── providers.tf     # Bloque terraform{} y provider{}
│   ├── variables.tf     # target_env y primary_az_suffixes
│   ├── main.tf          # Data sources, locals y local_file del reporte
│   └── outputs.tf       # Reporte de auditoría completo con sensitive = true
└── localstack/
    ├── providers.tf     # Endpoints sts, ec2 e iam apuntando a LocalStack
    ├── variables.tf     # Idéntico al de aws/
    ├── main.tf          # Recursos de prueba + mismos data sources
    └── outputs.tf       # Idéntico al de aws/
```

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`audit_report.tftpl`**

```
================================================================================
  REPORTE DE AUDITORÍA DE INFRAESTRUCTURA
  Generado por Terraform
================================================================================

IDENTIDAD
  Account ID : ${account_id}
  User ID    : ${caller_user_id}

REGIÓN
  Nombre     : ${region_name}
  Descripción: ${region_desc}

RED DE PRODUCCIÓN
  VPC ID     : ${vpc_id}
  CIDR       : ${vpc_cidr}

  Subredes (${length(subnet_ids)}):
%{ for id in subnet_ids ~}
    - ${id}
%{ endfor ~}

INSTANCIAS EN EJECUCIÓN (${length(instance_ips)}):
%{ if length(instance_ips) == 0 ~}
    (ninguna instancia en ejecución)
%{ else ~}
%{ for id, ip in instance_ips ~}
    - ${id}  →  ${ip}
%{ endfor ~}
%{ endif ~}

ZONAS DE DISPONIBILIDAD
  Todas     (${length(az_names)}): ${join(", ", az_names)}
  Principales (${length(primary_az_names)}): ${join(", ", primary_az_names)}

POLÍTICAS IAM DE REFERENCIA
  ReadOnlyAccess : ${policy_arn}

================================================================================
```

**`aws/variables.tf`**

```hcl
variable "target_env" {
  type    = string
  default = "production"
}

variable "primary_az_suffixes" {
  type    = list(string)
  default = ["a", "b"]
}
```

**`aws/main.tf`**

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_vpc" "production" {
  filter {
    name   = "tag:Env"
    values = [var.target_env]
  }
}

data "aws_subnets" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }
}

data "aws_instances" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_names = [for az in data.aws_availability_zones.available.names : az]

  primary_az_names = [
    for az in data.aws_availability_zones.available.names : az
    if contains(var.primary_az_suffixes, substr(az, -1, 1))
  ]

  instance_private_ips = {
    for i, id in data.aws_instances.production.ids :
    id => data.aws_instances.production.private_ips[i]
  }
}

resource "local_file" "audit_report" {
  filename = "${path.module}/audit_report.txt"
  content = templatefile("${path.module}/../audit_report.tftpl", {
    account_id       = data.aws_caller_identity.current.account_id
    caller_user_id   = data.aws_caller_identity.current.user_id
    region_name      = data.aws_region.current.name
    region_desc      = data.aws_region.current.description
    vpc_id           = data.aws_vpc.production.id
    vpc_cidr         = data.aws_vpc.production.cidr_block
    subnet_ids       = data.aws_subnets.production.ids
    instance_ips     = local.instance_private_ips
    az_names         = local.az_names
    primary_az_names = local.primary_az_names
    policy_arn       = data.aws_iam_policy.read_only.arn
  })
}
```

**`aws/outputs.tf`**

```hcl
output "account_id" {
  description = "ID de la cuenta AWS donde se ejecuta Terraform"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "ARN de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.arn
  sensitive   = true
}

output "caller_user_id" {
  description = "User ID de la identidad que ejecuta Terraform"
  value       = data.aws_caller_identity.current.user_id
}

output "region" {
  description = "Región activa del provider"
  value       = "${data.aws_region.current.name} (${data.aws_region.current.description})"
}

output "production_vpc_id" {
  description = "ID de la VPC de producción encontrada por tag"
  value       = data.aws_vpc.production.id
}

output "production_subnet_ids" {
  description = "IDs de las subredes de la VPC de producción"
  value       = data.aws_subnets.production.ids
}

output "production_instance_ips" {
  description = "IPs privadas de las instancias EC2 en ejecución"
  value       = local.instance_private_ips
}

output "read_only_policy_arn" {
  description = "ARN de la política IAM ReadOnlyAccess"
  value       = data.aws_iam_policy.read_only.arn
}

output "available_az_names" {
  description = "Nombres de todas las zonas de disponibilidad activas"
  value       = local.az_names
}

output "primary_az_names" {
  description = "AZs principales (sufijos configurados en var.primary_az_suffixes)"
  value       = local.primary_az_names
}

output "audit_report_path" {
  description = "Ruta del archivo de reporte de auditoría generado"
  value       = local_file.audit_report.filename
}
```

### 1.2 Preparar la VPC de Producción

Este laboratorio consulta infraestructura existente, por lo que necesitas una VPC con el tag `Env = "production"` en tu cuenta. Si no la tienes, créala desde AWS CLI:

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Env,Value=production
```

Verifica que el tag se aplicó correctamente:

```bash
aws ec2 describe-vpcs --filters "Name=tag:Env,Values=production"
```

### 1.3 Despliegue

Desde el directorio `lab05/aws/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

El `plan` mostrará `Plan: 1 to add` por el `local_file` del reporte. Los data sources de AWS no cuentan como recursos a crear.

### 1.4 Verificación de Outputs

Al finalizar `terraform apply`:

```
Outputs:

account_id              = "123456789012"
audit_report_path       = "./audit_report.txt"
available_az_names      = ["us-east-1a", "us-east-1b", "us-east-1c", ...]
caller_arn              = <sensitive>
caller_user_id          = "AIDAEXAMPLEUSERID"
primary_az_names        = ["us-east-1a", "us-east-1b"]
production_instance_ips = {}
production_subnet_ids   = ["subnet-0abc...", "subnet-0def..."]
production_vpc_id       = "vpc-0abc123..."
read_only_policy_arn    = "arn:aws:iam::aws:policy/ReadOnlyAccess"
region                  = "us-east-1 (US East (N. Virginia))"
```

Consulta el reporte generado en disco:

```bash
cat aws/audit_report.txt
```

Consulta el output sensible:

```bash
terraform output caller_arn
```

Prueba a cambiar los sufijos de AZ para ver el filtro en acción:

```bash
terraform apply -var='primary_az_suffixes=["a"]'
terraform output primary_az_names
```

---

## Verificación final

```bash
# Verificar que el reporte de auditoria fue generado
ls -la aws/audit_report.txt
cat aws/audit_report.txt

# Verificar la identidad de la cuenta activa
terraform output caller_account_id
terraform output caller_arn

# Verificar los datos de VPCs descubiertas
terraform output vpc_ids

# Confirmar que terraform apply no crea recursos en AWS
terraform plan | grep "No changes\|0 to add"
```

---

## 2. Limpieza

El único recurso creado es el `local_file`. Para eliminarlo:

```bash
terraform destroy
```

Si creaste la VPC de prueba en el paso 1.2, elimínala manualmente:

```bash
aws ec2 delete-vpc --vpc-id <VPC_ID>
```

---

## 3. LocalStack

Este laboratorio puede ejecutarse en LocalStack con adaptaciones (VPC y política IAM de prueba). Consulta [localstack/README.md](localstack/README.md) para las instrucciones de despliegue local.

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| VPC de producción | Debe existir previamente | Se crea en `main.tf` |
| `aws_instances` | Devuelve instancias reales | Devuelve lista vacía |
| `aws_iam_policy` | Resuelve políticas gestionadas de AWS | Requiere crear la política previamente |
| `aws_caller_identity` | Devuelve identidad IAM real | Devuelve cuenta `000000000000` |
| `aws_availability_zones` | AZs reales de la región | AZs simuladas por LocalStack |
| `depends_on` en data sources | No necesario | Necesario para VPC y política IAM |
| Recursos AWS creados | Ninguno | 1 VPC + 1 política IAM |

---

## Buenas prácticas aplicadas

- **Usa data sources en lugar de hardcodear IDs.** Un ID de VPC, de cuenta o un ARN de política hardcodeado rompe la portabilidad entre cuentas, regiones y particiones. Los data sources con filtros por nombre o tag son la alternativa correcta.
- **`sensitive = true` no cifra el estado.** Protege el valor en logs y en la salida estándar, pero `terraform.tfstate` sigue almacenándolo en texto plano. Para proteger el estado usa un backend remoto con cifrado (S3 + KMS).
- **Un data source que no encuentra resultados falla en el plan**, no en el apply. Esto es una ventaja: los errores de descubrimiento se detectan antes de que Terraform intente modificar nada.
- **Usa `depends_on` en data sources solo cuando sea necesario.** En condiciones normales Terraform infiere las dependencias automáticamente. Solo es necesario cuando el data source depende de un recurso que no referencia directamente.
- **Combina `templatefile()` con data sources** para generar reportes exportables. El resultado es un artefacto auditable que puede archivarse, enviarse por correo o adjuntarse a un ticket de cambio.
- **La cláusula `if` en expresiones `for` es más legible que `filter` anidados.** Úsala para transformar y filtrar colecciones en un solo paso dentro de un `local`.

---

## Recursos

- [Data source aws_caller_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity)
- [Data source aws_region](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region)
- [Data source aws_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc)
- [Data source aws_subnets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets)
- [Data source aws_instances](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/instances)
- [Data source aws_iam_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy)
- [Data source aws_availability_zones](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones)
- [Expresiones for con cláusula if](https://developer.hashicorp.com/terraform/language/expressions/for#filtering-elements)
- [Outputs sensitive](https://developer.hashicorp.com/terraform/language/values/outputs#sensitive-suppressing-values-in-cli-output)
- [Meta-argumento depends_on](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on)
