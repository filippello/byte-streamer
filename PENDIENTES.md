# Pendientes — byte remote streamer

Estado al 2026-09-12. Lo que ya está hecho vive en `README.md` y en la skill
`.claude/skills/byte-remote-stream/SKILL.md`.

---

## A. Para construir acá (elegidas para después)

### A1. Imagen Docker
Hornear deps + Chrome + `websocket-client` en una imagen propia. Baja el arranque
y elimina la varianza de `apt`. **El driver NVIDIA no se puede hornear**: la
versión de userspace tiene que coincidir con el kernel del host y cada host trae
otra, así que `pod-setup.sh` seguiría instalándolo al arrancar.
Necesita: Docker Desktop corriendo + credenciales de un registry.
Valor: medio. Es habilitador de A2 y A3 más que un fin.

### A2. Servicio con API propia
`POST /streams {sessionId, destinos}` dueño del ciclo de vida del pod. Desacopla,
se testea, y después byte lo llama desde su UI.
El costo real no es el código: hosting, secretos, auth y control de abuso.
Valor: medio-alto, pero sólo si hay más de un consumidor.

### A3. Feature completa dentro de byte ("lanzar stream remoto")
byte provisiona el pod, abre la arena, arranca ffmpeg.
**No es una feature, es un producto de infraestructura**: credenciales de nube,
facturación por usuario, cuotas, cola de trabajos, TTL de pods — y hereda todas
las trampas del README (driver, EGL, pre-calentado de pump, etc.).
Valor: alto en narrativa, muy caro. Dejar para cuando haya demanda real.

---

## B. Pedidos para el repo de byte

### B1. Token de autenticación para operador remoto ← **el de más leverage**

**Problema.** Para que una máquina nueva sea el operador hay que copiarle un
perfil de Chrome con las cookies y rehacer un handshake de Notlogin
(`relogin.py`). Es la parte más frágil del sistema: depende de que la cookie
persistente de notlogin no venza (dura 30 días), de mover un tarball entre
máquinas, y de que el token de Twitch viva en el `localStorage` de ESE browser.

**Pedido.** Que byte emita un **token o URL de un solo uso** que autentique una
sesión headless como el dueño de la cuenta, con alcance acotado (una sesión, un
agente) y vencimiento corto.

**Qué se cae si existe:** `relogin.py`, el tarball del perfil, y el problema de
que el OAuth de Twitch esté atado a una máquina.

**Sirve a cualquiera** que quiera operar byte remoto, no sólo a nosotros — y es
chico comparado con provisionar pods.

### B2. Perilla de tamaño del avatar en `half` y `full` — HECHO (sin mergear)

Entregado el 2026-09-12 en la branch `feat/remote-avatar-scale` del repo de byte
(commit `b09396f`), **todavía no en master ni en prod**.

`?avatarScale=1.4` y `byte.present({avatarScale})`, rango 0.5–2.5, legible en
`byte.state()` y `#byte-state`, sin persistir. Ausente deja el tamaño de siempre.

El detalle técnico que pedimos se respetó: escala el CONTENEDOR con una variable
CSS (`--cinema-avatar-scale` sobre `width`/`height` en `vh`), no hay ningún
`transform: scale()` sobre el canvas. Medido a `avatarScale=1.8` con DPR 2:
contenedor 621x869 CSS, drawing buffer 1241x1737, `transform: none` — o sea que
R3F re-renderiza a la resolución nueva en vez de estirar píxeles.

**Lo que falta antes de usarlo:** los dos caminos tratan distinto un valor fuera
de rango. `present()` clampea (`page.tsx:273` → 99 da 2.5), pero la URL lo
**descarta** (`remoteParams.ts:75` exige que ya esté en rango), asi que
`?avatarScale=99` deja el tamaño default sin avisar. Nosotros pasamos todo por
URL en `open`, asi que un valor mal tipeado se ve como "no hizo nada".
Pedir que la URL clampee igual que `present()`.

### B3. Audio del juego embebido — NO ES IMPLEMENTABLE ASÍ

Byte contestó el 2026-09-12 y tienen razón: el iframe del juego es
**cross-origin** (`infinitecinema.vercel.app` dentro de `app.bytearena.fun`), y
una página no puede tocar el `<video>` de un iframe de otro origen. Nuestro
`cdp-frame.py` funciona porque CDP se saltea esa frontera, no porque la página
pueda hacerlo. El pedido, tal como lo escribí, no se puede cumplir.

La versión implementable es un **protocolo `postMessage`** que el juego tiene que
adoptar del otro lado. O sea que deja de ser un pedido a byte solo y pasa a ser
un acuerdo entre byte y cada juego.

Antes de eso conviene mirar por qué el player monta `muted=true`, porque el
iframe ya lleva `allow="autoplay"`: puede que el arreglo real esté del lado del
juego y no haga falta protocolo ninguno.

Mientras tanto sigue el workaround por CDP, que se pierde al recargar.

### B4. Presupuesto de requests por juego

`API_GAME_CALL_BUDGET` (`src/games/apiGame.ts:56`, default 400) es **global a
todos los juegos por API**. En Infinite Cinema se agota en 105–116 min y corta la
corrida. El campo `callBudget` ya existe en `src/games/types.ts:384`.

Pedido: que el manifiesto del juego pueda declarar su propio presupuesto.
Un juego que es una TV para mirar horas no tiene el mismo perfil que uno que se
juega en veinte minutos.

### B5. (menor) `bridgeClients` y el health check — HECHO a medias

Entregado el 2026-09-12 en la misma branch (commit `a296a92`):
- `byte.meta()` ahora devuelve el meta **aplanado** — la doc prometía algo que el
  código no daba, y lo corrigieron.
- `docs/remoto.md` avisa explícito lo de `chrome=0` y el health check.

**Sigue abierto** el conteo de `bridgeClients: 2` con una sola pestaña. Dato para
quien lo retome: acá lo vimos volver solo a 1 cuando se reapeó un socket zombie,
asi que puede ser un socket que tarda en cerrarse y no un error de conteo.

## C. Cosas rotas ya diagnosticadas (no nuestras)

- **Desfasaje de Infinite Cinema**: byte comenta un clip que todavía no se ve. El
  adapter que lo arregla existe en `wip/infinitecinema-adapter` (lee
  `/api/watching`, o sea lo que muestra EL PLAYER, y saltea clips con <6s) pero
  **no está en master ni en prod**; ahí corre como juego cargado genérico
  (`game:"api"`, `profileId: gp_l785ek1e57ha`).
- **Lipsync**: el análisis de audio nunca corre (deadlock: `sawSignal` sólo se
  setea dentro de `level()`, que sólo se llama si `hasSignal()` ya es true —
  `VRMCharacter.tsx:1010/1019` + `voiceLevel.ts:137/184`), así que la boca va con
  `Math.sin(t*9)`. **A la vista parece bien** y Federico confirmó que se ve bien:
  es un bug latente de baja prioridad, no el problema que él reportó.
  El test no lo detecta porque `test-lipsync.cjs:85` llama a `level()` antes de
  leer `hasSignal()` — la sonda crea la condición que dice medir.
