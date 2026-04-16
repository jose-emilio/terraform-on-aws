# Sección 3 — KMS y Cifrado

> [← Sección anterior](./02_politicas_iam.md) | [Siguiente →](./04_secretos.md)

---

## 3.1 AWS KMS: La Raíz de Confianza Criptográfica

KMS (Key Management Service) es el servicio gestionado de AWS para crear, almacenar y controlar claves de cifrado. Respaldado por módulos HSM con certificación **FIPS 140-2**, es el pilar de la seguridad de datos en reposo y en tránsito.

| Pilar | Descripción |
|-------|------------|
| **Hardware HSM** | Módulos de seguridad con certificación FIPS 140-2 Level 2/3 |
| **Customer Managed Keys** | Control total de políticas, rotación y auditoría de uso |
| **Integración Nativa** | S3, EBS, RDS, DynamoDB, Secrets Manager, CloudTrail y más |

---

## 3.2 AWS Managed Keys vs. Customer Managed Keys (CMK)

AWS ofrece dos tipos de claves KMS. La elección depende de tus requisitos de control, auditoría y cumplimiento (PCI-DSS, GDPR, HIPAA):

| Aspecto | AWS Managed Keys | Customer Managed Keys (CMK) |
|---------|-----------------|----------------------------|
| Creación | Automáticas por AWS | Control total del cliente |
| Coste | Sin coste adicional | $1/mes por llave + uso API |
| Rotación | Gestionada por AWS | Configurable (manual/auto) |
| Key Policy | Inmutable | Personalizable |
| Auditoría | Limitada | CloudTrail completo |
| Compliance | General | PCI-DSS, GDPR, HIPAA ✅ |
| Prefijo | `aws/service` (ej: `aws/s3`) | Nombre personalizado |

---

## 3.3 Identidad de la Llave: `aws_kms_key` y Alias

Un **alias** (`alias/s3-app`) es un nombre amigable para tu llave que permite **rotar el material criptográfico sin cambiar ARNs** en el código Terraform:

```
aws_kms_key                          aws_kms_alias
• Recurso principal de la llave       • Nombre amigable: alias/mi-llave
• Genera un ARN único e inmutable     • Apunta a la llave subyacente
• Configura rotación y política       • Redirigible a nueva llave sin tocar código
• El ARN cambia si recreas la llave   • Best practice para rotación
                                      • Prefijo obligatorio: alias/
```

**Código: CMK con Alias y Rotación Automática**

```hcl
# Llave maestra con rotación automática anual
resource "aws_kms_key" "app_key" {
  description             = "Llave para cifrado de aplicación"
  enable_key_rotation     = true    # Rota automáticamente cada 365 días
  deletion_window_in_days = 30      # Protección: 30 días antes de eliminar

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

# Alias amigable para referenciar la llave
resource "aws_kms_alias" "app_key_alias" {
  name          = "alias/app-encryption-key"
  target_key_id = aws_kms_key.app_key.key_id
}
```

---

## 3.4 Key Policies: El Guardián de la Llave

Este es el punto más importante de KMS: **KMS NO depende solo de IAM**. Cada llave tiene su propia Key Policy. Si la política de la llave no permite el acceso, **ni siquiera un administrador IAM con permisos completos puede usarla**.

```
Reglas fundamentales de Key Policies:
• Cada CMK requiere una Key Policy (no es opcional)
• La Key Policy es el filtro primario: IAM Policies son secundarias
• El usuario Root DEBE estar en la Key Policy (o no podrás recuperar la llave)
• Separa roles: Administrador de la llave ≠ Usuario de la llave

⚠ Sin Key Policy correcta = llave inutilizable permanentemente
```

**Código: Key Policy con Segregación de Roles**

```hcl
resource "aws_kms_key" "app_key" {
  description = "Llave con Key Policy segregada"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Root: Administración total (obligatorio para no perder el acceso)
        Sid       = "AllowRootAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::123456789:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Rol de app: Solo cifrar/descifrar (mínimo privilegio)
        Sid       = "AllowAppEncrypt"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.app.arn }
        Action    = ["kms:Encrypt", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })
}
```

