# Laboratorio 27: Cimientos de EC2: Despliegue Dinamico y Seguro

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio aprovisionaras un servidor web EC2 profesional utilizando busquedas dinamicas de AMI, un IAM Instance Profile para evitar credenciales estaticas, IMDSv2 obligatorio para prevenir ataques SSRF y un script de bootstrap dinamico generado con `templatefile()`. El resultado es una instancia que sigue las mejores practicas de seguridad de AWS desde su creacion.

## Objetivos de Aprendizaje

Al finalizar este laboratorio seras capaz de:

- Usar el data source `aws_ami` con filtros para obtener la AMI mas reciente de Amazon Linux 2023 de forma agnóstica a la región
- Crear un IAM Instance Profile con un rol que permita gestión via SSM Session Manager, eliminando la necesidad de Access Keys estáticas
- Forzar el uso de IMDSv2 (`http_tokens = "required"`) para blindar la instancia contra ataques SSRF
- Implementar un script de bootstrap dinámico usando `templatefile()` para inyectar variables de Terraform en el `user_data` de la instancia
- Crear Security Groups granulares usando los recursos individuales de reglas

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
---

## Conceptos Clave

### Data Source `aws_ami`

Un **data source** en Terraform permite consultar información de la infraestructura existente sin crear recursos nuevos. `aws_ami` busca AMIs en el registro de EC2 según los filtros proporcionados:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}
```

- `most_recent = true`: de todas las AMIs que coincidan con los filtros, selecciona la mas reciente.
- `owners = ["amazon"]`: restringe la busqueda a AMIs oficiales de Amazon, evitando imagenes de terceros potencialmente inseguras.
- `filter`: cada bloque `filter` aplica un criterio adicional. Los filtros son acumulativos (AND logico).

La referencia `data.aws_ami.al2023.id` devuelve el ID de la AMI seleccionada, que puede variar entre regiones y con el tiempo conforme Amazon publica nuevas versiones.

### IAM Instance Profile

Un **Instance Profile** es el contenedor que permite asociar un rol IAM a una instancia EC2. Sin el, la instancia no tiene identidad IAM y cualquier operacion con la API de AWS requeriria Access Keys estaticas (una mala practica de seguridad).

```hcl
resource "aws_iam_instance_profile" "ec2" {
  name = "mi-perfil"
  role = aws_iam_role.ec2.name
}
```

La instancia obtiene credenciales temporales automáticamente a través del Instance Metadata Service. Estas credenciales rotan de forma transparente sin intervención manual.

### IMDSv2 (Instance Metadata Service v2)

El **Instance Metadata Service** (IMDS) permite a la instancia consultar información sobre sí misma (ID, región, credenciales del rol IAM) mediante peticiones HTTP a `http://169.254.169.254`. La versión 1 (IMDSv1) acepta peticiones GET simples, lo que la hace vulnerable a ataques **SSRF** (Server-Side Request Forgery): si un atacante consigue que la aplicación haga una petición HTTP a esa IP, obtiene las credenciales del rol.

**IMDSv2** mitiga este riesgo exigiendo un flujo de dos pasos:

1. Una petición `PUT` para obtener un **token de sesión** (con TTL configurable)
2. Las peticiones subsiguientes deben incluir el token en el header `X-aws-ec2-metadata-token`

Al configurar `http_tokens = "required"`, se desactiva IMDSv1 y solo se acepta el flujo seguro con token:

```hcl
metadata_options {
  http_endpoint = "enabled"
  http_tokens   = "required"
}
```

### Función `templatefile()`

Lee un archivo externo `.tftpl` y sustituye las variables declaradas por los valores proporcionados en un map. Esto permite generar scripts de bootstrap dinámicos que incorporan datos de Terraform (endpoints de bases de datos, nombres de entorno, etc.) sin hardcodear valores:

```hcl
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    app_name    = var.app_name
    db_endpoint = var.db_endpoint
  })
}
```

Dentro del archivo `.tftpl`:
- `${variable}` para interpolacion simple
- `%{ if condicion }...%{ endif }` para condicionales
- `%{ for item in lista }...%{ endfor }` para iteraciones

### Data Source `aws_iam_policy_document`

Genera políticas IAM en formato JSON de forma programática. Es más seguro y legible que escribir el JSON manualmente:

```hcl
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
```

El resultado (`data.aws_iam_policy_document.ec2_assume_role.json`) se pasa directamente al argumento `assume_role_policy` del rol IAM.

