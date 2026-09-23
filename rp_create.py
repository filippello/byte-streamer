#!/usr/bin/env python3
"""Crea un pod probando varias GPUs/clouds hasta encontrar stock."""
import json, os, subprocess, sys
KEY = open(os.path.expanduser("~/.runpod/key")).read().strip()
PUB = open(os.path.expanduser("~/.ssh/id_rsa.pub")).read().strip()
CANDS = ["NVIDIA GeForce RTX 3070","NVIDIA RTX A5000","NVIDIA GeForce RTX 3080",
         "NVIDIA GeForce RTX 3080 Ti","NVIDIA GeForce RTX 4070 Ti","NVIDIA RTX A4500",
         "NVIDIA RTX 4000 Ada Generation","NVIDIA GeForce RTX 3090","NVIDIA RTX A6000",
         "NVIDIA GeForce RTX 4090"]
# BYTE_SKIP_GPU: subcadenas separadas por "|" para saltear modelos que aceptan el
# alquiler pero no llegan a provisionar (pasa: quedan RUNNING sin runtime ni IP).
SKIP = [x for x in os.environ.get("BYTE_SKIP_GPU","").split("|") if x]
if SKIP:
    CANDS = [g for g in CANDS if not any(s.lower() in g.lower() for s in SKIP)]
# Imagen horneada (docker/Dockerfile): trae apt + Chrome + pip ya instalados,
# asi pod-setup.sh solo pone el driver. Tiene que ser PUBLICA en ghcr: RunPod
# no tiene credenciales nuestras. Para volver a la base pelada:
#   BYTE_IMAGE=runpod/base:1.1.0-ubuntu2404 ./byte-stream.sh up
IMAGE = os.environ.get("BYTE_IMAGE") or "ghcr.io/filippello/byte-streamer:latest"
def try_create(gpu, cloud):
    body = {"name":"byte-streamer","imageName":IMAGE,
            "gpuTypeIds":[gpu],"gpuCount":1,"containerDiskInGb":25,"volumeInGb":0,
            "ports":["22/tcp"],"cloudType":cloud,
            "env":{"PUBLIC_KEY":PUB,"NVIDIA_DRIVER_CAPABILITIES":"all","NVIDIA_VISIBLE_DEVICES":"all"}}
    p = subprocess.run(["curl","-s","--max-time","90","-X","POST",
        "-H",f"Authorization: Bearer {KEY}","-H","Content-Type: application/json",
        "-d",json.dumps(body),"https://rest.runpod.io/v1/pods"],capture_output=True,text=True)
    try: return json.loads(p.stdout)
    except Exception: return {"error":p.stdout[:200]}
# BYTE_CLOUD: forzar un solo tipo de nube. COMMUNITY es mas barato pero son
# maquinas de terceros: el host puede aceptar el alquiler y no provisionar nunca
# (pod RUNNING, runtime null, podHostId null). SECURE son datacenters de RunPod.
CLOUDS = tuple(x for x in os.environ.get("BYTE_CLOUD","").split("|") if x) or ("COMMUNITY","SECURE")
for cloud in CLOUDS:
    for gpu in CANDS:
        r = try_create(gpu, cloud)
        if r.get("id"):
            print(f"imagen: {IMAGE}")
            print(f"OK -> {gpu} / {cloud} / pod {r['id']}"); sys.exit(0)
        print(f"no  {cloud:<9} {gpu:<34} {str(r.get('error',''))[:50]}")
print("NINGUNA DISPONIBLE"); sys.exit(1)
