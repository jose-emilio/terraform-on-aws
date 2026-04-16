#!/bin/bash
# ── Generador de tráfico para Lab47 ──────────────────────────────────────────
# Genera tráfico de red variado para alimentar el VPC Flow Log:
#   - Peticiones HTTP salientes  → registros ACCEPT en el flow log
#   - El tráfico entrante bloqueado por el SG → registros REJECT

cat > /usr/local/bin/traffic-gen.sh << 'SCRIPT'
#!/bin/bash
while true; do
  TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Petición HTTP al endpoint de IP pública de AWS
  if curl -s --max-time 5 http://checkip.amazonaws.com > /dev/null 2>&1; then
    echo "$TS [OK] HTTP checkip.amazonaws.com"
  else
    echo "$TS [FAIL] HTTP checkip.amazonaws.com"
  fi

  # Petición HTTPS para generar tráfico en el puerto 443
  if curl -s --max-time 5 https://aws.amazon.com > /dev/null 2>&1; then
    echo "$TS [OK] HTTPS aws.amazon.com"
  else
    echo "$TS [FAIL] HTTPS aws.amazon.com"
  fi

  INTERVAL=$(( RANDOM % 30 + 15 ))
  echo "$TS [SLEEP] $${INTERVAL}s hasta el siguiente ciclo"
  sleep $INTERVAL
done
SCRIPT

chmod +x /usr/local/bin/traffic-gen.sh
nohup /usr/local/bin/traffic-gen.sh >> /var/log/traffic-gen.log 2>&1 &
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [INIT] traffic-gen arrancado (PID $!)" >> /var/log/traffic-gen.log
