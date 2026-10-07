#!/usr/bin/env python3
"""Cuenta regresiva a pantalla completa ANTES de que se vea el juego.

Para que: X tarda un rato en enganchar el RTMP y empezar a mostrar la
transmision. Si el juego ya esta corriendo en ese hueco, los primeros minutos de
partida se pierden. Con esto ffmpeg arranca empujando la cuenta regresiva, asi X
despierta mientras todavia no empezo nada importante.

POR QUE UN OVERLAY Y NO UNA VENTANA APARTE (como placa.sh): la placa tapa un
CAMBIO DE JUEGO, y ahi hay una navegacion al dashboard que destruiria cualquier
overlay del DOM. Durante la intro NO se navega: el juego ya esta deployado y la
pagina se queda quieta. Entonces el overlay alcanza, y encima se saca SOLO desde
el JS de la pagina.

Eso evita el problema que me costo cinco intentos el 2026-10-06: con ventana
aparte hace falta un proceso que la cierre al vencer el plazo, y ese proceso se
moria al cerrarse la sesion SSH —Chrome sobrevivia por su propio nohup pero el
que tenia que cerrarlo no—, dejando la cuenta clavada en pantalla para siempre.
Aca no hay proceso que vigilar: el temporizador vive en la pagina.

Uso: intro.py <minutos> ["titulo"] ["subtitulo"]
     intro.py --off
"""
import json, sys, urllib.request
from websocket import create_connection

ID = "byte-intro-overlay"

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

if len(sys.argv) > 1 and sys.argv[1] == "--off":
    print(cdp('(()=>{const e=document.getElementById("%s");if(e){e.remove();return "intro sacada"}return "no habia intro"})()' % ID))
    sys.exit(0)

minutos = float(sys.argv[1]) if len(sys.argv) > 1 else 5
titulo   = sys.argv[2] if len(sys.argv) > 2 else "byteraa"
sub      = sys.argv[3] if len(sys.argv) > 3 else "el stream arranca en"
seg = int(minutos * 60)

JS = """(()=>{
  const id=%s, seg=%d, titulo=%s, sub=%s;
  const viejo=document.getElementById(id); if(viejo) viejo.remove();
  const o=document.createElement("div"); o.id=id;
  o.style.cssText="position:fixed;inset:0;z-index:2147483647;background:#07070b;"+
    "display:flex;align-items:center;justify-content:center;"+
    "font-family:system-ui,-apple-system,sans-serif;color:#fff";
  o.innerHTML=
   '<div id="'+id+'-big" style="position:absolute;inset:0;display:flex;align-items:center;'+
   'justify-content:center;font-size:46vh;font-weight:800;opacity:.07;letter-spacing:-.04em;'+
   'font-variant-numeric:tabular-nums">--</div>'+
   '<div style="position:relative;z-index:2;text-align:center">'+
     '<div style="font-size:84px;font-weight:700;letter-spacing:-.02em"></div>'+
     '<div style="margin-top:18px;font-size:24px;letter-spacing:.34em;text-transform:uppercase;color:#8b8b9c"></div>'+
     '<div id="'+id+'-c" style="margin-top:26px;font-size:64px;font-weight:600;font-variant-numeric:tabular-nums">--:--</div>'+
     '<div style="margin-top:40px;width:420px;height:4px;background:#1c1c26;border-radius:2px;overflow:hidden">'+
       '<div id="'+id+'-b" style="height:100%%;width:0;background:#fff;transition:width 1s linear"></div></div>'+
   '</div>';
  // textContent y no innerHTML para el texto que viene de afuera.
  const frente=o.lastElementChild;
  frente.children[0].textContent=titulo;
  frente.children[1].textContent=sub;
  document.body.appendChild(o);

  const big=document.getElementById(id+"-big"), c=document.getElementById(id+"-c"), b=document.getElementById(id+"-b");
  // Reloj de pared, no un contador por tick: si el browser se atrasa, el numero
  // que se ve sigue siendo el real.
  const fin=Date.now()+seg*1000;
  (function pinta(){
    const el=document.getElementById(id); if(!el) return;       // lo sacaron a mano
    const q=Math.max(0, Math.round((fin-Date.now())/1000));
    const m=Math.floor(q/60), s=q%%60;
    c.textContent=(m<10?"0":"")+m+":"+(s<10?"0":"")+s;
    big.textContent=q>=60?(m+1):q;
    b.style.width=(100*(seg-q)/seg)+"%%";
    if(q>0) setTimeout(pinta,250);
    else el.remove();                                            // se saca SOLA
  })();
  return "intro de "+(seg/60)+" min puesta";})()""" % (
    json.dumps(ID), seg, json.dumps(titulo), json.dumps(sub))

print(cdp(JS))
