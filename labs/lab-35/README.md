# Laboratorio 35: Base de Datos Relacional Crítica: RDS Multi-AZ y Replicación

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 8 — Almacenamiento y Bases de Datos con Terraform](../../modulos/modulo-08/README.md)


## Visión general

En este laboratorio aprovisinarás una base de datos PostgreSQL de nivel empresarial con alta disponibilidad, seguridad en capas y escalado de lectura. La capa de aplicación es un CRM Dashboard Flask que se despliega en un **Auto Scaling Group** detrás de un **Application Load Balancer** y demuestra en tiempo real el failover de RDS Multi-AZ, la AZ activa de la primaria y la lectura desde la réplica.

Aprenderás a configurar un **DB Subnet Group** y un **Parameter Group** que fuerza SSL, a desplegar RDS con **Multi-AZ** para failover automático en menos de 60 segundos, a habilitar la **autenticación IAM** con tokens efímeros, a gestionar credenciales con **Secrets Manager** cifrado con CMK propia, y a crear una **Read Replica** en una AZ distinta para descargar lecturas.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un `aws_db_subnet_group` en subnets privadas y entender por qué RDS requiere subnets en múltiples AZs
- Configurar un `aws_db_parameter_group` con `rds.force_ssl = 1` para rechazar conexiones sin cifrado
- Desplegar `aws_db_instance` con `multi_az = true` y comprender el mecanismo de failover automático
- Activar `max_allocated_storage` para el autoscaling de almacenamiento sin tiempo de inactividad
- Habilitar `iam_database_authentication_enabled` y generar tokens de autenticación temporales con la CLI
- Gestionar la contraseña maestra con `aws_secretsmanager_secret` cifrado con CMK propia de KMS
- Crear una `aws_db_instance` como read replica con `replicate_source_db` en una AZ distinta
- Desplegar un `aws_launch_template` + `aws_autoscaling_group` con target tracking scaling
- Observar el cambio de AZ de la primaria en la aplicación web antes y después de un failover

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre RDS, KMS, Secrets Manager, IAM, EC2, S3 y Auto Scaling

---

## Arquitectura

```
Internet
    │ HTTP :80
    ▼
┌───────────────────────────────────────────────┐
│  Application Load Balancer (público, multi-AZ)│
│  lab35-alb  ·  us-east-1a / us-east-1b        │
└────────────────────┬──────────────────────────┘
                     │ HTTP :8080
          ┌──────────┴──────────┐
          ▼                     ▼
  ┌───────────────┐     ┌───────────────┐
  │  EC2 t4g.small│     │  EC2 t4g.small│  ← Auto Scaling Group
  │  us-east-1a   │     │  us-east-1b   │    min=1  desired=2  max=4
  │  Flask CRM    │     │  Flask CRM    │    target tracking CPU 60%
  └───────┬───────┘     └───────┬───────┘
          └──────────┬──────────┘
                     │
          ┌──────────┴────────────────────┐
          │                               │
          ▼ escrituras                    ▼ lecturas
  ┌────────────────┐             ┌────────────────────┐
  │  RDS PRIMARY   │  async      │  READ REPLICA      │
  │  us-east-1a    │────────────►│  us-east-1c        │
  │  db.t4g.small  │             │  db.t4g.small      │
  └───────┬────────┘             └────────────────────┘
          │ sync (Multi-AZ)
          ▼
  ┌────────────────┐
  │  RDS STANDBY   │
  │  us-east-1b    │
  │  (failover)    │
  └────────────────┘

  ┌────────────────┐   ┌─────────────────────────┐
  │  Secrets Mgr   │   │  S3 (artefactos app)    │
  │  KMS CMK       │   │  app.py descargado      │
  └────────────────┘   │  en cada arranque       │
                       └─────────────────────────┘
```

---

## Conceptos Clave

### DB Subnet Group: enrutamiento de red de RDS

