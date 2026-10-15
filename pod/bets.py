#!/usr/bin/env python3
"""Overlay de apuestas sobre el juego: avisos cuando alguien apuesta, y un panel
fijo con los mercados abiertos hasta que se cierran.

De donde sale cada cosa (leido del codigo de byte, no adivinado):
  - /api/bets/ticker?slug=<slug>  -> items con kind "bet" | "open" | "resolved"
    Cada bet trae who, stake, currency, option y title. Eso son los AVISOS.
  - /api/sessions/<id>/predictions -> markets[] con status, title, options,
    pools, total, bettors y closeMs. Eso es el PANEL FIJO: se muestran los que
    estan "open" y desaparecen solos cuando pasan a resolved o invalid.

Por que un overlay y no una ventana aparte: ffmpeg captura la PANTALLA, asi que
alcanza con dibujar encima de la pagina, y no hay ningun proceso que vigilar.
pointer-events:none para no robarle clicks al juego.

OJO: la inyeccion NO sobrevive a una navegacion, asi que el watchdog la repone
despues de cada cambio de juego del carrusel (igual que inject-css.py).

Uso: bets.py on | off
"""
import json, sys, urllib.request
from websocket import create_connection

ID = "byte-bets-overlay"

def cdp(expr):
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
    pages = [t for t in tabs if t.get("type") == "page"]
    page = next((t for t in pages if "bytearena" in t.get("url", "")), pages[0] if pages else None)
    if not page:
        print("no hay pagina"); sys.exit(1)
    ws = create_connection(page["webSocketDebuggerUrl"], timeout=30)
    _id = [0]
    def send(method, params=None):
        _id[0] += 1
        mio = _id[0]
        ws.send(json.dumps({"id": mio, "method": method, "params": params or {}}))
        while True:
            r = json.loads(ws.recv())
            if r.get("method") == "Page.javascriptDialogOpening":
                _id[0] += 1
                ws.send(json.dumps({"id": _id[0], "method": "Page.handleJavaScriptDialog",
                                    "params": {"accept": True}}))
                continue
            if r.get("id") == mio:
                return r
    send("Page.enable")
    r = send("Runtime.evaluate", {"expression": expr, "returnByValue": True})
    ws.close()
    return r.get("result", {}).get("result", {}).get("value") or r.get("error")

if len(sys.argv) > 1 and sys.argv[1] == "off":
    print(cdp('(()=>{const e=document.getElementById("ID_");if(e){e.remove();return "apuestas: overlay sacado"}return "no habia overlay"})()'.replace("ID_", ID)))
    sys.exit(0)

