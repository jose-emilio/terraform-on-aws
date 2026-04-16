# Sección 2 — EBS y EFS

> [← Sección anterior](./01_s3.md) | [Siguiente →](./03_rds_aurora.md)

---

## 2.1 Amazon EBS: Almacenamiento de Bloques

Mientras S3 almacena objetos (archivos con metadatos), EBS almacena bloques — el equivalente a un disco duro que conectas a tu servidor. La diferencia fundamental: los objetos S3 son inmutables (reemplazas el objeto completo), mientras que en EBS escribes en sectores específicos del disco como si fuera un SSD local.

> *"EBS es el disco duro de tu instancia EC2. Sin él, la instancia no puede arrancar. Con él, los datos persisten aunque la instancia se termine — puedes desconectar el disco y conectarlo a otra máquina, igual que con un disco físico."*

EBS tiene dos categorías de volúmenes:
- **Volúmenes Raíz**: el disco del sistema operativo. Se crea automáticamente al lanzar la instancia y, por defecto, se borra cuando la instancia termina.
- **Volúmenes Adicionales**: discos de datos con ciclo de vida independiente. Persisten tras terminar la instancia.

---

## 2.2 Tipos de Volumen: Elegir Correctamente

| Tipo | Familia | IOPS | Throughput | Caso de uso |
|------|---------|------|-----------|------------|
| **gp3** | SSD General | 3.000 base → 16.000 | 125 → 1.000 MB/s | Boot volumes, aplicaciones generales |
| **io2** | SSD Provisioned | Hasta 256.000 | Alta | Bases de datos críticas, SAP HANA |
| **st1** | HDD Throughput | — | Hasta 500 MB/s | Big data, logs, streaming |
| **sc1** | HDD Cold | — | Hasta 250 MB/s | Archival, datos fríos |

**gp3 es el tipo estándar para casi todo**: ofrece 3.000 IOPS base gratuitas y 125 MB/s de throughput, desacoplados del tamaño del disco (a diferencia de gp2 donde más IOPS = más GB). Además, es un 20% más barato que gp2.

```hcl
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = 100      # GiB
  type              = "gp3"
  iops              = 3000     # Base incluida
  throughput        = 125      # MB/s base incluida
  encrypted         = true
  kms_key_id        = aws_kms_key.ebs.arn

  tags = {
    Name        = "data-vol-01"
    Environment = var.environment
    Backup      = "true"       # Para que DLM lo gestione
  }
}

# Adjuntar a una instancia
resource "aws_volume_attachment" "app" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.web.id
}
```

---

## 2.3 La Restricción de AZ: EBS es Local

Una de las restricciones más importantes de EBS: **un volumen solo puede estar adjunto a instancias en la misma Availability Zone**. Si tu instancia está en `us-east-1a`, el volumen debe estar en `us-east-1a`. No puedes adjuntarlo a una instancia en `us-east-1b`.

Para mover datos entre AZs, el flujo es: Snapshot → restore en la AZ destino:

```hcl
# 1. Crear snapshot del volumen en us-east-1a
resource "aws_ebs_snapshot" "migrate" {
  volume_id   = aws_ebs_volume.source.id
  description = "AZ migration snapshot"
  tags        = { Name = "az-migrate" }
}

# 2. Restaurar en us-east-1b
resource "aws_ebs_volume" "restored" {
  availability_zone = "us-east-1b"   # Nueva AZ
  snapshot_id       = aws_ebs_snapshot.migrate.id
  type              = "gp3"
  encrypted         = true
  kms_key_id        = aws_kms_key.ebs.arn
  tags              = { Name = "restored-vol" }
}
```

---

## 2.4 Cifrado EBS con KMS

```hcl
# Activar cifrado por defecto para TODOS los volúmenes nuevos en la cuenta
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# Definir la CMK que se usará por defecto
resource "aws_ebs_default_kms_key" "this" {
  key_arn = aws_kms_key.ebs.arn
}

# CMK con rotación automática
resource "aws_kms_key" "ebs" {
  description         = "EBS encryption key"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.ebs_key.json
  tags                = { Name = "ebs-cmk" }
}
```