Un `aws_db_subnet_group` es el contrato de red de RDS: le indica al motor en qué subnets (y por tanto en qué AZs) puede colocar la instancia primaria y la standby de Multi-AZ. Debe incluir subnets en al menos dos AZs distintas. Sin él, RDS no puede desplegarse en una VPC.

```hcl
resource "aws_db_subnet_group" "main" {
  name       = "lab35-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]
}
```

### Parameter Group: SSL forzado

Un `aws_db_parameter_group` sobreescribe los parámetros del motor PostgreSQL. El parámetro `rds.force_ssl = 1` hace que el servidor rechace cualquier intento de conexión que no use TLS/SSL:

```
FATAL: no pg_hba.conf entry for host "...", user "dbadmin", database "appdb", no encryption
```

Usar un Parameter Group propio (en lugar del `default.postgres15`) es obligatorio para poder modificar parámetros sin afectar otras instancias.

### Multi-AZ: alta disponibilidad y failover automático

Con `multi_az = true`, RDS despliega una instancia standby en una AZ distinta y replica los datos de forma síncrona. El failover es automático en menos de 60 segundos y transparente para la aplicación: el endpoint DNS no cambia, solo la AZ donde corre la primaria.

```
┌──────────────────────────────────────┐
│  Endpoint DNS (no cambia en failover)│
│  lab35-main.xxx.us-east-1.rds.aws    │
└───────────────┬──────────────────────┘
                │
    ┌───────────┴────────────┐
    │                        │
┌───▼────────────┐    ┌──────▼─────────────┐
│  PRIMARY       │    │  STANDBY (Multi-AZ)│
│  us-east-1a    │◄───│  us-east-1b        │
│  (escrituras)  │sync│  (no sirve lecturas│
└────────────────┘    │   hasta failover)  │
                      └────────────────────┘
```

El standby **no sirve lecturas** en condiciones normales — solo existe para failover. Para escalar lecturas se usa la Read Replica.

### Auto Scaling Group + Launch Template

El ASG gestiona el ciclo de vida de las instancias EC2 de la capa de aplicación:

- **`aws_launch_template`**: define AMI, tipo de instancia, perfil IAM y `user_data`. Cada nueva versión del template puede aplicarse mediante un *instance refresh* sin tiempo de inactividad.
- **Target Tracking Scaling**: el ASG escala para mantener la CPU media en el 60%. AWS gestiona automáticamente el cooldown entre escalados.
- **`health_check_type = "ELB"`**: el ASG reemplaza instancias que el ALB marca como `unhealthy` (endpoint `/health` devuelve un código distinto de 200), no solo instancias apagadas.
- **`health_check_grace_period = 600`**: da 10 minutos a cada instancia para completar el `user_data` (instalar dependencias, esperar a RDS, arrancar Flask) antes de evaluar su salud.

```hcl
resource "aws_autoscaling_policy" "cpu" {
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app.name
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
```

### S3 para artefactos de la aplicación

El código de la aplicación (`app.py`) se almacena en S3 en lugar de embeberse en el `user_data`. Esto resuelve el límite de 16 KB de EC2 `user_data` y permite actualizar la app sin modificar el Launch Template:

```bash
# Actualizar la app sin recrear el ASG:
# 1. Modifica app.py
# 2. terraform apply  → sube la nueva versión a S3
# 3. Lanza un instance refresh en el ASG
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name lab35-asg \
  --preferences '{"MinHealthyPercentage":50}'
```

### Autoscaling de almacenamiento

`max_allocated_storage` activa el autoscaling: cuando el espacio libre cae por debajo del 10% durante 5 minutos, RDS amplía el volumen automáticamente hasta el límite configurado sin tiempo de inactividad.

```hcl
allocated_storage     = 20    # inicial
max_allocated_storage = 100   # máximo alcanzable automáticamente
```

### IAM Database Authentication: tokens temporales

Con `iam_database_authentication_enabled = true`, las aplicaciones pueden autenticarse en PostgreSQL usando un token IAM en lugar de una contraseña estática. El token caduca a los 15 minutos:

