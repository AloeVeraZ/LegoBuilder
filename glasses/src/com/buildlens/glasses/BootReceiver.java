package com.buildlens.glasses;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the phone link when the glasses are switched on, so there is nothing to open. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) LinkService.start(context);
    }
}