---

## 3.5 KMS Grants: Permisos Temporales y Dinámicos

Los **KMS Grants** permiten otorgar permisos temporales sobre una llave sin modificar la Key Policy. Servicios como EBS y RDS los usan internamente:

```
Características de los Grants:
• Recurso Terraform: aws_kms_grant
• Otorgan operaciones específicas: Encrypt, Decrypt, GenerateDataKey
• Son revocables en cualquier momento sin tocar la Key Policy
• Soportan grant_creation_tokens para cadenas de delegación
• Ideal para servicios que necesitan acceso efímero a la llave
```

```hcl
resource "aws_kms_grant" "ebs_grant" {
  name              = "ebs-service-grant"
  key_id            = aws_kms_key.app_key.key_id
  grantee_principal = aws_iam_role.ebs_service.arn

  operations = [
    "Decrypt",
    "GenerateDataKey",
    "GenerateDataKeyWithoutPlaintext"
  ]

  # Restricción adicional: solo para el departamento de ingeniería
  constraints {
    encryption_context_equals = {
      Department = "engineering"
    }
  }
}
```

---

## 3.6 Cifrado Transversal I: S3 y EBS

Vincular tu CMK a S3 y EBS garantiza que los datos almacenados estén cifrados con material criptográfico bajo tu control directo:

**Amazon S3 (SSE-KMS):**
- Cada objeto cifrado individualmente
- Bucket Policy puede forzar cifrado obligatorio
- Auditable vía CloudTrail por objeto

**Amazon EBS:**
- Cifrado a nivel de volumen completo
- Snapshots también quedan cifrados automáticamente
- Transparente para la instancia EC2 (usa Grants internamente)

```hcl
# Volumen EBS cifrado con CMK
resource "aws_ebs_volume" "app_data" {
  availability_zone = "us-east-1a"
  size              = 100
  encrypted         = true
  kms_key_id        = aws_kms_key.app_key.arn

  tags = { Name = "app-data-encrypted" }
}

# Cifrado de bucket S3 con CMK
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket_enc" {
  bucket = aws_s3_bucket.app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.app_key.arn
    }
    bucket_key_enabled = true   # Reduce costos API KMS en ~99%
  }
}
```

---

## 3.7 Cifrado Transversal II: RDS y DynamoDB

> ⚠️ **En RDS, el cifrado debe habilitarse al momento de crear la instancia. No se puede activar después sin recrear la base de datos.**

```hcl
# RDS: Cifrado obligatorio al crear (no editable después)
resource "aws_db_instance" "app_db" {
  engine            = "postgres"
  instance_class    = "db.t3.medium"
  allocated_storage = 50
  storage_encrypted = true
  kms_key_id        = aws_kms_key.app_key.arn
  # ... otros parámetros de configuración
}

# DynamoDB: Cifrado con CMK personalizada (activable en cualquier momento)
resource "aws_dynamodb_table" "app_table" {
  name         = "app-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.app_key.arn
  }
}
```

| Servicio | Cuándo habilitar | Comportamiento |
|---------|-----------------|----------------|
| RDS | Solo al crear | Cifra datos, logs y backups. Réplicas heredan el cifrado |
| DynamoDB | Cualquier momento | Tabla, índices y streams cifrados |
| EBS | Al crear el volumen | Snapshots también quedan cifrados |
| S3 | Cualquier momento | Objeto a objeto o cifrado por defecto del bucket |

---

## 3.8 Multi-Region Keys: Disponibilidad Global

Las llaves multi-región comparten el mismo material criptográfico. Puedes **cifrar en `us-east-1` y descifrar en `eu-west-1`** con la misma identidad de llave:

```hcl
# Proveedor para región de réplica
provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
}

# Llave primaria multi-región (us-east-1)
resource "aws_kms_key" "primary" {
  description         = "Llave primaria multi-region"
  multi_region        = true
  enable_key_rotation = true
}

# Réplica en eu-west-1 para DR y baja latencia
resource "aws_kms_replica_key" "replica_eu" {
  provider        = aws.eu
  primary_key_arn = aws_kms_key.primary.arn
  description     = "Réplica DR en Europa"
}
```