```bash
aws rds generate-db-auth-token \
  --hostname ENDPOINT --port 5432 \
  --region us-east-1 --username dbadmin
```

### Secrets Manager: credenciales centralizadas con CMK

El secreto se cifra con una Customer Managed Key de KMS. Esto permite auditar cada operación de descifrado en CloudTrail y revocar el acceso deshabilitando la clave. La instancia EC2 necesita tanto `secretsmanager:GetSecretValue` como `kms:Decrypt` sobre la CMK:

```python
import boto3, json
secret = boto3.client('secretsmanager').get_secret_value(SecretId='lab35/db/master-password')
creds  = json.loads(secret['SecretString'])
# creds['host'], creds['port'], creds['password'], etc.
```

### Read Replica: escalado de lecturas

Copia de solo lectura con replicación asíncrona. El CRM Dashboard dirige todas las consultas SELECT a la réplica y las escrituras al primario:

```
┌─────────────────┐   async   ┌──────────────────────┐
│  PRIMARY        │──────────►│  READ REPLICA        │
│  us-east-1a     │           │  us-east-1c          │
│  escrituras     │           │  lecturas (CRM)      │
└─────────────────┘           └──────────────────────┘
```

La replicación es asíncrona — puede haber un lag de milisegundos. Para datos que requieren consistencia inmediata, usa siempre el endpoint principal.

---

## Estructura del proyecto

```
labs/lab35/
├── README.md
└── aws/
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    ├── app.py
    ├── user_data.sh.tpl
    └── aws.s3.tfbackend
```

---

## 1. Despliegue en AWS

```bash
# Obtén el ID de cuenta para el backend
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Desde labs/lab35/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$ACCOUNT_ID"
terraform plan
terraform apply
```

> **Nota**: `terraform apply` puede tardar entre 20 y 30 minutos. RDS Multi-AZ y la read replica requieren tiempo para aprovisionar y sincronizar los volúmenes. El ASG espera a que RDS esté disponible antes de lanzar instancias.

Una vez completado, obtén la URL de la aplicación:

```bash
terraform output app_url
```

---

## Verificación final

### 2.1 Aplicación web — CRM Dashboard

```bash
APP_URL=$(terraform output -raw app_url)

# Health check
curl -s "$APP_URL/health"
# Debe devolver: {"status": "ok"}

# Abre el dashboard en el navegador
echo "$APP_URL"
```

El dashboard muestra:
- **Tarjetas de estadísticas**: total de clientes, distribución por plan y MRR total
- **Estado de conexiones**: primaria (escritura) y réplica (lectura) con indicador verde/rojo
- **Card RDS Multi-AZ**: AZ actual de la instancia primaria, estado y botón **Failover**
- **Tabla de clientes**: 15 clientes precargados, filtrables por nombre/email/país y plan

### 2.2 Instancia RDS y Multi-AZ

```bash
# Estado, AZ y configuración de la primaria
aws rds describe-db-instances \
  --db-instance-identifier lab35-main \
  --query 'DBInstances[0].{Estado:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,AZStandby:SecondaryAvailabilityZone,Clase:DBInstanceClass,Motor:EngineVersion}'

# Endpoint DNS
aws rds describe-db-instances \
  --db-instance-identifier lab35-main \
  --query 'DBInstances[0].Endpoint'
```

### 2.3 Auto Scaling Group

```bash
# Estado del ASG y número de instancias
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names lab35-asg \
  --query 'AutoScalingGroups[0].{Min:MinSize,Deseado:DesiredCapacity,Max:MaxSize,Instancias:Instances[*].{ID:InstanceId,Estado:LifecycleState,Health:HealthStatus}}'

# Instancias registradas en el target group del ALB
TG_ARN=$(aws elbv2 describe-target-groups \
  --names lab35-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,Puerto:Target.Port,Estado:TargetHealth.State}'
# Ambas instancias deben aparecer como "healthy"
```

