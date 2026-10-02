#!/bin/bash
# TTL DEL LADO DEL POD: hora maxima de vida, pase lo que pase.
#
# Por que existe: el 2026-09-30 un pod quedo prendido 34h37m y lo termino RunPod
# cuando la cuenta llego a cero ($17.43 a $0.50/h). No lo apago nadie nuestro
# porque no habia nadie mirando: el guard vive en la sesion de Claude y muere
# con ella, y ese pod ni siquiera habia salido de este toolkit.
#
# Este script NO puede destruir el pod: eso necesita la API key de RunPod, y esa
# key no va a una maquina alquilada a un tercero (puede crear pods, no solo
# borrarlos). Lo que SI puede, sin ninguna credencial:
#   1. frenar la corrida de byte y matar ffmpeg  -> deja de salir al aire
#   2. apagarse                                   -> deja de hacer trabajo
# El `delete` de verdad lo hace `byte-stream.sh guard` desde la maquina local,
# que lleva el mismo deadline. Son dos capas a proposito: si una falla, la otra
# acota el daño.
#
# OJO con lo que esto NO garantiza: que el pod deje de FACTURAR. Un contenedor
# apagado puede seguir cobrando mientras el pod exista del lado de RunPod. Lo
# unico que corta la factura seguro es el terminate por API, que hace el guard.
POLL="${POLL:-60}"
MARK=/root/TTL_VENCIDO
LOG=/root/ttl.log
CONF=/root/.ttl

[ -f "$CONF" ] || { echo "$(date -Is) sin $CONF, no hay TTL que vigilar" >> "$LOG"; exit 0; }

while true; do
  # Se relee en cada vuelta A PROPOSITO: asi `byte-stream.sh ttl <horas>` puede
  # estirar o acortar el plazo con el pod ya andando, sin reiniciar nada.
  DEADLINE=0
  . "$CONF" 2>/dev/null
  [ -n "${DEADLINE:-}" ] || DEADLINE=0

  AHORA=$(date +%s)
  if [ "$DEADLINE" -gt 0 ] && [ "$AHORA" -ge "$DEADLINE" ]; then
    echo "$(date -Is) VENCIO EL TTL — frenando todo" >> "$LOG"

    # 1) cerrar la corrida en byte. Si no, la sesion queda viva del lado del
    #    servidor y el proximo deploy choca con "this agent is already playing".
    python3 /opt/streamer/cdp.py eval \
      '(async()=>{try{return JSON.stringify((await byte.stop()) ?? "ok")}catch(e){return "sin byte: "+e.message}})()' \
      >> "$LOG" 2>&1

    # 2) cortar el stream. Primero los loops de reintento, despues los ffmpeg:
    #    al reves, cada loop levanta el suyo de nuevo.
    pkill -9 -f 'opt/streamer/str' 2>/dev/null
    sleep 1
    ps -eo pid,comm --no-headers | grep '[f]fmpeg' | awk '{print $1}' | xargs -r kill -9

    printf 'ttl vencido %s' "$(date -Is)" > "$MARK"
    echo "$(date -Is) stream cortado y corrida frenada; apagando el pod" >> "$LOG"
    sync

    # 3) apagarse. Deja de consumir GPU y de hacer trabajo. El cobro lo corta
    #    el guard con el terminate por API; esto es el cinturon, no el airbag.
    poweroff -f 2>/dev/null || halt -f 2>/dev/null || kill -9 1
    exit 0
  fi

  sleep "$POLL"
done
