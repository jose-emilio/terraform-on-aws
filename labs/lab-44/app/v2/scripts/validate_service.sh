#!/bin/bash
# ValidateService: verifica que la aplicacion responde correctamente al health check.
set -euo pipefail

curl --silent --fail --max-time 5 http://localhost/health || exit 1