### 2.4 SSL forzado (Parameter Group)

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name lab35-pg15 \
  --query 'Parameters[?ParameterName==`rds.force_ssl`].{Nombre:ParameterName,Valor:ParameterValue,Fuente:Source}'
# Valor debe ser "1"
```

### 2.5 Autoscaling de almacenamiento

```bash
aws rds describe-db-instances \
  --db-instance-identifier lab35-main \
  --query 'DBInstances[0].{Asignado:AllocatedStorage,MaxAsignado:MaxAllocatedStorage,Tipo:StorageType,Cifrado:StorageEncrypted}'
# Debe mostrar: 20, 100, gp3, true
```

### 2.6 Secrets Manager

```bash
SECRET=$(terraform output -raw secret_name)

# Describe el secreto (cifrado con CMK)
aws secretsmanager describe-secret \
  --secret-id "$SECRET" \
  --query '{Nombre:Name,KMS:KmsKeyId,RotacionActiva:RotationEnabled}'

# Recupera las credenciales
aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --query SecretString --output text | python3 -m json.tool
# Debe mostrar: engine, host, port, dbname, username, password
```

### 2.7 IAM Database Authentication

```bash
DB_HOST=$(terraform output -raw db_host)
DB_USER=$(terraform output -raw db_username)

# Genera un token IAM (caduca en 15 minutos)
TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$DB_HOST" \
  --port 5432 \
  --region us-east-1 \
  --username "$DB_USER")

echo "Token generado (primeros 50 chars): ${TOKEN:0:50}..."

# El token se usa como contraseña desde una instancia en la misma VPC:
# PGPASSWORD="$TOKEN" psql "host=$DB_HOST port=5432 dbname=appdb user=$DB_USER sslmode=require"
```

### 2.8 Read Replica

```bash
# Estado y AZ de la réplica
aws rds describe-db-instances \
  --db-instance-identifier lab35-replica \
  --query 'DBInstances[0].{Estado:DBInstanceStatus,AZ:AvailabilityZone,Fuente:ReadReplicaSourceDBInstanceIdentifier}'

# Lag de replicación en segundos (0 = sin lag)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value=lab35-replica \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Average \
  --query 'Datapoints[*].Average'
```

### 2.9 Demostración de failover Multi-AZ

El CRM Dashboard incluye un botón **⚡ Failover** que dispara un `reboot_db_instance` con `ForceFailover=True` desde la propia aplicación.

**Procedimiento**:

1. Abre el dashboard en el navegador: `terraform output app_url`
2. Anota la AZ mostrada en el card **RDS Multi-AZ** (p. ej. `us-east-1a`)
3. Pulsa el botón **⚡ Failover** y confirma el diálogo
4. El banner verde indica que el failover se ha iniciado
5. Espera ~60 segundos y recarga la página
6. La AZ del card debe haber cambiado a la AZ del standby (p. ej. `us-east-1b`)
7. El endpoint DNS de RDS no ha cambiado — la aplicación siguió funcionando

Verifica los eventos de RDS para confirmar el failover:

```bash
aws rds describe-events \
  --source-identifier lab35-main \
  --source-type db-instance \
  --duration 30 \
  --query 'Events[*].{Hora:Date,Mensaje:Message}' \
  --output table
