"""
plan_inspector.py — Compuerta programatica para el pipeline de Terraform.

Recibe el evento de CodePipeline con el job ID y las credenciales temporales
para acceder al artefacto plan_output (ZIP cifrado en S3).

Flujo:
  1. Extrae el artefacto ZIP del bucket de artefactos
  2. Localiza tfplan.json dentro del ZIP
  3. Analiza el plan: cuenta acciones por tipo (create/update/delete/replace)
  4. Decide si bloquear segun MAX_DESTROYS:
       -1 → nunca bloquea (modo inspeccion)
        0 → bloquea si hay cualquier destroy
        N → bloquea si hay mas de N destroys
  5. Llama a put_job_success_result o put_job_failure_result con el resumen
     como outputVariables para que el aprobador lo vea en la consola

Variables de entorno:
  MAX_DESTROYS   Umbral de destrucciones (por defecto -1, inyectado desde Terraform)
"""

import boto3
import json
import logging
import os
import zipfile
import io

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """Punto de entrada de la funcion Lambda."""
    codepipeline = boto3.client("codepipeline")

    job = event["CodePipeline.job"]
    job_id = job["id"]
    credentials = job["data"]["artifactCredentials"]

    logger.info("Job ID: %s", job_id)

    try:
        plan_summary = _inspect_plan(job["data"]["inputArtifacts"], credentials)
        _report_success(codepipeline, job_id, plan_summary)
    except PlanBlockedError as exc:
        logger.warning("Plan bloqueado: %s", exc)
        _report_failure(codepipeline, job_id, str(exc))
    except Exception as exc:  # pylint: disable=broad-except
        logger.exception("Error inesperado: %s", exc)
        _report_failure(codepipeline, job_id, f"Error interno: {exc}")


# ── Inspeccion del plan ───────────────────────────────────────────────────────

def _inspect_plan(input_artifacts, credentials):
    """
    Descarga el artefacto, extrae tfplan.json y devuelve un diccionario con
    el resumen del plan. Lanza PlanBlockedError si supera el umbral.
    """
    artifact = _find_artifact(input_artifacts, "plan_output")
    tfplan = _download_tfplan_json(artifact, credentials)

    summary = _count_actions(tfplan)
    logger.info("Resumen del plan: %s", summary)

    max_destroys = int(os.environ.get("MAX_DESTROYS", "-1"))
    _check_threshold(summary["destroy"], max_destroys)

    return summary


def _find_artifact(artifacts, name):
    """Localiza el artefacto por nombre en la lista."""
    for artifact in artifacts:
        if artifact["name"] == name:
            return artifact
    raise ValueError(f"Artefacto '{name}' no encontrado en el job.")


def _download_tfplan_json(artifact, credentials):
    """
    Usa las credenciales temporales del job para descargar el artefacto ZIP
    cifrado en S3 y extraer tfplan.json.
    """
    s3 = boto3.client(
        "s3",
        aws_access_key_id=credentials["accessKeyId"],
        aws_secret_access_key=credentials["secretAccessKey"],
        aws_session_token=credentials["sessionToken"],
    )

    location = artifact["location"]["s3Location"]
    bucket = location["bucketName"]
    key = location["objectKey"]

    logger.info("Descargando artefacto s3://%s/%s", bucket, key)

    response = s3.get_object(Bucket=bucket, Key=key)
    zip_bytes = response["Body"].read()

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        names = zf.namelist()
        logger.info("Ficheros en el artefacto: %s", names)

        # Buscar tfplan.json en cualquier nivel del ZIP
        target = next((n for n in names if n.endswith("tfplan.json")), None)
        if target is None:
            raise ValueError(
                f"tfplan.json no encontrado en el artefacto. Ficheros: {names}"
            )

        with zf.open(target) as f:
            return json.load(f)


def _count_actions(tfplan):
    """
    Recorre resource_changes del plan JSON y cuenta acciones por tipo.

    Tipos posibles en el campo 'actions':
      ["create"]           → create
      ["update"]           → update
      ["delete"]           → delete
      ["delete", "create"] → replace (delete+create en dos pasos)
      ["create", "delete"] → replace (create-before-destroy)
      ["no-op"]            → sin cambio
      ["read"]             → solo lectura (data sources)
    """
    counts = {"create": 0, "update": 0, "delete": 0, "replace": 0, "no_op": 0}

    for change in tfplan.get("resource_changes", []):
        actions = change.get("change", {}).get("actions", [])

        if actions == ["no-op"] or actions == ["read"]:
            counts["no_op"] += 1
        elif actions == ["create"]:
            counts["create"] += 1
        elif actions == ["update"]:
            counts["update"] += 1
        elif actions == ["delete"]:
            counts["delete"] += 1
        elif set(actions) == {"delete", "create"}:
            counts["replace"] += 1
        else:
            logger.warning("Accion desconocida: %s en %s", actions, change.get("address"))

    # destroy = deletes + replaces (ambos destruyen el recurso existente)
    counts["destroy"] = counts["delete"] + counts["replace"]

    total = counts["create"] + counts["update"] + counts["delete"] + counts["replace"]
    counts["total_changes"] = total

    return counts


def _check_threshold(num_destroys, max_destroys):
    """
    Lanza PlanBlockedError si el numero de destrucciones supera el umbral.

    max_destroys == -1  → nunca bloquea
    max_destroys ==  0  → bloquea si hay cualquier destruccion
    max_destroys ==  N  → bloquea si num_destroys > N
    """
    if max_destroys == -1:
        return

    if num_destroys > max_destroys:
        raise PlanBlockedError(
            f"El plan destruye {num_destroys} recurso(s), "
            f"pero el umbral maximo es {max_destroys}. "
            "Revisa el plan y apruebalo manualmente si es intencionado."
        )


# ── Reporte a CodePipeline ────────────────────────────────────────────────────

def _report_success(codepipeline, job_id, summary):
    """
    Informa a CodePipeline que el job fue exitoso.
    Exporta outputVariables para que aparezcan en la consola del pipeline.
    """
    output_variables = {
        "plan_creates":  str(summary["create"]),
        "plan_updates":  str(summary["update"]),
        "plan_deletes":  str(summary["delete"]),
        "plan_replaces": str(summary["replace"]),
        "plan_destroys": str(summary["destroy"]),
        "plan_total":    str(summary["total_changes"]),
    }

    logger.info("Reportando exito. Variables: %s", output_variables)

    codepipeline.put_job_success_result(
        jobId=job_id,
        outputVariables=output_variables,
    )


def _report_failure(codepipeline, job_id, message):
    """Informa a CodePipeline que el job fallo y detiene el pipeline."""
    logger.error("Reportando fallo: %s", message)

    codepipeline.put_job_failure_result(
        jobId=job_id,
        failureDetails={
            "type": "JobFailed",
            "message": message[:2048],  # CodePipeline limita el mensaje a 2048 chars
        },
    )


# ── Excepciones ───────────────────────────────────────────────────────────────

class PlanBlockedError(Exception):
    """El plan supera el umbral de destrucciones configurado."""
