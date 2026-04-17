# Laboratorio 5: Configuración Dinámica y Plantillas de Sistema

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 2 — Lenguaje HCL y Configuración Avanzada](../../modulos/modulo-02/README.md)


## Visión general

En este laboratorio automatizarás la generación de scripts de inicio (User Data) usando plantillas `.tftpl`, transformarás listas en maps con expresiones `for`, leerás claves SSH desde el disco con `file()` y generarás archivos de configuración locales con directivas `%{if}` y `%{for}`. El objetivo es dominar las funciones de transformación y el sistema de plantillas de Terraform.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear plantillas de bash con variables y directivas usando `templatefile()`
- Transformar listas en maps de tags con expresiones `for` y `upper()`
- Leer archivos locales de forma segura con `file()`
- Generar archivos de configuración con lógica condicional usando `%{if}` y `%{for}`
- Combinar maps de tags con `merge()`

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
---

## Conceptos Clave

### Función `templatefile()`

Lee un archivo externo `.tftpl` y sustituye las variables declaradas en él por los valores que se le pasan como segundo argumento (un map):

```hcl
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    db_endpoint = var.db_endpoint
    services    = var.services
  })
}
```

La variable `path.module` contiene la ruta absoluta al directorio del módulo actual, lo que hace la referencia al archivo portable independientemente de desde dónde se ejecute Terraform.

Dentro del archivo `.tftpl` se usan:

- `${variable}` para interpolación simple
- `%{ for item in lista }...%{ endfor }` para iterar
- `%{ if condicion }...%{ else }...%{ endif }` para condicionales

El sufijo `~` en las directivas (`%{ endfor ~}`) elimina el salto de línea que la directiva introduce, evitando líneas en blanco extra en el resultado.

### Expresión `for` con `upper()`

Transforma una lista en un map aplicando una función a cada elemento:

```hcl
service_tags = { for svc in var.services : upper(svc) => "enabled" }
```

Con `var.services = ["nginx", "postgresql15"]` el resultado es:

```hcl
{
  "NGINX"        = "enabled"
  "POSTGRESQL15" = "enabled"
}
```

Este map puede pasarse directamente a un bloque `tags` o combinarse con otros maps usando `merge()`.

### Función `file()`

Lee el contenido de un archivo local en tiempo de `plan` y lo devuelve como string:

```hcl
public_key = file(var.public_key_path)
```

Es la forma correcta de incluir claves SSH o certificados en la configuración: el contenido del archivo nunca se escribe en el código fuente, solo se referencia su ruta.

> `file()` se evalúa en la máquina donde se ejecuta Terraform, no en la instancia EC2. Para leer archivos en la instancia se usa `templatefile()` con User Data.

### Directivas `%{if}` y `%{for}` en heredocs

Las directivas de plantilla también funcionan dentro de strings multilínea (`<<-EOT`) en recursos HCL, no solo en archivos `.tftpl`:

```hcl
content = <<-EOT
  %{ if var.env == "prod" ~}
  tls = true
  %{ else ~}
  tls = false
  %{ endif ~}
EOT
```

Esto permite generar archivos de configuración con lógica condicional sin necesidad de múltiples recursos `local_file` ni módulos adicionales.

### Función `merge()`

Combina dos o más maps en uno. Si hay claves duplicadas, el último map prevalece:

```hcl
tags = merge(
  { Name = var.app_name, Env = var.env },
  local.service_tags
)
```

---

## Estructura del proyecto

```
lab05/
├── user_data.tftpl      # Plantilla de bash compartida por ambos entornos
├── aws/
│   ├── providers.tf     # Bloque terraform{} y provider{}
│   ├── variables.tf     # env, app_name, db_endpoint, services, public_key_path
│   ├── main.tf          # locals, aws_key_pair, aws_launch_template, local_file
│   └── outputs.tf       # user_data renderizado, service_tags, key pair, config
└── localstack/
    ├── providers.tf     # Endpoint ec2 apuntando a LocalStack
    ├── variables.tf     # Idéntico al de aws/
    ├── main.tf          # Idéntico al de aws/
    └── outputs.tf       # Idéntico al de aws/
```

