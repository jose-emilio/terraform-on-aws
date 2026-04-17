# Laboratorio 34: Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 8 — Almacenamiento y Bases de Datos con Terraform](../../modulos/modulo-08/README.md)


## Visión general

En este laboratorio implementarás las dos formas principales de almacenamiento persistente en AWS: **EBS** para discos individuales de alta velocidad y **EFS** para sistemas de archivos compartidos entre múltiples instancias. Aprenderás a desacoplar IOPS y throughput del tamaño del volumen con **gp3**, a automatizar respaldos basados en etiquetas con **Data Lifecycle Manager**, a crear un sistema de archivos elástico cifrado con **EFS Elastic Throughput**, a desplegar mount targets en múltiples AZs y a aislar datos de aplicaciones con un **EFS Access Point** que impone identidad POSIX.

La infraestructura se organiza en tres **módulos locales reutilizables**: `modules/vpc` gestiona la VPC y las subnets, `modules/ec2-client` encapsula la instancia, su acceso SSM y el volumen EBS, y `modules/efs-share` gestiona el file system EFS, los mount targets y el Access Point. El módulo raíz orquesta los tres módulos y gestiona directamente la política DLM.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Estructurar la infraestructura en tres módulos locales (`vpc`, `ec2-client`, `efs-share`) con interfaces claras de variables y outputs
- Crear un volumen `aws_ebs_volume` de tipo gp3 configurando IOPS y throughput de forma independiente al tamaño
- Adjuntar el volumen a una instancia con `aws_volume_attachment`
- Definir una política `aws_dlm_lifecycle_policy` que automatiza snapshots EBS diarios con retención de 14 días basada en etiquetas
- Crear un `aws_efs_file_system` cifrado con `throughput_mode = "elastic"`
- Desplegar `aws_efs_mount_target` en cada subnet privada con `for_each` sobre una lista de IDs
- Configurar el Security Group del EFS para permitir TCP 2049 exclusivamente desde el Security Group de las instancias EC2
- Implementar un `aws_efs_access_point` con `posix_user` y `root_directory` para aislar los datos de una aplicación

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre EC2, EBS, EFS, IAM y DLM
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### gp3: desacoplamiento de rendimiento y capacidad

`gp2` escala IOPS automáticamente con el tamaño del volumen (3 IOPS/GB, máximo 16 000). Un volumen de 100 GB tiene 300 IOPS baseline — insuficiente para cargas de trabajo intensivas. `gp3` rompe esta dependencia: puedes configurar hasta 16 000 IOPS y 1 000 MB/s de throughput en cualquier tamaño de volumen, sin coste adicional hasta 3 000 IOPS y 125 MB/s.

```
gp2 de 100 GB → 300 IOPS fijos (no configurable)
gp3 de 100 GB → 6 000 IOPS + 400 MB/s (configuración independiente)
```

El coste de almacenamiento base de gp3 ($0.08/GB/mes) es un 20% inferior a gp2 ($0.10/GB/mes). El IOPS adicional se factura por separado (primeros 3 000 gratis).

### Data Lifecycle Manager (DLM)

DLM automatiza el ciclo de vida de snapshots EBS. En lugar de un script de cron o Lambda, defines una política declarativa que selecciona volúmenes por etiquetas, programa la creación de snapshots y gestiona la retención automática.

La política requiere dos recursos: un rol IAM que DLM asume para crear snapshots en tu cuenta, y la propia política con sus reglas de programación:

```hcl
# Rol IAM que DLM asume para operar en tu cuenta
resource "aws_iam_role" "dlm" {
  name = "${var.project}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# Política DLM
resource "aws_dlm_lifecycle_policy" "ebs_backup" {
  description        = "Snapshots diarios EBS - etiqueta Backup true - retencion 14 dias"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # Selecciona todos los volúmenes EBS con la etiqueta Backup=true
    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "daily-14d"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]   # hora UTC de inicio de la ventana
      }

      retain_rule {
        count = 14   # conserva los 14 snapshots más recientes; elimina el resto
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Project         = var.project
      }

      copy_tags = true   # hereda las etiquetas del volumen origen
    }
  }
}
```

La política selecciona volúmenes por etiqueta (`Backup = "true"`), no por ID. Esto significa que cualquier volumen nuevo que lleve esa etiqueta queda cubierto automáticamente sin modificar la política. El rol `AWSDataLifecycleManagerServiceRole` ya incluye los permisos necesarios (`ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:DescribeVolumes`, etc.) — no es necesario crear una política IAM personalizada.

