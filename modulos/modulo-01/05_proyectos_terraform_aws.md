# Sección 5 — Proyectos de Terraform con AWS

> [← Sección anterior](./04_arquitectura_interna.md) | [← Volver al índice](./README.md) | [Siguiente sección →](./06_localstack.md)

---

## 5.1 Estructura estándar de un proyecto Terraform

Ha llegado el momento de pasar de la teoría a la práctica. En esta sección construiremos un proyecto Terraform real desde cero y recorreremos el flujo completo: desde el primer archivo `.tf` hasta verificar el recurso creado en la consola de AWS y limpiarlo con `destroy`.

Todo proyecto profesional de Terraform se organiza en archivos con propósitos bien definidos. Esta convención no es obligatoria desde el punto de vista del lenguaje, pero sí es el estándar de la industria que encontrarás en cualquier repositorio profesional.

```
mi-proyecto-terraform/
├── main.tf           # Recursos: donde se definen los recursos de infraestructura
├── variables.tf      # Entradas: declaración de las variables configurables
├── outputs.tf        # Salidas: valores que el proyecto expone al exterior
├── terraform.tfvars  # Valores: los valores concretos para las variables
└── .terraform/       # Plugins descargados (generado automáticamente — NO subir a Git)
```

### ¿Por qué separar en archivos?

La separación no es arbitraria. Tiene consecuencias prácticas muy reales:

| Razón | Descripción |
|-------|-------------|
| **Legibilidad** | Cada archivo tiene un propósito claro; cualquier miembro del equipo sabe exactamente dónde buscar qué |
| **Colaboración** | Menos conflictos en Git cuando varios ingenieros trabajan en paralelo — cada uno toca un archivo diferente |
| **Escalabilidad** | Fácil de mantener al crecer: se añaden más archivos temáticos, no más líneas en un único fichero imposible de navegar |

---

## 5.2 El bloque `terraform {}`

Este bloque define la **configuración global del proyecto**: qué versión mínima de Terraform se requiere y qué providers son necesarios. Fijar versiones es crítico para evitar que una actualización automática de un provider rompa el código en producción cuando menos te lo esperas.

```hcl
# versions.tf — o al inicio de main.tf en proyectos pequeños

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

### El operador `~>`: compatibilidad sin sorpresas

El operador `~>` (llamado "pessimistic constraint operator") es el más utilizado en producción:

| Operador | Significado | Ejemplo |
|----------|-------------|---------|
| `= 5.0.0` | Versión exacta | Solo 5.0.0, nada más |
| `>= 5.0` | Esta versión o superior | 5.0, 5.1, 6.0, 7.0... (peligroso) |
| `~> 5.0` | Compatible en minor | 5.0, 5.1, 5.9... pero **NO** 6.0 |
| `~> 5.31.0` | Compatible en patch | 5.31.0, 5.31.1... pero **NO** 5.32 |

> **Concepto clave:** `~> 5.0` significa *"cualquier versión 5.x"*. Permite recibir parches de seguridad automáticamente pero evita saltos de versión mayor que podrían romper el código. Es el equilibrio perfecto entre estabilidad y actualizaciones.

---

## 5.3 Configuración del Provider AWS

El bloque `provider "aws"` activa la conexión con Amazon Web Services. Aquí es donde Terraform lee las credenciales que configuramos en la sección 3 del curso: las variables de entorno `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` o el perfil de `~/.aws/credentials`.

```hcl
# main.tf