```

Debes ver: `Multi-AZ instance failover started` → `DB instance restarted` → `Multi-AZ instance failover completed` (~55 segundos).

---

## 3. Reto 1: Enhanced Monitoring

RDS ofrece métricas estándar a nivel de hipervisor en CloudWatch. **Enhanced Monitoring** proporciona métricas del sistema operativo (CPU por proceso, memoria libre, IOPS de disco) con granularidad de hasta 1 segundo — imprescindible para diagnosticar cuellos de botella reales.

### Requisitos

1. Crea un rol IAM con la política `AmazonRDSEnhancedMonitoringRole` que permita al agente de RDS enviar métricas a CloudWatch.
2. Configura `monitoring_interval = 60` en `aws_db_instance.main` (valores válidos: 1, 5, 10, 15, 30, 60 segundos).
3. Asocia el rol con `monitoring_role_arn`.
4. Añade un output `monitoring_role_arn`.

### Criterios de éxito

- `aws rds describe-db-instances --query '..MonitoringInterval'` muestra `60`
- La pestaña **Monitoring** de `lab35-main` en la consola RDS muestra métricas de OS: `Active Memory`, `CPU User`, `Free Memory`, etc.
- Puedes explicar la diferencia entre métricas de hipervisor (CloudWatch estándar) y métricas de agente OS (Enhanced Monitoring)

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: Snapshot manual y restauración

`backup_retention_period = 7` habilita los backups automáticos y la restauración a cualquier punto en el tiempo dentro de esa ventana. Practicar la restauración antes de necesitarla es esencial en producción.

### Requisitos

1. Crea un snapshot manual de la instancia principal con `aws rds create-db-snapshot`
2. Espera a que el snapshot esté en estado `available`
3. Restaura el snapshot en una instancia nueva `lab35-restored`
4. Verifica que arranca y contiene la base de datos `appdb`
5. Elimina la instancia restaurada al terminar

> Este reto se realiza completamente con la CLI — no es necesario modificar Terraform.

### Criterios de éxito

- `aws rds describe-db-snapshots` muestra el snapshot con `Status: available`
- `aws rds describe-db-instances --db-instance-identifier lab35-restored` muestra estado `available`
- La instancia restaurada contiene la tabla `customers` con los datos originales

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — Enhanced Monitoring

Añade en `aws/main.tf`:

```hcl
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
```

Modifica `aws_db_instance.main` añadiendo:

```hcl
monitoring_interval = 60
monitoring_role_arn = aws_iam_role.rds_monitoring.arn
```

Añade en `aws/outputs.tf`:

```hcl
output "monitoring_role_arn" {
  description = "ARN del rol IAM para Enhanced Monitoring"
  value       = aws_iam_role.rds_monitoring.arn
}
```

Verifica:

```bash
terraform apply

aws rds describe-db-instances \
  --db-instance-identifier lab35-main \
  --query 'DBInstances[0].{Intervalo:MonitoringInterval,RolARN:MonitoringRoleArn}'
```

### Solución Reto 2 — Snapshot manual y restauración

```bash
# Paso 1: Crea el snapshot manual
aws rds create-db-snapshot \
  --db-instance-identifier lab35-main \
  --db-snapshot-identifier lab35-manual-snap-01

# Paso 2: Espera a que esté disponible (5-10 minutos)
aws rds wait db-snapshot-available \
  --db-snapshot-identifier lab35-manual-snap-01

aws rds describe-db-snapshots \
  --db-snapshot-identifier lab35-manual-snap-01 \
  --query 'DBSnapshots[0].{ID:DBSnapshotIdentifier,Estado:Status,GB:AllocatedStorage,Fecha:SnapshotCreateTime}'

