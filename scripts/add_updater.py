"""Agrega al AndroidManifest.xml lo que necesita el actualizador interno:
el permiso para pedir instalar paquetes y el FileProvider del APK descargado."""
import sys

path = sys.argv[1]
s = open(path, encoding='utf-8').read()

perm = '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />'
if 'REQUEST_INSTALL_PACKAGES' not in s:
    s = s.replace('</manifest>', '    ' + perm + '\n</manifest>', 1)

provider = '''        <provider
            android:name="com.misfinanzas.cup.UpdateFileProvider"
            android:authorities="${applicationId}.updates"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/update_paths" />
        </provider>
'''
if 'UpdateFileProvider' not in s:
    if '</application>' not in s:
        sys.exit('No encontré </application> en el manifiesto')
    s = s.replace('</application>', provider + '    </application>', 1)

open(path, 'w', encoding='utf-8').write(s)
print('Manifiesto listo para el actualizador interno')