provider "aws" {
  region = "us-east-1"

  # Tags globales que se aplican automáticamente a TODOS los recursos del proyecto
  default_tags {
    tags = {
      Environment = "dev"
      Project     = "curso-terraform"
      ManagedBy   = "terraform"
    }
  }
}
```

### La magia de `default_tags`

`default_tags` es una de las características más valiosas y menos conocidas del provider de AWS. Con esta configuración, **todos los recursos** que crees heredarán automáticamente estas etiquetas de organización. Nunca volverás a olvidar etiquetar un recurso, y el equipo mantiene consistencia sin ningún esfuerzo adicional.

Esto significa que cuando el equipo de FinOps necesite saber cuánto cuesta cada proyecto o entorno, los datos estarán disponibles automáticamente en Cost Explorer de AWS.

---

## 5.4 Primer recurso: `aws_s3_bucket`

### Anatomía de un bloque `resource`

Cada recurso en Terraform sigue siempre la misma estructura:

```
resource "TIPO_DE_RECURSO" "NOMBRE_LOCAL" {
  argumento = "valor"
}
```

- **TIPO_DE_RECURSO:** El tipo de recurso del provider (`aws_s3_bucket`, `aws_instance`, `aws_vpc`...)
- **NOMBRE_LOCAL:** El identificador dentro de tu código HCL. Solo existe en Terraform; no afecta al nombre real en AWS. Debe ser único por tipo de recurso.

### Tu primera infraestructura real en código

```hcl
# main.tf — primer recurso

resource "aws_s3_bucket" "mi_bucket" {
  bucket = "mi-bucket-curso-tf-123"   # Nombre global único en todo AWS

  tags = {
    Name = "Mi primer bucket"
  }
}
```

La referencia a este recurso desde otros lugares del código sería `aws_s3_bucket.mi_bucket.id` o `aws_s3_bucket.mi_bucket.arn`. El tipo más el nombre local forman el **identificador completo** del recurso en Terraform.

> **Importante:** El nombre del bucket S3 debe ser **globalmente único** en todo AWS — no solo en tu cuenta, sino en todas las cuentas del mundo. Añade tu número de cuenta o un sufijo aleatorio para garantizarlo.

---

## 5.5 Flujo completo: del código a AWS

Ahora recorremos el ciclo completo con este proyecto mínimo. Ejecuta cada comando y observa la salida.

### Paso 1 — `terraform init`: descarga el plugin de AWS

```bash
$ terraform init

Initializing the backend...

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.0.0...
- Installed hashicorp/aws v6.0.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

Observa cómo Terraform descarga el **plugin del AWS Provider** y genera `.terraform.lock.hcl` con el hash exacto del binario. Este archivo debe commitearse al repositorio para que todo el equipo use exactamente la misma versión.

---

### Paso 2 — `terraform plan`: la hora de la verdad

```bash
$ terraform plan

Terraform will perform the following actions:

  + aws_s3_bucket.mi_bucket {
      + bucket         = "mi-bucket-curso-tf-123"
      + arn            = (known after apply)
      + id             = (known after apply)
      + region         = (known after apply)
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

Identifica que se va a añadir **exactamente un recurso nuevo** (`+ aws_s3_bucket.mi_bucket`). Observa los atributos marcados como `(known after apply)`: AWS los asignará en el momento de la creación y Terraform los almacenará en el state file para que los demás recursos puedan referenciarlos.

---

### Paso 3 — `terraform apply`: tu primer cambio real en AWS

```bash
$ terraform apply

  Do you want to perform these actions?
  Only 'yes' will be accepted to approve.

  Enter a value: yes

aws_s3_bucket.mi_bucket: Creating...
aws_s3_bucket.mi_bucket: Creation complete after 2s [id=mi-bucket-curso-tf-123]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

Escribe `yes` para confirmar. Terraform informa en tiempo real del progreso. Después, abre la **consola de Amazon S3** en tu navegador para verificar visualmente que el bucket ha aparecido. Esto es la primera vez que ves código convertirse en infraestructura real.

---

### Paso 4 — Inspección: `terraform show` y `terraform state list`

```bash
# Ver la configuración completa del estado actual — todos los atributos del recurso
$ terraform show

# aws_s3_bucket.mi_bucket:
resource "aws_s3_bucket" "mi_bucket" {
  arn    = "arn:aws:s3:::mi-bucket-curso-tf-123"
  bucket = "mi-bucket-curso-tf-123"
  id     = "mi-bucket-curso-tf-123"
  region = "us-east-1"
}
```

