"""
Procesador de órdenes premium — Lab31.

Flujos soportados:
  1. SQS Event Source Mapping — event["Records"] presente.
     Lambda procesa el lote en bloque; si lanza excepción, el mensaje
     vuelve a la cola hasta maxReceiveCount (3) y pasa a la DLQ.

  2. Invocación async directa — para demostrar Lambda Destinations.
     Si amount > MAX_AMOUNT → lanza ValueError → on_failure → failure-queue.
     Si amount ≤ MAX_AMOUNT → retorna resultado → on_success → success-queue.
"""
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Límite de importe por orden. Órdenes que superen este valor provocan
# un fallo controlado para demostrar la ruta de error (DLQ / failure-queue).
MAX_AMOUNT = 9_999.99


def _process_order(order: dict) -> dict:
    """Valida y procesa una orden individual. Lanza ValueError si es inválida."""
    order_id = order.get("order_id", "unknown")
    order_type = order.get("order_type", "unknown")
    amount = float(order.get("amount", 0))

    logger.info(
        "Procesando orden order_id=%s order_type=%s amount=%.2f",
        order_id,
        order_type,
        amount,
    )

    if amount < 0:
        raise ValueError(f"order_id={order_id}: amount negativo ({amount})")

    if amount > MAX_AMOUNT:
        raise ValueError(
            f"order_id={order_id}: amount {amount:.2f} supera el límite {MAX_AMOUNT}"
        )

    return {
        "order_id": order_id,
        "order_type": order_type,
        "amount": amount,
        "status": "processed",
    }


def lambda_handler(event, context):
    env = os.environ.get("APP_ENV", "unknown")
    project = os.environ.get("APP_PROJECT", "unknown")

    # ── Path 1: SQS Event Source Mapping ──────────────────────────────────────
    # Lambda recibe un lote de mensajes SQS. Si _process_order() lanza una
    # excepción, Lambda devuelve un error al servicio SQS, que reencola el
    # mensaje. Tras maxReceiveCount intentos, SQS mueve el mensaje a la DLQ.
    if "Records" in event:
        results = []
        for record in event["Records"]:
            body = json.loads(record["body"])
            results.append(_process_order(body))

        logger.info(
            "[SQS] Batch completado: %d órdenes procesadas — env=%s project=%s",
            len(results),
            env,
            project,
        )
        return {"processed": len(results), "results": results}

    # ── Path 2: Invocación async directa (Lambda Destinations) ────────────────
    # Usado para demostrar aws_lambda_function_event_invoke_config.
    # El runtime de Lambda envía el resultado a on_success o on_failure
    # según si la función retorna con éxito o lanza una excepción.
    result = _process_order(event)
    result["processed_by"] = context.function_name
    result["request_id"] = context.aws_request_id
    result["env"] = env

    logger.info("[Async] Orden procesada exitosamente: %s", json.dumps(result))
    return result
