#!/bin/sh
set -e

# Obtiene metadatos de la tarea ECS desde el endpoint de metadatos v4.
TASK_META=$(wget -qO- "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null || echo '{}')

TASK_ARN=$(echo "$TASK_META"  | grep -o '"TaskARN":"[^"]*"'  | head -1 | cut -d'"' -f4)
CLUSTER=$(echo "$TASK_META"   | grep -o '"Cluster":"[^"]*"'  | head -1 | cut -d'"' -f4)
FAMILY=$(echo "$TASK_META"    | grep -o '"Family":"[^"]*"'   | head -1 | cut -d'"' -f4)
REVISION=$(echo "$TASK_META"  | grep -o '"Revision":"[^"]*"' | head -1 | cut -d'"' -f4)

TASK_ID=$(echo "$TASK_ARN" | grep -o '[^/]*$')
CLUSTER_NAME=$(echo "$CLUSTER" | grep -o '[^/]*$')
TIMESTAMP=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# ── Configuración de nginx con autenticación por header ────────────────────────
#
# El bloque map{} asigna $auth_valid = 1 solo cuando el header X-API-Key
# coincide exactamente con el valor inyectado desde SSM.
# El valor de $API_KEY se expande aquí por el shell — nginx nunca lo ve
# en texto plano en los logs ni en el estado de Terraform.
#
# Nota: map{} debe estar en el contexto http{}, que es donde se incluyen
# los ficheros de /etc/nginx/conf.d/ en la imagen nginx:alpine.
cat > /etc/nginx/conf.d/default.conf << CONF
map \$http_x_api_key \$auth_valid {
    default    0;
    "$API_KEY" 1;
}

server {
    listen 8080;

    # GET /  → devuelve metadatos de la tarea; requiere X-API-Key válida
    location / {
        if (\$auth_valid = 0) {
            add_header Content-Type "application/json" always;
            return 401 '{"error":"Unauthorized","message":"Header X-API-Key ausente o invalido"}';
        }

        root /usr/share/nginx/html;
        try_files /index.json =404;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    # GET /health  → health check sin autenticación (necesario para el Circuit Breaker)
    location /health {
        default_type application/json;
        return 200 '{"status":"ok","service":"api"}';
        add_header Cache-Control "no-cache";
    }
}
CONF

# Genera la respuesta JSON con metadatos de esta tarea Fargate
cat > /usr/share/nginx/html/index.json << JSON
{
  "service":     "api",
  "task_id":     "$TASK_ID",
  "cluster":     "$CLUSTER_NAME",
  "family":      "$FAMILY",
  "revision":    "$REVISION",
  "region":      "$APP_REGION",
  "launch_type": "FARGATE",
  "timestamp":   "$TIMESTAMP"
}
JSON

exec nginx -g 'daemon off;'
