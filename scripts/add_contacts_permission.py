import sys

# Agrega SOLO el permiso de lectura de contactos al AndroidManifest.xml
# (necesario para el selector de contactos). No agrega permiso de escritura.
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
perm = '<uses-permission android:name="android.permission.READ_CONTACTS" />'

if 'android.permission.READ_CONTACTS' in s:
    print('El permiso ya estaba en el manifest')
    sys.exit(0)

internet = '<uses-permission android:name="android.permission.INTERNET" />'
if internet in s:
    s = s.replace(internet, internet + '\n    ' + perm, 1)
elif '</manifest>' in s:
    s = s.replace('</manifest>', '    ' + perm + '\n</manifest>', 1)
else:
    print('No se encontró dónde poner el permiso en el manifest')
    sys.exit(1)

open(path, 'w', encoding='utf-8').write(s)
print('Permiso READ_CONTACTS agregado')
