# Sección 3 — Instalación y Configuración del Entorno

> [← Sección anterior](./02_ecosistema_hashicorp.md) | [← Volver al índice](./README.md) | [Siguiente sección →](./04_arquitectura_interna.md)

---

## 3.1 Instalación de Terraform en Linux, macOS y Windows

Terraform es un binario único sin dependencias externas. No requiere runtime, no requiere JVM ni intérprete de Python: se descarga, se coloca en el PATH y funciona. Esta simplicidad es una de sus grandes ventajas operativas.

```bash
# Linux (Ubuntu/Debian) — repositorio oficial HashiCorp
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Linux (CentOS/RHEL/Amazon Linux)
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install terraform

# macOS (Homebrew)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Windows (Chocolatey)
choco install terraform

# Verificación en cualquier plataforma
terraform -version
# Terraform v1.14.x
```

> **Recomendación:** Instala siempre desde el repositorio oficial de HashiCorp, no desde los repositorios genéricos del sistema operativo. Esto garantiza acceso a las versiones más recientes y los parches de seguridad.

---

## 3.2 tfenv: Gestión Profesional de Versiones

### El problema que resuelve tfenv

En el mundo real, distintos proyectos usan versiones distintas de Terraform. El proyecto de la empresa A usa Terraform 1.5, el de la empresa B usa 1.14, y el proyecto legacy usa 1.2. Cambiar manualmente el binario cada vez que cambias de proyecto es lento, tedioso y propenso a errores.

**tfenv** soluciona exactamente este problema, de la misma manera que `nvm` lo hace para Node.js o `pyenv` para Python. Es una herramienta esencial para cualquier profesional que trabaje con múltiples proyectos.

```bash
# Instalación de tfenv
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Listar versiones de Terraform disponibles en el Registry
tfenv list-remote

# Instalar una versión específica
tfenv install 1.14.8

# Instalar la última versión estable
tfenv install latest

# Activar una versión para el shell actual
tfenv use 1.14.8

# Ver la versión activa
terraform -version
# Terraform v1.14.8
```

### El archivo `.terraform-version`

El truco profesional de tfenv es el archivo `.terraform-version` en la raíz del proyecto. Cuando tfenv detecta este archivo, selecciona automáticamente la versión correcta al entrar al directorio:

```bash
# En la raíz del proyecto
echo "1.14.8" > .terraform-version

# Ahora, al entrar al directorio, tfenv activa automáticamente la versión 1.14.8
cd mi-proyecto
terraform -version  # → Terraform v1.14.8
```

Este archivo **debe commitearse al repositorio** para que todos los miembros del equipo usen exactamente la misma versión.

---

## 3.3 Instalación de AWS CLI v2

AWS CLI es la herramienta de línea de comandos oficial de Amazon Web Services. Es **necesaria** para que Terraform pueda autenticarse con tu cuenta de AWS y para que puedas verificar los recursos creados directamente desde la terminal.

```bash
# Linux (x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# macOS (Homebrew)
brew install awscli

# Windows (Chocolatey)
choco install awscli

# Verificación
aws --version
# aws-cli/2.x.x Python/3.x.x Linux/x86_64
```

---

## 3.4 Configuración de Credenciales AWS

Una vez instalado el CLI, necesitas configurar las credenciales de acceso a tu cuenta AWS. El comando `aws configure` crea los archivos de configuración necesarios de forma interactiva.

```bash
aws configure
# AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
# AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
# Default region name [None]: eu-west-1
# Default output format [None]: json
```

Este comando crea dos archivos en tu directorio home:
- `~/.aws/credentials` — almacena las claves de acceso
- `~/.aws/config` — almacena la región y el formato de salida

### Profiles: gestión de múltiples cuentas

En entornos profesionales es habitual trabajar con múltiples cuentas AWS (desarrollo, staging, producción, clientes distintos). Los **perfiles** permiten gestionar varias configuraciones simultáneamente:

```ini
# ~/.aws/credentials
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[production]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY

[cliente-acme]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE2
aws_secret_access_key = ...
```