`aws_ebs_encryption_by_default` activa el cifrado a nivel de cuenta — todos los nuevos volúmenes EBS creados en esa región serán automáticamente cifrados, incluyendo los volúmenes raíz y los de los ASGs. Los snapshots de volúmenes cifrados también son cifrados automáticamente.

---

## 2.5 Snapshots

Los snapshots EBS automáticos son copias incrementales almacenadas en S3 (gestionado por AWS). El primer snapshot es una copia completa; los siguientes solo copian los bloques modificados.

Los snapshots manuales son copias puntuales que se toman a voluntad.

```hcl
# Snapshot manual
resource "aws_ebs_snapshot" "daily" {
  volume_id = aws_ebs_volume.data.id

  tags = {
    Name = "daily-snapshot"
    Env  = "production"
  }
}

# Copiar snapshot a otra región (DR)
resource "aws_ebs_snapshot_copy" "cross_region" {
  source_snapshot_id = aws_ebs_snapshot.daily.id
  source_region      = "us-east-1"
  encrypted          = true
  kms_key_id         = aws_kms_key.dr.arn   # Re-cifrar con CMK de la región destino
}
```

**Fast Snapshot Restore (FSR)**: al restaurar un snapshot, los bloques se cargan a demanda, lo que causa degradación de IOPS durante la inicialización. FSR pre-carga todos los bloques anticipadamente, eliminando este problema. Tiene coste adicional por AZ habilitada.

---

## 2.6 Data Lifecycle Manager: Automatización de Snapshots

`aws_dlm_lifecycle_policy` automatiza la creación, retención y eliminación de snapshots, con soporte para copias cross-region:

```hcl
resource "aws_dlm_lifecycle_policy" "ebs" {
  description        = "EBS Daily Snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = "true" }   # Volúmenes con este tag

    schedule {
      name = "daily-snapshot"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
      }

      retain_rule { count = 14 }   # Retener 14 snapshots
      copy_tags = true

      # Copiar automáticamente a otra región
      cross_region_copy_rule {
        target    = "us-west-2"
        encrypted = true
        retain_rule {
          interval      = 7
          interval_unit = "DAYS"
        }
      }
    }
  }
}
```

DLM selecciona los volúmenes a través de tags — cualquier volumen con `Backup = "true"` entra en la política. Esto permite gestionar backups de toda la organización de forma declarativa.

---

## 2.7 Multi-Attach: Disco Compartido

El volumen `io2` con `multi_attach_enabled = true` permite adjuntarlo a hasta 16 instancias EC2 simultáneamente (en la misma AZ):

```hcl
resource "aws_ebs_volume" "shared" {
  availability_zone    = "us-east-1a"
  size                 = 100
  type                 = "io2"
  iops                 = 3000
  multi_attach_enabled = true
  encrypted            = true
}

# Adjuntar a múltiples instancias con for_each
resource "aws_volume_attachment" "cluster" {
  for_each = toset(["i-instance-aaa", "i-instance-bbb"])

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.shared.id
  instance_id = each.value
}
```

**Atención**: Multi-Attach no significa que EBS gestione el acceso concurrente. El sistema de archivos debe ser **cluster-aware** (como GFS2, OCFS2 o Oracle ASM). Con un filesystem estándar como ext4 o xfs, el acceso concurrente corrompería los datos.

---

## 2.8 AMIs: Imágenes de Máquina desde EBS

```hcl
resource "aws_ami_from_instance" "golden" {
  name               = "golden-ami-${timestamp()}"
  source_instance_id = aws_instance.base.id

  snapshot_without_reboot = true   # No reiniciar la instancia fuente

  ebs_block_device {
    device_name = "/dev/sda1"
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "golden-ami"
    Base = aws_instance.base.id
  }
}
```

