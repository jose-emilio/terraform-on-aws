# Sección 3 — Amazon RDS y Aurora

> [← Volver al índice](./README.md) | [Siguiente →](./04_dynamodb.md)

---

## 1. ¿Por qué RDS en lugar de instalar la BD tú mismo?

Imagina que cada vez que necesitas una base de datos, tuvieras que aprovisionar un servidor, instalar el motor, configurar backups, aplicar parches de seguridad, montar la réplica standby, y vigilarlo 24/7. RDS es el equipo que hace todo eso por ti.

> **El profesor explica:** "RDS no es magia: es responsabilidad compartida. AWS gestiona el hardware, el sistema operativo, el motor y la disponibilidad. Tú gestionas los datos, el esquema y las queries. Esa línea de corte es la que libera a tu equipo para construir producto en lugar de administrar servidores."

Amazon RDS soporta seis motores: MySQL 5.7/8.0, PostgreSQL 13-16, MariaDB, Oracle, SQL Server e IBM DB2. Multi-AZ mantiene una réplica síncrona en otra AZ con failover automático (típicamente entre 60 y 120 segundos) usando el mismo endpoint DNS, por lo que la aplicación no necesita cambiar nada.

```
┌─────────────────────────────────────────────────────────────┐
│                        RDS Multi-AZ                         │
│                                                             │
│   us-east-1a              us-east-1b                        │
│  ┌──────────┐             ┌──────────┐                      │
│  │  PRIMARY │◄────sync────│ STANDBY  │                      │
│  └──────────┘             └──────────┘                      │
│        ▲                       ▲                            │
│        └────── DNS endpoint ───┘                            │
│              (no cambia en failover)                        │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. `aws_db_subnet_group` — Aislamiento de Red

Una instancia RDS vive dentro de tu VPC, en subnets privadas. AWS elige en cuál AZ despliega primary y standby.

```hcl
resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-db-subnet"
  description = "Subnets for RDS instances"

  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id,
  ]

  tags = {
    Name = "${var.project}-db-subnet-group"
    Env  = var.environment
  }
}
```

**Reglas críticas:**
- Mínimo 2 subnets en AZs distintas (requisito de Multi-AZ).
- Solo subnets privadas — `publicly_accessible = false` siempre.
- La comunicación llega desde el tier de aplicación vía Security Groups.

---

## 3. `aws_db_parameter_group` — Tuning Declarativo del Motor

Los Parameter Groups permiten modificar variables internas de la BD — `max_connections`, logging SQL, zona horaria — directamente en Terraform, sin acceso SSH al servidor.

```hcl
resource "aws_db_parameter_group" "postgres" {
  name   = "${var.project}-pg16-params"
  family = "postgres16"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"        # Log queries > 1s
    apply_method = "pending-reboot"   # Parámetro estático
  }

  tags = local.common_tags
}
```

> **Nota:** Los parámetros dinámicos se aplican inmediatamente; los estáticos (como `shared_buffers`) requieren reinicio. Nunca modifiques el grupo `default.*` — es de solo lectura.

---

## 4. `aws_db_instance` — La Instancia Central

```hcl
resource "aws_db_instance" "main" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.r6g.xlarge"

  # Storage
  allocated_storage     = 100
  max_allocated_storage = 500   # Habilita Storage Auto Scaling
  storage_type          = "gp3"
  storage_encrypted     = true

  # Alta disponibilidad
  multi_az = true

  # Red
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  # Credenciales
  username = "admin_user"
  password = var.db_password   # Mejor: manage_master_user_password = true

  # Protección
  deletion_protection = true
  publicly_accessible = false
}
```

**`max_allocated_storage`** activa Storage Auto Scaling: cuando el espacio libre cae por debajo del 10%, RDS crece automáticamente sin downtime hasta el límite configurado.

---

## 5. Tipos de Storage: gp3 vs io1/io2

| Tipo | IOPS base | IOPS máximo | Throughput | Mejor para |
|------|-----------|-------------|------------|------------|
| **gp3** | 3,000 | 16,000 | 1,000 MB/s | 90% de los workloads |
| **io1** | Provisioned | 64,000 | 1,000 MB/s | Bases de datos OLTP intensivas |
| **io2 Block Express** | Provisioned | 256,000 | 4,000 MB/s | SAP HANA, Oracle crítico |

> **El profesor explica:** "La ventaja de gp3 sobre gp2 es que IOPS y throughput son independientes del tamaño. Con gp2 necesitabas 3.3 TB para tener 10,000 IOPS. Con gp3, pagas solo por los IOPS que necesitas, independientemente del tamaño del volumen."

---

## 6. Read Replicas — Escalado de Lectura

Las Read Replicas se crean con `replicate_source_db`, no configurando `multi_az`:

```hcl
resource "aws_db_instance" "read_replica" {
  replicate_source_db = aws_db_instance.main.identifier
  instance_class      = "db.r6g.xlarge"
  availability_zone   = "us-east-1b"
  storage_encrypted   = true
  kms_key_id          = aws_kms_key.rds.arn

  # Monitoreo obligatorio en réplicas de producción
  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  tags = {
    Name = "rds-read-replica"
    Role = "reader"
  }
}
```

| Tipo | Replicación | Uso principal | Se puede promover |
|------|-------------|---------------|-------------------|
| **Same-Region** | Asíncrona | Distribuir lecturas | Sí |
| **Cross-Region** | Asíncrona | DR y latencia global | Sí |
| **Multi-AZ Standby** | Síncrona | Failover automático | No (es HA, no lectura) |

---

## 7. Cifrado: At-Rest e In-Transit

```hcl
resource "aws_db_instance" "encrypted" {
  # At-rest: AES-256 con CMK
  storage_encrypted  = true
  kms_key_id         = aws_kms_key.rds.arn

  # Certificado TLS actualizado
  ca_cert_identifier = "rds-ca-rsa2048-g1"
}