### EFS Elastic Throughput

EFS ofrece tres modos de throughput:

| Modo | Comportamiento | Uso recomendado |
|---|---|---|
| `bursting` | Throughput proporcional al tamaño del FS; acumula créditos | File systems pequeños con acceso esporádico |
| `provisioned` | Throughput fijo garantizado; facturado por MB/s | Cargas predecibles y constantes |
| `elastic` | Throughput automático hasta 3 GB/s lecturas / 1 GB/s escrituras | Cargas variables o desconocidas |

`elastic` es el modo recomendado para la mayoría de nuevos deployments: solo pagas por los MB/s consumidos, sin aprovisionar capacidad de antemano.

### Mount Targets y AZs

Un mount target es el punto de entrada de red de EFS en una subnet. Para alta disponibilidad y latencia óptima, se despliega uno por AZ. EFS replica los datos de forma transparente entre todas las AZs de la región; cada instancia se conecta al mount target de su propia AZ:

```hcl
resource "aws_efs_mount_target" "main" {
  for_each = toset(var.subnet_ids)   # una iteración por subnet/AZ

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}
```

El Security Group del EFS debe permitir TCP 2049 (protocolo NFS) exclusivamente desde el Security Group de las instancias EC2. Usar `source_security_group_id` en lugar de CIDR es más seguro y escala automáticamente cuando se añaden nuevas instancias.

### EFS Access Point

Un Access Point virtualiza un directorio raíz dentro del EFS y aplica una identidad POSIX fija a todos los accesos:

- **`posix_user`**: UID y GID que el sistema operativo impone en cada operación de fichero, independientemente del usuario real del proceso.
- **`root_directory.path`**: el proceso ve este directorio como `/`, no puede navegar fuera de él.
- **`creation_info`**: si el directorio no existe, EFS lo crea con el propietario y permisos indicados.

Esto permite que múltiples aplicaciones compartan el mismo EFS con aislamiento total: cada una tiene su propio Access Point apuntando a su directorio, con su UID/GID, sin posibilidad de acceder a los datos de las demás.

---

## Estructura del proyecto

```
labs/lab34/
├── README.md
└── aws/
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    ├── aws.s3.tfbackend
    └── modules/
        ├── vpc/
        │   ├── main.tf
        │   ├── variables.tf
        │   └── outputs.tf
        ├── ec2-client/
        │   ├── main.tf
        │   ├── variables.tf
        │   └── outputs.tf
        └── efs-share/
            ├── main.tf
            ├── variables.tf
            └── outputs.tf
```

---

## 1. Despliegue en AWS

```bash
# Obtén el ID de cuenta para el nombre del bucket de estado
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Desde labs/lab34/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$ACCOUNT_ID"
terraform plan
terraform apply
```

---

## Verificación final

### 2.1 Volumen EBS gp3

```bash
EBS_ID=$(terraform output -raw ebs_volume_id)

# Verifica tipo, IOPS y throughput
aws ec2 describe-volumes \
  --volume-ids "$EBS_ID" \
  --query 'Volumes[0].{Tipo:VolumeType,GB:Size,IOPS:Iops,ThroughputMBs:Throughput,Cifrado:Encrypted}'
# Debe mostrar: gp3, 100, 6000, 400, true

# Verifica que está adjunto a la instancia
aws ec2 describe-volumes \
  --volume-ids "$EBS_ID" \
  --query 'Volumes[0].Attachments[0].{Instancia:InstanceId,Dispositivo:Device,Estado:State}'
```

### 2.2 Política DLM

