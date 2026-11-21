package com.buildlens.glasses;

import android.accessibilityservice.AccessibilityService;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;

/**
 * Keeps BuildLens available without a cable. The M6's power manager does not let sideloaded
 * apps start at power-on (the boot broadcast never arrives), but Android itself reconnects an
 * accessibility service that has been turned on, after every power-on. This one only starts
 * the phone link (LinkService). It is turned on once over USB by setup.sh or the Mac app
 * (the method MicroLumin's glasses app template uses). It reads nothing on screen.
 */
public class OpenService extends AccessibilityService {
    /** While connected: screens are opened from here, which the glasses allow from the
     *  background (a plain service may be stopped from opening one while unplugged). */
    static volatile OpenService instance;

    @Override
    public void onDestroy() {
        instance = null;
        super.onDestroy();
    }

    @Override
    protected void onServiceConnected() {
        instance = this;
        Log.i(LinkService.TAG, "open service: starting the link");
        LinkService.start(this);
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {}
    @Override public void onInterrupt() {}
}
