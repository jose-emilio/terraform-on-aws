# ── AUTH token para Redis ─────────────────────────────────────────────────────
#
# Restricciones de ElastiCache AUTH: minimo 16 caracteres, sin espacios ni @.
# override_special excluye esos caracteres conflictivos.

resource "random_password" "redis_auth" {
  length           = 32
  special          = true
  override_special = "!#$%-_+="
}

# ── Secrets Manager: AUTH token de Redis ─────────────────────────────────────
#
# El token se almacena en Secrets Manager para que la instancia EC2 lo recupere
# en tiempo de arranque sin necesidad de embeber secretos en el user_data o
# en variables de entorno visibles en la consola de EC2.

resource "aws_secretsmanager_secret" "redis_auth" {
  name        = "${var.project}/redis/auth-token"
  description = "AUTH token para el cluster de Redis (ElastiCache)"
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

# ── ElastiCache: subnet group ─────────────────────────────────────────────────
#
# El subnet group indica a ElastiCache en que subnets puede colocar los nodos.
# Debe incluir subnets en al menos dos AZs para soportar Multi-AZ y failover.
# Se usan las subnets privadas: Redis no debe ser accesible desde internet.

resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project}-redis-subnets"
  description = "Subnets privadas para el cluster de Redis"
  subnet_ids  = [for s in aws_subnet.private : s.id]
  tags        = local.tags
}

# ── ElastiCache: Redis Replication Group ──────────────────────────────────────
#
# Despliega un grupo de replicacion Redis con 1 nodo primario (escrituras) y
# 1 replica (lecturas), distribuidos en dos AZs distintas para tolerancia a fallos.
#
# transit_encryption_enabled = true: todas las conexiones deben usar TLS.
#   El cliente debe conectar con ssl=True (rediss://) en lugar de redis://.
#
# auth_token: password que los clientes deben presentar al conectar.
#   Combina autenticacion (auth_token) con cifrado en transito (TLS) para
#   proteccion en dos capas en la red.
#
# at_rest_encryption_enabled = true: los datos en disco se cifran con AES-256.
#
# automatic_failover_enabled = true: si el nodo primario falla, ElastiCache
#   promueve automaticamente la replica como nuevo primario en ~1 minuto.

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-redis"
  description          = "Redis cache para Lab36 - product catalog"

  node_type            = var.redis_node_type
  num_cache_clusters   = 2
  parameter_group_name = "default.redis7"
  port                 = 6379
  engine_version       = "7.1"

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  automatic_failover_enabled = true
  multi_az_enabled           = true

  apply_immediately = true

  tags = local.tags
}
