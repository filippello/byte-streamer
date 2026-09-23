# byte-streamer — transmitir agentes de byte a Twitch y pump.fun

Levanta un pod GPU en RunPod que actúa como **escritorio**: se loguea en byte,
abre la arena (que es donde están los píxeles reales), y ffmpeg captura esa
pantalla y la empuja por RTMP.

**Números medidos**: 30 fps sostenidos, ~4.3 Mbps a Twitch / ~2.5 Mbps a pump,
0 reconexiones. Contra **1.4 fps** en una EC2 sin GPU: la GPU es la diferencia
entre un stream y una presentación de diapositivas.

**Costo**: ~$0.13–0.16/hr (RTX 3070 / A5000 en community cloud). Crédito prepago,
así que hay techo duro de gasto.

---

## Uso rápido

```bash
./byte-stream.sh up                        # 6-8 min: crea pod, instala, loguea byte
./byte-stream.sh deploy "Infinite Cinema"  # deploya el agente
./byte-stream.sh go pump                   # o: go twitch
./byte-stream.sh chat pump <mint|url>      # o: chat twitch
./byte-stream.sh health                    # verificar de verdad
./byte-stream.sh shot ./captura.png        # ver qué sale al aire
./byte-stream.sh down                      # DESTRUIR (dejar de gastar)
```

`up` deja el estado del pod en `.state`; el resto de los comandos lo leen de ahí.

---

## Varios destinos a la vez

```bash
./byte-stream.sh go twitch      # uno solo (4500k)
./byte-stream.sh go pump,x      # los que quieras
./byte-stream.sh go all         # twitch + pump + X
```

Con más de uno usa el muxer **`tee`**: captura y codifica UNA vez y reparte.
Tres ffmpeg independientes también andarían, pero serían tres capturas y tres
encodes para ganar poco.

**El bitrate es el mínimo de los elegidos**, porque el tee manda el mismo stream
a todos: sumar pump baja a Twitch de 4500k a 2500k. Si hace falta bitrate por
destino, ahí sí van procesos separados.

**Dos cosas que no son opcionales**, las dos aprendidas rompiéndolas:

`onfail=ignore` en cada salida. Sin eso, el rebote de pump se lleva puestos a
los otros dos.

**Pre-calentar pump** (`/root/.prewarm`). pump rechaza SIEMPRE la primera
conexión, y `tee` **no reintenta un slave caído**: queda afuera para siempre y
seguís al aire en 2 de 3 sin enterarte. Por eso se le quema la primera conexión
con 3s de negro antes de arrancar. Con un solo destino no hace falta — ahí el
loop de reintento alcanza.

> Ojo con `printf '%s'` al escribir esa lista: sin `\n` final, `while read`
> descarta la última línea y el pre-calentado no corre. Se verifica en el log:
> tiene que aparecer `pre-calentando:`.

## Los dos destinos

|                  | Twitch                          | pump.fun                              |
|------------------|---------------------------------|---------------------------------------|
| Ingest           | `rtmp://live.twitch.tv/app`     | `rtmps://…livekit.cloud/x` (LiveKit)  |
| Bitrate          | 4500k                           | **2500k** — a 4500k corta             |
| Credencial video | stream key                      | stream key                            |
| Credencial chat  | **OAuth** (login interactivo)   | ninguna, solo el mint de la moneda    |
| Chat             | **bidireccional** (lee y escribe) | **solo escucha** (responde por voz)  |

### pump.fun: el bitrate no es opcional
A 4500k el ingest cortó con `Broken pipe` a los ~18 segundos. A 2500k aguantó
estable. LiveKit es más estricto que Twitch. **Si pump corta, bajá el bitrate
antes de buscar cualquier otra causa.**

### Twitch: el OAuth se hace UNA vez, a mano
La stream key solo empuja video. Para que el agente **lea** el chat hace falta
el OAuth, que es interactivo:

```bash
./byte-stream.sh vnc     # imprime el comando del túnel SSH
# entrás a http://localhost:6080/vnc.html, Broadcast -> Twitch -> Connect with Twitch
./byte-stream.sh mode    # openbox saca el fullscreen: hay que reponerlo
```

El token queda en el **localStorage del navegador** (`byte_twitch_token`), no en
la cuenta de byte. Por eso viaja en el perfil `~/.runpod/byte-profile-with-twitch.tgz`
y no hay que repetirlo en cada pod. **Si se pierde ese archivo, hay que rehacer
el VNC.**