```bash
# Usar un perfil específico con Terraform
export AWS_PROFILE=production
terraform apply

# O de forma puntual
aws s3 ls --profile cliente-acme
```

### ⚠️ Regla de oro de seguridad

> **El archivo `~/.aws/credentials` contiene las claves de acceso a toda tu cuenta AWS. Trátalo como una contraseña maestra.**
>
> - Nunca lo subas a Git, ni en repositorios privados
> - Nunca lo compartas por Slack, email ni mensajes
> - Añade `**/.aws/` y `*.tfvars` a tu `.gitignore` global

---

## 3.5 Variables de Entorno e IAM Roles

Además de los archivos de configuración, Terraform acepta credenciales a través de variables de entorno. Esta es la forma recomendada en entornos de CI/CD.

```bash
# Variables de entorno — Terraform las detecta automáticamente
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_DEFAULT_REGION="eu-west-1"

terraform plan  # Terraform usa estas variables sin configuración adicional
```

### IAM Roles en entornos cloud (el estándar de producción)

En entornos de producción sobre EC2, ECS o Lambda, **nunca** se usan claves de acceso estáticas. En su lugar, se asigna un **IAM Role** al recurso de cómputo. Terraform obtiene credenciales temporales automáticamente a través del servicio de metadatos de AWS (IMDS), sin que ninguna clave quede almacenada en disco.

```hcl
# ❌ MAL — Nunca hardcodear credenciales en el código
provider "aws" {
  access_key = "AKIAIOSFODNN7EXAMPLE"   # PELIGRO: se commitea al repositorio
  secret_key = "wJalrXUtnFEMI..."       # PELIGRO: expone acceso a toda la cuenta
  region     = "eu-west-1"
}

# ✅ BIEN — Terraform detecta credenciales del entorno automáticamente
provider "aws" {
  region = "eu-west-1"
  # Sin claves = usa el IAM Role del EC2, ECS task o Lambda que ejecuta Terraform
}
```

Sin claves almacenadas → menor superficie de ataque → mejor postura de seguridad.

---

## 3.6 VS Code + Extensión Terraform

Visual Studio Code es el editor de referencia para Terraform. Es gratuito, multiplataforma y tiene un ecosistema de extensiones incomparable.

La **extensión oficial de HashiCorp** ([HashiCorp Terraform](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform)) proporciona:

| Funcionalidad | Descripción |
|--------------|-------------|
| **Resaltado de sintaxis HCL** | Coloreado diferenciado de bloques, argumentos y valores |
| **Autocompletado inteligente** | Sugerencias de recursos, atributos y valores válidos según el provider |
| **Validación en tiempo real** | Errores subrayados mientras escribes, sin necesidad de ejecutar `terraform validate` |
| **Navegación entre archivos** | Ctrl+Click en una referencia (`aws_vpc.main.id`) para ir a la definición |
| **Hover con documentación** | Al pasar el cursor sobre un recurso, muestra la documentación inline |
| **Formateo automático** | Al guardar, aplica `terraform fmt` automáticamente |

Instalar esta extensión transforma la experiencia de escritura de HCL de forma radical. Es el equivalente a tener un IDE completo para Terraform.

---

## 3.7 tflint: Linter para Terraform

`terraform validate` verifica que la sintaxis HCL es correcta y que las referencias internas son coherentes. Pero no verifica si los valores son válidos para el proveedor cloud específico.

**tflint** añade una capa adicional de validación que `terraform validate` no cubre: comprueba que los valores declarados en el código son válidos para la API de AWS.

```bash
# Instalación
brew install tflint                            # macOS
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash  # Linux

# Inicializar el plugin de AWS
tflint --init

# Ejecutar el análisis
tflint

# Ejemplo de salida: detecta un tipo de instancia que no existe
$ tflint
1 issue(s) found:

Warning: "t2.superxl" is not a valid value for "instance_type" (aws_instance_invalid_type)

  on main.tf line 3:
   3:   instance_type = "t2.superxl"  # Este tipo no existe en AWS
```

