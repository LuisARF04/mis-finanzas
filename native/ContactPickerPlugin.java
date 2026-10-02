package com.misfinanzas.cup;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.provider.ContactsContract;
import android.util.Base64;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/**
 * Selector de contactos de Wallet.
 *
 * Abre la lista de contactos del teléfono, deja elegir UN número y devuelve
 * nombre, número y foto (JPEG cuadrado de 256 px en base64).
 * Solo pide permiso de LECTURA de contactos; no puede modificar nada.
 */
@CapacitorPlugin(
    name = "ContactPicker",
    permissions = {
        @Permission(strings = { Manifest.permission.READ_CONTACTS }, alias = "contacts")
    }
)
public class ContactPickerPlugin extends Plugin {

    @PluginMethod
    public void pick(PluginCall call) {
        if (getPermissionState("contacts") != PermissionState.GRANTED) {
            requestPermissionForAlias("contacts", call, "permissionResult");
            return;
        }
        openPicker(call);
    }

    @PermissionCallback
    private void permissionResult(PluginCall call) {
        if (getPermissionState("contacts") == PermissionState.GRANTED) {
            openPicker(call);
        } else {
            call.reject("permission_denied");
        }
    }

    private void openPicker(PluginCall call) {
        try {
            Intent intent = new Intent(Intent.ACTION_PICK, ContactsContract.CommonDataKinds.Phone.CONTENT_URI);
            startActivityForResult(call, intent, "pickResult");
        } catch (Exception e) {
            call.reject("picker_unavailable");
        }
    }

    @ActivityCallback
    private void pickResult(PluginCall call, ActivityResult result) {
        if (call == null) {
            return;
        }
        if (result == null || result.getResultCode() != Activity.RESULT_OK || result.getData() == null) {
            call.reject("cancelled");
            return;
        }
        Uri uri = result.getData().getData();
        if (uri == null) {
            call.reject("cancelled");
            return;
        }
        Cursor cursor = null;
        try {
            ContentResolver resolver = getContext().getContentResolver();
            String[] projection = new String[] {
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID
            };
            cursor = resolver.query(uri, projection, null, null, null);
            if (cursor == null || !cursor.moveToFirst()) {
                call.reject("not_found");
                return;
            }
            String name = cursor.getString(0);
            String number = cursor.getString(1);
            long contactId = cursor.getLong(2);

            JSObject ret = new JSObject();
            ret.put("name", name == null ? "" : name);
            ret.put("phone", number == null ? "" : number);
            ret.put("photo", readPhoto(resolver, contactId));
            call.resolve(ret);
        } catch (Exception e) {
            call.reject("read_error");
        } finally {
            if (cursor != null) {
                cursor.close();
            }
        }
    }

    // Foto del contacto como JPEG cuadrado de 256 px en base64 ("" si no tiene foto)
    private String readPhoto(ContentResolver resolver, long contactId) {
        InputStream in = null;
        try {
            Uri contactUri = ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, contactId);
            in = ContactsContract.Contacts.openContactPhotoInputStream(resolver, contactUri, true);
            if (in == null) {
                return "";
            }
            Bitmap bmp = BitmapFactory.decodeStream(in);
            if (bmp == null) {
                return "";
            }
            int side = Math.min(bmp.getWidth(), bmp.getHeight());
            int x = (bmp.getWidth() - side) / 2;
            int y = (bmp.getHeight() - side) / 2;
            Bitmap square = Bitmap.createBitmap(bmp, x, y, side, side);
            Bitmap scaled = Bitmap.createScaledBitmap(square, 256, 256, true);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, out);
            return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
        } catch (Exception e) {
            return "";
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (Exception ignored) {
                    // nada que hacer
                }
            }
        }
    }
}
