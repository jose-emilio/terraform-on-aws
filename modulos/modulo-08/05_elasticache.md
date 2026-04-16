# Sección 5 — Amazon ElastiCache

> [← Volver al índice](./README.md)

---

## 1. ¿Para Qué Existe ElastiCache?

Cada query a tu base de datos consume CPU, I/O y tiempo de red. Si el mismo query se ejecuta 10,000 veces por segundo con la misma respuesta, estás pagando 10,000 veces por el mismo resultado. ElastiCache almacena esas respuestas en memoria — sub-milisegundo — y tu base de datos respira.

> **El profesor explica:** "ElastiCache no reemplaza a tu base de datos. La complementa. La regla es simple: los datos que cambian poco y se leen mucho van al caché. Los datos que cambian con frecuencia o que necesitan consistencia fuerte se consultan directamente a la BD. El problema es cuando los equipos caché todo sin pensar en la invalidación — y entonces los usuarios ven datos obsoletos por horas."

**Casos de uso principales:**
- Caché de consultas DB frecuentes (resultados de queries costosos).
- Session store distribuido (reemplaza sesiones en disco).
- Leaderboards y contadores en tiempo real (Sorted Sets de Redis).
- Pub/Sub para mensajería ligera entre servicios.
- Rate limiting y deduplicación de eventos.

---

## 2. Redis vs Memcached — Elegir el Motor Correcto

| Característica | Redis | Memcached |
|----------------|-------|-----------|
| Estructuras de datos | Strings, Hashes, Lists, Sets, Sorted Sets, Streams | Solo key-value (strings) |
| Replicación | Sí (Multi-AZ automático) | No |
| Persistencia | RDB snapshots + AOF | No (volátil) |
| Cluster Mode | Sí (sharding horizontal) | Sí (sin replicación) |
| Auth | AUTH token + ACLs de usuario | No |
| Backups | Sí, automáticos | No |
| Multi-threading | Single-threaded (Redis 7: threaded I/O) | Multi-threaded nativo |
| Lua scripting | Sí | No |
| Pub/Sub | Sí | No |
| Recomendado para | 95% de los casos | Solo caché de objetos simples |

> **El profesor explica:** "Elige Memcached únicamente si tu único caso de uso es caché de objetos simples sin necesidad de failover. En cualquier otro caso, Redis es la respuesta. Es más potente, tiene HA, backups y estructuras de datos que te permiten resolver problemas que con Memcached requerirían lógica en aplicación."

---

## 3. `aws_elasticache_subnet_group` y Security Group

Igual que RDS, ElastiCache vive en subnets privadas dentro de tu VPC. El Security Group limita el acceso al puerto Redis (6379) solo desde el tier de aplicación.

```hcl
# Subnet Group: define las subnets privadas para los nodos
resource "aws_elasticache_subnet_group" "redis" {
  name        = "redis-subnet-group"
  description = "Redis subnet group - private subnets"
  subnet_ids  = aws_subnet.private[*].id
}

# Security Group: solo el app tier puede conectarse al puerto Redis
resource "aws_security_group" "redis" {
  name   = "redis-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 6379    # Redis default port
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]   # Solo desde app tier
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

**Reglas de seguridad de red:**
- Puerto Redis: 6379 | Puerto Memcached: 11211.
- Nunca abrir `0.0.0.0/0` en ingress de ElastiCache.
- El Subnet Group no se puede cambiar después de crear el cluster — define bien las subnets desde el inicio.

---

## 4. `aws_elasticache_parameter_group` — Tuning del Motor

```hcl
resource "aws_elasticache_parameter_group" "redis" {
  name   = "redis7-custom"
  family = "redis7"   # Familia del motor: redis7, redis6.x, memcached1.6

  # Política de eviction cuando la memoria está llena
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"   # Evicta keys con TTL expirado primero
  }

  # Habilitar notificaciones keyspace para pub/sub
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"   # E=keyevent, x=expired
  }

  # Cerrar conexiones idle después de N segundos
  parameter {
    name  = "timeout"
    value = "300"
  }
}
```

**Políticas de eviction (`maxmemory-policy`):**

| Política | Comportamiento |
|----------|----------------|
| `volatile-lru` | Evicta keys con TTL usando LRU (recomendado para caché + session) |
| `allkeys-lru` | Evicta cualquier key usando LRU (recomendado para caché puro) |
| `volatile-ttl` | Evicta keys con menor TTL restante |
| `noeviction` | Retorna error si no hay memoria (jamás en producción como caché) |

---

## 5. `aws_elasticache_replication_group` — Alta Disponibilidad

El Replication Group es el recurso principal de Redis en ElastiCache. Define el cluster completo: nodos, replicación, cifrado y configuración.

```hcl
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "prod-redis"
  description          = "Redis cluster for production"

  # Motor
  node_type      = "cache.r6g.large"
  engine_version = "7.0"
  port           = 6379

  # Configuración
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  # Cluster: 1 primary + 2 réplicas (3 nodos total)
  num_cache_clusters = 3

  # Alta Disponibilidad
  automatic_failover_enabled = true
  multi_az_enabled           = true

  # Cifrado
  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = true
}
```

**Topologías disponibles:**

| Configuración | `num_cache_clusters` | `num_node_groups` | Uso |
|--------------|----------------------|-------------------|-----|
| Single node | 1 | — | Desarrollo |
| Primary + réplicas | 2-6 | — | Producción estándar |
| Cluster Mode | — | 1-500 | Sharding horizontal masivo |

---

## 6. Seguridad: AUTH Token y Cifrado

```hcl
resource "random_password" "redis" {
  length           = 64
  special          = false   # AUTH token: solo alfanumérico
  override_special = ""
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis.id
  secret_string = random_password.redis.result
}