```bash
DLM_ID=$(terraform output -raw dlm_policy_id)
EBS_ID=$(terraform output -raw ebs_volume_id)

# Verifica que la política está habilitada y el rol asignado
aws dlm get-lifecycle-policy \
  --policy-id "$DLM_ID" \
  --query 'Policy.{Estado:State,Descripcion:Description,Rol:ExecutionRoleArn}'
# Debe mostrar: State=ENABLED

# Verifica las reglas: recursos objetivo, etiqueta selectora, horario y retención
aws dlm get-lifecycle-policy \
  --policy-id "$DLM_ID" \
  --query 'Policy.PolicyDetails.Schedules[0].{Horario:CreateRule.Times,Intervalo:CreateRule.Interval,Retencion:RetainRule.Count}'
# Debe mostrar: Times=["03:00"], Interval=24, Count=14

# Verifica que el volumen EBS tiene la etiqueta Backup=true que activa la política
aws ec2 describe-volumes \
  --volume-ids "$EBS_ID" \
  --query 'Volumes[0].Tags'

# Consulta snapshots creados por esta política (disponibles tras la primera ejecución a las 03:00 UTC)
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters \
    "Name=volume-id,Values=$EBS_ID" \
    "Name=tag:SnapshotCreator,Values=DLM" \
  --query 'Snapshots[*].{ID:SnapshotId,Estado:State,Iniciado:StartTime,Tamanyo:VolumeSize}' \
  --output table

# DLM no tiene un comando "ejecutar ahora" en la CLI. Para verificar sin esperar
# a las 03:00 UTC, crea un snapshot manual del volumen y comprueba que el ciclo
# de vida funciona cuando DLM ejecute su primera ventana.
aws ec2 create-snapshot \
  --volume-id "$EBS_ID" \
  --description "Snapshot manual de prueba - lab34" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=lab34},{Key=Origen,Value=manual}]" \
  --query '{ID:SnapshotId,Estado:State}'

# Lista todos los snapshots del volumen (manuales + los que cree DLM a las 03:00 UTC)
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=volume-id,Values=$EBS_ID" \
  --query 'Snapshots[*].{ID:SnapshotId,Estado:State,Fecha:StartTime,Descripcion:Description}' \
  --output table
```

### 2.3 EFS File System

```bash
EFS_ID=$(terraform output -raw efs_file_system_id)

# Estado general del file system
aws efs describe-file-systems \
  --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].{ID:FileSystemId,Estado:LifeCycleState,Cifrado:Encrypted,Throughput:ThroughputMode,Tamanyo:SizeInBytes.Value}'

# Mount targets (debe haber uno por AZ)
aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --query 'MountTargets[*].{ID:MountTargetId,AZ:AvailabilityZoneName,Subnet:SubnetId,IP:IpAddress,Estado:LifeCycleState}'
```

### 2.4 EFS Access Point

```bash
AP_ID=$(terraform output -raw efs_access_point_id)

aws efs describe-access-points \
  --access-point-id "$AP_ID" \
  --query 'AccessPoints[0].{ID:AccessPointId,Path:RootDirectory.Path,UID:PosixUser.Uid,GID:PosixUser.Gid,Estado:LifeCycleState}'
# Debe mostrar path=/app/data, UID=1001, GID=1001
```

### 2.5 Montaje del EFS desde la instancia (SSM)

```bash
# Los comandos terraform output se ejecutan en tu terminal local (donde corre
# Terraform), no dentro de la instancia EC2. Obtén los valores antes de abrir
# la sesión SSM y sustitúyelos manualmente en los comandos de la instancia.
INSTANCE_ID=$(terraform output -raw instance_id)
EFS_ID=$(terraform output -raw efs_file_system_id)
AP_ID=$(terraform output -raw efs_access_point_id)

echo "EFS_ID: $EFS_ID"
echo "AP_ID:  $AP_ID"

# Abre una sesión SSM (los valores de EFS_ID y AP_ID no existen en la instancia)
aws ssm start-session --target "$INSTANCE_ID"

# ── Dentro de la instancia (sustituye <EFS_ID> y <AP_ID> por los valores obtenidos arriba) ──

sudo dnf install -y amazon-efs-utils
sudo mkdir -p /mnt/efs

# Monta via Access Point con TLS.
# El mount helper de EFS acepta el ID en formato fsap-xxx, no el ARN.
sudo mount -t efs -o tls,accesspoint=<AP_ID> <EFS_ID>:/ /mnt/efs

# Verifica el montaje
df -h /mnt/efs
ls -la /mnt/efs   # muestra /app/data con UID/GID 1001

# Escribe un fichero — verifica que el propietario es UID 1001
echo "datos de la app" | sudo tee /mnt/efs/test.txt
ls -la /mnt/efs/test.txt

# ── Montaje permanente via /etc/fstab ─────────────────────────────────────────
# La entrada en /etc/fstab hace que el EFS se monte automaticamente en cada
# arranque. La opcion "_netdev" le indica al sistema que espere a que la red
# este disponible antes de intentar el montaje — imprescindible para NFS.
# "noresvport" mejora la disponibilidad reconectando desde un puerto no
# reservado si se pierde la conexion con el mount target.
# Sustituye <EFS_ID> y <AP_ID> por los valores obtenidos antes de la sesion SSM.

echo "<EFS_ID>:/ /mnt/efs efs _netdev,tls,accesspoint=<AP_ID>,noresvport 0 0" \
  | sudo tee -a /etc/fstab

# Verifica que la entrada es correcta antes de reiniciar
cat /etc/fstab

# Prueba el fstab sin reiniciar (desmonta y vuelve a montar todo lo de fstab)
sudo umount /mnt/efs
sudo mount -a

# Confirma que el EFS volvio a montarse
df -h /mnt/efs
```

