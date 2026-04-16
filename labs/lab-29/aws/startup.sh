#!/bin/sh
set -e

# Obtiene metadatos de esta tarea ECS (servicio Web) desde el endpoint v4.
TASK_META=$(wget -qO- "${ECS_CONTAINER_METADATA_URI_V4}/task" 2>/dev/null || echo '{}')

TASK_ARN=$(echo "$TASK_META"  | grep -o '"TaskARN":"[^"]*"'  | head -1 | cut -d'"' -f4)
CLUSTER=$(echo "$TASK_META"   | grep -o '"Cluster":"[^"]*"'  | head -1 | cut -d'"' -f4)
FAMILY=$(echo "$TASK_META"    | grep -o '"Family":"[^"]*"'   | head -1 | cut -d'"' -f4)
REVISION=$(echo "$TASK_META"  | grep -o '"Revision":"[^"]*"' | head -1 | cut -d'"' -f4)

TASK_ID=$(echo "$TASK_ARN" | grep -o '[^/]*$')
CLUSTER_NAME=$(echo "$CLUSTER" | grep -o '[^/]*$')
LAUNCH=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

if [ -n "$API_KEY" ]; then
  API_KEY_DISPLAY="$(echo "$API_KEY" | cut -c1-6)••••••••••••"
else
  API_KEY_DISPLAY="(no inyectada)"
fi

# ── Configuración de nginx ─────────────────────────────────────────────────────
# Añade proxy_pass para /api-data → http://api:8080/ (resuelto por Service Connect).
# El navegador llama a /api-data desde el mismo origen (sin CORS) y nginx reenvía
# la petición al microservicio API internamente sin exponer el puerto 8080 al exterior.
cat > /etc/nginx/conf.d/default.conf << CONF
server {
    listen 80;

    location / {
        root  /usr/share/nginx/html;
        index index.html;
    }

    location /api-data {
        proxy_pass            http://api:8080/;
        proxy_set_header      Host api;
        # El shell expande \$API_KEY aquí; nginx recibe el valor literal.
        proxy_set_header      X-API-Key "$API_KEY";
        proxy_read_timeout    5s;
        proxy_connect_timeout 5s;
        add_header            Cache-Control "no-cache, no-store";
    }
}
CONF