---

## Por qué la arena y no /stream/

`/stream/<id>` es la vista linda de byte, pero **no sirve**:

- En juegos *bridged* (Solana Survivors) embebe el `watchUrl` en modo agente y
  levanta **una segunda instancia del juego**, que se queda en el menú esperando
  decisiones que van al bridge real. Parece un cuelgue y no lo es.
- En Infinite Cinema directamente **sale en blanco**.

La causa está en el código de byte (`src/rtc.ts`): *"un juego browser-driven no se
puede reconstruir del lado del espectador… lo único que se puede compartir es
píxeles"*. Los píxeles viven en **una sola pestaña**: la del operador.

Por eso el pod **es** el operador: abre `/arena/<id>` y `stream-mode.py` le
esconde la interfaz de operador por CSS. **Solo puede haber un bridge por run**:
si otra máquina abre la misma arena, se pelean.

---

## Cortar solo cuando la corrida termina

```bash
./byte-stream.sh guard &    # despues de `go`
```

Una run **se acaba sola** y ffmpeg no se entera: sigue empujando la pantalla de
un agente muerto a 30 fps y 0 reconexiones. Pasó dos veces el 2026-09-11, ~100
minutos al aire sin que nadie hablara y con el `health` en verde.

Tres cosas la terminan, y conviene saber cuál fue (está en el historial:
`GET /api/sessions/<id>` → `history`, eventos `type:"system"`):

| límite | valor | dónde |
|---|---|---|
| presupuesto de requests del juego API | **400** | `API_GAME_CALL_BUDGET` (`src/games/apiGame.ts:56`) |
| tope de corrida | 2 h | `SESSION_MAX_RUN_MS` (`src/agent/session.ts:2425`) |
| límite de pasos | 600 en prod | `SESSION_MAX_STEPS` (`src/server.ts:120`) |

En Infinite Cinema **siempre gana el de 400 requests**: se agota en 105–116 min
según qué tan seguido cambien los clips. Ni el de 2 h ni el de pasos llegan.

`guard` son **dos capas a propósito**. `pod/watch-run.sh` corre *en el pod* y
corta ffmpeg apenas la run termina — sobrevive a que se muera la sesión de
Claude, que es donde se nos escapó la plata antes. La destrucción del pod la hace
la parte local, porque destruir requiere la API key de RunPod y **esa key no
tiene por qué estar en una máquina alquilada a un tercero**. El pod solo deja un
marcador (`/root/RUN_ENDED`) y la parte local lo lee.

Limitación honesta: si se cierra la sesión local, el stream se corta igual (capa
del pod) pero **el pod sigue facturando** hasta que alguien haga `down`.

## Verificar un stream (no alcanza con "ffmpeg está vivo")

Nos pasó transmitir **media hora una pantalla de error** con fps=30 y 0
reconexiones: byte se había reiniciado y la run murió, pero ffmpeg seguía
empujando el cartel. `health` chequea las cuatro cosas juntas:

1. `frame=` avanzando **y** `fps=30`
2. reconexiones en 0
3. la página sigue mostrando `status: running` (y no *"This run is over"*)
4. el renderer dice **NVIDIA** (si dice `llvmpipe`, está renderizando por software)

---

## Rendimiento: qué se come el framerate

Medido en RTX 3070 con juego vivo:

| escenario                                   | fps      |
|---------------------------------------------|----------|
| arena + avatar + **broadcast nativo de byte** | **16.4** |
| arena + avatar (ffmpeg)                      | **23.5** |
| arena **sin avatar**                         | **39.8** |

- **El broadcast nativo de byte cuesta ~30%**: captura la pestaña con
  `getDisplayMedia` y obliga a leer cada frame de la GPU a la CPU, en un hilo.
  Por eso usamos ffmpeg + x11grab, que encodea aparte y multi-hilo.
- **El avatar VRM cuesta ~40%**: Three.js renderiza personaje + habitación
  compitiendo con el juego. Entre 165px y 330px la diferencia está dentro del
  ruido; lo que pesa es tenerlo o no. Está fijo en **330px**.
- La máquina no es el límite: load ~2 sobre 128 cores, GPU al 6%. Una GPU más
  cara no cambia nada — el cuello es un hilo de Chrome.

---

## Cuando el pod no levanta (community cloud)

