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

OJO con el boton: hay que acotarlo a la tarjeta, o se agarra el DEPLOY del juego
de al lado. Ver clickear_juego() para como se hace y por que no con el largo del
texto.
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

# Criterio de "boton que lanza el juego". byte renombro los labels el
# 2026-10-10: "Deploy agent" paso a ser "Play" y cada tarjeta sumo un
# "Configure". El matcher buscaba los labels viejos y de golpe no vio NINGUNA
# tarjeta. Se aceptan los dos juegos de labels por si vuelven atras, y "play" se
# exige como texto COMPLETO del boton para no comerse un "Configure" ni un
# "Replay".
ESBOTON = (
    'const esBoton=e=>{const t=(e.innerText||"").trim();'
    'return /^(▸\\s*)?play$/i.test(t)'
    '||/DEPLOY AGENT|ENTER EVENT|FREE SEAT/i.test(t)};'
)

def hay_tarjetas():
    return ev("(()=>{%s return Array.from(document.querySelectorAll('button'))"
              ".filter(esBoton).length})()" % ESBOTON) or 0

def clickear_juego(nombre):
    # Se sube desde cada boton hasta la TARJETA: el ancestro mas grande que siga
    # teniendo UN SOLO boton de lanzar. El titulo es su primera linea. Despues se
    # exige coincidencia EXACTA de titulo, y solo si no hay se cae a substring.
    #
    # Lo exacto no es capricho: varios nombres son prefijo de otros. Verificado
    # contra el catalogo real el 2026-10-04, "Backrooms" matcheaba 2 tarjetas
    # (tambien la "Fruit Fly edition") y "Solana Survivors" matcheaba 3. Con
    # substring se clickeaba la primera que apareciera, o sea a veces el juego
    # equivocado y sin que nadie se enterara.
    js = """(()=>{%s
      const tarjetas=[];
      for(const b of Array.from(document.querySelectorAll("button")).filter(esBoton)){
        let p=b, card=null;
        for(let i=0;i<12&&p;i++){p=p.parentElement; if(!p) break;
          if(Array.from(p.querySelectorAll("button")).filter(esBoton).length!==1) break;
          card=p;}
        if(!card) continue;
        const l=(card.innerText||"").split("\\n").map(x=>x.trim()).filter(x=>x.length>2);
        tarjetas.push({boton:b, titulo:l[0]||""});}
      const n=%s;
      let c=tarjetas.filter(x=>x.titulo===n);
      if(c.length!==1) c=tarjetas.filter(x=>x.titulo.includes(n));
      if(c.length===1){c[0].boton.click(); return "ok";}
      if(c.length>1) return "ambiguo:"+c.length;
      return "no-esta";})()""" % (ESBOTON, json.dumps(nombre))
    return ev(js, wait=4)

def asiento_gratis():
    """Algunos juegos abren un modal con entrada paga o gratis. SIEMPRE el gratis:
    el pago se debita de la wallet del agente (vimos ~27.000 $BYTE)."""
    # El texto del modal cambio con el rediseño del 2026-10-10: antes decia
    # "Free seat / $0 / Same game, nothing spent", ahora solo "🎟 Free seat".
    # El filtro pedia "nothing spent" y dejo de encontrarlo, asi que el deploy
    # clickeaba el juego y se quedaba para siempre en el dashboard.
    #
    # La condicion negativa es la que importa: al lado hay un boton que debita
    # ~26.000 $BYTE de la wallet del agente. Se exige "free seat" Y que NO diga
    # "pay", verificado contra el modal real (gratis: "🎟 Free seat",
    # pago: "💰 Pay ~26,437 $BYTE (live)").
    # Hay DOS modales distintos, segun el juego:
    #   - de pago: "💰 Pay ~26,437 $BYTE (live)"  junto a  "🎟 Free seat"
    #   - gratis : "entry free ..."               y solo   "▸ Go live"
    # El filtro conocia solo el primero, asi que con los gratis (Free Bots,
    # Degen Realms) clickeaba el juego y se quedaba para siempre en el
    # dashboard. Visto el 2026-10-11 con los dos modales en la mano.
    #
    # La condicion negativa es la que protege: nunca se toca un boton que diga
    # "pay", porque debita de la wallet del agente.
    return ev("""(()=>{const c=Array.from(document.querySelectorAll("button")).filter(e=>{
        const t=(e.innerText||"").trim();
        return /free seat|go live/i.test(t)&&!/pay/i.test(t)&&e.offsetWidth>0});
      if(!c.length)return "";c[0].click();return c[0].innerText.trim();})()""", wait=4)

def ya_jugando():
    return ev("/already playing/i.test(document.body.innerText)")

def intento(n):
    print("  intento %d: yendo al dashboard" % n)
    ev("location.href='https://app.bytearena.fun/dashboard'", wait=3)
    if not esperar(hay_tarjetas, 60):
        return "el dashboard no cargo las tarjetas (60s)"

    r = clickear_juego(GAME)
    if r != "ok":
        # Volcado forense. Esta falla es INTERMITENTE: el mismo codigo deployo
        # Degen Realms bien el 2026-10-03 a las 03:31 y fallo a las 17:51, asi
        # que no es el matcher sino el estado de la pagina. Ya probe dos teorias
        # a ciegas (el limite de 420 chars, el ancestro con un solo boton) y las
        # dos fueron erradas. Sin ver el DOM del momento no se puede saber.
        diag = ev("""(()=>{""" + ESBOTON + """
          const btns=Array.from(document.querySelectorAll("button")).filter(esBoton);
          const nombres=btns.map(b=>{let p=b;
            for(let i=0;i<12&&p;i++){p=p.parentElement; if(!p) break;
              const t=(p.innerText||"").trim();
              if(t.length>3) return (t.split("\\n").filter(z=>z.trim().length>2)[0]||"?").slice(0,40);}
            return "?";});
          // Cualquier nodo que mencione el juego, aunque sea partido o con otro
          // formato: si aparece aca y el matcher no lo vio, el problema es como
          // lo buscamos; si no aparece, la tarjeta directamente no esta.
          const suelto=Array.from(document.querySelectorAll("*"))
            .filter(e=>e.children.length===0 && /Degen|%s/i.test(e.textContent||""))
            .slice(0,6).map(e=>e.tagName+":"+(e.textContent||"").trim().slice(0,60));
          return JSON.stringify({botones:btns.length, nombres:nombres,
                                 menciones:suelto, scrollY:window.scrollY,
                                 alto:document.body.scrollHeight});})()""" % GAME.split()[0])
        print("  DIAGNOSTICO: %s" % diag)
        if r == "no-esta":
            return ("%r no esta en el catalogo del dashboard — byte lo saco. "
                    "Paso con Degen Realms Arena el 2026-10-03." % GAME)
        if isinstance(r, str) and r.startswith("ambiguo"):
            return "%r matchea varias tarjetas (%s) — hace falta el titulo exacto" % (GAME, r)
        return "no encontre la tarjeta de %r — ver DIAGNOSTICO arriba" % GAME

    # Puede entrar directo a la arena, o abrir el modal de asiento.
    def en_arena():
        return "/arena/" in url()
    if esperar(en_arena, 20):
        return None
    r2 = asiento_gratis()
    if r2:
        print("  modal de entrada: clickee %r" % r2)
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
