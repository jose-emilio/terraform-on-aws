"""
Lab36 — NoSQL Product Catalog
Flask app con CRUD sobre DynamoDB + capa de cache Redis.
Muestra latencia de lecturas (cache HIT vs MISS) y escrituras en tiempo real.
"""
import os, time, json, uuid, decimal
from datetime import datetime, timezone
from flask import Flask, request, redirect, url_for
import boto3
from boto3.dynamodb.conditions import Key
import redis as redis_lib

app = Flask(__name__)

# ── Configuracion desde variables de entorno ──────────────────────────────────
REGION       = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
PROJECT      = os.environ.get("PROJECT", "lab36")
DYNAMO_TABLE = os.environ["DYNAMO_TABLE"]
EVENTS_TABLE = os.environ["EVENTS_TABLE"]
REDIS_HOST   = os.environ["REDIS_HOST"]
REDIS_PORT   = int(os.environ.get("REDIS_PORT", 6379))
REDIS_AUTH   = os.environ["REDIS_AUTH"]
CACHE_TTL    = int(os.environ.get("CACHE_TTL", 60))

CATEGORIES = ["Electronics", "Books", "Clothing", "Food", "Tools"]
STATUSES   = ["active", "inactive", "discontinued"]

STATUS_STYLE = {
    "active":       ("#00c853", "#e8f5e9", "ACTIVO"),
    "inactive":     ("#ff6d00", "#fff3e0", "INACTIVO"),
    "discontinued": ("#b71c1c", "#ffebee", "DESCONT."),
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────
dynamo          = boto3.resource("dynamodb", region_name=REGION)
products_table  = dynamo.Table(DYNAMO_TABLE)
events_table_db = dynamo.Table(EVENTS_TABLE)

# ── Estadísticas en memoria ───────────────────────────────────────────────────
_stats = {
    "hits": 0, "misses": 0,
    "hit_lat_ms": 0.0, "miss_lat_ms": 0.0,
    "writes": 0, "write_lat_ms": 0.0,
}


# ── Redis helpers ─────────────────────────────────────────────────────────────

def get_redis():
    """Crea una conexion Redis con TLS y AUTH. Devuelve None si falla."""
    try:
        r = redis_lib.Redis(
            host=REDIS_HOST, port=REDIS_PORT, password=REDIS_AUTH,
            ssl=True, ssl_cert_reqs=None, decode_responses=True,
            socket_connect_timeout=2, socket_timeout=2,
        )
        r.ping()
        return r
    except Exception:
        return None


class _DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, decimal.Decimal):
            return float(obj)
        return super().default(obj)


def cache_get(r, key):
    """Intenta leer del cache. Devuelve (value|None, latency_ms, 'HIT'|'MISS'|'ERROR')."""
    if not r:
        return None, 0.0, "ERROR"
    t0 = time.perf_counter()
    try:
        raw = r.get(key)
        lat = (time.perf_counter() - t0) * 1000
        if raw:
            _stats["hits"] += 1
            _stats["hit_lat_ms"] += lat
            return json.loads(raw), round(lat, 2), "HIT"
        _stats["misses"] += 1
        _stats["miss_lat_ms"] += lat
        return None, round(lat, 2), "MISS"
    except Exception:
        return None, 0.0, "ERROR"


def cache_set(r, key, value):
    if not r:
        return
    try:
        r.setex(key, CACHE_TTL, json.dumps(value, cls=_DecimalEncoder))
    except Exception:
        pass


def cache_invalidate(r, *keys):
    if not r:
        return
    try:
        r.delete(*keys)
    except Exception:
        pass


def cache_flush_all(r):
    """Elimina todas las claves del namespace lab36:products:*."""
    if not r:
        return 0
    try:
        keys = r.keys("lab36:products:*")
        if keys:
            r.delete(*keys)
            return len(keys)
    except Exception:
        pass
    return 0


# ── DynamoDB helpers ──────────────────────────────────────────────────────────

def _timed(fn, *args, **kwargs):
    """Ejecuta fn y devuelve (resultado, latencia_ms)."""
    t0 = time.perf_counter()
    result = fn(*args, **kwargs)
    return result, round((time.perf_counter() - t0) * 1000, 1)


def dynamo_scan_all():
    items, lat = _timed(lambda: products_table.scan()["Items"])
    items.sort(key=lambda x: (x.get("category", ""), x.get("name", "")))
    return items, lat