Síntoma: `up` dice **"el pod no expuso SSH"**. Por API el pod figura `RUNNING`
pero con `runtime: null`, sin IP y con `podHostId`/`gpuTypeId` en **null** —
nunca se le asignó una máquina física.

Es **community cloud**: son hosts de terceros, y uno puede aceptar el alquiler y
después no arrancar el contenedor. **Factura igual**, así que destruilo apenas lo
detectes (`./rp_destroy.sh <pod>`). Cuando de verdad no hay stock, RunPod
contesta honesto: *"There are no instances currently available"*.

Pasó el 2026-09-10: **tres pods seguidos** así (dos RTX 3070, un 3080), con el
status page de RunPod en verde. No era el script, ni la GPU, ni los créditos.

```bash
BYTE_CLOUD=SECURE ./byte-stream.sh up     # datacenters propios de RunPod
BYTE_SKIP_GPU="3070|3080" ./byte-stream.sh up   # saltear modelos que fallan
```

`BYTE_CLOUD=SECURE` fue lo que destrabó: levantó un A5000 a la primera, con el
mismo balance y el mismo request. Cuesta ~el doble por hora (**$0.273** contra
$0.133), así que es para cuando community está caída, no el default.

## Escollos que ya nos costaron horas

1. **El host no inyecta las libs de gráficos** aunque pidas
   `NVIDIA_DRIVER_CAPABILITIES=all`. Hay que instalar el userspace del driver
   *dentro* del contenedor (`pod-setup.sh`), detectando la versión desde
   `/proc/driver/nvidia/version`. Los errores *"Device or resource busy"* del
   installer son normales.
2. **Chrome elige el EGL de Mesa y cae a llvmpipe**. Hay que forzarlo con
   `__EGL_VENDOR_LIBRARY_FILENAMES=…/10_nvidia.json`.
3. **La cookie de byte no viaja en el perfil** (es de sesión). La de notlogin sí
   → `relogin.py` rehace el handshake sin magic link.
4. **El perfil trae un lock de la otra máquina** → borrar `Singleton*`, y lanzar
   con `--password-store=basic` (así se encriptaron las cookies en el origen).
5. **Diálogos nativos de Chrome bloquean CDP** ("Leave site?", el confirm de END
   RUN, el permiso de captura). No se clickean por JS: `xdotool`.
6. **`pkill -f` se mata a sí mismo** si el comando SSH contiene el patrón. Usar
   patrones que no matcheen (`opt/streamer/str`) o lanzar desde un script.
7. **`ps %CPU` es promedio de vida**, no uso instantáneo. Para diagnosticar,
   `top -bn2` o medir fps con `requestAnimationFrame`.
8. **byte permite UNA run activa**: si hay otra abierta el deploy no hace nada.
   Cerrar con `endrun`.
