#!/bin/bash
set -euo pipefail

# Instalar SSM Agent (AL2023 minimal no lo incluye)
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Instalar y configurar un servidor web basico para el health check del ALB
dnf install -y httpd
INSTANCE_ID=$(ec2-metadata -i | cut -d' ' -f2)
AZ=$(ec2-metadata -z | cut -d' ' -f2)
cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html>
<body>
  <h1>Lab18 — Seguridad y Control de Trafico en VPC</h1>
  <p>Instancia: ${INSTANCE_ID}</p>
  <p>AZ: ${AZ}</p>
</body>
</html>
HTML
systemctl enable httpd
systemctl start httpd
