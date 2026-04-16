#!/bin/bash
# Lab12 — Verificación de identidad IAM en EC2
# Este script se ejecuta una sola vez al arrancar la instancia (cloud-init).
# Comprueba que el Instance Profile ha entregado credenciales temporales válidas
# leyendo el IMDS con IMDSv2 y llamando a la API de STS.

set -e
LOG=/var/log/lab12-verify.log

{
  echo "=== Lab 12 — Verificación de Identidad IAM ==="
  echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo ""

  # ── Paso 1: Obtener token IMDSv2 ─────────────────────────────────────────
  # Con http_tokens=required en Terraform, el IMDS solo acepta peticiones
  # que incluyan un token de sesión. Sin este PUT previo, el curl devuelve 401.
  echo "--- [1] Obteniendo token IMDSv2 ---"
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

  if [ -z "$TOKEN" ]; then
    echo "ERROR: No se pudo obtener el token IMDSv2"
    exit 1
  fi
  echo "Token IMDSv2 obtenido correctamente."
  echo ""

  # ── Paso 2: Leer el nombre del rol del Instance Profile ──────────────────
  # El IMDS expone el nombre del rol en esta ruta. Si la instancia no tiene
  # Instance Profile, este endpoint devuelve 404.
  echo "--- [2] Nombre del rol IAM en el Instance Profile ---"
  ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  echo "Rol activo: $ROLE_NAME"
  echo ""

  # ── Paso 3: Leer las credenciales temporales emitidas por STS ────────────
  # Las credenciales rotan automáticamente. El campo "Expiration" indica
  # cuándo vence el conjunto actual. EC2 las renueva antes de ese momento.
  echo "--- [3] Credenciales temporales (STS) ---"
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE_NAME"
  echo ""

  # ── Paso 4: Verificar identidad con AWS CLI ───────────────────────────────
  # aws sts get-caller-identity usa automáticamente las credenciales del IMDS.
  # Devuelve el Account ID, el User ID y el ARN del rol asumido.
  echo "--- [4] aws sts get-caller-identity ---"
  aws sts get-caller-identity 2>&1 || echo "ERROR: No se pudo contactar con STS"
  echo ""

  # ── Paso 5: Verificar acceso de lectura a EC2 ────────────────────────────
  echo "--- [5] aws ec2 describe-instances (lectura) ---"
  aws ec2 describe-instances --query 'length(Reservations)' \
    --output text 2>&1 | xargs -I{} echo "Número de reservaciones visibles: {}"
  echo ""

  echo "=== Verificación completada ==="

} > "$LOG" 2>&1

echo "Lab12: log de verificación escrito en $LOG"
