#!/bin/bash
# byte-stream.sh — control del streamer de byte en un pod GPU de RunPod.
#
#   ./byte-stream.sh up                      crea el pod, instala todo y loguea byte
#   ./byte-stream.sh deploy "Infinite Cinema" deploya el agente a un juego
#   ./byte-stream.sh go twitch|pump|x         transmite a un destino
#   ./byte-stream.sh go twitch,pump,x         los tres a la vez (un ffmpeg por destino)
#   ./byte-stream.sh go all                   idem, atajo
#   ./byte-stream.sh chat twitch             prende el chat de Twitch (bidireccional)
#   ./byte-stream.sh chat pump <mint|url>    prende el chat de pump (solo escucha)
#
#   --- modo consola (prod desde 2026-09-08) ---
#   ./byte-stream.sh open <sessionId>        abre la arena con los params de remote=1
#   ./byte-stream.sh api '<js>'              llama window.byte  (ej: api 'byte.state()')
#   ./byte-stream.sh look                    lee #byte-state (estado legible por maquina)
#   ./byte-stream.sh present <bubble|half|full> [px]
#   ./byte-stream.sh zoom <factor>           achica el iframe del juego (0.8 = 80%)
#   ./byte-stream.sh carrusel "A|B|C" <horas> [min]   rota entre juegos, cambiando
#                                            recien al terminar cada partida
#   ./byte-stream.sh keep "<juego>" <horas>   al terminar una corrida redeploya el
#                                            mismo juego y sigue al aire hasta el tope
#   ./byte-stream.sh ttl <horas>             cambia la hora de muerte del pod (default 3h,
#                                            o BYTE_TTL_HORAS=N al hacer `up`)
#   ./byte-stream.sh guard-bg                vigila la run DETACHADO (lo normal): corta el
#                                            stream y DESTRUYE el pod al terminar la corrida
#   ./byte-stream.sh guard                   idem, pero atado a esta terminal
#   ./byte-stream.sh health                  chequeo real del stream
#   ./byte-stream.sh shot                    captura lo que sale al aire
#   ./byte-stream.sh vnc                     escritorio remoto (para OAuth a mano)
#   ./byte-stream.sh ssh                     entra al pod
#   ./byte-stream.sh down                    DESTRUYE el pod (deja de gastar)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/.state"
KEY=~/.ssh/id_rsa
# Perfil SLIM (118K vs 90M del original). Solo cookies + Local Storage (donde
# vive byte_twitch_token) + Preferences. El resto del perfil de Chrome son
# modelos de ML y caches que se regeneran solos: 159M -> 460K en disco.
# El link al pod sube a ~0.7 MB/min: el original tardaba 80+ minutos.
PROFILE=~/.runpod/byte-profile-slim.tgz

# Credenciales de streaming: viven FUERA del repo, en ~/.runpod/stream-keys.env
# (chmod 600), igual que la API key de RunPod. Se pueden pisar por entorno.
KEYFILE="${BYTE_STREAM_KEYS:-$HOME/.runpod/stream-keys.env}"
[ -f "$KEYFILE" ] && . "$KEYFILE"
TWITCH_TARGET="${TWITCH_TARGET:-rtmp://live.twitch.tv/app}"
need_key(){ # $1=variable  $2=destino
  [ -n "${!1:-}" ] || { echo "falta $1 — ponelo en $KEYFILE o exportalo (destino: $2)"; exit 1; }; }

load(){ [ -f "$STATE" ] || { echo "no hay pod (corré: $0 up)"; exit 1; }; . "$STATE"; }
sshp(){ ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=25 -p "$PORT" "root@$IP" "$@"; }
scpp(){ scp -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=25 -P "$PORT" "$@"; }