```bash
# Listar todos los recursos bajo gestión de este proyecto Terraform
$ terraform state list

aws_s3_bucket.mi_bucket
# Terraform tiene el inventario perfecto de tu infraestructura
```

`terraform show` y `terraform state list` son los comandos de auditoría del día a día. Permiten saber exactamente qué está gestionando Terraform y cuál es el estado actual de cada recurso.

---

### Paso 5 — `terraform destroy`: limpieza profesional

```bash
$ terraform destroy

  Terraform will destroy all resources.
  - aws_s3_bucket.mi_bucket

  Enter a value: yes

Destruction complete! Resources: 1 destroyed.
```

> **Buena práctica:** Ejecuta siempre `destroy` al terminar un laboratorio. Un bucket S3 vacío cuesta apenas nada, pero una instancia EC2 olvidada puede generar **facturas sorpresa** al final del mes. Desarrollar el hábito de destruir los entornos de prueba es señal de madurez profesional.

---

## 5.6 Análisis del `terraform.tfstate`

Después del `apply`, abre el archivo `terraform.tfstate` en tu editor. Verás cómo Terraform ha guardado los atributos críticos — incluyendo el ARN y el ID — que Amazon devolvió tras crear el recurso. Estos son los valores que otros recursos usarán para conectarse entre sí.

```json
{
  "version": 4,
  "terraform_version": "1.7.0",
  "resources": [
    {
      "type": "aws_s3_bucket",
      "name": "mi_bucket",
      "instances": [
        {
          "attributes": {
            "id":     "mi-bucket-curso-tf-123",
            "arn":    "arn:aws:s3:::mi-bucket-curso-tf-123",
            "bucket": "mi-bucket-curso-tf-123",
            "region": "us-east-1"
          }
        }
      ]
    }
  ]
}
```

### Advertencia de seguridad

> El estado contiene **TODA** la información de tu infraestructura, incluyendo posibles secretos, contraseñas de bases de datos y toda la topología de red. Trátalo con el máximo cuidado:
>
> - ❌ Nunca lo subas a Git (ni público ni privado en muchos casos).
> - ❌ Nunca lo edites a mano — siempre usa los comandos `terraform state`.
> - ✅ Usa siempre un **backend remoto** en producción (S3 con locking nativo desde Terraform ≥ 1.10).

---

## 5.7 LAB: Bucket S3 e Instancia EC2 básica

### Reto final del Módulo 1

Ha llegado el momento de demostrar lo aprendido. Añade un segundo recurso al proyecto actual: una **instancia EC2** (un servidor virtual en AWS). Necesitarás el ID de la AMI para tu región y el tipo de instancia.

```hcl
# Añadir a main.tf — junto al recurso aws_s3_bucket existente

# Data source: obtiene siempre el AMI más reciente de Amazon Linux 2023
# NUNCA uses un AMI ID hardcodeado: los IDs cambian con cada actualización
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "mi_servidor" {
  ami           = data.aws_ami.amazon_linux.id   # AMI siempre actualizado
  instance_type = "t3.micro"                     # Elegible para AWS Free Tier

  tags = {
    Name = "Mi primer servidor"
  }
}
```

### Tu misión — realiza todo el flujo por ti mismo

```
1. Añade el data source y el bloque resource "aws_instance" a main.tf
2. terraform plan   → verifica que el plan muestra 2 recursos a crear (1 instancia + 1 data source)
3. terraform apply  → confirma con "yes" y espera a que ambos se creen
4. Abre la consola de AWS → EC2 → Instances → verifica que el servidor aparece
5. terraform show   → examina el state file con los atributos de la instancia
6. terraform destroy → limpia TODOS los recursos al terminar
```

> ⚠️ **Las instancias EC2 tienen coste por hora** (~0,012 $/hora para t3.micro fuera del Free Tier). No dejes la instancia corriendo al terminar el laboratorio. El `destroy` final es obligatorio, no opcional.

---

> **Siguiente:** [Sección 6 — LocalStack: AWS local →](./06_localstack.md)
