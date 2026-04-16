# Sección 2 — Backend Remoto en AWS (S3)

> [← Sección anterior](./01_fundamentos_state.md) | [Siguiente →](./03_locking.md)

---

## 2.1 Arquitectura de un Backend Profesional

Un **Backend** es el almacenamiento centralizado del State. Sin él, cada miembro del equipo trabaja con una copia local distinta — lo que inevitablemente genera colisiones y pérdida de datos cuando dos ingenieros ejecutan `apply` el mismo día.

S3 es el estándar de la industria para este rol en AWS. Su arquitectura cubre tres dimensiones:

| Dimensión | Solución |
|-----------|----------|
| **Almacenamiento** | S3 almacena el `.tfstate` de forma centralizada. La `key` organiza los estados como un sistema de archivos: `prod/network.tfstate` |
| **Cifrado** | Con `encrypt = true`, S3 aplica AES-256 (SSE-S3) automáticamente en cada versión |
| **Versionado** | Bucket Versioning guarda cada versión del `.tfstate`. Un `apply` corrupto es reversible en minutos |

---

## 2.2 Prerequisito: El Bucket debe Existir Antes de `init`

Este es el detalle que más confunde a los principiantes: **el bucket S3 para el State debe existir ANTES de ejecutar `terraform init`**. Además, este bucket **no debe ser gestionado por el mismo código que lo usa como backend** — si lo fuera, crearía una dependencia circular fatal.

Checklist previo a configurar el backend:

| Requisito | Por qué |
|-----------|---------|
| **Bucket pre-existente** | Crea el bucket manualmente o con un proyecto Terraform separado |
| **Public Access Block** | Activa "Block All Public Access" — el State contiene datos sensibles y nunca debe ser accesible desde Internet |
| **Sin dependencias circulares** | No gestiones el bucket de State con el mismo proyecto que lo usa. Si Terraform necesita destruirse a sí mismo, no podrá acceder a su propio State |

---

## 2.3 Configuración del Bloque `backend "s3"`

La configuración del backend vive dentro del bloque `terraform {}` en tu `main.tf` o en un archivo dedicado `backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket  = "mi-empresa-tf-state"     # Nombre del bucket
    key     = "prod/network.tfstate"    # Ruta del archivo de estado
    region  = "eu-west-1"              # Región AWS
    encrypt = true                      # Cifrado SSE-S3 automático
  }
}
```

La `key` organiza el State como un sistema de archivos dentro del bucket. Usa rutas descriptivas que incluyan el entorno y el componente: `prod/network.tfstate`, `dev/compute.tfstate`. Esto mantiene el orden cuando un mismo bucket alberga estados de múltiples proyectos.

---

## 2.4 Cifrado en Reposo: SSE-S3 vs SSE-KMS

El State guarda secretos en texto plano — el cifrado es obligatorio, no opcional.

**SSE-S3 (nivel básico):** Con `encrypt = true`, S3 aplica cifrado AES-256 automáticamente. Es suficiente para la mayoría de proyectos.

```hcl
backend "s3" {
  bucket  = "mi-empresa-tf-state"
  key     = "prod/app.tfstate"
  region  = "eu-west-1"
  encrypt = true   # AES-256 gestionado por AWS
}
```

**SSE-KMS (nivel empresarial):** Con `kms_key_id`, usas Customer Master Keys (CMK) propias para auditoría vía CloudTrail y separación de permisos entre equipos:

| Aspecto | SSE-S3 | SSE-KMS |
|---------|--------|---------|
| Clave | Gestionada por AWS | CMK propia del cliente |
| Auditoría | Sin auditoría de accesos | CloudTrail completo |
| Permisos | Único para todos | Granulares por rol |
| Compliance | General | SOC2, HIPAA |
| Coste | Sin coste adicional | Coste por CMK |

> **Recuerda:** `sensitive = true` en variables solo oculta valores en la consola CLI. El State siempre los almacena en texto plano. El cifrado del bucket es tu primera línea de defensa real.

---

## 2.5 Permisos IAM Mínimos para el Backend

Principio de mínimo privilegio: el rol o usuario que ejecuta Terraform necesita exactamente estos permisos — ni más:

**S3 (obligatorio):**
```json
"Action": [
  "s3:GetObject",
  "s3:PutObject",
  "s3:ListBucket",
  "s3:DeleteObject"
]
```

**KMS (solo si usas SSE-KMS):**
```json
"Action": [
  "kms:Decrypt",
  "kms:Encrypt",
  "kms:GenerateDataKey"
]
```

Limita el `Resource` al ARN exacto del bucket y la clave KMS para evitar acceso accidental a otros estados.

---

## 2.6 Resiliencia: Versionado del Bucket S3

S3 Bucket Versioning guarda cada versión del `.tfstate` automáticamente. Si un `apply` corrompe el estado, puedes restaurar una versión anterior sin perder tu infraestructura.