---

## Estructura del proyecto

```
lab27/
├── user_data.tftpl      # Plantilla de bash compartida por ambos entornos
├── aws/
│   ├── aws.s3.tfbackend # Parametros del backend S3 (sin bucket)
│   ├── providers.tf     # Bloque terraform{} con backend S3 y provider{}
│   ├── variables.tf     # env, app_name, db_endpoint, instance_type
│   ├── main.tf          # data aws_ami, IAM role/profile, SG, instancia EC2
│   └── outputs.tf       # AMI, instancia, IAM, SG, user_data renderizado
└── localstack/
    ├── README.md        # Instrucciones de despliegue local
    ├── providers.tf     # Endpoints apuntando a LocalStack
    ├── variables.tf     # Identico al de aws/
    ├── main.tf          # Identico al de aws/
    └── outputs.tf       # Identico al de aws/
```

La plantilla `user_data.tftpl` vive en la raiz de `lab27/` y es compartida por ambos entornos mediante `path.module/../user_data.tftpl`.

---

## 1. Despliegue en AWS Real

### 1.1 Codigo Terraform

**`user_data.tftpl`**

```bash
#!/bin/bash
# Generado por Terraform — entorno: ${env}
set -euo pipefail

# Configuracion del entorno
echo "ENV=${env}" >> /etc/environment
echo "APP_NAME=${app_name}" >> /etc/environment
echo "DB_ENDPOINT=${db_endpoint}" >> /etc/environment

# Actualizacion del sistema
dnf update -y

# Instalacion de servidor web
dnf install -y httpd

# Pagina de verificacion con datos inyectados desde Terraform
cat <<'INNEREOF' > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head><title>${app_name}</title></head>
<body>
  <h1>${app_name} — ${env}</h1>
  <p>Instancia aprovisionada con Terraform</p>
  <p>Backend DB: ${db_endpoint}</p>
</body>
</html>
INNEREOF

# Arranque del servidor web
systemctl enable --now httpd

%{ if env == "prod" ~}
# Hardening adicional solo en produccion
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
%{ endif ~}

echo "Bootstrap completado para ${app_name} en ${env}"
```

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
variable "env" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "El entorno debe ser 'dev' o 'prod'."
  }
}

variable "app_name" {
  type    = string
  default = "corp-lab27"
}

variable "db_endpoint" {
  type    = string
  default = "db.corp-lab27.internal:5432"
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}
```

**`aws/main.tf`**

```hcl
# ─── Data Source: AMI dinamica ───────────────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── IAM Instance Profile ───────────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.app_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.app_name}-ec2-role"
    Env  = var.env
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${var.app_name}-ec2-profile"
    Env  = var.env
  }
}

# ─── Security Group ─────────────────────────────────────────────────────────
resource "aws_security_group" "web" {
  name        = "${var.app_name}-web-sg"
  description = "Permite HTTP entrante y todo el trafico saliente"

  tags = {
    Name = "${var.app_name}-web-sg"
    Env  = var.env
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP desde cualquier origen"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente"
}

# ─── User Data dinamico ─────────────────────────────────────────────────────
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    app_name    = var.app_name
    db_endpoint = var.db_endpoint
  })
}

# ─── Instancia EC2 ──────────────────────────────────────────────────────────
resource "aws_instance" "web" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data                   = local.user_data
  user_data_replace_on_change = true

  # IMDSv2 obligatorio: bloquea ataques SSRF al metadata service
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.app_name}-web"
    Env  = var.env
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

**`aws/outputs.tf`**

```hcl
output "ami_id" {
  description = "ID de la AMI de Amazon Linux 2023 seleccionada"
  value       = data.aws_ami.al2023.id
}

output "ami_name" {
  description = "Nombre de la AMI seleccionada"
  value       = data.aws_ami.al2023.name
}

output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.web.id
}

output "public_ip" {
  description = "IP pública de la instancia (si tiene)"
  value       = aws_instance.web.public_ip
}

output "instance_profile_arn" {
  description = "ARN del Instance Profile asociado a la instancia"
  value       = aws_iam_instance_profile.ec2.arn
}

output "iam_role_name" {
  description = "Nombre del rol IAM de la instancia"
  value       = aws_iam_role.ec2.name
}

output "user_data_rendered" {
  description = "Script de bootstrap generado por templatefile()"
  value       = local.user_data
}

output "security_group_id" {
  description = "ID del security group de la instancia"
  value       = aws_security_group.web.id
}
```

