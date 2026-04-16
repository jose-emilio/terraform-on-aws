# Laboratorio 1 — Primeros Pasos: Terraform, AWS CLI y LocalStack

[← Módulo 1 — Fundamentos de Infraestructura como Código y Terraform](../../modulos/modulo-01/README.md)


## Visión general

Guía de instalación y configuración de las herramientas necesarias para trabajar con **Infraestructura como Código (IaC)** usando Terraform en Linux, con soporte para AWS real y LocalStack como emulador local.

## Requisitos Previos

- Sistema operativo Linux (Ubuntu / Debian / Mint)
- Acceso a terminal con permisos `sudo`
- Conexión a internet
- Cuenta de AWS (para los laboratorios con nube real)

## 1. Instalación de Terraform

Terraform se instala desde los repositorios oficiales de HashiCorp para garantizar versiones actualizadas y firmadas.

```bash
# Instalar dependencias
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common wget

# Agregar la clave GPG de HashiCorp
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

# Agregar el repositorio
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# Instalar Terraform
sudo apt update && sudo apt install terraform -y
```

Verificar la instalación:

```bash
terraform -version
```

---

## 2. Instalación de AWS CLI

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

Verificar la instalación:

```bash
aws --version
```

---

## 3. Configuración de AWS CLI

Ejecuta el asistente de configuración:

```bash
aws configure
```

Se solicitarán los siguientes valores:

| Campo | Descripción | Ejemplo |
|---|---|---|
| AWS Access Key ID | Clave de acceso de tu usuario IAM | `AKIAIOSFODNN7EXAMPLE` |
| AWS Secret Access Key | Clave secreta asociada | `wJalrXUtnFEMI/K7MDENG/...` |
| Default region name | Región por defecto | `us-east-1` |
| Default output format | Formato de salida | `json` |

> Las credenciales se obtienen desde la consola de AWS en **IAM → Usuarios → Credenciales de seguridad**.

---

## 4. Instalación y Configuración de LocalStack

LocalStack emula los servicios de AWS localmente, permitiendo desarrollar y probar infraestructura sin costos ni conexión a AWS.

> **Asegúrate que tu máquina tiene Docker instalado.**

### 4.1 Instalación

```bash
curl --output localstack-cli-4.14.0-linux-amd64-onefile.tar.gz \
    --location https://github.com/localstack/localstack-cli/releases/download/v4.14.0/localstack-cli-4.14.0-linux-amd64-onefile.tar.gz

sudo tar xvzf localstack-cli-4.14.0-linux-*-onefile.tar.gz -C /usr/local/bin
```

### 4.2 Autenticación

1. Inicia sesión en [LocalStack Cloud](https://app.localstack.cloud/sign-in)
2. Genera un token en [Settings → Auth Tokens](https://app.localstack.cloud/settings/auth-tokens)
3. Configura el token localmente:

```bash
localstack auth set-token <TOKEN_AUTENTICACION>
```

### 4.3 Iniciar LocalStack

```bash
localstack start
```

> LocalStack quedará escuchando en `http://localhost.localstack.cloud:4566` por loque deberás abrir otra sesión de consola para poder interactuar. Si deseas que localstack te devuelva el control puedes usar la orden `localstack start -d`

## 5. Configuración de AWS CLI para LocalStack

Agrega el perfil `localstack` a los archivos de configuración de AWS CLI.

**`~/.aws/credentials`**
```ini
[localstack]
aws_access_key_id = test
aws_secret_access_key = test
```

**`~/.aws/config`**
```ini
[profile localstack]
output = json
region = us-east-1
endpoint_url = http://localhost.localstack.cloud:4566
```

Prueba el perfil:

```bash
aws --profile localstack s3 ls
```

## Verificación final

### AWS real

```bash
aws sts get-caller-identity
```

Resultado esperado:

```json
{
    "UserId": "AIDAEXAMPLEUSERID",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/jose-emilio"
}
```

### LocalStack

```bash
aws sts get-caller-identity --profile localstack
```

Resultado esperado:

```json
{
    "UserId": "000000000000",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

## 7. Configuración de Visual Studio Code

### Extensiones recomendadas

| Extensión | Propósito | Enlace |
|---|---|---|
| HashiCorp Terraform | Sintaxis, autocompletado y validación de HCL | [Instalar](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform) |
| AWS Toolkit | Gestión de recursos y credenciales AWS | [Instalar](https://marketplace.visualstudio.com/items?itemName=AmazonWebServices.aws-toolkit-vscode) |

### Pasos de configuración

1. Instala ambas extensiones desde el Marketplace de VSCode
2. Abre la extensión AWS Toolkit y selecciona el perfil de AWS configurado
3. Para cambiar entre AWS real y LocalStack, selecciona el perfil correspondiente (`default` o `localstack`)


## 8. Resumen de Perfiles Configurados

| Perfil | Destino | Uso |
|---|---|---|
| `default` | AWS real | Laboratorios con nube real |
| `localstack` | LocalStack local | Desarrollo y pruebas sin costo |

Para usar un perfil específico en cualquier comando:

```bash
aws <comando> --profile <nombre-perfil>
```

## Buenas prácticas aplicadas

- **Perfiles separados para AWS real y LocalStack**: usar perfiles de AWS CLI independientes (`default` para producción, `localstack` para desarrollo local) evita ejecutar comandos de producción contra LocalStack por error.
- **Variables de entorno para endpoint personalizado**: configurar `AWS_ENDPOINT_URL` o usar `--endpoint-url` en LocalStack es más seguro que modificar la configuración global del perfil default.
- **Verificar la instalación antes de continuar**: ejecutar `terraform version`, `aws --version` y `awslocal s3 ls` al final de la configuración garantiza que el entorno está listo antes de comenzar los laboratorios.
- **HashiCorp GPG para verificar Terraform**: descargar Terraform verificando la firma GPG del paquete protege contra binarios comprometidos o modificados en tránsito.
- **`tfenv` o `mise` para gestión de versiones de Terraform**: gestionar múltiples versiones de Terraform permite cambiar entre proyectos que requieren versiones diferentes sin reinstalar.

---

## Recursos

- [Documentación de Terraform](https://developer.hashicorp.com/terraform/docs)
- [Documentación de AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)
- [Documentación de LocalStack](https://docs.localstack.cloud/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Referencia de comandos AWS CLI](https://docs.aws.amazon.com/cli/latest/reference/)
