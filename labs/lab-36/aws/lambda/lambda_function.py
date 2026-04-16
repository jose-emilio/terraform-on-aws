"""
Lambda CDC Processor — Lab32
Procesa eventos del DynamoDB Stream de la tabla de productos y escribe
un registro de auditoria en la tabla de eventos con TTL de 7 dias.
"""
import json
import os
import uuid
import boto3
from datetime import datetime, timezone, timedelta
from decimal import Decimal

EVENTS_TABLE = os.environ["EVENTS_TABLE"]
REGION = os.environ.get("REGION", "us-east-1")

dynamo = boto3.resource("dynamodb", region_name=REGION)
events_table = dynamo.Table(EVENTS_TABLE)

# TTL: 7 dias desde ahora (en segundos epoch)
TTL_DAYS = 7


def _extract_attr(ddb_item: dict, attr: str, attr_type: str = "S") -> str:
    """Extrae un atributo del formato DynamoDB nativo ({"S": "value"})."""
    val = ddb_item.get(attr, {})
    return str(val.get(attr_type, val.get("N", val.get("S", "?"))))


def handler(event, context):
    """
    Punto de entrada de la Lambda.
    event["Records"] contiene los registros del stream de DynamoDB,
    cada uno con el formato:
        {
          "eventName": "INSERT" | "MODIFY" | "REMOVE",
          "dynamodb": {
            "Keys":     { "category": {"S": "..."}, "product_id": {"S": "..."} },
            "NewImage": { ... },   # presente en INSERT y MODIFY
            "OldImage": { ... },   # presente en MODIFY y REMOVE
          }
        }
    """
    processed = 0
    errors = 0

    for record in event.get("Records", []):
        try:
            event_name = record["eventName"]  # INSERT | MODIFY | REMOVE
            ddb = record.get("dynamodb", {})

            keys = ddb.get("Keys", {})
            new_image = ddb.get("NewImage", {})
            old_image = ddb.get("OldImage", {})

            category = _extract_attr(keys, "category")
            product_id = _extract_attr(keys, "product_id")

            # Nombre del producto: preferir new_image, fallback a old_image
            name = (
                _extract_attr(new_image, "name")
                if new_image
                else _extract_attr(old_image, "name")
            )
            if name == "?":
                name = "Producto desconocido"

            # Precio para mostrar en el evento
            price_cents_raw = (
                _extract_attr(new_image, "price_cents", "N")
                if new_image
                else _extract_attr(old_image, "price_cents", "N")
            )
            try:
                price_str = f"${int(price_cents_raw) / 100:.2f}"
            except (ValueError, TypeError):
                price_str = "-"

            # Estado del producto
            status = (
                _extract_attr(new_image, "status")
                if new_image
                else _extract_attr(old_image, "status")
            )

            # Descripcion legible del evento
            if event_name == "INSERT":
                summary = f"Nuevo producto: {name} ({category}) · {price_str} · {status}"
            elif event_name == "MODIFY":
                old_status = _extract_attr(old_image, "status") if old_image else status
                if old_status != status:
                    summary = f"Estado cambiado: {name} → {old_status} ➜ {status}"
                else:
                    summary = f"Modificado: {name} ({category}) · {price_str}"
            else:  # REMOVE
                summary = f"Eliminado: {name} ({category})"

            # Clave de la tabla de eventos
            now = datetime.now(timezone.utc)
            event_date = now.strftime("%Y-%m-%d")
            # SK: HH:MM:SS#uuid-corto para unicidad y orden dentro del dia
            event_id = now.strftime("%H:%M:%S") + "#" + str(uuid.uuid4())[:8]
            ttl_epoch = int((now + timedelta(days=TTL_DAYS)).timestamp())

            events_table.put_item(
                Item={
                    "event_date": event_date,
                    "event_id": event_id,
                    "event_type": event_name,
                    "category": category,
                    "product_id": product_id,
                    "name": name,
                    "summary": summary,
                    "timestamp": now.isoformat(),
                    "ttl_epoch": ttl_epoch,
                }
            )
            processed += 1

        except Exception as e:
            print(f"ERROR procesando record: {e} | record={json.dumps(record, default=str)}")
            errors += 1

    print(f"CDC: {processed} eventos procesados, {errors} errores")
    return {"statusCode": 200, "processed": processed, "errors": errors}
