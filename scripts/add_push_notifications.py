import re
import sys

# Agrega el complemento de Google Services a los dos archivos Gradle del
# proyecto, para que la app pueda leer google-services.json (Firebase).
# No hace nada si ya estaba agregado (se puede correr más de una vez).

project_gradle, app_gradle = sys.argv[1], sys.argv[2]

# ---- 1) android/build.gradle (nivel de proyecto): agrega la dependencia del plugin ----
s = open(project_gradle, encoding='utf-8').read()
CLASSPATH = "classpath 'com.google.gms:google-services:4.4.2'"

if CLASSPATH in s:
    print('build.gradle (proyecto): el plugin ya estaba agregado')
else:
    m = re.search(r'buildscript\s*\{.*?dependencies\s*\{', s, re.S)
    if not m:
        print('No se encontró buildscript { dependencies { en android/build.gradle', file=sys.stderr)
        sys.exit(1)
    pos = m.end()
    s = s[:pos] + f"\n        {CLASSPATH}" + s[pos:]
    open(project_gradle, 'w', encoding='utf-8').write(s)
    print('build.gradle (proyecto): plugin agregado')

# ---- 2) android/app/build.gradle (nivel de app): aplica el plugin al final ----
s = open(app_gradle, encoding='utf-8').read()
APPLY = "apply plugin: 'com.google.gms.google-services'"

if APPLY in s:
    print('build.gradle (app): el plugin ya estaba aplicado')
else:
    s = s.rstrip('\n') + f"\n{APPLY}\n"
    open(app_gradle, 'w', encoding='utf-8').write(s)
    print('build.gradle (app): plugin aplicado')
