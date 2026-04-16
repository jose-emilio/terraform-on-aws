#!/bin/bash
set -euo pipefail

# ── Dependencias ──────────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3-pip postgresql15

pip3 install flask psycopg2-binary boto3

# ── Recupera credenciales desde Secrets Manager ───────────────────────────────
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${secret_name}" \
  --region "${region}" \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
DB_PORT=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['port'])")
DB_NAME=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['dbname'])")
DB_USER=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ── Espera a que RDS este aceptando conexiones ────────────────────────────────
# Aunque Terraform espera a que la instancia RDS este en estado "available",
# el motor PostgreSQL puede tardar unos segundos adicionales en aceptar
# conexiones TCP tras el primer arranque. El bucle reintenta cada 10 segundos
# hasta un maximo de 5 minutos antes de abortar.

echo "Esperando a que RDS este listo..."
MAX_RETRIES=30
RETRY=0
until PGPASSWORD="$DB_PASS" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require connect_timeout=5" \
  -c "SELECT 1" &>/dev/null; do
  RETRY=$((RETRY + 1))
  if [ "$RETRY" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: RDS no respondio tras $((MAX_RETRIES * 10)) segundos. Abortando." >&2
    exit 1
  fi
  echo "Intento $RETRY/$MAX_RETRIES — reintentando en 10 segundos..."
  sleep 10
done
echo "RDS listo tras $((RETRY * 10)) segundos."

# ── Bootstrap de la base de datos ────────────────────────────────────────────
# Comprueba si la tabla ya existe antes de ejecutar el DDL/DML.
# En un ASG varias instancias pueden arrancar en paralelo o en distintos
# momentos: la comprobacion evita escrituras innecesarias y posibles
# condiciones de carrera en el INSERT.

ALREADY_BOOTSTRAPPED=$(PGPASSWORD="$DB_PASS" psql \
  "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require connect_timeout=5" \
  -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='customers'" \
  2>/dev/null | tr -d ' ')

if [ "$${ALREADY_BOOTSTRAPPED:-0}" = "0" ]; then
  echo "Ejecutando bootstrap de la base de datos..."
  PGPASSWORD="$DB_PASS" psql \
    "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS customers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(120) NOT NULL,
    email       VARCHAR(200) UNIQUE NOT NULL,
    country     VARCHAR(80)  NOT NULL,
    plan        VARCHAR(20)  NOT NULL CHECK (plan IN ('free','starter','pro','enterprise')),
    mrr         NUMERIC(10,2) NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO customers (name, email, country, plan, mrr) VALUES
  ('Acme Corp',          'billing@acmecorp.com',       'US', 'enterprise', 4200.00),
  ('Globex Industries',  'admin@globex.io',             'DE', 'pro',        890.00),
  ('Initech Solutions',  'ops@initech.net',             'GB', 'pro',        890.00),
  ('Umbrella Ltd',       'accounts@umbrella.co.uk',     'GB', 'enterprise', 3600.00),
  ('Soylent Systems',    'hello@soylentsystems.com',    'CA', 'starter',    149.00),
  ('Massive Dynamic',    'finance@massivedynamic.com',  'US', 'enterprise', 5800.00),
  ('Dunder Mifflin',     'michael@dundermifflin.com',   'US', 'starter',    149.00),
  ('Vandelay Industries','art@vandelay.com',             'US', 'pro',        890.00),
  ('Bluth Company',      'gob@bluthcompany.com',        'US', 'free',         0.00),
  ('Pied Piper',         'richard@piedpiper.com',       'US', 'pro',        890.00),
  ('Hooli',              'gavin@hooli.xyz',             'US', 'enterprise', 9900.00),
  ('Los Pollos Hermanos','gus@lph.mx',                  'MX', 'starter',    149.00),
  ('Prestige Worldwide', 'boats@prestigeww.com',        'AU', 'free',         0.00),
  ('Cyberdyne Systems',  'miles@cyberdyne.ai',          'US', 'enterprise', 7200.00),
  ('Wonka Industries',   'willy@wonka.com',             'CH', 'pro',        890.00)
ON CONFLICT (email) DO NOTHING;
SQLEOF
else
  echo "La base de datos ya esta inicializada. Omitiendo bootstrap."
fi

# ── Descarga la aplicacion Flask desde S3 ────────────────────────────────────
# app.py se sube a S3 mediante aws_s3_object en Terraform.
# Descargarlo en tiempo de arranque desacopla el codigo de la aplicacion
# del user_data, permite actualizar la app sin recrear el Launch Template
# y elimina el limite de 16 KB de user_data.

mkdir -p /opt/app
aws s3 cp "s3://${bucket_name}/app.py" /opt/app/app.py --region "${region}"

# ── Fichero de entorno ────────────────────────────────────────────────────────
cat > /opt/app/.env <<EOF
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=${db_name}
DB_USER=$DB_USER
DB_PASS=$DB_PASS
REPLICA_HOST=${replica_host}
REPLICA_PORT=${replica_port}
PROJECT=${project}
DB_INSTANCE_ID=${db_instance_id}
AWS_REGION=${region}
EOF
chmod 600 /opt/app/.env

# ── Servicio systemd ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/lab35-app.service <<'SVCEOF'
[Unit]
Description=Lab35 CRM Dashboard
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
systemctl enable lab35-app
systemctl start lab35-app