La plantilla `user_data.tftpl` vive en la raíz de `lab04/` y es compartida por ambos entornos mediante `path.module/../user_data.tftpl`.

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`user_data.tftpl`**

```bash
#!/bin/bash
# Generado por Terraform — entorno: ${env}
set -euo pipefail

# Configuración del entorno
echo "ENV=${env}" >> /etc/environment
echo "APP_NAME=${app_name}" >> /etc/environment

# Conexión a la base de datos
echo "DB_ENDPOINT=${db_endpoint}" >> /etc/environment

# Instalación de servicios declarados en Terraform
%{ for svc in services ~}
dnf install -y ${svc}
%{ endfor ~}

%{ if env == "prod" ~}
# Hardening adicional solo en producción
systemctl enable --now auditd
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
%{ endif ~}

echo "Bootstrap completado para ${app_name} en ${env}"
```

**`aws/providers.tf`**

```hcl
# Configuración del backend de Terraform y versión mínima del provider de AWS
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# El provider lee las credenciales del perfil "default" de ~/.aws/credentials
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
  default = "corp-lab4"
}

variable "db_endpoint" {
  type    = string
  default = "db.corp-lab4.internal:5432"
}

variable "services" {
  type    = list(string)
  default = ["nginx", "postgresql15", "amazon-cloudwatch-agent"]
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}
```

**`aws/main.tf`**

```hcl
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    app_name    = var.app_name
    db_endpoint = var.db_endpoint
    services    = var.services
  })

  # { "NGINX" = "enabled", "POSTGRESQL15" = "enabled", ... }
  service_tags = { for svc in var.services : upper(svc) => "enabled" }
}

resource "aws_key_pair" "lab4" {
  key_name   = "${var.app_name}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.app_name}-key"
    Env  = var.env
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  instance_type = "t4g.small"
  key_name      = aws_key_pair.lab4.key_name

  user_data = base64encode(local.user_data)

  tags = merge(
    { Name = var.app_name, Env = var.env },
    local.service_tags
  )
}

resource "local_file" "app_config" {
  filename = "${path.module}/app.conf"
  content  = <<-EOT
    [app]
    name     = ${var.app_name}
    env      = ${var.env}
    db       = ${var.db_endpoint}

    %{ if var.env == "prod" ~}
    [security]
    tls          = true
    min_tls      = TLSv1.2
    hsts         = true
    %{ else ~}
    [security]
    tls          = false
    %{ endif ~}

    [services]
    %{ for svc in var.services ~}
    ${svc} = enabled
    %{ endfor ~}
  EOT
}
```

**`aws/outputs.tf`**

```hcl
output "user_data_rendered" {
  description = "Script de bootstrap generado por templatefile()"
  value       = local.user_data
}

output "service_tags" {
  description = "Tags de servicios generados con la expresión for"
  value       = local.service_tags
}

output "key_pair_name" {
  description = "Nombre del key pair registrado en AWS"
  value       = aws_key_pair.lab4.key_name
}

output "launch_template_id" {
  description = "ID del launch template creado"
  value       = aws_launch_template.app.id
}

output "config_file_path" {
  description = "Ruta del archivo de configuración generado por local_file"
  value       = local_file.app_config.filename
}
```

### 1.2 Preparar la Clave SSH

Antes de desplegar, asegúrate de tener un par de claves SSH. Si no existe, genéralo:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

Verifica que el archivo de clave pública existe:

```bash
cat ~/.ssh/id_rsa.pub
```

### 1.3 Despliegue

Desde el directorio `lab04/aws/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

Durante el `plan`, Terraform mostrará el script de User Data ya renderizado con los valores de las variables, lo que permite verificar el resultado antes de que llegue a la instancia.

### 1.4 Verificar los Outputs

Al finalizar `terraform apply`:

```
Outputs:

config_file_path   = "./app.conf"
key_pair_name      = "corp-lab4-key"
launch_template_id = "lt-0abc123..."
service_tags       = {
  "AMAZON-CLOUDWATCH-AGENT" = "enabled"
  "NGINX"                   = "enabled"
  "POSTGRESQL15"            = "enabled"
}
user_data_rendered = <<EOT
  #!/bin/bash
  # Generado por Terraform — entorno: dev
  ...
EOT
```

Verifica el archivo de configuración generado localmente:

```bash
cat aws/app.conf
```

En entorno `dev` la sección `[security]` solo contendrá `tls = false`. Prueba con entorno `prod`:

```bash
terraform apply -var='env=prod'
cat aws/app.conf
```

Ahora la sección `[security]` incluirá `tls = true`, `min_tls` y `hsts`.

Verifica el key pair en AWS:

```bash
aws ec2 describe-key-pairs --filters "Name=key-name,Values=corp-lab4-key"
```

---

## Verificación final

```bash
# Verificar que la instancia EC2 está running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=corp-*" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}' \
  --output table

# Comprobar que el User Data fue generado correctamente
terraform output user_data_rendered | head -20

# Verificar el archivo de configuracion local generado
cat aws/app.conf

# Conectarse al servidor y verificar que el script se ejecutó
PUBLIC_IP=$(terraform output -raw instance_public_ip)
ssh -i ~/.ssh/id_rsa ec2-user@${PUBLIC_IP} "systemctl status $(terraform output -raw app_name)"
```

---

## 2. Limpieza

```bash
terraform destroy
```

> El archivo `app.conf` generado por `local_file` también se elimina al hacer `destroy`.

---

## 3. LocalStack

Este laboratorio puede ejecutarse íntegramente en LocalStack. Consulta [localstack/README.md](localstack/README.md) para las instrucciones de despliegue local.

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `aws_key_pair` | Registra la clave en EC2 real | Soportado, comportamiento idéntico |
| `aws_launch_template` | Recurso real en EC2 | Soportado |
| `local_file` | Escribe en el disco local | Idéntico (no es un recurso AWS) |
| `templatefile()` | Se evalúa en local antes del plan | Idéntico |
| `file()` | Lee del disco local | Idéntico |

---

## Buenas prácticas aplicadas

- **Usa `templatefile()` en lugar de heredocs con interpolación directa** para scripts largos. Mantener el script en un `.tftpl` separado permite editarlo con resaltado de sintaxis de bash y facilita las revisiones de código.
- **Nunca hardcodees claves SSH en el código.** `file()` mantiene la clave fuera del repositorio y del estado de Terraform (solo se almacena la clave pública, nunca la privada).
- **El sufijo `~` en las directivas es importante.** Sin él, cada `%{ for }` y `%{ endfor }` introduce una línea en blanco extra en el resultado, lo que puede romper scripts bash o archivos de configuración sensibles al formato.
- **Usa `merge()` para componer tags** en lugar de duplicar bloques. Permite combinar tags corporativos fijos con tags generados dinámicamente de forma limpia.
- **Verifica el User Data antes de aplicar** usando el output `user_data_rendered`. Es mucho más fácil corregir un error de plantilla en el `plan` que depurar un servidor que no arrancó correctamente.

---

## Recursos

- [Función templatefile()](https://developer.hashicorp.com/terraform/language/functions/templatefile)
- [Directivas de plantilla](https://developer.hashicorp.com/terraform/language/expressions/strings#directives)
- [Función file()](https://developer.hashicorp.com/terraform/language/functions/file)
- [Función upper()](https://developer.hashicorp.com/terraform/language/functions/upper)
- [Función merge()](https://developer.hashicorp.com/terraform/language/functions/merge)
- [Función base64encode()](https://developer.hashicorp.com/terraform/language/functions/base64encode)
- [Recurso local_file](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file)
- [Recurso aws_key_pair](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/key_pair)
- [Recurso aws_launch_template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template)
