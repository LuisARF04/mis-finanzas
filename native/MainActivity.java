package com.misfinanzas.cup;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // Registra el selector de contactos propio de Wallet
        registerPlugin(ContactPickerPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