resource "aws_elasticache_replication_group" "secure" {
  replication_group_id = "secure-redis"
  description          = "Redis with full encryption"
  node_type            = "cache.r6g.large"

  # Cifrado at-rest con CMK
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.redis.arn

  # Cifrado in-transit (TLS)
  transit_encryption_enabled = true

  # AUTH token (requiere transit_encryption_enabled = true)
  auth_token = random_password.redis.result   # 16-128 chars alfanumérico

  # HA
  automatic_failover_enabled = true
  multi_az_enabled           = true
  num_cache_clusters         = 3
}
```

> **Regla crítica:** `at_rest_encryption_enabled` y `transit_encryption_enabled` se definen al crear el cluster y son **inmutables**. No puedes habilitarlos en un cluster existente — necesitas crear uno nuevo y migrar los datos. Actívalos siempre desde el día uno.

**Rotación del AUTH token:** usa la estrategia SET/ROTATE — actualiza el token en Secrets Manager, despliega la nueva versión en el cluster (ElastiCache permite dos tokens activos simultáneamente durante la rotación), actualiza la aplicación, y revoca el token antiguo.

---

## 7. Backups, Snapshots y Maintenance Window

```hcl
resource "aws_elasticache_replication_group" "backup" {
  replication_group_id = "prod-redis-backup"
  description          = "Redis with backup config"
  node_type            = "cache.r6g.large"

  # Backups automáticos (solo Redis, no Memcached)
  snapshot_retention_limit  = 7               # Días a retener snapshots
  snapshot_window           = "03:00-04:00"   # UTC, ventana diaria de backup
  final_snapshot_identifier = "redis-final-snap"  # Snapshot al eliminar

  # Mantenimiento y patches
  maintenance_window         = "sun:05:00-sun:06:00"   # Evita overlap con backup
  auto_minor_version_upgrade = true

  # Notificaciones de mantenimiento vía SNS
  notification_topic_arn = aws_sns_topic.redis.arn
}
```

**Configuración de ventanas:**
- `snapshot_window` y `maintenance_window` no deben solaparse.
- Ambas en horarios de bajo tráfico (madrugada UTC).
- Los snapshots se almacenan en S3 gestionado por AWS.
- Restaurar un snapshot crea un nuevo Replication Group — no sobrescribe el existente.

---

## 8. CloudWatch Monitoring y Alarmas

```hcl
# Alarma de CPU alta
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "elasticache-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 65   # 65% como umbral de alerta

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# Alarma de evictions (señal de poca memoria)
resource "aws_cloudwatch_metric_alarm" "evictions" {
  alarm_name          = "elasticache-evictions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 0   # Cualquier eviction es una alerta

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# Alarma de ReplicationLag
resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  alarm_name          = "elasticache-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ReplicationLag"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1   # Más de 1 segundo de lag

  dimensions = {
    CacheClusterId = aws_elasticache_replication_group.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

**Métricas clave a monitorear:**

| Métrica | Umbral de alerta | Acción |
|---------|-----------------|--------|
| `CPUUtilization` | > 65% | Escalar instancia o Cluster Mode |
| `EngineCPUUtilization` | > 80% | Escalar instancia |
| `Evictions` | > 0 | Revisar TTLs o aumentar memoria |
| `CacheHitRate` | < 80% | Revisar TTLs y estrategia de caché |
| `ReplicationLag` | > 1s | Verificar consistencia de datos |
| `DatabaseMemoryUsagePercentage` | > 80% | Escalar instancia |
| `CurrConnections` | Tendencia creciente | Verificar connection pooling en app |

---

## 9. Auto Scaling y Global Datastore

### Auto Scaling de Réplicas

```hcl
resource "aws_appautoscaling_target" "redis_replicas" {
  max_capacity       = 5
  min_capacity       = 1
  resource_id        = "replication-group/${aws_elasticache_replication_group.redis.id}"
  scalable_dimension = "elasticache:replication-group:Replicas"
  service_namespace  = "elasticache"
}

resource "aws_appautoscaling_policy" "redis_replicas" {
  name               = "redis-replica-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.redis_replicas.resource_id
  scalable_dimension = aws_appautoscaling_target.redis_replicas.scalable_dimension
  service_namespace  = aws_appautoscaling_target.redis_replicas.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ElastiCachePrimaryEngineCPUUtilization"
    }
    target_value       = 60.0
    scale_in_cooldown  = 300   # 5 min antes de reducir
    scale_out_cooldown = 60
  }
}
```

### Global Datastore

Global Datastore replica un cluster de Redis a regiones secundarias para DR y latencia global:
- Primary region + hasta 2 secondary regions.
- Replicación asíncrona < 1 segundo típico entre regiones.
- Failover manual a secondary region cuando el primary falla.
- Lecturas locales en cada región (reducción de latencia inter-region).
- Requiere Redis 5.0.6+. Compatible con Cluster Mode disabled y Cluster Mode enabled.

---

## 10. Gobernanza Completa: Checklist Terraform

```hcl
# 1. Subnet Group (subnets privadas, 2+ AZs)
resource "aws_elasticache_subnet_group" "redis" { ... }

# 2. Parameter Group (tuning del motor)
resource "aws_elasticache_parameter_group" "redis" {
  # maxmemory-policy, timeout, notify-keyspace-events
}

# 3. Security Group (solo app tier ingress puerto 6379)
resource "aws_security_group" "redis" {
  # ingress: solo desde aws_security_group.app
}

# 4. Replication Group (HA + cifrado + backups)
resource "aws_elasticache_replication_group" "redis" {
  # at_rest_encryption_enabled = true  (inmutable, activar desde inicio)
  # transit_encryption_enabled = true  (inmutable, activar desde inicio)
  # auth_token                  = ... (almacenar en Secrets Manager)
  # automatic_failover_enabled  = true
  # multi_az_enabled            = true
  # num_cache_clusters          = 3    (1 primary + 2 réplicas)
  # snapshot_retention_limit    = 7
  # maintenance_window          = "sun:05:00-sun:06:00"
}

# 5. CloudWatch Alarms (CPU, Evictions, ReplicationLag, CacheHitRate)
resource "aws_cloudwatch_metric_alarm" "cpu"         { ... }
resource "aws_cloudwatch_metric_alarm" "evictions"   { ... }
resource "aws_cloudwatch_metric_alarm" "replication" { ... }

# 6. Auto Scaling de réplicas (opcional, producción con tráfico variable)
resource "aws_appautoscaling_target" "redis_replicas" { ... }
resource "aws_appautoscaling_policy" "redis_replicas"  { ... }
```

---

## 11. Best Practices: Rendimiento y Seguridad

**Rendimiento:**
- Redis 7+ para mejor rendimiento y funciones avanzadas.
- `cache.r7g` para mejor ratio costo/rendimiento (Graviton3).
- Cluster Mode Enabled cuando la memoria de un nodo no es suficiente.
- TTLs apropiados para evitar evictions — una `Eviction` es siempre una señal de problema.
- Connection pooling en la aplicación — Redis es single-threaded para comandos.
- Implementar `lazy loading` + `write-through` según la criticidad de los datos.

**Seguridad:**
- `at_rest_encryption_enabled = true` siempre, con CMK en datos sensibles.
- `transit_encryption_enabled = true` siempre — sin esto no puedes usar AUTH token.
- AUTH token almacenado en Secrets Manager con rotación periódica.
- Security Groups: solo puerto 6379 desde el app tier — nunca `0.0.0.0/0`.
- Subnets privadas sin route a Internet Gateway.
- `automatic_failover_enabled = true` siempre en producción.
- Backups diarios con `snapshot_retention_limit >= 7`.

> **El profesor resume:** "ElastiCache es el multiplicador de tu base de datos. Con el caché bien implementado, una instancia RDS `db.r6g.large` puede servir la misma carga que necesitaría `db.r6g.4xlarge` sin caché. El ahorro en la BD paga con creces el costo del cluster Redis. El truco está en la invalidación: si no tienes una estrategia clara para cuándo y cómo invalidas el caché, eventualmente tendrás usuarios viendo datos incorrectos en producción."

---

> [← Volver al índice](./README.md)
