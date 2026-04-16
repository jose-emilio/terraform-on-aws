import os, datetime
import boto3
import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, request, redirect, url_for

app = Flask(__name__)

PRIMARY_DSN = (
    f"host={os.environ['DB_HOST']} port={os.environ['DB_PORT']} "
    f"dbname={os.environ['DB_NAME']} user={os.environ['DB_USER']} "
    f"password={os.environ['DB_PASS']} sslmode=require connect_timeout=5"
)
REPLICA_DSN = (
    f"host={os.environ['REPLICA_HOST']} port={os.environ['REPLICA_PORT']} "
    f"dbname={os.environ['DB_NAME']} user={os.environ['DB_USER']} "
    f"password={os.environ['DB_PASS']} sslmode=require connect_timeout=5"
)

DB_INSTANCE_ID = os.environ.get("DB_INSTANCE_ID", "")
AWS_REGION     = os.environ.get("AWS_REGION", "us-east-1")

PLAN_COLOR = {
    "free":       ("#546e7a", "#eceff1"),
    "starter":    ("#1565c0", "#e3f2fd"),
    "pro":        ("#6a1b9a", "#f3e5f5"),
    "enterprise": ("#e65100", "#fff3e0"),
}

def get_conn(dsn):
    return psycopg2.connect(dsn, cursor_factory=psycopg2.extras.RealDictCursor)

def db_meta(dsn):
    try:
        conn = get_conn(dsn)
        cur  = conn.cursor()
        cur.execute("SELECT version(), pg_is_in_recovery() AS replica")
        row = cur.fetchone()
        cur.close(); conn.close()
        return {"ok": True, "version": row["version"][:55], "replica": row["replica"]}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def get_rds_info():
    """Devuelve AZ y estado actual de la instancia RDS principal via boto3."""
    try:
        rds = boto3.client("rds", region_name=AWS_REGION)
        resp = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_ID)
        inst = resp["DBInstances"][0]
        return {
            "ok":     True,
            "az":     inst.get("AvailabilityZone", "?"),
            "status": inst.get("DBInstanceStatus", "?"),
            "multi_az": inst.get("MultiAZ", False),
        }
    except Exception as e:
        return {"ok": False, "az": "?", "status": "?", "multi_az": False, "error": str(e)}

def get_customers(search="", plan_filter=""):
    try:
        conn = get_conn(REPLICA_DSN)
        cur  = conn.cursor()
        sql  = "SELECT id, name, email, country, plan, mrr, created_at FROM customers WHERE 1=1"
        params = []
        if search:
            sql += " AND (name ILIKE %s OR email ILIKE %s OR country ILIKE %s)"
            params += [f"%{search}%", f"%{search}%", f"%{search}%"]
        if plan_filter:
            sql += " AND plan = %s"
            params.append(plan_filter)
        sql += " ORDER BY mrr DESC, name ASC"
        cur.execute(sql, params)
        rows = cur.fetchall()
        cur.close(); conn.close()
        return {"ok": True, "rows": rows}
    except Exception as e:
        return {"ok": False, "error": str(e), "rows": []}

def get_stats():
    try:
        conn = get_conn(REPLICA_DSN)
        cur  = conn.cursor()
        cur.execute("""
            SELECT
                COUNT(*)                                  AS total,
                COUNT(*) FILTER (WHERE plan='enterprise') AS enterprise,
                COUNT(*) FILTER (WHERE plan='pro')        AS pro,
                COUNT(*) FILTER (WHERE plan='starter')    AS starter,
                COUNT(*) FILTER (WHERE plan='free')       AS free,
                COALESCE(SUM(mrr),0)                      AS total_mrr
            FROM customers
        """)
        row = cur.fetchone()
        cur.close(); conn.close()
        return dict(row)
    except Exception:
        return {"total": "?", "enterprise": "?", "pro": "?",
                "starter": "?", "free": "?", "total_mrr": "?"}

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