---

## 3.9 Terraform State: Cifrado del Backend con KMS

El archivo `terraform.tfstate` contiene secretos, passwords y datos sensibles en texto plano. Almacenarlo sin cifrar es un riesgo crítico:

**Qué contiene el State File:**
- Passwords de RDS en texto plano
- Claves de acceso y tokens de servicios
- ARNs completos de todos los recursos
- Configuraciones y outputs sensibles

```hcl
# Backend seguro para Terraform State con CMK
terraform {
  backend "s3" {
    bucket     = "mi-empresa-terraform-state"
    key        = "prod/infrastructure.tfstate"
    region     = "us-east-1"
    encrypt    = true
    kms_key_id = "arn:aws:kms:us-east-1:123456:key/abc..."
    use_lockfile = true   # S3 Native Locking
  }
}
```

---

## 3.10 Rotación de Claves: Seguridad sin Esfuerzo

| Tipo | Proceso | Cuándo usar |
|------|---------|-------------|
| **Rotación Automática** | AWS genera nuevo material internamente. El Key ID y ARN no cambian. Datos antiguos se descifran con material viejo | `enable_key_rotation = true` — una línea. Sin downtime. PCI-DSS/GDPR automático |
| **Rotación Manual** | Crear nueva CMK. Re-cifrar datos. Actualizar referencias | Material criptográfico importado. Llaves asimétricas (no soportan auto) |

La rotación automática es la opción correcta para el 95% de los casos. Con `enable_key_rotation = true`, el Key ID y ARN permanecen igual — tu código Terraform no cambia.

---

## 3.11 KMS y CloudTrail: Auditoría de Uso

Cada operación criptográfica queda registrada automáticamente en CloudTrail:

```
1. Operación KMS: Encrypt, Decrypt, GenerateDataKey, ReEncrypt
2. Registro CloudTrail: Quién, cuándo, qué llave, desde dónde (IP, agente)
3. Alerta y Análisis: CloudWatch Alarms + Athena para queries forenses
```

Eventos clave a monitorear:
- `DisableKey` / `ScheduleKeyDeletion` → Posible sabotaje
- `Decrypt` desde IP desconocida → Posible exfiltración de datos

---

## 3.12 Troubleshooting: `AccessDeniedException` en KMS

| Causa | Diagnóstico | Fix |
|-------|------------|-----|
| **Key Policy no permite acceso** | La Key Policy es el filtro primario. Verifica que el Principal tenga `kms:Decrypt` y `kms:Encrypt` en la política de la llave | Añadir el ARN del rol/usuario a la Key Policy |
| **ARN del Alias ≠ ARN de la Key** | `arn:aws:kms:...:alias/nombre` no es intercambiable con `arn:aws:kms:...:key/uuid` | Algunas APIs requieren el ARN de la key, no del alias |
| **Llave deshabilitada** | Todas las operaciones criptográficas fallan si la llave está en estado `Disabled` | `aws kms describe-key --key-id <ARN>` para verificar el estado |

---

## 3.13 Resumen: El Cifrado como Estándar

| Práctica | Implementación |
|----------|---------------|
| **CMK** | Llaves propias con control total de políticas, rotación y auditoría |
| **Key Policies** | Filtro primario que aísla cada llave. Ni el IAM Admin accede sin permiso explícito |
| **Integración** | S3, EBS, RDS, DynamoDB, TF State: todo cifrado con la misma CMK y Alias |
| **Rotación** | Automática cada 365 días. Mismo Key ID, nuevo material. Sin impacto en código |

> **Principio:** El cifrado no es opcional en entornos productivos. Todo dato en reposo que toque servicios AWS debe estar cifrado con una CMK bajo tu control.

---

> **Siguiente:** [Sección 4 — Gestión de Secretos →](./04_secretos.md)