Sin tflint, este error solo se descubriría al ejecutar `terraform apply` y esperar a que la API de AWS rechace la solicitud — potencialmente varios minutos después. Con tflint, se detecta en segundos antes de cualquier llamada a la API.

---

## 3.8 terraform-docs: Documentación Automática

Los módulos de Terraform necesitan documentación para que otros ingenieros los puedan usar sin leer todo el código fuente. `terraform-docs` extrae automáticamente las variables, outputs y tipos del código y genera tablas Markdown listas para incluir en el README.

```bash
# Instalación
brew install terraform-docs

# Generar documentación e imprimir por pantalla
terraform-docs markdown table .

# Inyectar en el README.md existente (requiere marcadores HTML en el fichero)
# El README debe contener: <!-- BEGIN_TF_DOCS --> y <!-- END_TF_DOCS -->
terraform-docs markdown table --output-file README.md --output-mode inject .
```

### Ejemplo de tabla generada automáticamente

| Nombre | Tipo | Valor por defecto | Requerido |
|--------|------|:-----------------:|:---------:|
| `instance_type` | `string` | `"t3.micro"` | no |
| `region` | `string` | `"eu-west-1"` | no |
| `environment` | `string` | n/a | **sí** |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | no |

Sin esta herramienta, la documentación de los módulos se desactualiza en cuanto alguien añade una variable nueva y olvida actualizar el README. Con terraform-docs integrado en pre-commit hooks, la documentación se actualiza automáticamente en cada commit.

---

## 3.9 Pre-commit Hooks para IaC

Los pre-commit hooks son scripts de Git que se ejecutan automáticamente **justo antes de confirmar cambios**. Son la primera línea de defensa para garantizar la calidad del código Terraform.

La idea es sencilla: si el código no pasa las validaciones, el commit se rechaza. El desarrollador debe corregir el error antes de poder guardar sus cambios. Esto elimina el problema de "código roto que llega al repositorio compartido".

```yaml
# .pre-commit-config.yaml — en la raíz del repositorio
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.0
    hooks:
      - id: terraform_fmt        # Formatea el código automáticamente
      - id: terraform_validate   # Valida la sintaxis HCL
      - id: terraform_tflint     # Detecta errores específicos de AWS
      - id: terraform_docs       # Actualiza la documentación del módulo
```

### El flujo con pre-commit

```
git commit
    │
    ├── terraform_fmt → ¿Está bien formateado? (si no, lo corrige)
    ├── terraform_validate → ¿Sintaxis HCL válida?
    ├── terraform_tflint → ¿Valores válidos para AWS?
    └── terraform_docs → ¿Documentación actualizada?
          │
          ├── Todo OK → ✅ Commit realizado
          └── Algún fallo → ❌ Commit rechazado (corrígelo antes)
```

```bash
# Instalación de pre-commit
pip install pre-commit

# Activar los hooks en el repositorio actual
pre-commit install

# Ejecutar manualmente sobre todos los archivos
pre-commit run --all-files
```

---

## 3.10 Verificación del Entorno

> **⛔ No avances al siguiente tema hasta que el entorno esté 100% funcional.**

Ejecuta cada uno de estos comandos y verifica que la salida es la esperada:

```bash
# 1. Verificar Terraform
terraform -version
# Esperado: Terraform v1.x.x (on linux_amd64)

# 2. Verificar AWS CLI
aws --version
# Esperado: aws-cli/2.x.x Python/3.x.x

# 3. Verificar identidad AWS — esta es la prueba definitiva
aws sts get-caller-identity
# Esperado:
# {
#     "UserId": "AIDA...",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:user/mi-usuario"
# }
```

Si el tercer comando devuelve un error de autenticación, Terraform tampoco podrá conectar con AWS. Resuelve las credenciales antes de continuar.

---

> **Siguiente:** [Sección 4 — Arquitectura Interna de Terraform →](./04_arquitectura_interna.md)
