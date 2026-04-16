# ── Tabla de productos ────────────────────────────────────────────────────────
#
# Modelo schemaless con Partition Key "category" y Sort Key "product_id".
# El modo PAY_PER_REQUEST (On-Demand) elimina el aprovisionamiento de RCU/WCU:
# DynamoDB escala automaticamente ante cualquier patron de carga sin
# configuracion adicional, ideal para cargas impredecibles.
#
# GSI "by-status-index": permite consultar productos por estado (active/inactive/
# discontinued) ordenados por precio de menor a mayor. La proyeccion ALL evita
# accesos adicionales a la tabla base para obtener los atributos restantes.
#
# DynamoDB Streams con NEW_AND_OLD_IMAGES captura el estado antes y despues
# de cada modificacion, lo que permite detectar que atributos cambiaron.

resource "aws_dynamodb_table" "products" {
  name         = "${var.project}-products"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "category"
  range_key = "product_id"

  attribute {
    name = "category"
    type = "S"
  }
  attribute {
    name = "product_id"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "price_cents"
    type = "N"
  }

  # GSI: consultas por estado del producto, ordenado por precio ascendente
  global_secondary_index {
    name = "by-status-index"
    key_schema {
      attribute_name = "status"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "price_cents"
      key_type       = "RANGE"
    }
    projection_type = "ALL"
  }

  # Streams: captura de cambios en tiempo real para procesado por Lambda CDC
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = local.tags
}

# ── Tabla de eventos CDC ──────────────────────────────────────────────────────
#
# La Lambda CDC escribe aqui cada cambio detectado en la tabla de productos.
# PK: event_date (YYYY-MM-DD) permite agrupar y recuperar eventos por dia.
# SK: event_id (HH:MM:SS#uuid) garantiza unicidad y orden temporal dentro del dia.
# TTL: los eventos se eliminan automaticamente despues de 7 dias sin consumir
# Write Capacity Units (el borrado por TTL es eventual, no inmediato).

resource "aws_dynamodb_table" "events" {
  name         = "${var.project}-events"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "event_date"
  range_key = "event_id"

  attribute {
    name = "event_date"
    type = "S"
  }
  attribute {
    name = "event_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  tags = local.tags
}