case "${1:-}" in
up)
  OUT=$(python3 "$DIR/rp_create.py") || { echo "$OUT"; exit 1; }
  echo "$OUT"
  POD=$(echo "$OUT" | grep -oE 'pod [a-z0-9]+' | awk '{print $2}')
  K=$(cat ~/.runpod/key)
  echo "esperando SSH…"
  for i in $(seq 1 40); do
    R=$(curl -s --max-time 25 -H "Authorization: Bearer $K" "https://rest.runpod.io/v1/pods/$POD")
    IP=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("publicIp") or "")')
    PORT=$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("portMappings") or {}).get("22") or "")')
    [ -n "$PORT" ] && break; sleep 12
  done
  # Un pod que nunca expone SSH IGUAL se alquila y se cobra. Salir sin
  # destruirlo deja un huerfano que ni siquiera queda en .state, asi que nadie
  # se entera hasta mirar la factura. Pasa seguido en COMMUNITY: el host acepta
  # el alquiler y no provisiona nunca.
  if [ -z "${PORT:-}" ]; then
    echo "el pod no expuso SSH — destruyendolo para no pagarlo de gusto"
    "$DIR/rp_destroy.sh" "$POD" || echo "NO SE PUDO DESTRUIR $POD — borralo a mano"
    echo "probá de nuevo, y si se repite forzá datacenter: BYTE_CLOUD=SECURE $0 up"
    exit 1
  fi
  printf 'POD=%s\nIP=%s\nPORT=%s\n' "$POD" "$IP" "$PORT" > "$STATE"
  echo "pod $POD en $IP:$PORT"
  echo "subiendo scripts y perfil…"
  scpp "$DIR"/pod/* "$PROFILE" "root@$IP:/root/" >/dev/null
  sshp "mkdir -p /opt/streamer && cd /root && cp cdp.py cdp-dialog.py inject-css.py stream.sh stream-mode.py chat-bridge.py relogin.py deploy-game.py /opt/streamer/ && chmod +x /opt/streamer/* /root/*.sh && tar xzf byte-profile-slim.tgz"
  echo "preparando el pod…"
  sshp "setsid nohup /root/pod-setup.sh >/dev/null 2>&1 </dev/null & echo lanzado"
  # Poll corto: el paso dura entre ~40s (imagen horneada) y ~6 min (base pelada),
  # y con sleep 25 se tiraban hasta 25s de puro esperar despues de terminar.
  for i in $(seq 1 150); do
    sshp "test -f /root/SETUP_DONE && echo READY" 2>/dev/null | grep -q READY && { echo "setup listo"; break; }
    [ $((i % 5)) -eq 0 ] && echo "  preparando… ($((i*6))s)"
    sleep 6
  done
  sshp "test -f /root/SETUP_DONE" || { echo "el setup no termino — mirá /root/setup.log"; exit 1; }
  # Los ### del setup dicen donde se fue el tiempo. Sin esto optimizamos a ciegas.
  sshp "grep -a '^###' /root/setup.log" 2>/dev/null
  echo "levantando Chrome…"
  # launch-desktop.sh escribe FIN en desktop.status cuando termina: esperar ESO
  # en vez de un sleep fijo de 100s.
  sshp "setsid nohup /root/launch-desktop.sh >/dev/null 2>&1 </dev/null & \
        for i in \$(seq 1 40); do sleep 5; grep -qE '^(FIN|XVFB FALLO|CHROME FALLO)\$' /root/desktop.status 2>/dev/null && break; done; \
        cat /root/desktop.status"
  echo "rehaciendo login de byte (la cookie no viaja en el perfil)…"
  sshp "python3 /opt/streamer/relogin.py"
  # TTL desde el minuto cero, no desde que alguien se acuerde de armarlo. Se
  # puede pisar antes (BYTE_TTL_HORAS=5 ./byte-stream.sh up) o despues
  # ($0 ttl <horas>). Default conservador: una corrida tipica dura 1-2 h.
  TTLH="${BYTE_TTL_HORAS:-3}"
  D=$(python3 -c 'import time,sys; print(int(time.time()+float(sys.argv[1])*3600))' "$TTLH")
  printf 'DEADLINE=%s\n' "$D" | sshp "cat > /root/.ttl"
  printf 'DEADLINE=%s\n' "$D" >> "$STATE"
  sshp "/root/start-ttl.sh" || echo "OJO: el TTL del pod no arranco"
  echo "TTL: $TTLH h — el pod se apaga solo a las $(date -r "$D" '+%H:%M')"
  ;;
deploy) load; sshp "python3 /opt/streamer/deploy-game.py '${2:-Infinite Cinema}'"; sshp "/root/fullscreen.sh; python3 /opt/streamer/stream-mode.py" ;;
go)
  # Uno o varios destinos separados por coma. Cada uno se lleva su PROPIO ffmpeg
  # con su propio reintento (ver pod/stream.sh): por eso cada uno puede ir a su
  # bitrate y la caida de uno ya no se lleva puestos a los otros.
  load
  SEL="${2:-twitch}"; [ "$SEL" = "all" ] && SEL="twitch,pump,x"
  DESTS=""
  IFS=',' read -r -a PARTS <<< "$SEL"
  for d in "${PARTS[@]}"; do
    case "$d" in
      twitch) T="$TWITCH_TARGET"; K="${TWITCH_KEY:-}"; BR="${TWITCH_BITRATE:-4500k}" ;;
      pump)   T="${PUMP_TARGET:-}"; K="${PUMP_KEY:-}"; BR="${PUMP_BITRATE:-2500k}" ;;
      x)      T="${X_TARGET:-}";    K="${X_KEY:-}";    BR="${X_BITRATE:-2500k}" ;;
      *) echo "destino desconocido: '$d' (validos: twitch, pump, x, all)"; exit 1 ;;
    esac
    [ -n "$K" ] && [ -n "$T" ] || { echo "faltan credenciales de '$d' en $KEYFILE"; exit 1; }
    DESTS="${DESTS}${BR} ${T}/${K}"$'\n'
  done
  echo "destinos: $SEL"
  printf '%s' "$DESTS" | sshp "cat > /root/.dests; chmod 600 /root/.dests; rm -f /root/.prewarm /root/.bitrate"
  sshp "/root/go.sh" ;;
open)
  load
  ID="${2:?uso: $0 open <sessionId>}"
  # Default elegido por Federico (2026-09-09): medio cuerpo y SIN dock — el dock
  # le tapaba el brazo, y sin el el juego usa todo el ancho. Pisar con REMOTE_PARAMS.
  P="${REMOTE_PARAMS:-remote=1&scene=cinema&avatar=half&chrome=0}"
  sshp "python3 /opt/streamer/cdp.py nav 'https://app.bytearena.fun/arena/$ID?$P'"
  sshp "/root/fullscreen.sh" ;;
api)
  load; EXPR="${2:?uso: $0 api '<js>'   ej: api 'byte.state()'}"
  sshp "python3 /opt/streamer/cdp.py eval '(async()=>{try{return JSON.stringify((await ($EXPR)) ?? null)}catch(e){return \"ERROR: \"+e.message}})()'" ;;
look)
  load; sshp "python3 /opt/streamer/cdp.py eval 'document.getElementById(\"byte-state\")?.textContent ?? \"NO HAY #byte-state (falta remote=1?)\"'" ;;
present)
  load; A="${2:?uso: $0 present bubble|half|full [px]}"; B="${3:-330}"
  sshp "python3 /opt/streamer/cdp.py eval 'JSON.stringify(byte.present({avatar:\"$A\",bubble:$B}) ?? \"ok\")'" ;;
zoom)
  # Achica (o agranda) el iframe del juego dentro de la escena cinema. byte no
  # expone ninguna perilla para esto, asi que va por CSS desde la pagina padre,
  # que es same-origin; el contenido de adentro del iframe no se toca.
  # transform y no width/height a proposito: el juego se sigue renderizando a
  # resolucion completa y solo se MUESTRA mas chico, asi no pierde nitidez.
  load
  F="${2:?uso: $0 zoom <factor>   (ej: $0 zoom 0.8 = 80%)}"
  printf '.game-iframe{transform:scale(%s);transform-origin:center center;}\n' "$F" \
    | sshp "cat > /root/.cinema-css"
  sshp "python3 /opt/streamer/inject-css.py"
  echo "iframe al $(python3 -c 'import sys;print(int(float(sys.argv[1])*100))' "$F")% — se reaplica solo despues de cada redeploy"
  ;;
carrusel)
  # Rota entre varios juegos dandole a cada uno un turno. El cambio ocurre al
  # TERMINAR una partida, no al cumplirse el turno: asi no se corta ninguna
  # partida por la mitad. La transicion por el dashboard la tapa placa.sh.
  load
  LISTA="${2:?uso: $0 carrusel \"Juego A|Juego B|Juego C\" <horas> [min por juego]}"
  H="${3:-4}"; MIN="${4:-30}"
  UNTIL=$(python3 -c 'import time,sys; print(int(time.time()+float(sys.argv[1])*3600))' "$H")
  TURNO=$(python3 -c 'import sys; print(int(float(sys.argv[1])*60))' "$MIN")
  P="${REMOTE_PARAMS:-remote=1&scene=cinema&avatar=half&chrome=0}"
  # byte.present() NO persiste: al cambiar de juego la escala del avatar vuelve
  # a 1. Va en los params, que si se respetan al cargar.
  ESC=$(sshp "timeout 25 python3 /opt/streamer/cdp.py eval 'byte.state().avatarScale'" 2>/dev/null \
        | tr -d '"' | tr -d '[:space:]')
  case "$ESC" in
    ''|1|1.0|null) : ;;
    *) P="${P}&avatarScale=${ESC}"; echo "llevo avatarScale=$ESC en los params" ;;
  esac
  printf 'KEEP_GAMES=%q\nKEEP_TURNO=%q\nKEEP_UNTIL=%q\nKEEP_PARAMS=%q\n' \
    "$LISTA" "$TURNO" "$UNTIL" "$P" | sshp "cat > /root/.keep"
  # Un carrusel nuevo arranca de cero: si queda el estado del anterior, retoma en
  # el juego equivocado o con un turno que no corresponde.
  sshp "rm -f /root/.carrusel-estado"
  echo "carrusel armado — $MIN min por juego, corta en $H h ($(date -r "$UNTIL" '+%H:%M'))"
  printf '%s\n' "$LISTA" | tr '|' '\n' | sed 's/^/  · /'
  echo "ojo: si el watchdog ya esta corriendo, relanzalo para que lo tome ($0 guard-bg)"
  ;;
keep)
  # Modo "transmitime esto por N horas". Una sola corrida casi nunca llega:
  # Fight Night se queda sin presupuesto de llamadas mucho antes. Esto le deja
  # dicho al watchdog del pod que, cuando una corrida termine, redeploye el
  # mismo juego y siga al aire, hasta la hora tope.
  load
  G="${2:?uso: $0 keep \"<juego>\" <horas>}"; H="${3:-2}"
  UNTIL=$(python3 -c 'import time,sys; print(int(time.time()+float(sys.argv[1])*3600))' "$H")
  P="${REMOTE_PARAMS:-remote=1&scene=cinema&avatar=half&chrome=0}"
  # byte.present() NO persiste: al redeployar, la escala del avatar vuelve a 1 y
  # el personaje aparece mas chico. Paso el valor VIVO a los params de la URL,
  # que si se respetan al cargar. Nos paso el 2026-10-02 con avatarScale 1.5.
  ESC=$(sshp "timeout 25 python3 /opt/streamer/cdp.py eval 'byte.state().avatarScale'" 2>/dev/null \
        | tr -d '"' | tr -d '[:space:]')
  case "$ESC" in
    ''|1|1.0|null) : ;;
    *) P="${P}&avatarScale=${ESC}"; echo "llevo avatarScale=$ESC en los params" ;;
  esac
  # %q y no %s: el nombre del juego lleva espacios y guion largo, y los params
  # llevan '&'. Sin comillas, el `.` del watchdog leia "KEEP_GAME=PUMP.RPG" y
  # despues intentaba EJECUTAR el resto — KEEP_GAME quedaba vacio y el modo keep
  # se apagaba en silencio, diciendo que estaba armado.
  printf 'KEEP_GAME=%q\nKEEP_UNTIL=%q\nKEEP_PARAMS=%q\n' "$G" "$UNTIL" "$P" \
    | sshp "cat > /root/.keep"
  echo "al terminar cada corrida redeploya \"$G\" — corta en $H h ($(date -r "$UNTIL" '+%H:%M'))"
  ;;
ttl)
  # Cambia la hora de muerte con el pod ya andando. ttl.sh relee /root/.ttl en
  # cada vuelta, asi que no hay que reiniciar nada. El guard local lee .state.
  load
  H="${2:?uso: $0 ttl <horas desde ahora>   (ej: $0 ttl 2)}"
  D=$(python3 -c 'import time,sys; print(int(time.time()+float(sys.argv[1])*3600))' "$H")
  printf 'DEADLINE=%s\n' "$D" | sshp "cat > /root/.ttl"
  grep -v '^DEADLINE=' "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"
  printf 'DEADLINE=%s\n' "$D" >> "$STATE"
  echo "TTL: el pod se apaga a las $(date -r "$D" '+%H:%M') (en $H h)"
  echo "ojo: si el guard ya esta corriendo, releva el deadline viejo — relanzalo con $0 guard-bg"
  ;;
guard-bg)
  # `guard` detachado, que es como hay que usarlo casi siempre. Lanzado como
  # tarea de fondo de una sesion de Claude lo matan a los pocos segundos (visto
  # 3 de 3); con el subshell + nohup queda con PPID 1 y sobrevive a la sesion y
  # al terminal. El destino del log se imprime para poder seguirlo.
  load
  LOG="${BYTE_GUARD_LOG:-/tmp/byte-guard.log}"
  ( nohup "$0" guard >"$LOG" 2>&1 & )
  sleep 4
  P="$(ps -eo pid,ppid,command | grep "$(basename "$0") guar[d]" | awk '$2==1{print $1; exit}')"
  [ -n "$P" ] || { echo "el guard no quedo detachado — revisa $LOG"; exit 1; }
  echo "guard detachado (pid $P, PPID 1) — log: $LOG"
  cat "$LOG" ;;
guard)
  # Dos capas, a proposito:
  #  - EN EL POD (watch-run.sh): corta ffmpeg apenas la run termina. Sobrevive a
  #    que se muera esta sesion. No puede destruir el pod: haria falta la API key
  #    de RunPod adentro de una maquina alquilada a un tercero.
  #  - ACA: espera el marcador y destruye el pod. La key nunca sale de esta maquina.
  load
  # El arranque del watchdog remoto vive en un script DEL POD, no en esta linea:
  # si el pkill viaja por SSH, el patron matchea el propio shell remoto y se
  # mata solo antes de arrancar nada. Detalle en pod/start-watchdog.sh.
  sshp "/root/start-watchdog.sh" || { echo "sin watchdog en el pod — abortando para no dejarte un stream sin vigilancia"; exit 1; }
  # El TTL es independiente de la corrida: si la run no termina nunca, igual hay
  # una hora en la que el pod se cae. Es la leccion del pod que vivio 34h37m.
  sshp "/root/start-ttl.sh" || echo "OJO: el TTL del pod no arranco — queda solo la capa local"
  # Los logs del pod mueren CON el pod. El 2026-10-02 el modo keep no pudo
  # redeployar, el watchdog corto bien y el guard destruyo bien, pero el motivo
  # estaba en /root/watchdog.log y se fue con la maquina: nos quedamos sin la
  # evidencia justo del caso que habia que depurar. Antes de destruir, se baja.
  rescatar_logs(){
    local dest="$DIR/logs/$POD-$(date +%Y%m%d-%H%M)"
    mkdir -p "$dest"
    for f in watchdog.log ttl.log setup.log desktop.status chrome.log; do
      sshp "cat /root/$f 2>/dev/null" > "$dest/$f" 2>/dev/null
    done
    sshp "for l in /root/ffmpeg.*.log; do [ -e \"\$l\" ] && { echo \"=== \$l ===\"; tail -40 \"\$l\"; }; done" \
      > "$dest/ffmpeg.txt" 2>/dev/null
    find "$dest" -size 0 -delete 2>/dev/null
    echo "logs del pod guardados en $dest"
  }
  # Responde existe | no-existe | no-se. La diferencia entre las dos ultimas es
  # la que evita abandonar un pod que igual factura.
  pod_existe(){
    local k code
    k="$(cat ~/.runpod/key)"
    code="$(curl -s -o /tmp/byte-pod.json -w '%{http_code}' --max-time 25 \
            -H "Authorization: Bearer $k" "https://rest.runpod.io/v1/pods/$POD" 2>/dev/null)"
    case "$code" in
      200) grep -q "\"$POD\"" /tmp/byte-pod.json 2>/dev/null && echo existe || echo no-se ;;
      404) echo no-existe ;;
      *)   echo no-se ;;
    esac
  }
  echo "vigilando $POD — al terminar la run: corta el stream y destruye el pod"
  [ "${DEADLINE:-0}" -gt 0 ] && echo "TTL: a las $(date -r "$DEADLINE" '+%H:%M') lo destruyo aunque siga corriendo"
  while true; do
    # Tope duro. Va ANTES que todo lo demas: una run viva no es excusa para
    # seguir pagando mas alla de lo pactado.
    if [ "${DEADLINE:-0}" -gt 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "venció el TTL — destruyendo el pod"
      rescatar_logs
      "$DIR/rp_destroy.sh" "$POD"; rm -f "$STATE"; echo "pod destruido, gasto en 0"; exit 0
    fi
    R=$(sshp "cat /root/RUN_ENDED /root/TTL_VENCIDO 2>/dev/null" 2>/dev/null)
    if [ -n "$R" ]; then
      # $R ya viene con su propia etiqueta desde watch-run.sh ("status=finished",
      # "cambio de sesion (...)"), asi que aca NO se le antepone nada.
      echo "la run termino ($R) — stream cortado por el pod; destruyendo…"
      rescatar_logs
      "$DIR/rp_destroy.sh" "$POD"; rm -f "$STATE"; echo "pod destruido, gasto en 0"; exit 0
    fi
    # Un SSH que falla NO prueba que el pod se murio: puede ser un hipo de red.
    # Antes bastaba UNO para que el guard se fuera diciendo "nada que vigilar", y
    # el 2026-09-23 eso dejo un pod facturando 8,4 horas al vacio ($2,28) despues
    # de que la run ya habia terminado. Ahora se exige insistencia, y la verdad
    # la tiene la API de RunPod, no el SSH.
    if sshp "true" >/dev/null 2>&1; then
      FALLOS=0
    else
      FALLOS=$((${FALLOS:-0}+1))
      echo "el pod no responde por SSH ($FALLOS/5)"
      if [ "$FALLOS" -ge 5 ]; then
        # Tres respuestas posibles, y la tercera es la que nos costo plata:
        #   existe      -> esta facturando y no responde: se destruye.
        #   no-existe    -> ya no hay nada que pagar: nos vamos.
        #   no-se        -> la consulta FALLO. NO es lo mismo que "no existe".
        # El 2026-10-03 un corte de red tiro los 5 SSH y tambien la consulta a la
        # API; el codigo viejo preguntaba con `grep -q "$POD"` sobre una salida
        # vacia, leyo "no existe" y abandono un pod vivo que siguio cobrando a
        # $0.50/h. Ante la duda NO se abandona: se sigue vigilando y, si no se
        # recupera, el TTL termina forzando el destroy.
        case "$(pod_existe)" in
          existe)
            echo "sigue vivo para RunPod pero no responde — destruyendo para no pagarlo de gusto"
            rescatar_logs
            "$DIR/rp_destroy.sh" "$POD"; rm -f "$STATE"; echo "pod destruido, gasto en 0"
            exit 0 ;;
          no-existe)
            echo "el pod ya no existe para RunPod — nada que destruir"
            rm -f "$STATE"; exit 0 ;;
          *)
            echo "no pude confirmar con RunPod si el pod existe — NO lo abandono, sigo vigilando"
            FALLOS=0 ;;
        esac
      fi
    fi
    sleep 60
  done ;;
chat)   load; sshp "python3 /opt/streamer/chat-bridge.py '${2:-twitch}' '${3:-}'" ;;
endrun) load; sshp "/root/end-run.sh" ;;
mode)   load; sshp "/root/fullscreen.sh; python3 /opt/streamer/stream-mode.py" ;;
health) load; sshp "/root/health.sh" ;;
shot)
  load; sshp "DISPLAY=:1 import -window root /root/shot.png" && scpp "root@$IP:/root/shot.png" "${2:-./shot.png}" && echo "guardado en ${2:-./shot.png}" ;;
vnc)
  load
  sshp "/root/vnc-up.sh" || { echo "noVNC no levanto — mirá /root/vnc-up.log en el pod"; exit 1; }
  echo; echo "1) en otra terminal, dejá corriendo:"
  echo "   ssh -i $KEY -N -L 6080:localhost:6080 -p $PORT root@$IP"
  echo "2) abrí: http://localhost:6080/vnc.html"
  echo "3) al terminar: ./byte-stream.sh mode   (openbox saca el fullscreen)" ;;
ssh)    load; ssh -i "$KEY" -o StrictHostKeyChecking=no -p "$PORT" "root@$IP" ;;
status)
  K=$(cat ~/.runpod/key)
  curl -s --max-time 25 -H "Authorization: Bearer $K" https://rest.runpod.io/v1/pods | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('sin pods' if not d else json.dumps([{'id':p.get('id'),'estado':p.get('desiredStatus')} for p in d]))"
  curl -s --max-time 25 -H "Content-Type: application/json" -d '{"query":"query { myself { clientBalance currentSpendPerHr } }"}' "https://api.runpod.io/graphql?api_key=$K" ;;
down)
  load; "$DIR/rp_destroy.sh" "$POD"; rm -f "$STATE"; echo "pod destruido" ;;
*) sed -n '2,20p' "$0" ;;
esac