### 1.2 Despliegue

Desde el directorio `lab27/aws/`:

```bash
# Obtener el ID de tu cuenta AWS
BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
terraform plan
terraform apply
```

El estado se almacena en `s3://<BUCKET>/lab27/terraform.tfstate` usando el bucket creado en el lab02.

Durante el `plan`, presta atencion a:

- **`data.aws_ami.al2023`**: Terraform consulta la API de EC2 y muestra la AMI seleccionada. Esto ocurre en la fase de plan, no durante el apply.
- **`user_data_rendered`**: el output muestra el script ya renderizado con los valores reales, permitiendo verificar que `templatefile()` inyectó las variables correctamente.

### 1.3 Verificación

Al finalizar `terraform apply`:

```
Outputs:

ami_id               = "ami-0abcdef1234567890"
ami_name             = "al2023-ami-2023.6.20241212.0-kernel-6.1-arm64"
instance_id          = "i-0abc123def456..."
instance_profile_arn = "arn:aws:iam::123456789012:instance-profile/corp-lab27-ec2-profile"
public_ip            = "54.xx.xx.xx"
...
```

**Verificar la AMI seleccionada:**

```bash
terraform output ami_name
```

El nombre debe comenzar con `al2023-ami-2023` confirmando que el data source seleccionó Amazon Linux 2023.

**Verificar el Instance Profile:**

```bash
aws iam list-instance-profiles-for-role --role-name corp-lab27-ec2-role
```

**Verificar que IMDSv2 está activo:**

```bash
aws ec2 describe-instances \
  --instance-ids $(terraform output -raw instance_id) \
  --query 'Reservations[0].Instances[0].MetadataOptions'
```

Resultado esperado:

```json
{
    "State": "applied",
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 1,
    "HttpEndpoint": "enabled"
}
```

El campo `"HttpTokens": "required"` confirma que solo IMDSv2 está permitido.

**Verificar el servidor web (si la instancia tiene IP pública y el SG lo permite):**

```bash
curl http://$(terraform output -raw public_ip)
```

**Conectarse via SSM Session Manager (sin SSH):**

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
```

### 1.4 Verificar el User Data renderizado

El output `user_data_rendered` permite inspeccionar el script que recibió la instancia:

```bash
terraform output user_data_rendered
```

Confirma que las variables `${env}`, `${app_name}` y `${db_endpoint}` fueron sustituidas por los valores reales de Terraform.

---

## 2. Reto: Restricción de AMI por Entorno

El equipo de seguridad exige que en producción solo se usen AMIs con un nombre que contenga la palabra `minimal` (imágenes sin paquetes innecesarios), mientras que en desarrollo se permite cualquier AMI de Amazon Linux 2023.

**Tu objetivo:**

1. Añade una variable `ami_name_filter` de tipo `string` en `variables.tf` con valor por defecto `"al2023-ami-2023.*-arm64"`.

2. Añade un bloque `validation` a la variable `env` (o crea una lógica en `locals`) que fuerce que cuando `var.env == "prod"`, el filtro de AMI contenga la cadena `minimal`. Pista: puedes usar la función `strcontains()`.

3. Actualiza el `data "aws_ami"` para que use `var.ami_name_filter` en lugar del valor fijo.

4. Verifica que `terraform plan -var='env=prod'` falla si el filtro no contiene `minimal`, y que `terraform plan -var='env=prod' -var='ami_name_filter=al2023-ami-minimal-2023.*-arm64'` funciona correctamente.

### Criterios de Éxito

- En `dev`, el plan funciona con el filtro por defecto sin cambios.
- En `prod`, el plan falla con un mensaje de error claro si el filtro no contiene `minimal`.
- El data source `aws_ami` usa la variable en lugar de un valor fijo.

[Ver solución →](#6-solucion-del-reto-restriccion-de-ami)

---

## 3. Solución del Reto: Restricción de AMI

> Intenta resolver el reto antes de leer esta sección.

### Paso 1 — Añadir la variable `ami_name_filter` en `variables.tf`

```hcl
variable "ami_name_filter" {
  type        = string
  default     = "al2023-ami-2023.*-arm64"
  description = "Patron de nombre para filtrar la AMI. En prod debe contener 'minimal'."
}
```

### Paso 2 — Añadir la validación cruzada

Terraform no permite validaciones que referencien otras variables dentro de un bloque `variable`. La alternativa es usar un bloque `check` o una `locals` con `validation` mediante un recurso `null_resource` o un `precondition`. La forma más limpia en Terraform 1.5+ es un bloque `check`:

```hcl
check "ami_filter_prod" {
  assert {
    condition     = var.env != "prod" || strcontains(var.ami_name_filter, "minimal")
    error_message = "En produccion, ami_name_filter debe contener 'minimal' para cumplir con la politica de seguridad."
  }
}
```

Alternativamente, si usas una versión anterior a 1.5, puedes usar un `precondition` en el data source:

```hcl
data "aws_ami" "al2023" {
  # ...filtros...

  lifecycle {
    precondition {
      condition     = var.env != "prod" || strcontains(var.ami_name_filter, "minimal")
      error_message = "En produccion, ami_name_filter debe contener 'minimal'."
    }
  }
}
```

### Paso 3 — Actualizar el data source

Sustituye el valor fijo del filtro `name` por la variable:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

### Verificación

```bash
# Dev: funciona con el filtro por defecto
terraform plan