9. **Un reinicio del backend de byte mata todas las runs** ("sessions live in the
   server's memory"). Eso explica los `crashed` históricos.

---

## Archivos

| archivo | qué hace |
|---|---|
| `byte-stream.sh` | orquestador; el único que se corre a mano |
| `rp_create.py` | crea el pod probando varias GPUs/clouds hasta encontrar stock |
| `rp_destroy.sh` | destruye el pod y lista lo que queda |
| `pod/pod-setup.sh` | driver NVIDIA userspace + Chrome + deps |
| `pod/launch-desktop.sh` | Xvfb + PulseAudio + Chrome con el perfil logueado |
| `pod/relogin.py` | rehace el handshake Notlogin → byte |
| `pod/deploy-game.py` | deploya el agente a un juego por nombre |
| `pod/end-run.sh` | cierra la run activa (incluye el confirm nativo) |
| `pod/stream-mode.py` | CSS: esconde la UI de operador, agranda el juego |
| `pod/fullscreen.sh` | F11 a Chrome (hace falta tras navegar o tras el VNC) |
| `pod/stream.sh` | x11grab + audio → RTMP, con NVENC si está disponible |
| `pod/go.sh` | arranca `stream.sh` limpio (mata supervisores viejos) |
| `pod/chat-bridge.py` | prende el chat sin usar el broadcast de byte |
| `pod/health.sh` | el chequeo de 4 puntos |
| `pod/vnc-up.sh` | escritorio remoto por túnel SSH |
| `pod/cdp.py` | helper mínimo de CDP |

**Fuera del repo** (no versionar): `~/.runpod/key` (API key de RunPod),
`~/.runpod/stream-keys.env` (destinos y claves RTMP de Twitch/pump, chmod 600) y
`~/.runpod/byte-profile-with-twitch.tgz` (perfil con byte + Twitch conectados).
Las claves se pueden pisar por entorno, o apuntar a otro archivo con
`BYTE_STREAM_KEYS=/ruta/otro.env`.

---

## Pendientes

- **Chat de pump**: falta el mint de la moneda. Es un `chat pump <mint>` y listo.
- **El fondo de la habitación** dentro del círculo de Mario viene renderizado en
  el 3D (setting "Lobby" del agente), no se saca por CSS.
- **Imagen Docker**: el `Dockerfile` está pensado pero sin construir — falta
  Docker Desktop corriendo y un login de registry. Bajaría el arranque de ~6 min
  a menos de 1. El driver NVIDIA **no** se puede hornear: la versión de userspace
  tiene que coincidir con el kernel del host, y cada host trae otra.
- **Sync de audio: arreglado pero SIN PROBAR.** El 2026-09-09 Federico reportó
  que el audio se oía desfasado. Causa encontrada en el log: `thread_queue_size`
  en el default (**8**) con 4 warnings de bloqueo en las dos entradas, y ninguna
  corrección de drift — X11 y Pulse tienen relojes distintos y nada los
  reconciliaba. `pod/stream.sh` ya lleva `-thread_queue_size 1024`,
  `-use_wallclock_as_timestamps 1` en ambas entradas y
  `-af aresample=async=1000`. **Se subió al pod pero nunca se reinició ffmpeg con
  eso**: el pod se destruyó antes. La próxima corrida es la primera prueba —
  verificar que desaparecen los warnings de `Thread message queue blocking`.
- **TTL del lado del servidor**: hoy el watchdog vive en la sesión de Claude y
  muere con ella. Un pod olvidado es el riesgo económico real.

---

## Cuando el modo consola llegue a prod

byte tiene un **modo consola** hecho para este toolkit, en la branch
`feat/remote-session-api` (doc: `docs/remoto.md` en el repo de byte). **Todavía
no está en prod**, así que los scripts de acá siguen siendo el camino válido.
Cuando se deploye, la mitad de este directorio sobra.

La URL de arranque pasa a llevar la presentación entera:

```
/arena/<id>?remote=1&scene=cinema&avatar=half&chrome=0
```

Ese es el **default elegido por Federico (2026-09-09)**: medio cuerpo y **sin
dock**. Con el dock visible, el panel de thoughts le tapa el brazo al avatar; sin
el, el juego usa todo el ancho y el personaje se ve entero. Para volver a la
burbuja: `REMOTE_PARAMS='remote=1&scene=cinema&avatar=bubble&bubble=330&dock=1&chrome=0' ./byte-stream.sh open <id>`,
o en caliente `./byte-stream.sh present bubble 330`.

y lo dinámico se pide por `window.byte` desde CDP (un `Runtime.evaluate`, misma
cookie y mismo WS: no hay auth nueva).

| hoy | pasa a ser |
|---|---|
| `pod/stream-mode.py` (CSS contra sus clases) | `?scene=cinema&avatar=…&bubble=…&dock=…&chrome=0` |
| `pod/deploy-game.py` (scraping de botones) | `byte.deploy(juego, {replace:true})` |
| `pod/end-run.sh` + `xdotool` en el confirm | `byte.stop()` |
| `pod/chat-bridge.py` (POST a mano) | `?chat=twitch` / `byte.chat.start(...)` |
| el regex de `health.sh` sobre `innerText` | `JSON.parse($('#byte-state').textContent)` |

Lo que **no** cambia: sigue habiendo **un solo bridge por run**
(`byte.meta().bridgeClients` dice cuántas pestañas lo son — si hay una y no sos
vos, mirá, no robes el volante), sigue conviniendo encodear con ffmpeg afuera
del browser (el broadcast nativo cuesta ~30% de fps), y un restart del backend
sigue matando las runs. Los `confirm()` que quedan vivos son los del
**dashboard** (END RUN / DISMISS); con `byte.deploy` y `byte.stop` no se pasa
por ahí.

**Cómo probarlo el día que suba**: pegar esa URL en `START_URL` de
`pod/launch-desktop.sh` y correr `byte.state()` por CDP.
