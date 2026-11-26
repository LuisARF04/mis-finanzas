package com.misfinanzas.cup;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // Plugins propios de Wallet (código en la carpeta native/ del repo)
        registerPlugin(ContactPickerPlugin.class);  // selector de contactos
        registerPlugin(ApkUpdaterPlugin.class);     // descargar e instalar actualizaciones dentro de la app
        super.onCreate(savedInstanceState);
    }
}
