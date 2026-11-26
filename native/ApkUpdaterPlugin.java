package com.misfinanzas.cup;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.UnknownHostException;
import javax.net.ssl.SSLException;

/**
 * Descarga la actualización (APK) dentro de la app y abre el instalador de
 * Android, sin pasar por el navegador.
 *
 * JS: Capacitor.Plugins.ApkUpdater
 *   download({url})   -> descarga a la caché; emite eventos "progress" {percent, bytes, total}
 *   install()         -> abre el instalador; si falta el permiso de "instalar apps
 *                        desconocidas" abre esa pantalla de Ajustes y devuelve {needsPermission:true}
 *   canInstall()      -> {allowed}
 */
@CapacitorPlugin(name = "ApkUpdater")
public class ApkUpdaterPlugin extends Plugin {

    private volatile boolean busy = false;

    private File updatesDir() {
        return new File(getContext().getCacheDir(), "updates");
    }

    @PluginMethod
    public void download(final PluginCall call) {
        final String url = call.getString("url");
        if (url == null || url.isEmpty()) {
            call.reject("Falta la dirección de descarga");
            return;
        }
        if (busy) {
            call.reject("Ya hay una descarga en curso");
            return;
        }
        busy = true;
        new Thread(() -> {
            HttpURLConnection conn = null;
            File dir = updatesDir();
            File part = new File(dir, "update.apk.part");
            File done = new File(dir, "update.apk");
            try {
                if (!dir.exists() && !dir.mkdirs()) throw new IOException("No se pudo preparar la carpeta de descarga");
                URL u = new URL(url);
                boolean ok = false;
                // GitHub redirige a otro servidor: seguimos las redirecciones a mano
                for (int i = 0; i < 8; i++) {
                    conn = (HttpURLConnection) u.openConnection();
                    conn.setInstanceFollowRedirects(false);
                    conn.setConnectTimeout(20000);
                    conn.setReadTimeout(30000);
                    conn.setRequestProperty("User-Agent", "Wallet-Android");
                    conn.setRequestProperty("Accept", "application/octet-stream");
                    int code = conn.getResponseCode();
                    if (code >= 300 && code < 400) {
                        String loc = conn.getHeaderField("Location");
                        conn.disconnect();
                        conn = null;
                        if (loc == null) throw new IOException("El servidor no indicó a dónde ir");
                        u = new URL(u, loc);
                        continue;
                    }
                    if (code != 200) throw new IOException("El servidor respondió con error " + code);
                    ok = true;
                    break;
                }
                if (!ok || conn == null) throw new IOException("Demasiadas redirecciones");

                long total = conn.getContentLengthLong();
                long bytes = 0;
                int lastPct = -2;
                long lastT = 0;
                try (InputStream in = new BufferedInputStream(conn.getInputStream());
                     OutputStream out = new FileOutputStream(part)) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        out.write(buf, 0, n);
                        bytes += n;
                        int pct = total > 0 ? (int) (bytes * 100 / total) : -1;
                        long now = System.currentTimeMillis();
                        if (pct != lastPct && (now - lastT > 120 || pct == 100)) {
                            lastPct = pct;
                            lastT = now;
                            JSObject ev = new JSObject();
                            ev.put("percent", pct);
                            ev.put("bytes", bytes);
                            ev.put("total", total);
                            notifyListeners("progress", ev);
                        }
                    }
                }
                if (total > 0 && part.length() != total) throw new IOException("La descarga quedó incompleta");
                if (done.exists() && !done.delete()) throw new IOException("No se pudo reemplazar la descarga anterior");
                if (!part.renameTo(done)) throw new IOException("No se pudo guardar el archivo");

                JSObject res = new JSObject();
                res.put("bytes", done.length());
                call.resolve(res);
            } catch (UnknownHostException e) {
                part.delete();
                call.reject("Sin conexión a internet o no se encuentra el servidor de descargas");
            } catch (SocketTimeoutException e) {
                part.delete();
                call.reject("La conexión tardó demasiado. Inténtalo de nuevo");
            } catch (SSLException e) {
                part.delete();
                call.reject("No se pudo establecer una conexión segura con el servidor");
            } catch (Exception e) {
                part.delete();
                String m = e.getMessage();
                call.reject(m != null && !m.isEmpty() ? m : "No se pudo descargar la actualización");
            } finally {
                if (conn != null) conn.disconnect();
                busy = false;
            }
        }).start();
    }

    private boolean allowedToInstall() {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O
            || getContext().getPackageManager().canRequestPackageInstalls();
    }

    @PluginMethod
    public void canInstall(PluginCall call) {
        JSObject res = new JSObject();
        res.put("allowed", allowedToInstall());
        call.resolve(res);
    }

    @PluginMethod
    public void install(PluginCall call) {
        File apk = new File(updatesDir(), "update.apk");
        if (!apk.exists()) {
            call.reject("Primero descarga la actualización");
            return;
        }
        JSObject res = new JSObject();
        try {
            if (!allowedToInstall()) {
                Intent s = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getContext().getPackageName()));
                s.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getContext().startActivity(s);
                res.put("needsPermission", true);
                call.resolve(res);
                return;
            }
            Uri uri = FileProvider.getUriForFile(getContext(),
                getContext().getPackageName() + ".updates", apk);
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
            res.put("needsPermission", false);
            call.resolve(res);
        } catch (Exception e) {
            String m = e.getMessage();
            call.reject("No se pudo abrir el instalador" + (m != null ? ": " + m : ""));
        }
    }
}