JS = r'''
(()=>{
  const ID = "__ID__";
  const viejo = document.getElementById(ID); if (viejo) viejo.remove();

  const raiz = document.createElement("div"); raiz.id = ID;
  raiz.style.cssText =
    "position:fixed;left:24px;bottom:24px;z-index:2147483000;pointer-events:none;"+
    "font-family:system-ui,-apple-system,sans-serif;display:flex;flex-direction:column;"+
    "gap:10px;align-items:flex-start;max-width:420px";
  document.body.appendChild(raiz);

  const avisos = document.createElement("div");
  avisos.style.cssText = "display:flex;flex-direction:column;gap:8px;align-items:flex-start";
  const panel = document.createElement("div");
  panel.style.cssText = "display:flex;flex-direction:column;gap:8px;align-items:stretch;width:100%";
  raiz.appendChild(avisos); raiz.appendChild(panel);

  const plata = (v, cur) => cur === "sol"
    ? (+(v/1e9).toFixed(4)) + " SOL"
    : (v||0).toLocaleString("en-US") + " pts";

  // --- avisos: aparecen cuando alguien apuesta, y se van solos ---
  const vistos = new Set();
  function aviso(it){
    const d = document.createElement("div");
    const si = (it.option||"").toUpperCase() !== "NO";
    d.style.cssText =
      "background:rgba(10,10,14,.92);border:1px solid "+(si?"#1f8f4e":"#9f2d3d")+";"+
      "border-left:4px solid "+(si?"#28c76f":"#ea3a51")+";border-radius:10px;"+
      "padding:10px 14px;color:#fff;font-size:17px;line-height:1.35;"+
      "box-shadow:0 8px 28px rgba(0,0,0,.55);opacity:0;transform:translateY(8px);"+
      "transition:opacity .25s,transform .25s;max-width:420px";
    d.innerHTML =
      '<b style="color:#fff"></b> apostó <b style="color:'+(si?"#28c76f":"#ea3a51")+'"></b>'+
      ' a <b></b><div style="color:#9a9aa8;font-size:14px;margin-top:3px"></div>';
    // textContent y no innerHTML para lo que viene del servidor
    const b = d.querySelectorAll("b");
    b[0].textContent = it.who || "alguien";
    b[1].textContent = plata(it.stake||0, it.currency);
    b[2].textContent = it.option || "?";
    d.querySelector("div").textContent = it.title || "";
    avisos.appendChild(d);
    requestAnimationFrame(()=>{ d.style.opacity="1"; d.style.transform="none"; });
    setTimeout(()=>{ d.style.opacity="0"; d.style.transform="translateY(8px)";
                     setTimeout(()=>d.remove(), 300); }, 9000);
    while (avisos.children.length > 4) avisos.firstChild.remove();
  }

  // --- panel: los mercados ABIERTOS, hasta que se cierran ---
  function pintarMercados(ms){
    panel.innerHTML = "";
    for (const m of ms){
      const cerra = m.closeMs ? Math.max(0, Math.round((m.closeMs - Date.now())/1000)) : null;
      const c = document.createElement("div");
      c.style.cssText =
        "background:rgba(10,10,14,.9);border:1px solid #2a2a36;border-radius:10px;"+
        "padding:10px 14px;color:#fff;box-shadow:0 8px 28px rgba(0,0,0,.5)";
      const t = document.createElement("div");
      t.style.cssText = "font-size:16px;font-weight:600;margin-bottom:4px";
      t.textContent = m.title || m.id || "mercado";
      const s = document.createElement("div");
      s.style.cssText = "font-size:14px;color:#9a9aa8";
      const partes = [];
      if (m.bettors != null) partes.push(m.bettors + (m.bettors === 1 ? " apuesta" : " apuestas"));
      if (m.total) partes.push(plata(m.total, m.currency));
      if (cerra != null && cerra > 0) partes.push("cierra en " + (cerra >= 60 ? Math.floor(cerra/60)+"m" : cerra+"s"));
      s.textContent = partes.join(" · ");
      c.appendChild(t); c.appendChild(s);
      panel.appendChild(c);
    }
  }

  async function tick(){
    if (!document.getElementById(ID)) return;             // lo sacaron
    const id = (location.href.match(/arena\/([a-z0-9_]+)/)||[])[1];
    try {
      const r = await fetch("/api/sessions/"+id+"/predictions", {cache:"no-store"});
      if (r.ok){
        const j = await r.json();
        const abiertos = (j.markets||[]).filter(m => (m.status||"open") === "open");
        pintarMercados(abiertos);
        // El feed de la propia sesion ya trae las apuestas; si no, se cae al ticker.
        for (const it of (j.activity||[])){
          const k = it.kind + ":" + it.market + ":" + it.at + ":" + (it.who||"");
          if (it.kind === "bet" && !vistos.has(k)){ vistos.add(k); aviso(it); }
        }
      }
    } catch(e){}
    setTimeout(tick, 5000);
  }
  // La primera vuelta solo MARCA lo que ya estaba, para no escupir de golpe
  // todas las apuestas viejas al prender el overlay.
  (async ()=>{
    try{
      const id = (location.href.match(/arena\/([a-z0-9_]+)/)||[])[1];
      const r = await fetch("/api/sessions/"+id+"/predictions", {cache:"no-store"});
      if (r.ok){ const j = await r.json();
        for (const it of (j.activity||[])) vistos.add(it.kind+":"+it.market+":"+it.at+":"+(it.who||"")); }
    }catch(e){}
    tick();
  })();
  return "apuestas: overlay puesto";
})()
'''.replace("__ID__", ID)

print(cdp(JS))
