"""
Utilidades compartidas para el Lab30 — distribuidas como Lambda Layer.

Al empaquetar la capa, Lambda espera la estructura:
  layer.zip
  └── python/
      └── utils.py          ← este fichero

Lambda añade automáticamente python/ al sys.path, por lo que el handler
puede importar este módulo con un simple: from utils import ...
"""
import json
import os
from datetime import datetime, timezone


def format_response(status_code: int, body: dict) -> dict:
    """Devuelve una respuesta HTTP compatible con el payload format 2.0 de API Gateway v2."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "X-Lab": os.environ.get("APP_PROJECT", "lab30"),
        },
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


def get_metadata(context) -> dict:
    """Extrae metadatos del contexto de ejecución de Lambda para incluirlos en la respuesta."""
    return {
        "function":    context.function_name,
        "request_id":  context.aws_request_id,
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "environment": os.environ.get("APP_ENV", "unknown"),
        "project":     os.environ.get("APP_PROJECT", "unknown"),
    }
