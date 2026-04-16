#!/bin/bash
set -e

# ── 1. Instalar CloudWatch Agent ─────────────────────────────────────────────
dnf install -y amazon-cloudwatch-agent

# ── 2. Configurar el agente ──────────────────────────────────────────────────
# log_group_name se inyecta por Terraform via templatefile()
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWAGENT_EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app.log",
            "log_group_name": "${log_group_name}",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      }
    }
  }
}
CWAGENT_EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# ── 3. Crear el generador de logs ────────────────────────────────────────────
# El script escribe entradas INFO/WARN/ERROR en /var/log/app.log cada 1-10 s.
# Ratio aproximado: 67% INFO · 17% WARN · 16% ERROR.
cat > /usr/local/bin/log-gen.sh << 'LOGGEN_EOF'
#!/bin/bash
# Genera logs INFO/WARN/ERROR con un ratio aproximado de 50% / 25% / 25%.
# Intervalo: 0.5-2 segundos para producir datos visibles rápidamente.
while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  R=$((RANDOM % 4))
  if [ "$R" -lt 2 ]; then
    IDX=$((RANDOM % 8))
    case $IDX in
      0) MSG="Request processed in $((RANDOM % 50 + 5))ms" ;;
      1) MSG="Health check passed" ;;
      2) MSG="Cache hit ratio $((RANDOM % 10 + 88))%" ;;
      3) MSG="DB query OK in $((RANDOM % 20 + 3))ms" ;;
      4) MSG="Session started for user-$((RANDOM % 1000))" ;;
      5) MSG="Config reloaded successfully" ;;
      6) MSG="Metrics flushed to CloudWatch" ;;
      *) MSG="Scheduled task completed in $((RANDOM % 200 + 50))ms" ;;
    esac
    echo "$TS [INFO] $MSG" >> /var/log/app.log
  elif [ "$R" -eq 2 ]; then
    IDX=$((RANDOM % 6))
    case $IDX in
      0) MSG="Memory usage at $((RANDOM % 20 + 70))%" ;;
      1) MSG="Slow query detected: $((RANDOM % 5 + 2)).$((RANDOM % 9))s" ;;
      2) MSG="Connection pool at $((RANDOM % 15 + 75))% capacity" ;;
      3) MSG="Retry attempt $((RANDOM % 3 + 1)) for upstream service" ;;
      4) MSG="Response time degraded: $((RANDOM % 500 + 500))ms" ;;
      *) MSG="Disk usage at $((RANDOM % 15 + 75))% on /dev/xvda1" ;;
    esac
    echo "$TS [WARN] $MSG" >> /var/log/app.log
  else
    IDX=$((RANDOM % 6))
    case $IDX in
      0) MSG="Database connection timeout after 30s" ;;
      1) MSG="Failed to process payment request" ;;
      2) MSG="Authentication service unavailable" ;;
      3) MSG="Out of memory: kill process or sacrifice child" ;;
      4) MSG="SSL certificate validation failed for api.internal" ;;
      *) MSG="Unhandled exception in order processor: NullPointerException" ;;
    esac
    echo "$TS [ERROR] $MSG" >> /var/log/app.log
  fi
  # Intervalo 0.5-2 segundos
  sleep $(awk "BEGIN{printf \"%.1f\", 0.5 + ($RANDOM % 16) * 0.1}")
done
LOGGEN_EOF

chmod +x /usr/local/bin/log-gen.sh

# ── 4. Registrar log-gen como servicio systemd ───────────────────────────────
cat > /etc/systemd/system/log-gen.service << 'LOGSVC_EOF'
[Unit]
Description=Application Log Generator — Lab46
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/log-gen.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
LOGSVC_EOF

systemctl daemon-reload
systemctl enable --now log-gen
