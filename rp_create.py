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

def chequear_ghcr(img):
    """Un pod que no puede bajar la imagen igual se alquila y igual se cobra.
    Mejor fallar ANTES de rentar nada."""
    if not img.startswith("ghcr.io/"):
        return
    repo, _, tag = img[len("ghcr.io/"):].partition(":")
    tok = subprocess.run(["curl","-s","--max-time","20",
        f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io"],
        capture_output=True, text=True).stdout
    try: tok = json.loads(tok).get("token","")
    except Exception: tok = ""
    code = subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}",
        "--max-time","20","-H",f"Authorization: Bearer {tok}",
        "-H","Accept: application/vnd.oci.image.index.v1+json,"
             "application/vnd.docker.distribution.manifest.list.v2+json",
        f"https://ghcr.io/v2/{repo}/manifests/{tag or 'latest'}"],
        capture_output=True, text=True).stdout.strip()
    if code != "200":
        print(f"la imagen {img} no se puede bajar sin credenciales (HTTP {code}).")
        print("RunPod no tiene login nuestro: hay que poner el paquete PUBLICO una")
        print(f"sola vez en https://github.com/users/{repo.split('/')[0]}/packages/container/{repo.split('/')[-1]}/settings")
        print("Mientras tanto se puede arrancar con la base pelada:")
        print("  BYTE_IMAGE=runpod/base:1.1.0-ubuntu2404 ./byte-stream.sh up")
        sys.exit(1)

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
chequear_ghcr(IMAGE)

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
