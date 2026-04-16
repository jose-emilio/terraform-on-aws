#!/bin/bash
set -euo pipefail

# ── Dependencias ──────────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3-pip

pip3 install flask boto3 redis

# ── Recupera el AUTH token de Redis desde Secrets Manager ─────────────────────
REDIS_AUTH=$(aws secretsmanager get-secret-value \
  --secret-id "${redis_secret_name}" \
  --region "${region}" \
  --query SecretString \
  --output text)

# ── Descarga la aplicacion Flask desde S3 ────────────────────────────────────
mkdir -p /opt/app
aws s3 cp "s3://${bucket_name}/app.py" /opt/app/app.py --region "${region}"

# ── Fichero de entorno ────────────────────────────────────────────────────────
cat > /opt/app/.env <<EOF
DYNAMO_TABLE=${dynamo_table}
EVENTS_TABLE=${events_table}
REDIS_HOST=${redis_host}
REDIS_PORT=6379
REDIS_AUTH=$${REDIS_AUTH}
CACHE_TTL=${cache_ttl}
AWS_DEFAULT_REGION=${region}
PROJECT=${project}
EOF
chmod 600 /opt/app/.env

# ── Seed inicial de productos en DynamoDB ─────────────────────────────────────
# Solo siembra datos si la tabla esta vacia.
python3 <<'PYEOF'
import boto3, os, uuid, sys
from datetime import datetime, timezone

region       = "${region}"
dynamo_table = "${dynamo_table}"

dynamo = boto3.resource("dynamodb", region_name=region)
table  = dynamo.Table(dynamo_table)

# Comprueba si ya hay productos para evitar duplicados en reinicios
resp = table.scan(Select="COUNT")
if resp.get("Count", 0) > 0:
    print(f"La tabla ya contiene {resp['Count']} productos. Omitiendo seed.")
    sys.exit(0)

products = [
    ("Electronics", "Laptop Pro 15",       "Laptop ARM de alto rendimiento",     129900, "active",       12),
    ("Electronics", "USB-C Hub 7-en-1",    "Hub multipuerto con HDMI y PD 100W",  3999, "active",      150),
    ("Electronics", "Raton Inalambrico",   "Ergonom. silencioso, 90 dias bat.",   2999, "active",       80),
    ("Electronics", "SSD Externo 1TB",     "USB 3.2 Gen2, 1000 MB/s lectura",    8999, "inactive",     25),
    ("Books",       "Python Cookbook",     "Recetas avanzadas de Python 3",       3499, "active",       45),
    ("Books",       "Clean Code",          "El arte del codigo limpio",           2999, "active",       60),
    ("Books",       "AWS en Accion",       "Guia practica de AWS",                4499, "active",       30),
    ("Clothing",    "Camiseta Dev L",      "I ship therefore I am, 100% algodon", 1999, "active",      100),
    ("Clothing",    "Sudadera Gris M",     "Sudadera premium de algodon organico",5999, "active",       40),
    ("Clothing",    "Gorra Negra",         "Gorra bordada logo, talla unica",     1499, "inactive",     75),
    ("Food",        "Cafe Specialty 500g", "Arabica origen unico, tueste medio",  1699, "active",      200),
    ("Food",        "Barras Energia x12",  "Sabores mixtos, sin gluten",          1299, "active",      500),
    ("Tools",       "Teclado Mecanico TKL","Cherry MX Blue, retroiluminacion RGB",14999,"active",      20),
    ("Tools",       "Soporte Monitor Dual","Ajuste de altura y angulo independ.", 4999, "active",       35),
    ("Tools",       "Kit Organiz. Cables", "Gestion de escritorio, 18 piezas",     899, "discontinued", 90),
]

now = datetime.now(timezone.utc).isoformat()
with table.batch_writer() as batch:
    for category, name, desc, price_cents, status, stock in products:
        batch.put_item(Item={
            "category":    category,
            "product_id":  str(uuid.uuid4())[:8],
            "name":        name,
            "description": desc,
            "price_cents": price_cents,
            "status":      status,
            "stock":       stock,
            "created_at":  now,
        })

print(f"Seed completado: {len(products)} productos en {dynamo_table}")
PYEOF

# ── Servicio systemd ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/lab36-app.service <<'SVCEOF'
[Unit]
Description=Lab36 NoSQL Product Catalog
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/app
EnvironmentFile=/opt/app/.env
ExecStart=/usr/bin/python3 /opt/app/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable lab36-app
systemctl start lab36-app
