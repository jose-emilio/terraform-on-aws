#!/bin/bash
# deploy.sh — Configuracion del servidor web con metadatos de instancia
#
# Ejecutado por terraform_data via provisioner "remote-exec".
# Variables de entorno inyectadas por Terraform:
#   APP_VERSION  — version de la aplicacion (var.app_version)
#   PROJECT      — prefijo del proyecto (var.project)
#
# Uso manual (para pruebas):
#   sudo APP_VERSION=1.0.0 PROJECT=lab37 ./deploy.sh

set -euo pipefail

APP_VERSION="${APP_VERSION:-unknown}"
PROJECT="${PROJECT:-lab37}"
LOG="/var/log/${PROJECT}-deploy.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG"
}

# ── Helpers IMDSv2 ────────────────────────────────────────────────────────────
# IMDSv2 requiere un token de sesion obtenido con PUT antes de cualquier GET.
# El token tiene un TTL de 60 segundos, suficiente para todas las consultas
# del script. Sin el token, la instancia rechaza las peticiones (http_tokens=required).
imds_token() {
  curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60"
}

imds_get() {
  local path="$1"
  local token
  token=$(imds_token)
  curl -sf "http://169.254.169.254/latest/meta-data/${path}" \
    -H "X-aws-ec2-metadata-token: ${token}" 2>/dev/null || echo "N/A"
}

imds_identity() {
  local field="$1"
  local token
  token=$(imds_token)
  curl -sf "http://169.254.169.254/latest/dynamic/instance-identity/document" \
    -H "X-aws-ec2-metadata-token: ${token}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${field}','N/A'))"
}

log "============================================"
log "Iniciando despliegue v${APP_VERSION} — ${PROJECT}"
log "============================================"

# ── 1. Actualizar paquetes ────────────────────────────────────────────────────
log "Actualizando paquetes del sistema..."
dnf update -y --quiet 2>&1 | tail -1

# ── 2. Instalar nginx ─────────────────────────────────────────────────────────
log "Instalando nginx..."
dnf install -y nginx --quiet

# ── 3. Recopilar metadatos de la instancia via IMDSv2 ─────────────────────────
log "Consultando metadatos de la instancia (IMDSv2)..."

INSTANCE_ID=$(imds_get "instance-id")
INSTANCE_TYPE=$(imds_get "instance-type")
AMI_ID=$(imds_get "ami-id")
AZ=$(imds_get "placement/availability-zone")
REGION=$(imds_identity "region")
PUBLIC_IP=$(imds_get "public-ipv4")
LOCAL_IP=$(imds_get "local-ipv4")
HOSTNAME=$(imds_get "hostname")
MAC=$(imds_get "mac")
VPC_ID=$(imds_get "network/interfaces/macs/${MAC}/vpc-id")
SUBNET_ID=$(imds_get "network/interfaces/macs/${MAC}/subnet-id")
SECURITY_GROUPS=$(imds_get "security-groups")
IAM_ROLE=$(imds_get "iam/security-credentials/" 2>/dev/null || echo "N/A")
ACCOUNT_ID=$(imds_identity "accountId")
ARCH=$(imds_identity "architecture")
KERNEL=$(uname -r)
VCPUS=$(nproc)
TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
DISK_GB=$(df -BG / | awk 'NR==2 {print $2}' | tr -d 'G')
OS_VERSION=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
DEPLOY_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UPTIME=$(uptime -p)

log "Metadatos recopilados: instancia=${INSTANCE_ID} region=${REGION} az=${AZ}"

