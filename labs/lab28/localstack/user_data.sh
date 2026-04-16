#!/bin/bash
# Versión simplificada para LocalStack: sin IMDSv2 (no hay metadatos reales).
LAUNCH=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

dnf install -y httpd

sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf

cat > /etc/httpd/conf.d/lab28.conf << 'CONF'
Header always set Connection "close"
CONF

cat > /var/www/html/index.html << HTML
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lab28 · ${app_version}</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
    .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 2rem 2.5rem; max-width: 480px; width: 90%; box-shadow: 0 25px 50px rgba(0,0,0,0.5); }
    .badge { display: inline-block; background: #f59e0b; color: #1c1917; font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; padding: 0.25rem 0.75rem; border-radius: 999px; margin-bottom: 1.25rem; }
    h1 { font-size: 1.75rem; font-weight: 700; color: #f1f5f9; margin-bottom: 0.25rem; }
    .subtitle { font-size: 0.9rem; color: #94a3b8; margin-bottom: 1.75rem; }
    .grid { display: grid; gap: 0.75rem; }
    .row { display: flex; align-items: center; gap: 0.75rem; background: #0f172a; border: 1px solid #1e3a5f; border-radius: 8px; padding: 0.75rem 1rem; }
    .icon { font-size: 1.25rem; flex-shrink: 0; width: 1.75rem; text-align: center; }
    .label { font-size: 0.7rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: #64748b; line-height: 1; margin-bottom: 0.2rem; }
    .value { font-size: 0.9rem; color: #e2e8f0; font-family: "SFMono-Regular", Consolas, monospace; }
    .footer { margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #334155; font-size: 0.75rem; color: #475569; text-align: center; }
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">LocalStack</div>
    <h1>Instancia simulada</h1>
    <p class="subtitle">Escalabilidad y Alta Disponibilidad con Terraform</p>
    <div class="grid">
      <div class="row">
        <div class="icon">🏷️</div>
        <div><div class="label">Versión</div><div class="value">${app_version}</div></div>
      </div>
      <div class="row">
        <div class="icon">🌍</div>
        <div><div class="label">Entorno</div><div class="value">LocalStack (simulado)</div></div>
      </div>
    </div>
    <div class="footer">Arrancada el $LAUNCH</div>
  </div>
</body>
</html>
HTML

systemctl enable --now httpd