@app.route("/failover", methods=["POST"])
def failover():
    """Reinicia la instancia RDS principal con ForceFailover=True.
    Provoca la promocion del standby Multi-AZ como nueva primaria.
    El endpoint DNS de RDS no cambia; el failover tarda < 60 segundos."""
    try:
        rds = boto3.client("rds", region_name=AWS_REGION)
        rds.reboot_db_instance(
            DBInstanceIdentifier=DB_INSTANCE_ID,
            ForceFailover=True,
        )
        msg = "failover_triggered"
    except Exception as e:
        msg = f"error:{str(e)[:80]}"
    return redirect(url_for("index", _anchor="", failover=msg))

@app.route("/")
def index():
    search      = request.args.get("q", "").strip()
    plan_filter = request.args.get("plan", "").strip()
    failover_msg = request.args.get("failover", "")
    now         = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    primary   = db_meta(PRIMARY_DSN)
    replica   = db_meta(REPLICA_DSN)
    rds_info  = get_rds_info()
    stats     = get_stats()
    result    = get_customers(search, plan_filter)
    customers = result["rows"]
    source    = "READ REPLICA" if replica["ok"] and replica.get("replica") else "PRIMARY"

    rows_html = ""
    for c in customers:
        bg, fg = PLAN_COLOR.get(c["plan"], ("#555", "#fff"))
        badge = (f'<span style="background:{bg};color:{fg};padding:2px 10px;'
                 f'border-radius:12px;font-size:0.75rem;font-weight:700;'
                 f'text-transform:uppercase">{c["plan"]}</span>')
        mrr  = (f'${float(c["mrr"]):,.2f}'
                if c["plan"] != "free"
                else '<span style="color:#78909c">&#8212;</span>')
        date = (c["created_at"].strftime("%Y-%m-%d")
                if hasattr(c["created_at"], "strftime")
                else str(c["created_at"])[:10])
        rows_html += (
            f'<tr>'
            f'<td style="color:#90caf9;font-weight:600">#{c["id"]}</td>'
            f'<td style="font-weight:600">{c["name"]}</td>'
            f'<td style="color:#b0bec5">{c["email"]}</td>'
            f'<td>{c["country"]}</td>'
            f'<td>{badge}</td>'
            f'<td style="text-align:right;font-weight:600">{mrr}</td>'
            f'<td style="color:#78909c">{date}</td>'
            f'</tr>'
        )

    if not rows_html:
        rows_html = ('<tr><td colspan="7" style="text-align:center;'
                     'color:#78909c;padding:2rem">Sin resultados</td></tr>')

    total_mrr = (f"${float(stats['total_mrr']):,.2f}"
                 if stats["total_mrr"] != "?" else "?")

    primary_status = ("CONECTADO" if primary["ok"]
                      else f"ERROR: {primary.get('error','')[:40]}")
    replica_status = ("CONECTADO" if replica["ok"]
                      else f"ERROR: {replica.get('error','')[:40]}")
    primary_class  = "ok" if primary["ok"] else "err"
    replica_class  = "ok" if replica["ok"] else "err"

    rds_az     = rds_info["az"]
    rds_status = rds_info["status"]
    rds_status_class = "ok" if rds_status == "available" else "warn"

    plan_options = "".join(
        f'<option value="{p}" {"selected" if plan_filter == p else ""}>'
        f'{p.capitalize()}</option>'
        for p in ["free", "starter", "pro", "enterprise"]
    )

    # Banner de estado tras un failover
    if failover_msg == "failover_triggered":
        failover_banner = (
            '<div class="banner ok-banner">'
            '&#9889; Failover iniciado. La instancia standby se esta promoviendo a primaria. '
            'El endpoint DNS de RDS no cambia. Refresca en ~60 segundos para ver la nueva AZ.'
            '</div>'
        )
    elif failover_msg.startswith("error:"):
        failover_banner = (
            f'<div class="banner err-banner">&#9888; Error al iniciar failover: '
            f'{failover_msg[6:]}</div>'
        )
    else:
        failover_banner = ""

    html = f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Lab35 - CRM Dashboard</title>
  <style>
    *{{box-sizing:border-box;margin:0;padding:0}}
    body{{font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(135deg,#0f2027,#203a43,#2c5364);min-height:100vh;color:#e0e0e0;padding:2rem 1rem}}
    .wrap{{max-width:1100px;margin:0 auto}}
    h1{{font-size:1.8rem;font-weight:700;color:#fff;text-align:center}}
    h1 span{{color:#90caf9}}
    .sub{{text-align:center;color:#78909c;margin:.3rem 0 1.8rem;font-size:.9rem}}
    .stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:1rem;margin-bottom:1.8rem}}
    .stat{{background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.1);border-radius:10px;padding:1rem;text-align:center}}
    .stat .val{{font-size:1.7rem;font-weight:700;color:#fff}}
    .stat .lbl{{font-size:.75rem;color:#78909c;margin-top:.2rem;text-transform:uppercase;letter-spacing:.5px}}
    .dbbar{{display:flex;gap:1rem;margin-bottom:1.5rem;flex-wrap:wrap}}
    .dbcard{{flex:1;min-width:220px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:10px;padding:.9rem 1.2rem;display:flex;align-items:center;gap:.8rem}}
    .dot{{width:10px;height:10px;border-radius:50%;flex-shrink:0}}
    .dot.ok{{background:#66bb6a;box-shadow:0 0 6px #66bb6a}}
    .dot.err{{background:#ef5350;box-shadow:0 0 6px #ef5350}}
    .dot.warn{{background:#ffa726;box-shadow:0 0 6px #ffa726}}
    .dbcard .title{{font-size:.8rem;color:#90caf9;font-weight:600;text-transform:uppercase;letter-spacing:.4px}}
    .dbcard .detail{{font-size:.78rem;color:#b0bec5;margin-top:.15rem}}
    .ok{{color:#66bb6a;font-weight:600}}
    .err{{color:#ef5350;font-weight:600}}
    .warn{{color:#ffa726;font-weight:600}}
    .toolbar{{display:flex;gap:.8rem;margin-bottom:1.2rem;flex-wrap:wrap}}
    .toolbar input,.toolbar select{{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.15);border-radius:8px;color:#e0e0e0;padding:.55rem .9rem;font-size:.88rem;outline:none}}
    .toolbar input{{flex:1;min-width:180px}}
    .toolbar input::placeholder{{color:#78909c}}
    .toolbar select option{{background:#1e2a35;color:#e0e0e0}}
    .toolbar button{{background:#1565c0;color:#fff;border:none;border-radius:8px;padding:.55rem 1.2rem;cursor:pointer;font-size:.88rem;font-weight:600}}
    .toolbar button:hover{{background:#1976d2}}
    .table-wrap{{background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:12px;overflow:hidden}}
    table{{width:100%;border-collapse:collapse;font-size:.875rem}}
    thead th{{background:rgba(255,255,255,.08);padding:.75rem 1rem;text-align:left;font-size:.75rem;text-transform:uppercase;letter-spacing:.5px;color:#90caf9;font-weight:600}}
    tbody tr{{border-top:1px solid rgba(255,255,255,.05);transition:background .15s}}
    tbody tr:hover{{background:rgba(255,255,255,.04)}}
    td{{padding:.7rem 1rem;vertical-align:middle}}
    .source-note{{text-align:right;font-size:.75rem;color:#546e7a;margin-top:.6rem}}
    footer{{text-align:center;margin-top:2rem;color:rgba(255,255,255,.25);font-size:.78rem}}
    .failover-btn{{background:#b71c1c;color:#fff;border:none;border-radius:8px;padding:.55rem 1.4rem;cursor:pointer;font-size:.88rem;font-weight:600;display:flex;align-items:center;gap:.4rem}}
    .failover-btn:hover{{background:#c62828}}
    .banner{{border-radius:8px;padding:.8rem 1.2rem;margin-bottom:1.2rem;font-size:.88rem;font-weight:500}}
    .ok-banner{{background:rgba(102,187,106,.15);border:1px solid #66bb6a;color:#a5d6a7}}
    .err-banner{{background:rgba(239,83,80,.15);border:1px solid #ef5350;color:#ef9a9a}}
  </style>
</head>
<body>
<div class="wrap">
  <h1>Lab 35 - <span>CRM Dashboard</span></h1>
  <p class="sub">Base de Datos Relacional Critica: RDS Multi-AZ + Replicacion + Secrets Manager</p>

  {failover_banner}

  <div class="stats">
    <div class="stat"><div class="val">{stats['total']}</div><div class="lbl">Clientes</div></div>
    <div class="stat"><div class="val">{stats['enterprise']}</div><div class="lbl">Enterprise</div></div>
    <div class="stat"><div class="val">{stats['pro']}</div><div class="lbl">Pro</div></div>
    <div class="stat"><div class="val">{stats['starter']}</div><div class="lbl">Starter</div></div>
    <div class="stat"><div class="val">{stats['free']}</div><div class="lbl">Free</div></div>
    <div class="stat"><div class="val">{total_mrr}</div><div class="lbl">MRR Total</div></div>
  </div>

  <div class="dbbar">
    <div class="dbcard">
      <div class="dot {primary_class}"></div>
      <div>
        <div class="title">Primaria (escritura)</div>
        <div class="detail"><span class="{primary_class}">{primary_status}</span></div>
        <div class="detail" style="color:#546e7a">{primary.get('version', '')}</div>
      </div>
    </div>
    <div class="dbcard">
      <div class="dot {replica_class}"></div>
      <div>
        <div class="title">Read Replica (lectura)</div>
        <div class="detail"><span class="{replica_class}">{replica_status}</span></div>
        <div class="detail" style="color:#546e7a">pg_is_in_recovery = {replica.get('replica', '?')}</div>
      </div>
    </div>
    <div class="dbcard">
      <div class="dot {rds_status_class}"></div>
      <div style="flex:1">
        <div class="title">RDS Multi-AZ</div>
        <div class="detail">AZ primaria: <span style="color:#90caf9;font-weight:600">{rds_az}</span></div>
        <div class="detail">Estado: <span class="{rds_status_class}">{rds_status}</span></div>
      </div>
      <form method="post" action="/failover" style="margin-left:auto"
            onsubmit="return confirm('Esto provocara un failover de RDS (~60 s de interrupcion). ¿Continuar?')">
        <button type="submit" class="failover-btn" {"disabled" if rds_status != "available" else ""}>
          &#9889; Failover
        </button>
      </form>
    </div>
  </div>

  <form method="get" action="/">
    <div class="toolbar">
      <input name="q" placeholder="Buscar por nombre, email o pais..." value="{search}">
      <select name="plan">
        <option value="">Todos los planes</option>
        {plan_options}
      </select>
      <button type="submit">Buscar</button>
      <button type="button" onclick="location.href='/'">Limpiar</button>
    </div>
  </form>

  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>ID</th><th>Nombre</th><th>Email</th><th>Pais</th>
          <th>Plan</th><th style="text-align:right">MRR</th><th>Alta</th>
        </tr>
      </thead>
      <tbody>{rows_html}</tbody>
    </table>
  </div>
  <p class="source-note">Datos leidos desde: {source} &nbsp;|&nbsp; {len(customers)} registros mostrados</p>
  <footer>{now} &nbsp;|&nbsp; {os.environ['PROJECT']}</footer>
</div>
</body>
</html>"""
    return html, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
