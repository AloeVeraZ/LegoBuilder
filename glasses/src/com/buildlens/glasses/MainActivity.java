package com.buildlens.glasses;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * BuildLens on the MicroLumin M6 glasses (Android 9, 640x480, black = see-through).
 *
 * Shows the current building step: a green line-art frame of the model with the new pieces
 * filled in, the step number and the pieces to add. Next / back with the temple touchpad,
 * the ring, swipes or taps. Follows the iPhone app over Wi-Fi: it runs a small TCP server
 * (newline-separated JSON, {"step": N}) and advertises it as _buildlens-glass._tcp so the
 * phone finds it automatically. Steps changed here are sent back to the phone.
 */
public class MainActivity extends Activity {
    static final String TAG = "BuildLens";
    static final int PORT = 52733;
    static final int GREEN = Color.rgb(92, 255, 128);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Socket> clients = new CopyOnWriteArrayList<>();
    private JSONArray steps;
    private String setName = "";
    private int step = 0;
    private boolean finished = false;

    private ImageView frame;
    private TextView header, sub, parts, status;
    private ServerSocket server;
    private NsdManager nsd;
    private NsdManager.RegistrationListener nsdListener;
    private WifiManager.MulticastLock multicastLock;
    private GestureDetector gestures;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        loadSteps();
        buildUi();
        gestures = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onSingleTapUp(MotionEvent e) { next(true); return true; }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                if (Math.abs(vx) > Math.abs(vy)) { if (vx < 0) next(true); else back(true); }
                else { if (vy < 0) next(true); else back(true); }
                return true;
            }
        });
        show();
        startServer();
    }

    // ------------------------------------------------------------ data
    private void loadSteps() {
        try (InputStream in = getAssets().open("steps.json")) {
            byte[] buf = new byte[in.available()];
            int n = 0, r;
            while (n < buf.length && (r = in.read(buf, n, buf.length - n)) > 0) n += r;
            JSONObject root = new JSONObject(new String(buf, 0, n, StandardCharsets.UTF_8));
            steps = root.getJSONArray("steps");
            setName = root.optString("name");
        } catch (Exception e) {
            Log.e(TAG, "steps.json", e);
            steps = new JSONArray();
        }
    }

    // ------------------------------------------------------------ UI
    private TextView label(int sizeSp, boolean bold) {
        TextView t = new TextView(this);
        t.setTextColor(GREEN);
        t.setTextSize(sizeSp);
        t.setTypeface(Typeface.MONOSPACE, bold ? Typeface.BOLD : Typeface.NORMAL);
        t.setShadowLayer(2, 0, 0, Color.BLACK);
        return t;
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        frame = new ImageView(this);
        frame.setScaleType(ImageView.ScaleType.FIT_CENTER);
        root.addView(frame, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout overlay = new LinearLayout(this);
        overlay.setOrientation(LinearLayout.VERTICAL);
        overlay.setPadding(18, 14, 18, 14);
        header = label(22, true);
        sub = label(13, true);
        parts = label(13, false);
        status = label(10, false);
        status.setAlpha(0.7f);
        View spacer = new View(this);
        overlay.addView(header);
        overlay.addView(sub);
        overlay.addView(spacer, new LinearLayout.LayoutParams(-1, 0, 1f));
        overlay.addView(parts);
        overlay.addView(status);
        root.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        root.setOnTouchListener((v, e) -> gestures.onTouchEvent(e));
        setContentView(root);
    }

    private void show() {
        int count = steps.length();
        if (count == 0) { header.setText("NO STEPS"); return; }
        step = Math.max(0, Math.min(step, count - 1));
        try {
            if (finished) {
                header.setText("DONE ✓");
                sub.setText(setName.toUpperCase());
                parts.setText("");
                frame.setImageBitmap(null);
            } else {
                JSONObject s = steps.getJSONObject(step);
                header.setText("STEP " + (step + 1) + "/" + count);
                sub.setText(s.optString("sub"));
                JSONArray lines = s.getJSONArray("parts");
                StringBuilder b = new StringBuilder();
                for (int i = 0; i < lines.length() && i < 4; i++) b.append(lines.getString(i)).append('\n');
                if (lines.length() > 4) b.append("+").append(lines.length() - 4).append(" MORE\n");
                parts.setText(b.toString().trim());
                try (InputStream in = getAssets().open(s.getString("frame"))) {
                    Bitmap bmp = BitmapFactory.decodeStream(in);
                    frame.setImageBitmap(bmp);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "show", e);
        }
        status.setText(clients.isEmpty() ? "phone: not linked" : "phone: linked");
    }

    private void next(boolean fromHere) {
        if (finished) return;
        if (step + 1 < steps.length()) step++; else finished = true;
        show();
        if (fromHere) broadcast();
    }

    private void back(boolean fromHere) {
        if (finished) finished = false; else if (step > 0) step--;
        show();
        if (fromHere) broadcast();
    }

    // Temple touchpad and ring arrive as key events. Every code is logged so unknown buttons
    // can be mapped: adb logcat -s BuildLens
    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        Log.i(TAG, "key down " + code + " " + KeyEvent.keyCodeToString(code));
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_RIGHT: case KeyEvent.KEYCODE_DPAD_DOWN: case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_DPAD_CENTER: case KeyEvent.KEYCODE_PAGE_DOWN: case KeyEvent.KEYCODE_MEDIA_NEXT:
            case KeyEvent.KEYCODE_SPACE: case KeyEvent.KEYCODE_TAB: case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                next(true); return true;
            case KeyEvent.KEYCODE_DPAD_LEFT: case KeyEvent.KEYCODE_DPAD_UP: case KeyEvent.KEYCODE_PAGE_UP:
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS: case KeyEvent.KEYCODE_DEL:
                back(true); return true;
            default:
                return super.onKeyDown(code, e);
        }
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent e) {
        return gestures.onTouchEvent(e) || super.onGenericMotionEvent(e);
    }

    // ------------------------------------------------------------ phone link
    private void startServer() {
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("buildlens");
            multicastLock.setReferenceCounted(false);
            multicastLock.acquire();
        }
        new Thread(() -> {
            try {
                server = new ServerSocket(PORT);
                main.post(this::advertise);
                while (!server.isClosed()) {
                    Socket s = server.accept();
                    s.setTcpNoDelay(true);
                    clients.add(s);
                    main.post(() -> { show(); sendTo(s); });
                    new Thread(() -> readLoop(s), "client").start();
                }
            } catch (Exception e) {
                Log.w(TAG, "server stopped: " + e);
            }
        }, "server").start();
    }

    private void advertise() {
        try {
            NsdServiceInfo info = new NsdServiceInfo();
            info.setServiceName("BuildLens Glasses");
            info.setServiceType("_buildlens-glass._tcp");
            info.setPort(PORT);
            nsd = (NsdManager) getSystemService(NSD_SERVICE);
            nsdListener = new NsdManager.RegistrationListener() {
                @Override public void onServiceRegistered(NsdServiceInfo i) { Log.i(TAG, "advertised " + i.getServiceName()); }
                @Override public void onRegistrationFailed(NsdServiceInfo i, int err) { Log.w(TAG, "advertise failed " + err); }
                @Override public void onServiceUnregistered(NsdServiceInfo i) {}
                @Override public void onUnregistrationFailed(NsdServiceInfo i, int err) {}
            };
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, nsdListener);
        } catch (Exception e) {
            Log.w(TAG, "nsd: " + e);
        }
    }

    private void readLoop(Socket s) {
        try (BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) {
                JSONObject msg = new JSONObject(line);
                if (msg.has("step")) {
                    int n = msg.getInt("step");
                    boolean done = msg.optBoolean("finished", false);
                    main.post(() -> { step = n; finished = done; show(); });
                }
            }
        } catch (Exception e) {
            Log.i(TAG, "client gone: " + e);
        } finally {
            clients.remove(s);
            try { s.close(); } catch (Exception ignored) {}
            main.post(this::show);
        }
    }

    private String message() {
        return "{\"step\":" + step + ",\"finished\":" + finished + "}\n";
    }

    private void sendTo(Socket s) {
        String m = message();
        new Thread(() -> {
            try {
                OutputStream o = s.getOutputStream();
                o.write(m.getBytes(StandardCharsets.UTF_8));
                o.flush();
            } catch (Exception e) {
                clients.remove(s);
            }
        }).start();
    }

    private void broadcast() {
        for (Socket s : clients) sendTo(s);
    }

    @Override
    protected void onDestroy() {
        try { if (nsd != null && nsdListener != null) nsd.unregisterService(nsdListener); } catch (Exception ignored) {}
        try { if (server != null) server.close(); } catch (Exception ignored) {}
        for (Socket s : clients) try { s.close(); } catch (Exception ignored) {}
        if (multicastLock != null) multicastLock.release();
        super.onDestroy();
    }
}