# ── 4. Generar pagina web con metadatos ───────────────────────────────────────
log "Generando pagina web..."
cat > /usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PROJECT} — v${APP_VERSION}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
      background: #0d1117;
      color: #e6edf3;
      min-height: 100vh;
      padding: 2rem 1rem;
    }

    .container { max-width: 900px; margin: 0 auto; }

    /* ── Header ── */
    header {
      display: flex;
      align-items: center;
      gap: 1rem;
      margin-bottom: 2rem;
      padding-bottom: 1.5rem;
      border-bottom: 1px solid #30363d;
    }
    .logo {
      width: 48px; height: 48px;
      background: linear-gradient(135deg, #ff9900, #ff6600);
      border-radius: 12px;
      display: flex; align-items: center; justify-content: center;
      font-size: 1.5rem;
      flex-shrink: 0;
    }
    h1 { font-size: 1.6rem; font-weight: 700; color: #ff9900; }
    .subtitle { font-size: 0.85rem; color: #8b949e; margin-top: .2rem; }

    /* ── Badges ── */
    .badges { display: flex; gap: .5rem; flex-wrap: wrap; margin-bottom: 1.5rem; }
    .badge {
      display: inline-flex; align-items: center; gap: .35rem;
      padding: .3rem .75rem;
      border-radius: 999px;
      font-size: .75rem; font-weight: 600;
      letter-spacing: .03em;
    }
    .badge-green  { background: #1a4731; color: #3fb950; border: 1px solid #238636; }
    .badge-orange { background: #3d2404; color: #ff9900; border: 1px solid #9e5a00; }
    .badge-blue   { background: #0d2a4a; color: #58a6ff; border: 1px solid #1f6feb; }
    .badge-purple { background: #271a4a; color: #bc8cff; border: 1px solid #6e40c9; }
    .dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }

    /* ── Secciones ── */
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
      gap: 1rem;
      margin-bottom: 1rem;
    }
    .card {
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      overflow: hidden;
    }
    .card-header {
      display: flex; align-items: center; gap: .5rem;
      padding: .75rem 1rem;
      background: #1c2128;
      border-bottom: 1px solid #30363d;
      font-size: .75rem; font-weight: 700;
      text-transform: uppercase; letter-spacing: .08em;
      color: #8b949e;
    }
    .card-icon { font-size: 1rem; }

    /* ── Tabla de metadatos ── */
    table { width: 100%; border-collapse: collapse; }
    tr { border-bottom: 1px solid #21262d; }
    tr:last-child { border-bottom: none; }
    td {
      padding: .6rem 1rem;
      font-size: .83rem;
      vertical-align: middle;
    }
    td:first-child {
      color: #8b949e;
      white-space: nowrap;
      width: 42%;
      font-size: .78rem;
    }
    td:last-child { color: #e6edf3; font-family: 'Cascadia Code', 'Fira Code', monospace; }
    .mono { font-family: 'Cascadia Code', 'Fira Code', monospace; font-size: .78rem; }
    .highlight { color: #ff9900; font-weight: 600; }
    .ok { color: #3fb950; }

    /* ── Barra de recursos ── */
    .resource-bar {
      display: flex; align-items: center; gap: .75rem;
      padding: .6rem 1rem;
      border-bottom: 1px solid #21262d;
      font-size: .83rem;
    }
    .resource-bar:last-child { border-bottom: none; }
    .bar-label { color: #8b949e; width: 5rem; flex-shrink: 0; font-size: .78rem; }
    .bar-value { color: #e6edf3; font-family: monospace; width: 4rem; flex-shrink: 0; }
    .bar-track {
      flex: 1; height: 6px; background: #21262d;
      border-radius: 3px; overflow: hidden;
    }
    .bar-fill { height: 100%; border-radius: 3px; }
    .bar-fill-orange { background: linear-gradient(90deg, #ff9900, #ff6600); }
    .bar-fill-blue   { background: linear-gradient(90deg, #58a6ff, #1f6feb); }
    .bar-fill-green  { background: linear-gradient(90deg, #3fb950, #238636); }

    /* ── Footer ── */
    footer {
      margin-top: 1.5rem;
      padding-top: 1rem;
      border-top: 1px solid #30363d;
      font-size: .75rem; color: #484f58;
      display: flex; justify-content: space-between; flex-wrap: wrap; gap: .5rem;
    }
    footer span { font-family: monospace; }
  </style>
</head>
<body>
<div class="container">

  <!-- Header -->
  <header>
    <div class="logo">&#9729;</div>
    <div>
      <h1>${PROJECT}</h1>
      <div class="subtitle">Gestionado con Terraform · terraform_data + provisioners</div>
    </div>
  </header>

  <!-- Badges de estado -->
  <div class="badges">
    <span class="badge badge-green"><span class="dot"></span> Running</span>
    <span class="badge badge-orange">v${APP_VERSION}</span>
    <span class="badge badge-blue">${REGION}</span>
    <span class="badge badge-blue">${AZ}</span>
    <span class="badge badge-purple">${INSTANCE_TYPE}</span>
    <span class="badge badge-purple">${ARCH}</span>
  </div>

  <!-- Grid principal -->
  <div class="grid">

    <!-- Identidad -->
    <div class="card">
      <div class="card-header"><span class="card-icon">&#128274;</span> Identidad</div>
      <table>
        <tr><td>Instance ID</td><td class="highlight">${INSTANCE_ID}</td></tr>
        <tr><td>Account ID</td><td>${ACCOUNT_ID}</td></tr>
        <tr><td>AMI ID</td><td>${AMI_ID}</td></tr>
        <tr><td>IAM Role</td><td>${IAM_ROLE}</td></tr>
        <tr><td>Hostname</td><td>${HOSTNAME}</td></tr>
      </table>
    </div>

    <!-- Red -->
    <div class="card">
      <div class="card-header"><span class="card-icon">&#127760;</span> Red</div>
      <table>
        <tr><td>IP Publica</td><td class="highlight ok">${PUBLIC_IP}</td></tr>
        <tr><td>IP Privada</td><td>${LOCAL_IP}</td></tr>
        <tr><td>VPC ID</td><td>${VPC_ID}</td></tr>
        <tr><td>Subnet ID</td><td>${SUBNET_ID}</td></tr>
        <tr><td>Security Groups</td><td>${SECURITY_GROUPS}</td></tr>
        <tr><td>MAC</td><td>${MAC}</td></tr>
      </table>
    </div>

    <!-- Sistema -->
    <div class="card">
      <div class="card-header"><span class="card-icon">&#128421;</span> Sistema</div>
      <table>
        <tr><td>OS</td><td>${OS_VERSION}</td></tr>
        <tr><td>Kernel</td><td>${KERNEL}</td></tr>
        <tr><td>Arquitectura</td><td>${ARCH}</td></tr>
        <tr><td>vCPUs</td><td>${VCPUS}</td></tr>
        <tr><td>RAM Total</td><td>${TOTAL_RAM_MB} MB</td></tr>
        <tr><td>Disco raiz</td><td>${DISK_GB} GB</td></tr>
        <tr><td>Uptime</td><td>${UPTIME}</td></tr>
      </table>
    </div>

    <!-- Despliegue -->
    <div class="card">
      <div class="card-header"><span class="card-icon">&#128640;</span> Despliegue</div>
      <table>
        <tr><td>Version</td><td class="highlight">v${APP_VERSION}</td></tr>
        <tr><td>Proyecto</td><td>${PROJECT}</td></tr>
        <tr><td>Region</td><td>${REGION}</td></tr>
        <tr><td>Zona</td><td>${AZ}</td></tr>
        <tr><td>Tipo instancia</td><td>${INSTANCE_TYPE}</td></tr>
        <tr><td>Desplegado</td><td>${DEPLOY_TIME}</td></tr>
        <tr><td>Herramienta</td><td class="ok">Terraform + terraform_data</td></tr>
      </table>
    </div>

  </div><!-- /grid -->

  <!-- Footer -->
  <footer>
    <span>Instancia: ${INSTANCE_ID}</span>
    <span>Desplegado: ${DEPLOY_TIME}</span>
    <span>v${APP_VERSION} · ${PROJECT}</span>
  </footer>

</div>
</body>
</html>
HTML

# ── 5. Endpoint JSON para healthchecks y automatizacion ───────────────────────
log "Generando endpoint /version.json..."
cat > /usr/share/nginx/html/version.json <<JSON
{
  "project":       "${PROJECT}",
  "version":       "${APP_VERSION}",
  "deployed_at":   "${DEPLOY_TIME}",
  "instance_id":   "${INSTANCE_ID}",
  "instance_type": "${INSTANCE_TYPE}",
  "ami_id":        "${AMI_ID}",
  "region":        "${REGION}",
  "az":            "${AZ}",
  "public_ip":     "${PUBLIC_IP}",
  "private_ip":    "${LOCAL_IP}",
  "vpc_id":        "${VPC_ID}",
  "arch":          "${ARCH}"
}
JSON

# ── 6. Arrancar nginx ─────────────────────────────────────────────────────────
log "Arrancando nginx..."
systemctl enable --now nginx

# ── 7. Verificacion local ─────────────────────────────────────────────────────
if systemctl is-active --quiet nginx; then
  log "nginx activo — verificando respuesta HTTP..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost)
  log "Respuesta HTTP: ${HTTP_CODE}"
  [ "$HTTP_CODE" = "200" ] || { log "ERROR: nginx responde ${HTTP_CODE}"; exit 1; }
else
  log "ERROR: nginx no esta activo tras el arranque"
  exit 1
fi

log "============================================"
log "Despliegue v${APP_VERSION} completado con exito"
log "============================================"