# Paso 3: Restaura en una instancia nueva
DB_SUBNET_GROUP=$(aws rds describe-db-instances \
  --db-instance-identifier lab35-main \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier lab35-restored \
  --db-snapshot-identifier lab35-manual-snap-01 \
  --db-instance-class db.t4g.small \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --no-publicly-accessible

# Paso 4: Espera a que esté disponible
aws rds wait db-instance-available \
  --db-instance-identifier lab35-restored

aws rds describe-db-instances \
  --db-instance-identifier lab35-restored \
  --query 'DBInstances[0].{ID:DBInstanceIdentifier,Estado:DBInstanceStatus,Motor:EngineVersion}'

# Limpieza
aws rds delete-db-instance \
  --db-instance-identifier lab35-restored \
  --skip-final-snapshot
```

---

## 5. Limpieza

```bash
# Desde labs/lab35/aws/
terraform destroy
```

> `terraform destroy` puede tardar 15-20 minutos. RDS espera a que la primaria, la réplica y el Multi-AZ standby estén completamente detenidos antes de eliminarlos.

---

## 6. Gestión de Secretos: configurar la rotación automática

La rotación automática requiere una Lambda de rotación. Para desplegarla desde Serverless Application Repository:

> **Requisito previo — conectividad de la Lambda a la VPC**: la Lambda de rotación necesita acceso de red a la instancia RDS (puerto 5432) y a la API de Secrets Manager. Para ello debe desplegarse dentro de la VPC del laboratorio, en las subnets privadas, con un Security Group que permita el tráfico saliente a RDS y a Secrets Manager (ya sea a través del NAT Gateway o mediante VPC Endpoints). Sin esta configuración la rotación fallará con un error de timeout al intentar conectar con la base de datos.

```bash
# Paso 1: Crea el change set desde Serverless Application Repository
CHANGE_SET_ID=$(aws serverlessrepo create-cloud-formation-change-set \
  --application-id arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser \
  --stack-name secrets-rotation-pg \
  --parameter-overrides \
    '[{"Name":"endpoint","Value":"https://secretsmanager.us-east-1.amazonaws.com"},
      {"Name":"functionName","Value":"SecretsManagerRDSPostgreSQLRotation"}]' \
  --capabilities CAPABILITY_IAM CAPABILITY_RESOURCE_POLICY \
  --query ChangeSetId --output text)

# Paso 2: Ejecuta el change set
aws cloudformation execute-change-set --change-set-name "$CHANGE_SET_ID"

# Paso 3: Espera a que el stack esté desplegado (~2 minutos)
aws cloudformation wait stack-create-complete \
  --stack-name secrets-rotation-pg

# Paso 4: Obtén el ARN de la Lambda desplegada
ROTATION_LAMBDA_ARN=$(aws lambda get-function \
  --function-name SecretsManagerRDSPostgreSQLRotation \
  --query 'Configuration.FunctionArn' --output text)

echo "Lambda ARN: $ROTATION_LAMBDA_ARN"

# Paso 5: Aplica con rotación habilitada
terraform apply -var="rotation_lambda_arn=$ROTATION_LAMBDA_ARN"
```

---

## Buenas prácticas aplicadas

- Nunca uses `publicly_accessible = true` en instancias de producción. RDS debe ser accesible solo desde dentro de la VPC a través de subnets privadas.
- Activa `deletion_protection = true` en producción para evitar borrados accidentales con `terraform destroy`.
- Usa `skip_final_snapshot = false` con `final_snapshot_identifier` en producción — el snapshot final es la última línea de defensa ante una eliminación accidental.
- Prefiere IAM Database Authentication sobre contraseñas estáticas en EC2, ECS o Lambda — los tokens son efímeros y no necesitan rotación explícita.
- Monitoriza `ReplicaLag` en CloudWatch. Un lag creciente indica que la primaria escribe más rápido de lo que la réplica puede procesar.
- El standby Multi-AZ **no sirve lecturas** — solo existe para failover. Para escalar lecturas usa exclusivamente la Read Replica.
- Cifra los secretos con una CMK propia en lugar de la clave gestionada por AWS. Esto permite auditar cada operación de descifrado en CloudTrail y revocar el acceso deshabilitando la clave.
- Expón el botón de failover **solo en entornos de laboratorio**. En producción, el failover manual debe requerir autenticación adicional o ejecutarse desde herramientas de runbook.

---

## Recursos

- [RDS Multi-AZ — AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html)
- [RDS IAM Database Authentication — AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)
- [Secrets Manager Rotation — AWS](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)
- [RDS Storage Autoscaling — AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.StorageTypes.html#USER_PIOPS.Autoscaling)
- [EC2 Auto Scaling Target Tracking — AWS](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Terraform: aws_db_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance)
- [Terraform: aws_autoscaling_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group)
- [Terraform: aws_secretsmanager_secret_rotation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_rotation)
