"""
Handler principal de la API de Items — Lab30.

Importa 'utils' desde la Lambda Layer adjunta al desplegar; en tests locales
sin la capa, asegúrate de tener src/layer/python/ en PYTHONPATH.

Rutas disponibles:
  GET  /items         → lista todos los items
  GET  /items/{id}    → devuelve un item por ID
  POST /items         → crea un nuevo item (body JSON con campo 'nombre')

Nota: _CATALOG es una variable de módulo. Se conserva entre invocaciones
"cálidas" (warm) del mismo contenedor Lambda y se reinicia en cada cold start.
En producción usa DynamoDB u otro almacén persistente.
"""
import json
from utils import format_response, get_metadata

_CATALOG: dict = {
    "1": {"id": "1", "nombre": "Laptop Pro",       "precio": 1299.99, "categoria": "Electrónica"},
    "2": {"id": "2", "nombre": "Teclado Mecánico", "precio":  149.99, "categoria": "Electrónica"},
    "3": {"id": "3", "nombre": "Monitor 4K",        "precio":  599.99, "categoria": "Electrónica"},
}


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path   = event.get("rawPath", "/")
    params = event.get("pathParameters") or {}

    # ── GET /items ─────────────────────────────────────────────────────────────
    if method == "GET" and path == "/items":
        return format_response(200, {
            "items":    list(_CATALOG.values()),
            "total":    len(_CATALOG),
            "metadata": get_metadata(context),
        })

    # ── GET /items/{id} ────────────────────────────────────────────────────────
    if method == "GET" and params.get("id"):
        item = _CATALOG.get(params["id"])
        if item:
            return format_response(200, {"item": item, "metadata": get_metadata(context)})
        return format_response(404, {"error": "Item no encontrado", "id": params["id"]})

    # ── POST /items ────────────────────────────────────────────────────────────
    if method == "POST":
        raw_body = event.get("body") or "{}"
        try:
            body = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
        except json.JSONDecodeError:
            return format_response(400, {"error": "Cuerpo JSON inválido"})

        if not body.get("nombre"):
            return format_response(400, {"error": "El campo 'nombre' es requerido"})

        new_id   = str(max(int(k) for k in _CATALOG) + 1)
        new_item = {
            "id":        new_id,
            "nombre":    body["nombre"],
            "precio":    float(body.get("precio", 0.0)),
            "categoria": body.get("categoria", "General"),
        }
        _CATALOG[new_id] = new_item
        return format_response(201, {"item": new_item, "metadata": get_metadata(context)})

    return format_response(404, {
        "error":  "Ruta no encontrada",
        "path":   path,
        "method": method,
    })
