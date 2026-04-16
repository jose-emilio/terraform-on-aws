#!/bin/bash
# ValidateService: verifica que la aplicacion responde correctamente al health check.
# CodeDeploy usa el exit code de este script para decidir si el despliegue en
# esta instancia es exitoso:
#   exit 0  → instancia validada, el despliegue continua
#   exit != 0 → instancia fallida; si supera el umbral de minimum_healthy_hosts,
#               CodeDeploy aborta el despliegue y activa el rollback automatico.
set -euo pipefail

curl --silent --fail --max-time 5 http://localhost/health || exit 1