# Prod sin minimal: falla
terraform plan -var='env=prod'
# Error: En produccion, ami_name_filter debe contener 'minimal'...

# Prod con minimal: funciona
terraform plan -var='env=prod' -var='ami_name_filter=al2023-ami-minimal-2023.*-arm64'
```

---

## 4. Reto Adicional: Política IAM de Mínimo Privilegio para S3

El rol IAM actual solo tiene la política `AmazonSSMManagedInstanceCore`. El equipo necesita que la instancia pueda leer objetos de un bucket S3 específico (p. ej. para descargar configuraciones), pero **sin** otorgar acceso a todos los buckets de la cuenta.

**Tu objetivo:**

1. Añade una variable `config_bucket_name` de tipo `string` con valor por defecto `"corp-lab27-config"`.

2. Crea un `data "aws_iam_policy_document"` que otorgue permisos `s3:GetObject` y `s3:ListBucket` **únicamente** sobre el bucket `var.config_bucket_name` y sus objetos.

3. Crea un recurso `aws_iam_policy` con el documento generado y asócialo al rol existente con `aws_iam_role_policy_attachment`.

4. Añade un output `s3_policy_arn` que exponga el ARN de la política creada.

5. Verifica con `terraform plan` que se crean 2 recursos nuevos (la política y el attachment) sin modificar los existentes.

### Pistas

- El ARN de un bucket S3 es `arn:aws:s3:::nombre-del-bucket` y el de sus objetos `arn:aws:s3:::nombre-del-bucket/*`.
- `s3:ListBucket` se aplica al bucket; `s3:GetObject` se aplica a los objetos (`/*`).
- Usa dos bloques `statement` separados en el policy document, uno para cada nivel de recurso.

### Criterios de Éxito

- El plan muestra exactamente `2 to add` (la policy y el attachment).
- Los recursos existentes (rol, instance profile, instancia) no se modifican.
- La política solo permite `s3:GetObject` y `s3:ListBucket` sobre el bucket especificado, no sobre `*`.

[Ver solución →](#8-solucion-del-reto-adicional-politica-s3)

---

## 5. Solución del Reto Adicional: Política S3

> Intenta resolver el reto antes de leer esta sección.

### Paso 1 — Variable en `variables.tf`

```hcl
variable "config_bucket_name" {
  type        = string
  default     = "corp-lab27-config"
  description = "Nombre del bucket S3 con configuraciones de la aplicacion."
}
```

### Paso 2 — Policy document y recursos en `main.tf`

```hcl
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid       = "ListConfigBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.config_bucket_name}"]
  }

  statement {
    sid       = "GetConfigObjects"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.config_bucket_name}/*"]
  }
}

resource "aws_iam_policy" "s3_read" {
  name   = "${var.app_name}-s3-read"
  policy = data.aws_iam_policy_document.s3_read.json

  tags = {
    Name = "${var.app_name}-s3-read"
    Env  = var.env
  }
}

resource "aws_iam_role_policy_attachment" "s3_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.s3_read.arn
}
```

### Paso 3 — Output en `outputs.tf`

```hcl
output "s3_policy_arn" {
  description = "ARN de la politica IAM de lectura S3"
  value       = aws_iam_policy.s3_read.arn
}
```

### Verificación

```bash
terraform plan
# Plan: 2 to add, 0 to change, 0 to destroy.

terraform apply

# Verificar que la política está asociada al rol
aws iam list-attached-role-policies --role-name corp-lab27-ec2-role
```

La política resultante solo permite lectura sobre el bucket específico. A diferencia de usar la política gestionada `AmazonS3ReadOnlyAccess` (que da acceso a todos los buckets), esta política sigue el principio de mínimo privilegio.

---

## Verificación final

```bash
# Obtener la IP pública de la instancia
PUBLIC_IP=$(terraform output -raw public_ip)

# Probar el servidor web
curl -s "http://${PUBLIC_IP}"

# Verificar que IMDSv2 está activo (requiere token)
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=lab27" \
  --query 'Reservations[*].Instances[*].MetadataOptions.HttpTokens' \
  --output text
# Esperado: required

# Verificar el IAM Instance Profile asignado
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=lab27" \
  --query 'Reservations[*].Instances[*].IamInstanceProfile.Arn' \
  --output text

# Conectarse via SSM (sin SSH ni claves)
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target "${INSTANCE_ID}"
```

---

## 6. Limpieza

Desde el directorio `lab27/aws/`:

```bash
terraform destroy
```

---

## 7. LocalStack

Este laboratorio puede ejecutarse integramente en LocalStack para validar la sintaxis y la estructura de los recursos. Consulta [localstack/README.md](localstack/README.md) para las instrucciones de despliegue local.

>  **Limitación:** dado que LocalStack simula la instancia EC2 sin ejecutarla realmente, el User Data no se ejecuta y la página web no estará accesible. Las verificaciones de IMDSv2, Instance Profile y AMI se validan a nivel de API.

---

## 8. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `data "aws_ami"` | Consulta el catálogo real de AMIs | Devuelve AMIs simuladas |
| `aws_iam_role` | Rol IAM real con permisos efectivos | Soportado, comportamiento simulado |
| `aws_iam_instance_profile` | Profile real asociable a instancias | Soportado |
| `aws_instance` | Instancia EC2 real ejecutandose | Instancia simulada |
| `metadata_options` (IMDSv2) | Protección real contra SSRF | Aceptado por la API, no aplicable |
| `templatefile()` | Se evalúa en local antes del plan | Idéntico (función de Terraform) |
| `user_data` | Ejecutado por cloud-init al arrancar | Almacenado pero no ejecutado |
| Conectividad HTTP | Servidor web accesible | No accesible (instancia simulada) |
| SSM Session Manager | Funcional con el Instance Profile | No disponible |

---

## Buenas prácticas aplicadas

- **Nunca hardcodees AMI IDs.** Usa `data "aws_ami"` con filtros para obtener la versión más reciente de forma agnóstica a la región. Un AMI ID que funciona en `us-east-1` no existe en `eu-west-1`.
- **Usa Instance Profiles en lugar de Access Keys.** Las credenciales temporales del Instance Metadata Service rotan automáticamente y no requieren gestión manual. Las Access Keys estáticas dentro de una instancia son un riesgo de seguridad crítico.
- **Fuerza IMDSv2 siempre.** Configura `http_tokens = "required"` en todas las instancias. IMDSv1 es vulnerable a ataques SSRF y AWS recomienda desactivarlo. Considera establecer esto como política a nivel de cuenta con una SCP.
- **Verifica el User Data antes de aplicar.** El output `user_data_rendered` permite detectar errores de plantilla en el `plan` en lugar de depurar una instancia que no arrancó correctamente.
- **No abras el puerto SSH.** Usa SSM Session Manager para acceso interactivo. Esto elimina la necesidad de gestionar claves SSH, bastion hosts y reglas de firewall para el puerto 22.
- **Usa `user_data_replace_on_change = true`** para forzar la recreación de la instancia cuando cambie el script de bootstrap. Sin este argumento, cambios en el User Data se ignoran en instancias existentes.

---

## Recursos

- [Data source aws_ami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami)
- [Recurso aws_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance)
- [Recurso aws_iam_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)
- [Recurso aws_iam_instance_profile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile)
- [Data source aws_iam_policy_document](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document)
- [Recurso aws_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group)
- [Función templatefile()](https://developer.hashicorp.com/terraform/language/functions/templatefile)
- [Configurar IMDSv2 en EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Buenas prácticas de seguridad en EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security.html)
