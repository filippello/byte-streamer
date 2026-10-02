#!/usr/bin/env python3
"""Deploya el agente a un juego desde el dashboard.

Uso: deploy-game.py "Infinite Cinema" | "Hells Agents" | ...
Sale 0 si quedo en una arena, 1 si no. Imprime SIEMPRE el motivo.

Historia de por que es asi de paranoico: el 2026-10-02 el modo keep no pudo
redeployar al terminar una corrida, corto el stream, y como el log vivia en el
pod se destruyo con el. Una hora de aire perdida y cero evidencia. Antes esto
clickeaba a ciegas con sleeps fijos y decia "NO ENCONTRADO" sin mas.

Las tres fallas que puede haber, y que ahora se distinguen:
  - el dashboard todavia no cargo las tarjetas  -> se espera, no se clickea al vacio
  - el juego abre un modal de asiento pago/gratis -> se elige el GRATIS
  - el agente sigue jugando la corrida anterior  -> se dice con todas las letras

OJO con el boton: hay que acotarlo a la tarjeta (subir por parentElement hasta
el primer ancestro que tenga el nombre Y menos de 420 chars), porque si no se
agarra el DEPLOY del juego de al lado.
"""
import json, sys, time, urllib.request
from websocket import create_connection

GAME = sys.argv[1] if len(sys.argv) > 1 else "Infinite Cinema"

def ev(expr, wait=0):
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json/list"))
    ps = [t for t in tabs if t["type"] == "page"]
    p = next((t for t in ps if "bytearena" in t["url"]), ps[0])
    ws = create_connection(p["webSocketDebuggerUrl"], timeout=90)
    _id = [0]
    def send(method, params):
        _id[0] += 1
        mio = _id[0]
        ws.send(json.dumps({"id": mio, "method": method, "params": params}))
        while True:
            r = json.loads(ws.recv())
            # Un dialogo abierto congela el renderer entero (ver cdp.py).
            if r.get("method") == "Page.javascriptDialogOpening":
                _id[0] += 1
                ws.send(json.dumps({"id": _id[0], "method": "Page.handleJavaScriptDialog",
                                    "params": {"accept": True}}))
                continue
            if r.get("id") == mio:
                return r
    send("Page.enable", {})
    r = send("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True})
    ws.close()
    if wait:
        time.sleep(wait)
    return r.get("result", {}).get("result", {}).get("value")

def url():
    return ev("location.href") or ""

def esperar(cond, segundos, paso=2):
    """Poll en vez de sleep fijo: el dashboard tarda distinto cada vez."""
    limite = time.time() + segundos
    while time.time() < limite:
        v = cond()
        if v:
            return v
        time.sleep(paso)
    return None

def hay_tarjetas():
    return ev("""Array.from(document.querySelectorAll("button"))
        .filter(x=>/DEPLOY AGENT|ENTER EVENT|FREE SEAT/i.test(x.innerText)).length""") or 0

def clickear_juego(nombre):
    return ev("""(()=>{const btns=Array.from(document.querySelectorAll("button"))
      .filter(x=>/DEPLOY AGENT|ENTER EVENT|FREE SEAT/i.test(x.innerText));
      for(const b of btns){let p=b;
        for(let i=0;i<10&&p;i++){p=p.parentElement; if(!p) break;
          const t=p.innerText||"";
          if(t.includes(%s) && t.length<420){b.click(); return "ok";}}}
      return "no-esta";})()""" % json.dumps(nombre), wait=4)

def asiento_gratis():
    """Algunos juegos abren un modal con entrada paga o gratis. SIEMPRE el gratis:
    el pago se debita de la wallet del agente (vimos ~27.000 $BYTE)."""
    return ev("""(()=>{const c=Array.from(document.querySelectorAll("button")).filter(e=>{
        const t=e.innerText||"";
        return /Free seat/i.test(t)&&/nothing spent/i.test(t)&&!/Pay to play/i.test(t)&&e.offsetWidth>0});
      if(!c.length)return "";c[0].click();return "gratis";})()""", wait=4)

def ya_jugando():
    return ev("/already playing/i.test(document.body.innerText)")

def intento(n):
    print("  intento %d: yendo al dashboard" % n)
    ev("location.href='https://app.bytearena.fun/dashboard'", wait=3)
    if not esperar(hay_tarjetas, 60):
        return "el dashboard no cargo las tarjetas (60s)"

    r = clickear_juego(GAME)
    if r != "ok":
        hay = ev("""JSON.stringify(Array.from(document.querySelectorAll("button"))
            .filter(x=>/DEPLOY AGENT|ENTER EVENT|FREE SEAT/i.test(x.innerText)).length)""")
        return "no encontre la tarjeta de %r (habia %s juegos en pantalla)" % (GAME, hay)

    # Puede entrar directo a la arena, o abrir el modal de asiento.
    def en_arena():
        return "/arena/" in url()
    if esperar(en_arena, 20):
        return None
    if asiento_gratis():
        print("  modal de asiento: elegi el gratis")
        if esperar(en_arena, 45):
            return None
    if ya_jugando():
        return "byte dice 'this agent is already playing' — quedo viva la corrida anterior"
    if esperar(en_arena, 25):
        return None
    return "clickee el juego pero nunca llegamos a /arena/ (quedo en %s)" % url()

fallo = None
for n in (1, 2, 3):
    fallo = intento(n)
    if fallo is None:
        break
    print("  fallo: %s" % fallo)
    if n < 3:
        time.sleep(10)

if fallo:
    print("NO PUDE DEPLOYAR %r: %s" % (GAME, fallo))
    print("url:", url())
    sys.exit(1)

print("deployado ->", GAME)
print("url:", url())
print("estado:", ev("(document.body.innerText.match(/status: [a-z]+/i)||['?'])[0]"))
