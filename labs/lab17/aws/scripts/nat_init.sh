#!/bin/bash
set -euo pipefail

# Instalar SSM Agent (AL2023 minimal no lo incluye)
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Habilitar IP forwarding en el kernel
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-nat.conf
sysctl -p /etc/sysctl.d/90-nat.conf

# Instalar iptables y configurar MASQUERADE
# AL2023 minimal usa nftables como backend; iptables-nft proporciona
# los comandos iptables como capa de compatibilidad.
dnf install -y iptables-nft

# MASQUERADE: reescribe la IP origen de los paquetes reenviados
# con la IP pública de esta instancia, permitiendo que las subredes
# privadas accedan a Internet a través de ella.
iptables -t nat -A POSTROUTING -o ens5 -s ${vpc_cidr} -j MASQUERADE
iptables -A FORWARD -i ens5 -o ens5 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ens5 -o ens5 -j ACCEPT
