import re
import json
from datetime import datetime, timezone
import sys

html = open('/tmp/page.html', encoding='utf-8', errors='ignore').read()

# Nos quedamos solo con la parte de la página que sigue a "Tiempo Real",
# que es donde empieza la tabla con los valores de hoy (así evitamos
# que alguna otra mención suelta de "USD" en el resto de la página confunda la búsqueda).
marker = html.find('Tiempo Real')
zone = html[marker:marker + 6000] if marker != -1 else html

# Quitamos las etiquetas HTML y dejamos texto plano y espacios simples,
# por ejemplo: "1 USD Dólar Estadounidense 750.00 CUP+5 1 EUR Euro 850.00 CUP+2.5 ..."
text = re.sub(r'<[^>]+>', ' ', zone)
text = re.sub(r'\s+', ' ', text)

def find_rate(code):
    m = re.search(r'1\s*' + code + r'.{0,80}?([0-9]+(?:[.,][0-9]+)?)\s*CUP', text)
    return float(m.group(1).replace(',', '.')) if m else None

usd = find_rate('USD')
mlc = find_rate('MLC')

if not usd:
    print("No se encontró la tasa de USD en la página. Fragmento analizado:", file=sys.stderr)
    print(text[:1000], file=sys.stderr)
    sys.exit(1)

out = {
    "usd": usd,
    "mlc": mlc,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
json.dump(out, open('rates.json', 'w'), indent=2)
print("Guardado:", out)