---

## 3. Reto 1: EFS File System Policy (cifrado en transito obligatorio)

El EFS acepta conexiones NFS sin TLS por defecto. En entornos regulados es obligatorio cifrar los datos en tránsito. Una **File System Policy** (política de recursos del EFS) permite denegar todas las conexiones que no usen TLS, de forma similar a una bucket policy en S3.

### Requisitos

1. Añade un `aws_efs_file_system_policy` que aplique al file system creado por el módulo.
2. La política debe denegar cualquier acción EFS a cualquier principal si la conexión no usa TLS (`aws:SecureTransport = false`).
3. Añade un output `efs_policy` que muestre el JSON de la política aplicada.

> El recurso `aws_efs_file_system_policy` va en el **módulo raíz** (`aws/main.tf`) y referencia el file system mediante `module.efs_share.file_system_id`. No es necesario modificar el módulo `efs-share` para este reto.

### Criterios de éxito

- `aws efs describe-file-system-policy --file-system-id "$EFS_ID"` muestra la política con `Effect: Deny` y condición `aws:SecureTransport`.
- Un intento de montaje sin TLS (`-o notls`) desde la instancia falla con `access denied`.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: Segundo Access Point para un equipo diferente

El módulo `efs-share` gestiona el Access Point de la aplicación principal. Un segundo equipo necesita su propio espacio aislado en el mismo EFS con un UID/GID diferente y un directorio raíz propio.

### Requisitos

1. Añade un segundo `aws_efs_access_point` directamente en el **módulo raíz** (`aws/main.tf`), sin modificar el módulo `efs-share`.
2. Usa `posix_user.uid = 1002`, `posix_user.gid = 1002` y `root_directory.path = "/analytics/data"`.
3. El directorio debe crearse con `owner_uid = 1002`, `owner_gid = 1002` y `permissions = "750"`.
4. Añade un output `analytics_access_point_id` con el ID del nuevo Access Point.

> El segundo Access Point referencia el file system del módulo mediante `module.efs_share.file_system_id`.

### Criterios de éxito

- `aws efs describe-access-points` muestra dos Access Points: uno con path `/app/data` (UID 1001) y otro con `/analytics/data` (UID 1002).
- Puedes explicar por qué los dos Access Points garantizan que un proceso con UID 1001 no puede leer los ficheros creados por un proceso con UID 1002, aunque ambos usen el mismo EFS.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — EFS File System Policy

El recurso `aws_efs_file_system_policy` va en el **módulo raíz** (`aws/main.tf`). No es necesario modificar el módulo `efs-share` porque el file system ID está disponible como output (`module.efs_share.file_system_id`).

Añade en `aws/main.tf`:

```hcl
resource "aws_efs_file_system_policy" "tls_only" {
  file_system_id = module.efs_share.file_system_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonTLS"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "elasticfilesystem:*"
        Resource  = module.efs_share.file_system_arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}
```

Añade en `aws/outputs.tf`:

```hcl
output "efs_policy" {
  description = "Politica de recursos del EFS (requiere TLS)"
  value       = aws_efs_file_system_policy.tls_only.policy
}
```

Verifica:

```bash
terraform apply

EFS_ID=$(terraform output -raw efs_file_system_id)

# Verifica la política aplicada
aws efs describe-file-system-policy \
  --file-system-id "$EFS_ID" \
  --query Policy --output text | python3 -m json.tool

# Intento de montaje sin TLS — debe fallar con access denied
# (dentro de la instancia via SSM)
sudo mkdir /mnt/efs-notls
sudo mount -t nfs4 \
  -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  "$EFS_ID".efs.us-east-1.amazonaws.com:/ /mnt/efs-notls
```

### Solución Reto 2 — Segundo Access Point