**Escenario de Disaster Recovery:**
```
1. Un apply corrupto sobrescribe el State
2. Abrir S3 → Versiones del objeto
3. Seleccionar la versión anterior sana
4. Restaurar → State consistente de nuevo

Tiempo de recuperación: minutos, no horas.
```

Activar el versionado:
```bash
aws s3api put-bucket-versioning \
  --bucket mi-tf-state \
  --versioning-config Status=Enabled
```

---

## 2.7 Migración: De Local a Remoto en 3 Pasos

Agregar el bloque `backend` al código y ejecutar `terraform init` inicia un proceso interactivo que **copia automáticamente el State local al bucket S3 remoto**:

```bash
# Paso 1: Agregar bloque backend en main.tf
terraform {
  backend "s3" { ... }
}

# Paso 2: Ejecutar init (detecta cambio de backend)
$ terraform init
Initializing the backend...

Do you want to copy existing state to the new backend?
  Enter a value: yes

# Paso 3: Confirmar → "yes"
Successfully configured the backend "s3"!
```

Terraform detecta el cambio de backend, ofrece copiar el State existente y lo migra sin perder ningún recurso. El archivo local `terraform.tfstate` puede eliminarse una vez confirmado que el remoto es correcto.

---

## 2.8 Backend Parcial y Configuración por Entorno

La **Partial Configuration** permite dejar argumentos vacíos en el backend para inyectar valores en tiempo de ejecución. Esto hace posible reusar el mismo código HCL para diferentes entornos con backends aislados:

```hcl
# main.tf — bloque backend vacío (intencionalmente)
terraform {
  backend "s3" {
    # Vacío — los valores se inyectan en tiempo de ejecución
  }
}
```

```ini
# dev.tfbackend — archivo de configuración por entorno
bucket = "dev-tf-state"
key    = "dev/app.tfstate"
region = "eu-west-1"
```

```bash
# Inyectar en runtime:
$ terraform init -backend-config=dev.tfbackend
# Para producción:
$ terraform init -backend-config=prod.tfbackend
```

Este patrón es ideal para CI/CD multi-entorno: el mismo repositorio, el mismo código, backends aislados por entorno o cliente.

---

## 2.9 `-backend-config` en Pipelines CI/CD

El flag `-backend-config` admite tres formas de inyección:

```bash
# Opción 1: Archivo externo
$ terraform init -backend-config=prod.tfbackend

# Opción 2: Variables inline
$ terraform init \
    -backend-config="bucket=prod-state" \
    -backend-config="key=prod/app.tfstate"

# Opción 3: Variables de entorno (CI/CD)
export AWS_DEFAULT_REGION="eu-west-1"
$ terraform init -backend-config=ci.tfbackend
```

En pipelines de GitHub Actions o GitLab CI, el archivo `.tfbackend` por entorno se almacena cifrado como secreto y se inyecta en runtime, garantizando que cada ejecución usa el backend correcto.

---

## 2.10 Caso Real: Multi-Account Backend Strategy

En arquitecturas empresariales, el State vive en una **cuenta centralizada de Seguridad**. Los desarrolladores usan `AssumeRole` para acceder al backend desde sus cuentas de aplicación, reforzando la separación de responsabilidades:

```
Cuenta Seguridad (111111)
└── S3 Bucket (State)
└── DynamoDB (Locks)
└── KMS Key (Cifrado)

Cuenta App (222222)
└── EC2, RDS, VPC...
```

```hcl
backend "s3" {
  bucket   = "sec-tf-state"
  key      = "app/prod.tfstate"
  role_arn = "arn:aws:iam::111111:role/TfState"
}
```

Ningún desarrollador tiene acceso directo al bucket de State — solo a través del rol con permisos mínimos definidos en la cuenta de Seguridad.

---

## 2.11 Buenas Prácticas: Mantenimiento del Corazón

El backend es el corazón de tu infraestructura como código. Estas prácticas garantizan su salud a largo plazo:

| Categoría | Práctica |
|-----------|----------|
| **Protección** | MFA Delete en el bucket S3. Block Public Access activo |
| **Auditoría** | CloudTrail para todas las operaciones sobre el State. AWS Config para validar cifrado y versionado continuamente |
| **Resiliencia** | Bucket Versioning + Lifecycle Rules para retener versiones anteriores. Cross-Region Replication para desastres regionales. Prueba la restauración periódicamente |

---

## 2.12 Resumen: Del Caos a la Colaboración

Con un backend S3 correctamente configurado, tu flujo de trabajo pasa de un archivo local vulnerable a un sistema colaborativo con cifrado, versionado y locking. Tu infraestructura ahora es resiliente y el equipo puede trabajar en paralelo sin riesgo de colisiones.

> **Principio:** El State es tu activo más crítico. Protégelo con cifrado, controla el acceso con IAM, y nunca trabajes sin un backend remoto en proyectos profesionales.

---

> **Siguiente:** [Sección 3 — Bloqueo del State (Locking) →](./03_locking.md)