# In-transit: forzar SSL en PostgreSQL
resource "aws_db_parameter_group" "force_ssl" {
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"   # Rechaza conexiones no cifradas
  }
}
```

> **Importante:** El cifrado at-rest se define en la creación de la instancia y es inmutable. No puedes cifrar una instancia no cifrada en caliente — necesitas crear un snapshot, cifrarlo y restaurar a una nueva instancia.

---

## 8. IAM Database Authentication + Secrets Manager

```hcl
# IAM Auth: tokens temporales en lugar de contraseñas fijas
resource "aws_db_instance" "iam_auth" {
  # ...
  iam_database_authentication_enabled = true
}

# Secrets Manager: rotación automática de credenciales
resource "aws_secretsmanager_secret" "rds" {
  name                    = "rds/primary/credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_rotation" "rds" {
  secret_id           = aws_secretsmanager_secret.rds.id
  rotation_lambda_arn = aws_lambda_function.rotator.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

**IAM Authentication** genera tokens temporales con vida de 15 minutos. Ideal para microservicios y Lambda: nunca almacenas credenciales en variables de entorno. Límite: 200 nuevas conexiones por segundo (usar Secrets Manager para casos de alta concurrencia).

**Alternativa recomendada:** `manage_master_user_password = true` en `aws_db_instance` delega la rotación directamente a Secrets Manager sin Lambda intermediaria.

---

## 9. Backups: Automatizados y Snapshots Manuales

```hcl
resource "aws_db_instance" "backup_config" {
  # Backups automáticos con PITR (0 = deshabilitado)
  backup_retention_period  = 35             # Máximo 35 días
  backup_window            = "03:00-04:00"  # UTC
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # PITR: granularidad de 5 minutos
}

# Snapshot manual (persiste tras eliminar la instancia)
resource "aws_db_snapshot" "manual" {
  db_instance_identifier = aws_db_instance.backup_config.identifier
  db_snapshot_identifier = "pre-migration-snapshot"
}
```

| Tipo | Retención | Persiste tras delete | Cross-region | PITR |
|------|-----------|----------------------|--------------|------|
| Automatizado | 0-35 días | No | Con AWS Backup | Sí |
| Manual | Sin límite | Sí | Sí (copy) | No |

---

## 10. Enhanced Monitoring + Performance Insights

```hcl
resource "aws_iam_role" "rds_monitoring" {
  name               = "rds-enhanced-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_mon.json
}

resource "aws_iam_role_policy_attachment" "rds_mon" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "monitored" {
  # ...

  # Enhanced Monitoring: métricas a nivel OS (1-60 seg)
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Performance Insights: análisis de carga SQL
  performance_insights_enabled          = true
  performance_insights_retention_period = 731   # 2 años
}
```

> **El profesor explica:** "Enhanced Monitoring va más allá de CloudWatch: te da métricas a nivel de proceso del sistema operativo. Performance Insights es como tener un DBA mirando qué query está bloqueando la base de datos en este momento. La retención de 731 días (2 años) permite análisis de tendencias históricas."

---

## 11. RDS Proxy — Connection Pooling para Serverless

El patrón Lambda + RDS crea un problema: cada invocación Lambda abre una nueva conexión al motor. Con miles de invocaciones concurrentes, agota `max_connections`. RDS Proxy agrega un pool de conexiones entre Lambda y RDS.

```hcl
resource "aws_db_proxy" "rds" {
  name                   = "rds-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = aws_db_subnet_group.main.subnet_ids
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = true

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "REQUIRED"
    secret_arn  = aws_secretsmanager_secret.rds.arn
  }
}
```

**Beneficios:**
- Reduce conexiones abiertas al motor hasta un 99%.
- Failover 66% más rápido que la conexión directa.
- Soporta MySQL y PostgreSQL.
- Se integra con IAM Auth y Secrets Manager nativamente.

---

## 12. `aws_rds_cluster` — Amazon Aurora

Aurora es un motor cloud-native compatible con MySQL y PostgreSQL, con arquitectura de storage distribuido que ofrece 5x el rendimiento de MySQL estándar.

```hcl
resource "aws_rds_cluster" "aurora" {
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.04.0"

  cluster_identifier          = "prod-aurora"
  master_username             = "admin"
  manage_master_user_password = true   # Secrets Manager automático

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Seguridad
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  # Backups
  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"

  # Protección producción
  skip_final_snapshot = false
  deletion_protection = true
}
```

**Aurora vs RDS estándar:**

| Característica | RDS Estándar | Aurora |
|----------------|--------------|--------|
| Storage auto-scaling | Hasta 64 TiB | Hasta 128 TiB |
| Réplicas de lectura | Hasta 5 | Hasta 15 |
| Failover | < 60 segundos | < 30 segundos |
| Copias en storage | 2 (Multi-AZ) | 6 (3 AZs) |
| Rendimiento vs MySQL | 1x | 5x |
| Serverless v2 | No | Sí (ACU min/max) |

---

## 13. Event Subscriptions vía SNS

```hcl
resource "aws_db_event_subscription" "alerts" {
  name      = "rds-event-alerts"
  sns_topic = aws_sns_topic.rds_alerts.arn

  source_type = "db-instance"
  source_ids  = [aws_db_instance.main.identifier]

  event_categories = [
    "availability",
    "failover",
    "failure",
    "maintenance",
  ]
}
```

Las categorías de eventos cubren: `availability`, `failover`, `backup`, `configuration change`, `deletion`, `failure`, `maintenance`, `notification`, `recovery`. Puedes suscribirte a todas o filtrar por tipo.

---

## 14. Best Practices: Checklist de Gobernanza

**Infraestructura mínima en Terraform:**

```
✓ aws_db_subnet_group        (subnets privadas, 2+ AZs)
✓ aws_security_group         (solo app tier ingress)
✓ aws_kms_key                (CMK para encryption)
✓ aws_db_parameter_group     (tuning y SSL forzado)
✓ aws_db_instance            (Multi-AZ, gp3, encrypted)
✓ aws_db_instance            (read_replica para lectura)
✓ aws_iam_role               (Enhanced Monitoring)
✓ aws_db_proxy               (si usas Lambda)
✓ aws_db_event_subscription  (alertas SNS)
```

**Configuraciones obligatorias en producción:**

```hcl
storage_encrypted                   = true
publicly_accessible                 = false
deletion_protection                 = true
iam_database_authentication_enabled = true
manage_master_user_password         = true
backup_retention_period             = 35    # Máximo
monitoring_interval                 = 60    # Enhanced Monitoring
performance_insights_enabled        = true
```

> **El profesor resume:** "Si cometiste un error al configurar RDS sin cifrado, sin Multi-AZ o sin backups en producción, no hay rollback fácil. Terraform no puede cambiar `storage_encrypted` en una instancia existente — necesitas recrear. Por eso el ciclo correcto es: diseña el módulo con todas las configuraciones de seguridad desde el día uno."

---

## 15. Módulo Completo: RDS PostgreSQL Seguro

```hcl
module "rds_postgres" {
  source = "./modules/rds"

  project     = var.project
  environment = "production"

  # Motor
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.r6g.xlarge"

  # Storage con Auto Scaling
  allocated_storage     = 100
  max_allocated_storage = 1000
  storage_type          = "gp3"

  # Red
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_ids = [module.app.security_group_id]

  # HA
  multi_az = true

  # Seguridad
  storage_encrypted                   = true
  kms_key_arn                         = aws_kms_key.rds.arn
  iam_database_authentication_enabled = true
  manage_master_user_password         = true

  # Backup
  backup_retention_period = 35
  backup_window           = "03:00-04:00"

  # Monitoreo
  monitoring_interval                   = 60
  performance_insights_enabled          = true
  performance_insights_retention_period = 731

  # Protección
  deletion_protection = true
  publicly_accessible = false
}
```

---

> [← Volver al índice](./README.md) | [Siguiente →](./04_dynamodb.md)
