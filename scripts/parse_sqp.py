import re
import json
import os
from datetime import datetime, timezone

html = open('/tmp/telegram.html', encoding='utf-8', errors='ignore').read()

# Quitamos las etiquetas HTML y dejamos texto plano y espacios simples.
text = re.sub(r'<[^>]+>', ' ', html)
text = re.sub(r'\s+', ' ', text)

# El canal de QvaPay publica mensajes como:
#   "Tasas P2P — QvaPay ... CUP: 975.90 x USD ..."
# Los mensajes van de más viejo a más nuevo, así que nos quedamos
# con la ÚLTIMA coincidencia (la más reciente).
matches = re.findall(r'CUP:\s*([0-9]+(?:[.,][0-9]+)?)\s*x\s*USD', text)
if not matches:
    print("No se encontró ninguna tasa CUP x USD en el canal de Telegram. Fragmento final analizado:")
    print(text[-1500:])
    raise SystemExit(1)

sqp = float(matches[-1].replace(',', '.'))

# Se actualiza solo la clave "sqp" dentro de rates.json, conservando
# lo que ya haya puesto ahí el paso de El Toque (usd, mlc).
out = {}
if os.path.exists('rates.json'):
    out = json.load(open('rates.json'))
out['sqp'] = sqp
out['sqp_updated_at'] = datetime.now(timezone.utc).isoformat()
json.dump(out, open('rates.json', 'w'), indent=2)
print("Guardado sqp:", sqp, "->", out)