El patrón de **Golden AMI** consiste en crear una AMI con todo el software de base pre-instalado (agentes de monitorización, herramientas corporativas, hardening de seguridad). El ASG usa esa AMI para lanzar instancias que arrancan en segundos en lugar de minutos.

---

## 2.9 Amazon EFS: Elastic File System

EBS es un disco para una instancia. EFS es un **sistema de archivos compartido** que pueden montar cientos de instancias EC2 simultáneamente, desde múltiples AZs, con lectura y escritura concurrente.

> *"EBS es un disco duro — una instancia, un disco. EFS es una unidad de red NAS — cientos de servidores comparten el mismo sistema de archivos, leen y escriben al mismo tiempo, y el almacenamiento crece automáticamente cuando se necesita."*

Características clave:
- Protocolo **NFS v4.1** — compatible con Linux nativamente, sin drivers adicionales
- **Completamente elástico**: crece y reduce automáticamente, pagas solo por lo que usas
- **Multi-AZ**: Mount Targets en cada AZ, acceso de alta disponibilidad desde cualquier zona
- Durabilidad **99.999999999%** (igual que S3)

---

## 2.10 Creación del File System

```hcl
resource "aws_efs_file_system" "shared" {
  creation_token = "app-shared-efs"   # Identificador único para idempotencia
  encrypted      = true
  kms_key_id     = aws_kms_key.efs.arn

  performance_mode = "generalPurpose"   # generalPurpose | maxIO
  throughput_mode  = "elastic"          # elastic | bursting | provisioned

  # Mover archivos no accedidos a IA tras 30 días
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  # Devolver a Standard en el primer acceso
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name = "app-shared-efs"
    Env  = "production"
  }
}
```

---

## 2.11 Mount Targets: Un Endpoint por AZ

EFS necesita un **Mount Target** en cada AZ donde haya instancias que necesiten acceder. Cada Mount Target recibe una ENI con IP privada en esa subnet:

```hcl
# Un Mount Target por subnet privada
resource "aws_efs_mount_target" "this" {
  for_each = var.private_subnet_ids   # Set de IDs de subnets

  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Security Group: solo NFS (TCP 2049) desde las instancias
resource "aws_security_group" "efs" {
  name   = "efs-mount-target-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "NFS from EC2 instances"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]   # Referencia cruzada
  }

  tags = { Name = "efs-sg" }
}
```

La referencia cruzada entre Security Groups (origen = SG de las instancias EC2) es más segura que usar rangos CIDR — si las instancias cambian de IP, el acceso sigue funcionando automáticamente.

---

## 2.12 Modos de Rendimiento y Throughput

**Modos de rendimiento**:
- `generalPurpose`: latencia <1ms, hasta 35.000 IOPS. **El default y recomendado** para web servers, CMS, home dirs.
- `maxIO`: escala a >500.000 IOPS con mayor latencia. Para big data y media processing con miles de clientes paralelos.

**Modos de throughput**:

```hcl
# Elastic: ajusta automáticamente según la demanda (recomendado)
resource "aws_efs_file_system" "elastic" {
  throughput_mode  = "elastic"
  performance_mode = "generalPurpose"
  encrypted        = true
}

# Provisioned: throughput fijo garantizado
resource "aws_efs_file_system" "provisioned" {
  throughput_mode                  = "provisioned"
  provisioned_throughput_in_mibps = 256   # MB/s garantizados
  performance_mode                 = "generalPurpose"
  encrypted                        = true
}
```

`elastic` es la elección correcta para la mayoría de los casos — no pagas por throughput que no usas y no te quedas sin capacidad en picos.

---

## 2.13 Clases de Almacenamiento: IA para FinOps

EFS Standard cuesta ~$0.30/GB/mes. EFS Infrequent Access (IA) cuesta ~$0.016/GB/mes — hasta un **94% de ahorro** para archivos poco accedidos. El Lifecycle Management mueve archivos automáticamente entre clases:

```hcl
resource "aws_efs_file_system" "shared" {
  # ...

  # Mover a IA tras 30 días sin acceso
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  # Devolver a Standard en el primer acceso (opcional)
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }
}
```

Para reducir aún más el coste en dev/test, usa `One Zone` storage class: almacena los datos en una sola AZ (sin replicación Multi-AZ) al ~50% del precio de Standard.

---

## 2.14 Cifrado y File System Policy

El cifrado `at-rest` en EFS es **inmutable** — debe habilitarse al crear el file system y no puede cambiarse después:

```hcl
resource "aws_kms_key" "efs" {
  description         = "CMK for EFS encryption"
  enable_key_rotation = true
}

resource "aws_efs_file_system" "encrypted" {
  creation_token   = "encrypted-efs"
  encrypted        = true
  kms_key_id       = aws_kms_key.efs.arn
  throughput_mode  = "elastic"
}
```

La **File System Policy** fuerza cifrado `in-transit` (TLS) para todas las conexiones:

```hcl
resource "aws_efs_file_system_policy" "enforce_tls" {
  file_system_id = aws_efs_file_system.shared.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = { AWS = "*" }
      Action    = "*"
      Resource  = aws_efs_file_system.shared.arn
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
```

Esta policy bloquea cualquier conexión NFS sin TLS. Para montarlo, la instancia debe usar `amazon-efs-utils` con la opción `-o tls`.

---

## 2.15 Access Points: Aislamiento por Aplicación

Los Access Points de EFS permiten que cada aplicación acceda con su propia identidad POSIX y directorio raíz exclusivo:

```hcl
resource "aws_efs_access_point" "app" {
  file_system_id = aws_efs_file_system.shared.id

  # Identidad POSIX forzada — independiente del usuario del cliente
  posix_user {
    uid = 1000
    gid = 1000
  }

  # Directorio raíz exclusivo para esta app
  root_directory {
    path = "/app/data"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }
}
```

Con Access Points, cada aplicación (o microservicio) ve solo su propio subdirectorio del file system, como si fuera la raíz. El aislamiento es a nivel del sistema de archivos, no a nivel de red. Especialmente útil para Lambda y ECS/Fargate.

---

## 2.16 Comparativa: EBS vs. EFS vs. S3

| | EBS | EFS | S3 |
|--|-----|-----|-----|
| **Tipo** | Bloque | Sistema de archivos | Objeto |
| **Protocolo** | Bloque (interno) | NFS v4.1 | HTTP(S) |
| **Multi-attach** | Solo io2, 16 inst., 1 AZ | Cientos de inst., multi-AZ | Cualquier cliente HTTP |
| **Latencia** | <1ms | <1ms (GP) | Milisegundos |
| **Escalado** | Manual (resize) | Automático | Ilimitado |
| **Persistencia** | Con la instancia (configurable) | Independiente | Independiente |
| **Casos de uso** | BD, boot volumes | CMS, ML, archivos compartidos | Data lakes, backups, estáticos |

---

## 2.17 Resumen: EBS y EFS

**EBS — Reglas clave**:
- `gp3` para todo uso general (20% más barato que gp2)
- `io2` solo para IOPS >16.000 o Multi-Attach
- `encrypted = true` siempre + `aws_ebs_encryption_by_default` a nivel de cuenta
- DLM para automatizar snapshots por tags
- Volumen limitado a una AZ — usar snapshots para migrar

**EFS — Reglas clave**:
- Un Mount Target por AZ en subnets privadas
- Security Group: solo TCP 2049 desde SG de las instancias
- `throughput_mode = "elastic"` como default
- `encrypted = true` + File System Policy para forzar TLS
- Lifecycle Management: Standard → IA tras 30 días (92% ahorro)
- Access Points para aislamiento multi-app

---

> **Siguiente:** [Sección 3 — Amazon RDS y Aurora →](./03_rds_aurora.md)
