"""
Lab32 — Lambda en VPC con Provisioned Concurrency.

Demuestra dos conceptos clave:

  1. vpc_config: la función se ejecuta con una ENI dentro de la VPC (subredes
     privadas), lo que le permite alcanzar recursos internos como RDS o
     ElastiCache sin exponer esos recursos a internet.

  2. Provisioned Concurrency: cuando está activa, la variable de entorno
     AWS_LAMBDA_INITIALIZATION_TYPE vale "provisioned-concurrency", lo que
     confirma que el contenedor fue pre-calentado y no hubo cold start.
     Con invocaciones bajo demanda normales valdrá "on-demand".
"""
import json
import logging
import os
import socket

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    # AWS_LAMBDA_INITIALIZATION_TYPE vale:
    #   "provisioned-concurrency" → contenedor pre-calentado (sin cold start)
    #   "on-demand"               → cold start normal
    init_type = os.environ.get("AWS_LAMBDA_INITIALIZATION_TYPE", "on-demand")

    payload = {
        "function_name": context.function_name,
        "function_version": context.function_version,
        "request_id": context.aws_request_id,
        "memory_limit_mb": context.memory_limit_in_mb,
        "remaining_ms": context.get_remaining_time_in_millis(),
        "init_type": init_type,
        "vpc_hostname": socket.gethostname(),
        "env": os.environ.get("APP_ENV", "unknown"),
        "project": os.environ.get("APP_PROJECT", "unknown"),
    }

    logger.info("Invocación procesada: %s", json.dumps(payload))
    return {"statusCode": 200, "body": json.dumps(payload, indent=2)}