El segundo Access Point va en el **módulo raíz** (`aws/main.tf`) referenciando el file system del módulo. No se modifica `modules/efs-share` porque añadir un recurso allí afectaría a todos los usos futuros del módulo; un Access Point adicional es un requisito de este deployment concreto.

Añade en `aws/main.tf`:

```hcl
resource "aws_efs_access_point" "analytics" {
  file_system_id = module.efs_share.file_system_id

  posix_user {
    uid = 1002
    gid = 1002
  }

  root_directory {
    path = "/analytics/data"
    creation_info {
      owner_uid   = 1002
      owner_gid   = 1002
      permissions = "750"
    }
  }

  tags = merge(local.tags, { Name = "${var.project}-analytics-ap" })
}
```

Añade en `aws/outputs.tf`:

```hcl
output "analytics_access_point_id" {
  description = "ID del EFS Access Point del equipo de analytics"
  value       = aws_efs_access_point.analytics.id
}
```

Verifica:

```bash
terraform apply

# Lista todos los Access Points del EFS
aws efs describe-access-points \
  --file-system-id "$(terraform output -raw efs_file_system_id)" \
  --query 'AccessPoints[*].{ID:AccessPointId,Path:RootDirectory.Path,UID:PosixUser.Uid,GID:PosixUser.Gid}'
# Debe mostrar dos entradas: /app/data (1001) y /analytics/data (1002)
```

El aislamiento entre Access Points es real a nivel de sistema de archivos POSIX: los ficheros creados por UID 1001 tienen `owner=1001` en los metadatos del EFS. Un proceso con UID 1002 que acceda al directorio `/app/data` recibirá `EACCES` porque los permisos `750` solo conceden acceso al propietario y su grupo — el kernel del cliente NFS aplica las reglas POSIX estándar.

---

## 5. Limpieza

```bash
# Desde labs/lab34/aws/
terraform destroy
```

> Si has montado el EFS en la instancia, desmóntalo antes de destruir:
> `sudo umount /mnt/efs`

---

## 6. LocalStack

```bash
localstack start -d

# Desde labs/lab34/localstack/
terraform fmt
terraform init
terraform apply
```

Consulta [localstack/README.md](localstack/README.md) para las instrucciones completas de verificación y la tabla de limitaciones.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| EBS gp3 iops/throughput | Rendimiento real desacoplado del tamaño | Parámetros aceptados; sin efecto real |
| DLM snapshots automáticos | Snapshots reales creados y rotados diariamente | No disponible en Community |
| EFS cifrado en reposo | Cifrado real con clave KMS gestionada | Configuración aceptada; sin cifrado real |
| EFS Elastic Throughput | Throughput escala hasta 3 GB/s lectura | Configuración aceptada; sin efecto real |
| EFS mount targets | Puntos NFS reales accesibles desde EC2 | Recurso creado; sin NFS real |
| EFS Access Point (POSIX) | Enforcement real en el kernel del cliente NFS | Configuración verificable; sin enforcement real |

---

## Buenas prácticas aplicadas

- Etiqueta los volúmenes EBS con `Backup = "true"` desde el primer despliegue para que la política DLM los capture desde el inicio.
- Despliega siempre un mount target por AZ. Si la AZ de un mount target falla, las instancias en otras AZs siguen accediendo al EFS sin interrupción.
- Usa `encrypted = true` en EFS aunque los datos no sean sensibles — el coste es cero y simplifica los requisitos de auditoría.
- Prefiere Access Points sobre montajes directos del root del EFS. El aislamiento POSIX previene errores de configuración que exponen datos entre aplicaciones.
- Para cargas de trabajo que requieren baja latencia (bases de datos, logs de alta frecuencia), usa EBS. EFS añade latencia de red NFS — es adecuado para ficheros de configuración, assets compartidos y datos de acceso concurrente.

---

## Recursos

- [EBS Volume Types — AWS](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [AWS DLM — Automate EBS Snapshots](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)
- [EFS Performance — Throughput Modes](https://docs.aws.amazon.com/efs/latest/ug/performance.html)
- [EFS Access Points](https://docs.aws.amazon.com/efs/latest/ug/efs-access-points.html)
- [Terraform: aws_ebs_volume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_volume)
- [Terraform: aws_dlm_lifecycle_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy)
- [Terraform: aws_efs_file_system](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system)
- [Terraform: aws_efs_access_point](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point)
