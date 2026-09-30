import re
import json
from datetime import datetime, timezone

html = open('/tmp/eltoque_telegram.html', encoding='utf-8', errors='ignore').read()

# Quitamos las etiquetas HTML y dejamos texto plano y espacios simples.
text = re.sub(r'<[^>]+>', ' ', html)
text = re.sub(r'\s+', ' ', text)

# El canal de El Toque publica mensajes como:
#   "Actualización de tasas de mercado informal de divisas en Cuba
#    Fecha: 02/08/2026
#    USD: 675.00 CUP
#    MLC: 467.00 CUP"
# Los mensajes van de más viejo a más nuevo, así que nos quedamos
# con la ÚLTIMA coincidencia de cada una (la más reciente).
def find_rate(code):
    matches = re.findall(code + r':\s*([0-9]+(?:[.,][0-9]+)?)\s*CUP', text)
    return float(matches[-1].replace(',', '.')) if matches else None

usd = find_rate('USD')
mlc = find_rate('MLC')

if not usd:
    print("No se encontró ninguna tasa de USD en el canal de Telegram. Fragmento final analizado:")
    print(text[-1500:])
    raise SystemExit(1)

out = {
    "usd": usd,
    "mlc": mlc,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
json.dump(out, open('rates.json', 'w'), indent=2)
print("Guardado:", out)