def dynamo_query_category(category):
    items, lat = _timed(
        lambda: products_table.query(
            KeyConditionExpression=Key("category").eq(category)
        )["Items"]
    )
    items.sort(key=lambda x: x.get("name", ""))
    return items, lat


def dynamo_query_status(status):
    """Usa el GSI by-status-index: PK=status, SK=price_cents (orden ascendente)."""
    items, lat = _timed(
        lambda: products_table.query(
            IndexName="by-status-index",
            KeyConditionExpression=Key("status").eq(status),
        )["Items"]
    )
    return items, lat


def get_recent_events(limit=12):
    try:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        resp = events_table_db.query(
            KeyConditionExpression=Key("event_date").eq(today),
            ScanIndexForward=False,
            Limit=limit,
        )
        return resp.get("Items", [])
    except Exception:
        return []


# ── Rutas Flask ───────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    return {"status": "ok"}, 200


@app.route("/", methods=["GET"])
def index():
    r = get_redis()
    redis_ok = r is not None

    filter_cat    = request.args.get("cat", "").strip()
    filter_status = request.args.get("status", "").strip()
    show_form     = request.args.get("form", "").strip()
    edit_cat      = request.args.get("edit_cat", "").strip()
    edit_id       = request.args.get("edit_id", "").strip()

    # Informacion de la ultima operacion (pasada como query param tras redirect)
    last_op     = request.args.get("op", "")
    last_lat    = request.args.get("lat", "")
    last_src    = request.args.get("src", "")
    last_cache  = request.args.get("cache", "")

    # Cache key basada en los filtros activos
    cache_key = f"lab36:products:{filter_cat or 'all'}:{filter_status or 'all'}"

    cached, cache_lat, cache_result = cache_get(r, cache_key)
    if cached is not None:
        products = cached
        read_lat = cache_lat
        read_src = "REDIS CACHE"
    else:
        if filter_cat:
            products, read_lat = dynamo_query_category(filter_cat)
        elif filter_status:
            products, read_lat = dynamo_query_status(filter_status)
        else:
            products, read_lat = dynamo_scan_all()
        read_src = "DYNAMODB"
        cache_set(r, cache_key, products)

    # Item de edicion (precarga el formulario)
    edit_item = None
    if show_form == "edit" and edit_cat and edit_id:
        try:
            resp = products_table.get_item(Key={"category": edit_cat, "product_id": edit_id})
            edit_item = resp.get("Item")
        except Exception:
            pass

    events = get_recent_events()

    # Calcular estadisticas de cache
    total_reads = _stats["hits"] + _stats["misses"]
    hit_rate    = round(_stats["hits"] / total_reads * 100, 1) if total_reads > 0 else 0.0
    avg_hit_lat = round(_stats["hit_lat_ms"] / _stats["hits"], 1) if _stats["hits"] > 0 else 0.0
    avg_miss_lat = round(_stats["miss_lat_ms"] / _stats["misses"], 1) if _stats["misses"] > 0 else 0.0
    avg_write_lat = round(_stats["write_lat_ms"] / _stats["writes"], 1) if _stats["writes"] > 0 else 0.0

    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    # ── HTML ─────────────────────────────────────────────────────────────────
    cat_options = "".join(
        f'<option value="{c}" {"selected" if filter_cat == c else ""}>{c}</option>'
        for c in CATEGORIES
    )
    status_options = "".join(
        f'<option value="{s}" {"selected" if filter_status == s else ""}>{s.capitalize()}</option>'
        for s in STATUSES
    )
    form_cat_options = "".join(
        f'<option value="{c}">{c}</option>' for c in CATEGORIES
    )
    form_status_options = "".join(
        f'<option value="{s}">{s.capitalize()}</option>' for s in STATUSES
    )

    # Banner ultima operacion
    op_icons = {"added": "✚", "updated": "✎", "deleted": "✕", "flushed": "⟳"}
    op_labels = {"added": "Producto añadido", "updated": "Producto actualizado",
                 "deleted": "Producto eliminado", "flushed": "Caché vaciado"}
    if last_op in op_labels:
        lat_info = f" &nbsp;·&nbsp; Latencia: <strong>{last_lat} ms</strong>" if last_lat else ""
        src_info = f" &nbsp;·&nbsp; <em>{last_src}</em>" if last_src else ""
        op_banner = (
            f'<div class="banner op-banner">'
            f'{op_icons.get(last_op, "✓")} {op_labels[last_op]}{lat_info}{src_info}'
            f'</div>'
        )
    else:
        op_banner = ""

    # Indicador de fuente de lectura actual
    if cache_result == "HIT":
        src_badge = (
            f'<span class="src-badge hit">⚡ REDIS HIT &nbsp;·&nbsp; {read_lat} ms</span>'
        )
    elif cache_result == "MISS":
        src_badge = (
            f'<span class="src-badge miss">◎ CACHE MISS — DynamoDB: {read_lat} ms</span>'
        )
    else:
        src_badge = f'<span class="src-badge db">◎ DynamoDB: {read_lat} ms</span>'

    # Filas de productos
    rows_html = ""
    for p in products:
        price = float(p.get("price_cents", 0)) / 100
        status = p.get("status", "active")
        sc, _, slabel = STATUS_STYLE.get(status, ("#888", "#eee", status.upper()))
        badge = (
            f'<span style="background:{sc}22;color:{sc};border:1px solid {sc}55;'
            f'padding:2px 9px;border-radius:10px;font-size:.72rem;font-weight:700;'
            f'letter-spacing:.4px">{slabel}</span>'
        )
        stock = int(p.get("stock", 0))
        stock_color = "#ef5350" if stock < 10 else "#66bb6a" if stock > 50 else "#ffa726"
        rows_html += (
            f'<tr>'
            f'<td style="font-weight:600;color:#80cbc4">{p.get("category","")}</td>'
            f'<td><div style="font-weight:600">{p.get("name","")}</div>'
            f'<div style="color:#546e7a;font-size:.75rem">{p.get("description","")[:50]}</div></td>'
            f'<td style="text-align:right;font-weight:700;color:#fff">${price:,.2f}</td>'
            f'<td>{badge}</td>'
            f'<td style="text-align:center;color:{stock_color};font-weight:600">{stock}</td>'
            f'<td style="white-space:nowrap">'
            f'<a href="/?form=edit&edit_cat={p.get("category","")}&edit_id={p.get("product_id","")}" '
            f'class="btn-sm btn-edit">✎ Editar</a>'
            f'<form method="post" action="/delete" style="display:inline" '
            f'onsubmit="return confirm(\'¿Eliminar {p.get("name","")}?\');">'
            f'<input type="hidden" name="category" value="{p.get("category","")}">'
            f'<input type="hidden" name="product_id" value="{p.get("product_id","")}">'
            f'<button type="submit" class="btn-sm btn-del">✕</button>'
            f'</form></td>'
            f'</tr>'
        )
    if not rows_html:
        rows_html = '<tr><td colspan="6" style="text-align:center;color:#546e7a;padding:2.5rem">Sin resultados para los filtros seleccionados</td></tr>'

    # Formulario Add / Edit
    form_html = ""
    if show_form == "add":
        form_html = _render_form(None, form_cat_options, form_status_options)
    elif show_form == "edit" and edit_item:
        form_html = _render_form(edit_item, form_cat_options, form_status_options)

    # Panel de eventos CDC
    events_html = ""
    event_type_style = {
        "INSERT": ("#00c853", "✚"),
        "MODIFY": ("#00b0ff", "✎"),
        "REMOVE": ("#ef5350", "✕"),
    }
    for ev in events:
        etype = ev.get("event_type", "?")
        ec, eicon = event_type_style.get(etype, ("#aaa", "·"))
        ts = ev.get("timestamp", "")[:19].replace("T", " ")
        events_html += (
            f'<div class="event-item">'
            f'<span style="color:{ec};font-weight:700;width:18px;display:inline-block">{eicon}</span>'
            f'<span style="color:#546e7a;font-size:.75rem;margin-right:.5rem">{ts[11:]}</span>'
            f'<span style="font-size:.82rem">{ev.get("summary","")}</span>'
            f'</div>'
        )
    if not events_html:
        events_html = '<div style="color:#546e7a;font-size:.82rem;padding:.5rem 0">Sin eventos hoy — realiza operaciones CRUD para ver el stream</div>'

    redis_dot = "ok" if redis_ok else "err"
    redis_label = "CONECTADO" if redis_ok else "NO DISPONIBLE"

    html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Lab36 · NoSQL Product Catalog</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{font-family:'Segoe UI',system-ui,sans-serif;
         background:linear-gradient(135deg,#050d1a 0%,#0a1628 50%,#0d2137 100%);
         min-height:100vh;color:#cfd8dc;padding:1.5rem 1rem}}
    a{{color:inherit;text-decoration:none}}
    .wrap{{max-width:1200px;margin:0 auto}}

    /* Header */
    .header{{display:flex;align-items:center;justify-content:space-between;margin-bottom:1.5rem;flex-wrap:wrap;gap:.5rem}}
    .title{{font-size:1.6rem;font-weight:800;color:#fff}}
    .title span{{color:#00bcd4}}
    .subtitle{{font-size:.78rem;color:#546e7a;margin-top:.15rem}}
    .redis-badge{{display:flex;align-items:center;gap:.5rem;background:rgba(255,255,255,.05);
                  border:1px solid rgba(255,255,255,.1);border-radius:8px;padding:.45rem .9rem;font-size:.8rem}}
    .dot{{width:9px;height:9px;border-radius:50%;flex-shrink:0}}
    .dot.ok{{background:#66bb6a;box-shadow:0 0 6px #66bb6a88}}
    .dot.err{{background:#ef5350;box-shadow:0 0 6px #ef535088}}

    /* Stats */
    .stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:.8rem;margin-bottom:1.2rem}}
    .stat{{background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.08);
           border-radius:10px;padding:.9rem 1rem;text-align:center}}
    .stat .val{{font-size:1.5rem;font-weight:800;color:#fff}}
    .stat .lbl{{font-size:.7rem;color:#546e7a;text-transform:uppercase;letter-spacing:.5px;margin-top:.15rem}}
    .stat.hit .val{{color:#00e676}}
    .stat.miss .val{{color:#ff5252}}
    .stat.lat-h .val{{color:#00bcd4}}
    .stat.lat-d .val{{color:#ffa726}}
    .stat.wr .val{{color:#ce93d8}}

    /* Banner */
    .banner{{border-radius:8px;padding:.7rem 1.2rem;margin-bottom:1rem;font-size:.85rem}}
    .op-banner{{background:rgba(0,188,212,.1);border:1px solid #00bcd455;color:#80deea}}

    /* Layout 2 columnas */
    .layout{{display:grid;grid-template-columns:1fr 320px;gap:1.2rem;align-items:start}}
    @media(max-width:900px){{.layout{{grid-template-columns:1fr}}}}

    /* Panel principal */
    .panel{{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);
            border-radius:12px;overflow:hidden}}
    .panel-hdr{{padding:.8rem 1.2rem;background:rgba(255,255,255,.04);
                display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem}}
    .panel-hdr h2{{font-size:.9rem;font-weight:700;color:#90caf9;text-transform:uppercase;letter-spacing:.5px}}

    /* Toolbar */
    .toolbar{{display:flex;gap:.6rem;flex-wrap:wrap;align-items:center}}
    .toolbar select,.toolbar input[type=text]{{background:rgba(255,255,255,.07);
      border:1px solid rgba(255,255,255,.13);border-radius:6px;color:#e0e0e0;
      padding:.4rem .75rem;font-size:.82rem;outline:none}}
    .toolbar select option{{background:#0d1b2a}}
    .btn{{border:none;border-radius:6px;padding:.42rem 1rem;cursor:pointer;
          font-size:.82rem;font-weight:600;transition:opacity .15s}}
    .btn:hover{{opacity:.85}}
    .btn-primary{{background:#00838f;color:#fff}}
    .btn-add{{background:#1565c0;color:#fff}}
    .btn-flush{{background:rgba(255,255,255,.08);color:#b0bec5;border:1px solid rgba(255,255,255,.13)}}
    .btn-clear{{background:transparent;color:#546e7a;border:1px solid rgba(255,255,255,.08)}}
    .btn-sm{{border-radius:5px;padding:.28rem .65rem;font-size:.75rem;cursor:pointer;
             font-weight:600;border:none;transition:opacity .15s;margin-left:.25rem}}
    .btn-sm:hover{{opacity:.8}}
    .btn-edit{{background:#1565c022;color:#90caf9;border:1px solid #1565c055}}
    .btn-del{{background:#b71c1c22;color:#ef9a9a;border:1px solid #b71c1c55}}

    /* Fuente de datos */
    .src-badge{{display:inline-flex;align-items:center;padding:.25rem .8rem;
                border-radius:6px;font-size:.75rem;font-weight:700;letter-spacing:.3px}}
    .src-badge.hit{{background:#00e67622;color:#00e676;border:1px solid #00e67644}}
    .src-badge.miss{{background:#ff525222;color:#ff7043;border:1px solid #ff525244}}
    .src-badge.db{{background:#ffa72622;color:#ffa726;border:1px solid #ffa72644}}

    /* Tabla */
    table{{width:100%;border-collapse:collapse;font-size:.84rem}}
    thead th{{padding:.65rem 1rem;text-align:left;font-size:.72rem;text-transform:uppercase;
               letter-spacing:.5px;color:#546e7a;font-weight:600;border-bottom:1px solid rgba(255,255,255,.07)}}
    tbody tr{{border-bottom:1px solid rgba(255,255,255,.04);transition:background .12s}}
    tbody tr:hover{{background:rgba(255,255,255,.03)}}
    td{{padding:.65rem 1rem;vertical-align:middle}}

    /* Formulario */
    .form-panel{{background:rgba(0,188,212,.05);border:1px solid rgba(0,188,212,.2);
                  border-radius:10px;padding:1.2rem;margin-bottom:1rem}}
    .form-panel h3{{color:#00bcd4;font-size:.9rem;font-weight:700;margin-bottom:.9rem;text-transform:uppercase;letter-spacing:.4px}}
    .form-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:.7rem}}
    .form-group label{{display:block;font-size:.75rem;color:#546e7a;margin-bottom:.25rem;text-transform:uppercase;letter-spacing:.4px}}
    .form-group input,.form-group select,.form-group textarea{{
      width:100%;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.13);
      border-radius:6px;color:#e0e0e0;padding:.45rem .75rem;font-size:.85rem;outline:none}}
    .form-group textarea{{resize:vertical;min-height:56px}}
    .form-group input::placeholder{{color:#546e7a}}
    .form-actions{{display:flex;gap:.6rem;margin-top:.9rem}}

    /* Sidebar */
    .sidebar{{display:flex;flex-direction:column;gap:1rem}}
    .side-panel{{background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);
                  border-radius:10px;padding:1rem}}
    .side-panel h3{{font-size:.8rem;font-weight:700;color:#90caf9;text-transform:uppercase;
                    letter-spacing:.5px;margin-bottom:.8rem}}

    /* Latencia bar */
    .lat-row{{display:flex;align-items:center;gap:.6rem;margin-bottom:.5rem;font-size:.8rem}}
    .lat-label{{width:90px;color:#78909c;font-size:.72rem}}
    .lat-bar-wrap{{flex:1;background:rgba(255,255,255,.07);border-radius:4px;height:6px;overflow:hidden}}
    .lat-bar{{height:6px;border-radius:4px;transition:width .3s}}
    .lat-val{{width:55px;text-align:right;font-weight:700;font-size:.78rem}}

    /* Eventos */
    .event-item{{padding:.4rem 0;border-bottom:1px solid rgba(255,255,255,.05);
                  display:flex;align-items:flex-start;gap:.5rem;font-size:.82rem}}
    .event-item:last-child{{border-bottom:none}}

    footer{{text-align:center;margin-top:1.5rem;color:rgba(255,255,255,.2);font-size:.74rem}}
  </style>
</head>
<body>
<div class="wrap">

  <!-- Header -->
  <div class="header">
    <div>
      <div class="title">Lab 36 · <span>NoSQL Product Catalog</span></div>
      <div class="subtitle">DynamoDB On-Demand + GSI + Streams · ElastiCache Redis + TLS/AUTH · CDC Lambda · CloudWatch</div>
    </div>
    <div class="redis-badge">
      <div class="dot {redis_dot}"></div>
      <span>Redis &nbsp;<strong style="color:{'#66bb6a' if redis_ok else '#ef5350'}">{redis_label}</strong></span>
    </div>
  </div>

  <!-- Stats de cache -->
  <div class="stats">
    <div class="stat"><div class="val">{len(products)}</div><div class="lbl">Productos</div></div>
    <div class="stat hit"><div class="val">{_stats['hits']}</div><div class="lbl">Cache Hits</div></div>
    <div class="stat miss"><div class="val">{_stats['misses']}</div><div class="lbl">Cache Misses</div></div>
    <div class="stat"><div class="val">{hit_rate}%</div><div class="lbl">Hit Rate</div></div>
    <div class="stat lat-h"><div class="val">{avg_hit_lat} ms</div><div class="lbl">Lat. Redis</div></div>
    <div class="stat lat-d"><div class="val">{avg_miss_lat} ms</div><div class="lbl">Lat. DynamoDB</div></div>
    <div class="stat wr"><div class="val">{avg_write_lat} ms</div><div class="lbl">Lat. Escritura</div></div>
  </div>

  {op_banner}

  <!-- Formulario Add/Edit -->
  {form_html}

  <!-- Layout principal -->
  <div class="layout">

    <!-- Panel de productos -->
    <div>
      <div class="panel">
        <div class="panel-hdr">
          <h2>Catalogo de Productos</h2>
          <div style="display:flex;align-items:center;gap:.5rem;flex-wrap:wrap">
            {src_badge}
            <a href="/?form=add" class="btn btn-add">✚ Añadir</a>
            <form method="post" action="/flush" style="display:inline">
              <button type="submit" class="btn btn-flush">⟳ Vaciar Caché</button>
            </form>
          </div>
        </div>

        <!-- Filtros -->
        <div style="padding:.7rem 1rem;border-bottom:1px solid rgba(255,255,255,.07)">
          <form method="get" action="/">
            <div class="toolbar">
              <select name="cat">
                <option value="">Todas las categorías</option>
                {cat_options}
              </select>
              <select name="status">
                <option value="">Todos los estados</option>
                {status_options}
              </select>
              <button type="submit" class="btn btn-primary">Filtrar</button>
              <a href="/" class="btn btn-clear">✕ Limpiar</a>
            </div>
          </form>
        </div>

        <!-- Tabla -->
        <table>
          <thead>
            <tr>
              <th>Categoría</th>
              <th>Producto</th>
              <th style="text-align:right">Precio</th>
              <th>Estado</th>
              <th style="text-align:center">Stock</th>
              <th>Acciones</th>
            </tr>
          </thead>
          <tbody>{rows_html}</tbody>
        </table>

        <div style="padding:.5rem 1rem;text-align:right;border-top:1px solid rgba(255,255,255,.05)">
          <span style="font-size:.72rem;color:#37474f">
            {len(products)} productos · fuente: <strong style="color:#90a4ae">{read_src}</strong>
            {'&nbsp;·&nbsp; <span style="color:#00e676">cache TTL: ' + str(CACHE_TTL) + 's</span>' if cache_result == 'HIT' else ''}
          </span>
        </div>
      </div>
    </div>

    <!-- Sidebar -->
    <div class="sidebar">

      <!-- Latencia comparativa -->
      <div class="side-panel">
        <h3>⚡ Latencia Comparada</h3>
        <div style="font-size:.72rem;color:#546e7a;margin-bottom:.8rem">
          Promedios de la sesion actual
        </div>

        <div class="lat-row">
          <span class="lat-label">Redis HIT</span>
          <div class="lat-bar-wrap">
            <div class="lat-bar" style="width:{min(100, avg_hit_lat)}%;background:#00e676"></div>
          </div>
          <span class="lat-val" style="color:#00e676">{avg_hit_lat} ms</span>
        </div>
        <div class="lat-row">
          <span class="lat-label">DynamoDB</span>
          <div class="lat-bar-wrap">
            <div class="lat-bar" style="width:{min(100, avg_miss_lat / 2)}%;background:#ffa726"></div>
          </div>
          <span class="lat-val" style="color:#ffa726">{avg_miss_lat} ms</span>
        </div>
        <div class="lat-row">
          <span class="lat-label">Escritura</span>
          <div class="lat-bar-wrap">
            <div class="lat-bar" style="width:{min(100, avg_write_lat / 2)}%;background:#ce93d8"></div>
          </div>
          <span class="lat-val" style="color:#ce93d8">{avg_write_lat} ms</span>
        </div>

        <div style="margin-top:1rem;padding-top:.8rem;border-top:1px solid rgba(255,255,255,.07)">
          <div style="font-size:.72rem;color:#546e7a;margin-bottom:.4rem">Lectura actual</div>
          <div style="font-size:.9rem;font-weight:700;color:{'#00e676' if cache_result=='HIT' else '#ffa726'}">
            {'⚡ ' if cache_result=='HIT' else '◎ '}{read_src}: {read_lat} ms
          </div>
          {'<div style="font-size:.7rem;color:#546e7a;margin-top:.2rem">~' + str(round(avg_miss_lat / avg_hit_lat if avg_hit_lat > 0 else 0, 0)) + 'x mas rapido con cache</div>' if avg_hit_lat > 0 and avg_miss_lat > 0 else ''}
        </div>
      </div>

      <!-- GSI info -->
      <div class="side-panel">
        <h3>📑 Indice GSI</h3>
        <div style="font-size:.78rem;color:#78909c;line-height:1.6">
          <div><span style="color:#90caf9">Index:</span> by-status-index</div>
          <div><span style="color:#90caf9">PK:</span> status (S)</div>
          <div><span style="color:#90caf9">SK:</span> price_cents (N)</div>
          <div><span style="color:#90caf9">Proyeccion:</span> ALL</div>
        </div>
        <div style="margin-top:.8rem;display:flex;flex-wrap:wrap;gap:.3rem">
          {''.join(f'<a href="/?status={s}" style="background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1);border-radius:5px;padding:.2rem .6rem;font-size:.72rem;color:#b0bec5">{s}</a>' for s in STATUSES)}
        </div>
        <div style="font-size:.7rem;color:#37474f;margin-top:.6rem">
          Filtra por estado usando el GSI → productos ordenados por precio
        </div>
      </div>

      <!-- Eventos CDC -->
      <div class="side-panel">
        <h3>📡 Eventos CDC (Hoy)</h3>
        <div style="font-size:.7rem;color:#37474f;margin-bottom:.6rem">
          Lambda procesa el DynamoDB Stream en tiempo real
        </div>
        {events_html}
      </div>

    </div>
  </div>

  <footer>{now} &nbsp;·&nbsp; {PROJECT} &nbsp;·&nbsp; DynamoDB On-Demand + Redis 7 TLS</footer>
</div>
</body>
</html>"""
    return html, 200


def _render_form(item, cat_options, status_options):
    """Genera el HTML del formulario de alta/edicion de producto."""
    is_edit = item is not None
    title = "✎ Editar Producto" if is_edit else "✚ Nuevo Producto"
    action = "/update" if is_edit else "/add"
    price_val = ""
    if is_edit:
        try:
            price_val = f"{float(item.get('price_cents', 0)) / 100:.2f}"
        except Exception:
            price_val = "0.00"

    # Select con valor seleccionado
    def sel_cat(c):
        sel = "selected" if is_edit and item.get("category") == c else ""
        return f'<option value="{c}" {sel}>{c}</option>'
    def sel_status(s):
        sel = "selected" if is_edit and item.get("status") == s else ""
        return f'<option value="{s}" {sel}>{s.capitalize()}</option>'

    cat_opts_form = "".join(sel_cat(c) for c in CATEGORIES)
    st_opts_form  = "".join(sel_status(s) for s in STATUSES)

    hidden = ""
    if is_edit:
        hidden = (
            f'<input type="hidden" name="category" value="{item.get("category","")}">'
            f'<input type="hidden" name="product_id" value="{item.get("product_id","")}">'
        )

    return f"""
<div class="form-panel">
  <h3>{title}</h3>
  <form method="post" action="{action}">
    {hidden}
    <div class="form-grid">
      <div class="form-group">
        <label>Categoria</label>
        <select name="category" {"disabled" if is_edit else ""}>
          {cat_opts_form}
        </select>
      </div>
      <div class="form-group">
        <label>Nombre del producto</label>
        <input type="text" name="name" value="{item.get('name','') if is_edit else ''}"
               placeholder="Nombre del producto" required>
      </div>
      <div class="form-group">
        <label>Precio ($)</label>
        <input type="number" name="price" step="0.01" min="0"
               value="{price_val}" placeholder="0.00" required>
      </div>
      <div class="form-group">
        <label>Estado</label>
        <select name="status">{st_opts_form}</select>
      </div>
      <div class="form-group">
        <label>Stock</label>
        <input type="number" name="stock" min="0"
               value="{int(item.get('stock', 0)) if is_edit else ''}" placeholder="0" required>
      </div>
      <div class="form-group" style="grid-column:1/-1">
        <label>Descripcion</label>
        <textarea name="description" placeholder="Descripcion breve del producto">{item.get('description','') if is_edit else ''}</textarea>
      </div>
    </div>
    <div class="form-actions">
      <button type="submit" class="btn btn-primary">{'Guardar cambios' if is_edit else 'Crear producto'}</button>
      <a href="/" class="btn btn-clear">Cancelar</a>
    </div>
  </form>
</div>"""


@app.route("/add", methods=["POST"])
def add_product():
    r = get_redis()
    category    = request.form.get("category", "").strip()
    name        = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price_str   = request.form.get("price", "0").strip()
    status      = request.form.get("status", "active").strip()
    stock_str   = request.form.get("stock", "0").strip()

    if not category or not name:
        return redirect(url_for("index"))

    try:
        price_cents = int(float(price_str) * 100)
    except ValueError:
        price_cents = 0
    try:
        stock = int(stock_str)
    except ValueError:
        stock = 0

    product_id = str(uuid.uuid4())[:8]
    now = datetime.now(timezone.utc).isoformat()

    t0 = time.perf_counter()
    products_table.put_item(Item={
        "category": category, "product_id": product_id,
        "name": name, "description": description,
        "price_cents": price_cents, "status": status,
        "stock": stock, "created_at": now,
    })
    lat = round((time.perf_counter() - t0) * 1000, 1)
    _stats["writes"] += 1
    _stats["write_lat_ms"] += lat

    # Invalida el cache para esta categoria y para "todos"
    cache_invalidate(r, "lab36:products:all:all", f"lab36:products:{category}:all",
                     f"lab36:products:all:{status}", f"lab36:products:{category}:{status}")

    return redirect(url_for("index", op="added", lat=lat, src="DynamoDB"))


@app.route("/update", methods=["POST"])
def update_product():
    r = get_redis()
    category    = request.form.get("category", "").strip()
    product_id  = request.form.get("product_id", "").strip()
    name        = request.form.get("name", "").strip()
    description = request.form.get("description", "").strip()
    price_str   = request.form.get("price", "0").strip()
    status      = request.form.get("status", "active").strip()
    stock_str   = request.form.get("stock", "0").strip()

    try:
        price_cents = int(float(price_str) * 100)
    except ValueError:
        price_cents = 0
    try:
        stock = int(stock_str)
    except ValueError:
        stock = 0

    t0 = time.perf_counter()
    products_table.update_item(
        Key={"category": category, "product_id": product_id},
        UpdateExpression=(
            "SET #n = :n, description = :d, price_cents = :p, #s = :s, stock = :st"
        ),
        ExpressionAttributeNames={"#n": "name", "#s": "status"},
        ExpressionAttributeValues={
            ":n": name, ":d": description, ":p": price_cents, ":s": status, ":st": stock,
        },
    )
    lat = round((time.perf_counter() - t0) * 1000, 1)
    _stats["writes"] += 1
    _stats["write_lat_ms"] += lat

    # Invalida todas las claves que pueden contener este producto
    cache_invalidate(
        r,
        "lab36:products:all:all",
        f"lab36:products:{category}:all",
        f"lab36:products:all:{status}",
        f"lab36:products:{category}:{status}",
    )

    return redirect(url_for("index", op="updated", lat=lat, src="DynamoDB"))


@app.route("/delete", methods=["POST"])
def delete_product():
    r = get_redis()
    category   = request.form.get("category", "").strip()
    product_id = request.form.get("product_id", "").strip()

    t0 = time.perf_counter()
    products_table.delete_item(Key={"category": category, "product_id": product_id})
    lat = round((time.perf_counter() - t0) * 1000, 1)
    _stats["writes"] += 1
    _stats["write_lat_ms"] += lat

    # Invalida todo el namespace de productos
    cache_flush_all(r)

    return redirect(url_for("index", op="deleted", lat=lat, src="DynamoDB"))


@app.route("/flush", methods=["POST"])
def flush_cache():
    r = get_redis()
    cache_flush_all(r)
    return redirect(url_for("index", op="flushed", src="Redis"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
