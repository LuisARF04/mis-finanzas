import re
import json
from datetime import datetime, timezone

html = open('/tmp/eltoque_telegram.html', encoding='utf-8', errors='ignore').read()

# Quitamos las etiquetas HTML y dejamos texto plano y espacios simples.
text = re.sub(r'<[^>]+>', ' ', html)
text = re.sub(r'\s+', ' ', text)

# El canal de El Toque publica mensajes como:
#   "Tasa representativa del mercado informal (elTOQUE)
#    EUR: 1030.00 CUP  USD: 975.00 CUP  MLC: 820.08 CUP
#    Hay ofertas en los rangos: USD: de 900.00 a 1060.00 CUP ..."
# Los mensajes van de más viejo a más nuevo, así que nos quedamos
# con la ÚLTIMA coincidencia de cada una (la más reciente).
def to_number(s):
    # "975.00", "975,00", "1,030.00" o "1.030,00"
    if ',' in s and '.' in s:
        s = s.replace(',', '') if s.rfind('.') > s.rfind(',') else s.replace('.', '').replace(',', '.')
    elif ',' in s:
        s = s.replace(',', '.') if len(s.split(',')[-1]) != 3 else s.replace(',', '')
    return float(s)

def find_rate(code):
    # "USD: 975.00 CUP" (los rangos "USD: de 900.00 a 1060.00 CUP" no coinciden)
    matches = re.findall(code + r':\s*([0-9][0-9.,]*[0-9])\s*CUP', text)
    return to_number(matches[-1]) if matches else None

usd = find_rate('USD')
mlc = find_rate('MLC')

if not usd:
    print("No se encontró ninguna tasa de USD en el canal de Telegram. Fragmento final analizado:")
    print(text[-1500:])
    raise SystemExit(1)

if not (50 <= usd <= 20000):
    print("La tasa de USD encontrada no parece real:", usd)
    raise SystemExit(1)

# Conserva lo que ya había (por ejemplo SQP, que lo guarda el otro paso)
try:
    out = json.load(open('rates.json'))
except Exception:
    out = {}
out.update({
    "usd": usd,
    "mlc": mlc if mlc else out.get("mlc"),
    "updated_at": datetime.now(timezone.utc).isoformat(),
})
json.dump(out, open('rates.json', 'w'), indent=2)
print("Guardado:", out)