# ── Página HTML ────────────────────────────────────────────────────────────────
cat > /usr/share/nginx/html/index.html << HTML
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lab29 · ECS Fargate</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f172a;
      color: #e2e8f0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem 1rem;
    }

    .wrapper {
      display: grid;
      grid-template-columns: 1fr auto 1fr;
      align-items: start;
      gap: 1.25rem;
      max-width: 960px;
      width: 100%;
    }

    @media (max-width: 680px) { .wrapper { grid-template-columns: 1fr; } }

    .card {
      background: #1e293b;
      border: 1px solid #334155;
      border-radius: 12px;
      padding: 1.75rem 2rem;
      box-shadow: 0 25px 50px rgba(0,0,0,0.5);
    }

    .badge {
      display: inline-block;
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      padding: 0.2rem 0.7rem;
      border-radius: 999px;
      margin-bottom: 1rem;
    }
    .badge-web { background: #0891b2; color: #fff; }
    .badge-api { background: #7c3aed; color: #fff; }

    h2 { font-size: 1.4rem; font-weight: 700; color: #f1f5f9; margin-bottom: 0.2rem; }
    .subtitle { font-size: 0.82rem; color: #94a3b8; margin-bottom: 1.25rem; }

    .grid { display: grid; gap: 0.55rem; }

    .row {
      display: flex;
      align-items: center;
      gap: 0.7rem;
      background: #0f172a;
      border: 1px solid #1e3a5f;
      border-radius: 8px;
      padding: 0.6rem 0.85rem;
    }

    .icon { font-size: 1.1rem; flex-shrink: 0; width: 1.6rem; text-align: center; }
    .label { font-size: 0.65rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.07em; color: #64748b; line-height: 1; margin-bottom: 0.18rem; }
    .value { font-size: 0.85rem; color: #e2e8f0; font-family: "SFMono-Regular", Consolas, monospace; word-break: break-all; }

    .pill {
      display: inline-block;
      background: #083344;
      color: #67e8f9;
      border: 1px solid #164e63;
      border-radius: 999px;
      font-size: 0.68rem;
      font-weight: 700;
      padding: 0.1rem 0.55rem;
    }
    .pill-api {
      background: #2e1065;
      color: #c4b5fd;
      border-color: #4c1d95;
    }

    .secret  { color: #fcd34d; }
    .ok      { color: #4ade80; }
    .loading { color: #94a3b8; font-style: italic; }
    .error   { color: #f87171; }

    .arrow {
      display: flex;
      align-items: center;
      justify-content: center;
      color: #475569;
      font-size: 1.75rem;
      align-self: center;
    }
    @media (max-width: 680px) { .arrow { transform: rotate(90deg); } }

    .footer { margin-top: 1.25rem; padding-top: 0.9rem; border-top: 1px solid #334155; font-size: 0.72rem; color: #475569; text-align: center; }

    #refresh-btn {
      margin-top: 0.75rem;
      width: 100%;
      padding: 0.4rem;
      background: #1e3a5f;
      border: 1px solid #164e63;
      border-radius: 6px;
      color: #67e8f9;
      font-size: 0.75rem;
      cursor: pointer;
      transition: background 0.15s;
    }
    #refresh-btn:hover { background: #164e63; }
  </style>
</head>
<body>
  <div class="wrapper">

    <!-- ── Tarjeta: Servicio Web ────────────────────────────────────────── -->
    <div class="card">
      <div class="badge badge-web">Web · Fargate</div>
      <h2>Servicio Web</h2>
      <p class="subtitle">Tarea activa — nginx sirviendo la UI</p>

      <div class="grid">
        <div class="row">
          <div class="icon">📦</div>
          <div>
            <div class="label">Task ID</div>
            <div class="value">$TASK_ID</div>
          </div>
        </div>
        <div class="row">
          <div class="icon">☁️</div>
          <div>
            <div class="label">Cluster</div>
            <div class="value">$CLUSTER_NAME</div>
          </div>
        </div>
        <div class="row">
          <div class="icon">📋</div>
          <div>
            <div class="label">Task Definition</div>
            <div class="value">$FAMILY &nbsp;<span class="pill">rev $REVISION</span></div>
          </div>
        </div>
        <div class="row">
          <div class="icon">🌍</div>
          <div>
            <div class="label">Región / Entorno</div>
            <div class="value">$APP_REGION &nbsp;·&nbsp; $APP_ENV</div>
          </div>
        </div>
        <div class="row">
          <div class="icon">🔑</div>
          <div>
            <div class="label">API Key (SSM SecureString)</div>
            <div class="value secret">$API_KEY_DISPLAY</div>
          </div>
        </div>
      </div>

      <div class="footer">Arrancada el $LAUNCH</div>
    </div>

    <!-- ── Flecha Service Connect ──────────────────────────────────────── -->
    <div class="arrow" title="Service Connect: http://api:8080/">⟶</div>

    <!-- ── Tarjeta: Microservicio API ─────────────────────────────────── -->
    <div class="card">
      <div class="badge badge-api">API · Service Connect</div>
      <h2>Microservicio API</h2>
      <p class="subtitle">Datos obtenidos vía <code>http://api:8080</code></p>

      <div class="grid" id="api-grid">
        <div class="row">
          <div class="icon">🔄</div>
          <div>
            <div class="label">Estado</div>
            <div class="value loading" id="api-status">Conectando…</div>
          </div>
        </div>
        <div class="row" id="api-task-row" style="display:none">
          <div class="icon">📦</div>
          <div>
            <div class="label">Task ID (API)</div>
            <div class="value" id="api-task-id">—</div>
          </div>
        </div>
        <div class="row" id="api-def-row" style="display:none">
          <div class="icon">📋</div>
          <div>
            <div class="label">Task Definition (API)</div>
            <div class="value" id="api-family">—</div>
          </div>
        </div>
        <div class="row" id="api-ts-row" style="display:none">
          <div class="icon">🕐</div>
          <div>
            <div class="label">Timestamp API</div>
            <div class="value" id="api-timestamp">—</div>
          </div>
        </div>
        <div class="row" id="api-launch-row" style="display:none">
          <div class="icon">🚀</div>
          <div>
            <div class="label">Launch Type</div>
            <div class="value"><span class="pill pill-api" id="api-launch">FARGATE</span></div>
          </div>
        </div>
      </div>

      <button id="refresh-btn" onclick="fetchApi()">↻ Refrescar datos de la API</button>

      <div class="footer" id="api-footer">Actualizando cada 15 s…</div>
    </div>

  </div>

  <script>
    function fetchApi() {
      const status  = document.getElementById('api-status');
      const footer  = document.getElementById('api-footer');
      const rows    = ['api-task-row','api-def-row','api-ts-row','api-launch-row'];

      status.textContent = 'Conectando…';
      status.className   = 'value loading';

      fetch('/api-data')
        .then(function(r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.json();
        })
        .then(function(d) {
          status.textContent = '✓ Conectado';
          status.className   = 'value ok';

          document.getElementById('api-task-id').textContent  = d.task_id   || '—';
          document.getElementById('api-family').innerHTML     =
            (d.family || '—') + ' &nbsp;<span class="pill pill-api">rev ' + (d.revision || '?') + '</span>';
          document.getElementById('api-timestamp').textContent= d.timestamp || '—';

          rows.forEach(function(id) {
            document.getElementById(id).style.display = '';
          });

          footer.textContent = 'Última respuesta: ' + new Date().toLocaleTimeString();
        })
        .catch(function(err) {
          status.textContent = '✗ ' + err.message;
          status.className   = 'value error';
          rows.forEach(function(id) {
            document.getElementById(id).style.display = 'none';
          });
          footer.textContent = 'Reintentando en 15 s…';
        });
    }

    fetchApi();
    setInterval(fetchApi, 15000);
  </script>
</body>
</html>
HTML

exec nginx -g 'daemon off;'
