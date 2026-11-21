package com.buildlens.glasses;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The always-on half of BuildLens on the glasses: it waits for the phone, so the wearer
 * never has to start anything. It runs from boot, costs next to nothing while idle (one
 * thread asleep in accept()), and when the phone opens the instructions it brings the
 * display up by itself.
 *
 * Link: a TCP server advertised as _buildlens-glass._tcp. Messages are one JSON object per
 * line, the same in both directions: {"step": 4, "finished": false} and optionally
 * "replay": true to show the same step again from the start. The phone adds "open": true
 * while its instructions are on screen, which brings this display up if it is not.
 *
 * The current step lives here, not in the screen, so it survives the screen being closed
 * and the phone app quitting.
 */
public class LinkService extends Service {
    static final String TAG = "BuildLens";
    static final int PORT = 52733;

    /** The screen, while it is in front. Called on the main thread. */
    interface Listener {
        void onRemoteStep(boolean replay);
        void onLinkChanged();
    }

    static volatile int step = 0;
    static volatile boolean finished = false;
    private static volatile LinkService instance;
    private static volatile Listener listener;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Socket> clients = new CopyOnWriteArrayList<>();
    private final ExecutorService sender = Executors.newSingleThreadExecutor();
    private ServerSocket server;
    private NsdManager nsd;
    private NsdManager.RegistrationListener nsdListener;
    private WifiManager.MulticastLock multicastLock;

    static void start(Context context) {
        Intent intent = new Intent(context, LinkService.class);
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
        else context.startService(intent);
    }

    static void setListener(Listener l) { listener = l; }

    static boolean phoneLinked() {
        LinkService s = instance;
        return s != null && !s.clients.isEmpty();
    }

    /** Tells the phone what the glasses now show (after a click on the glasses). */
    static void send(boolean replay) {
        LinkService s = instance;
        if (s != null) s.broadcast(replay);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        startForeground(1, notification());
        startServer();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification notification() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel("link", "Phone link", NotificationManager.IMPORTANCE_MIN);
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(channel);
            builder = new Notification.Builder(this, "link");
        } else {
            builder = new Notification.Builder(this);
        }
        return builder.setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("BuildLens")
                .setContentText("Ready for the phone")
                .build();
    }

    // ------------------------------------------------------------ server
    private void startServer() {
        holdMulticast(true);
        new Thread(() -> {
            try {
                server = new ServerSocket(PORT);
                main.post(this::advertise);
                while (!server.isClosed()) {
                    final Socket s = server.accept();
                    s.setTcpNoDelay(true);
                    clients.add(s);
                    // Finding us is done, so the Wi-Fi radio can go back to filtering
                    // multicast, which saves power.
                    holdMulticast(false);
                    // A phone that joins mid-build picks up where the glasses are.
                    if (!finished) sendTo(s, message(false));
                    notifyLink();
                    new Thread(() -> readLoop(s), "client").start();
                }
            } catch (Exception e) {
                Log.w(TAG, "server stopped: " + e);
            }
        }, "server").start();
    }

    /** Needed on some devices for the phone to find us; not needed once it has. */
    private synchronized void holdMulticast(boolean hold) {
        try {
            if (multicastLock == null) {
                WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
                if (wifi == null) return;
                multicastLock = wifi.createMulticastLock("buildlens");
                multicastLock.setReferenceCounted(false);
            }
            if (hold) multicastLock.acquire(); else if (multicastLock.isHeld()) multicastLock.release();
        } catch (Exception e) {
            Log.w(TAG, "multicast lock: " + e);
        }
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
                if (!msg.has("step")) continue;
                final int n = msg.getInt("step");
                final boolean done = msg.optBoolean("finished", false);
                final boolean replay = msg.optBoolean("replay", false);
                // "open": the instructions are on screen on the phone, so ours should be too.
                final boolean open = msg.optBoolean("open", false);
                main.post(() -> {
                    boolean changed = n != step || done != finished;
                    step = n;
                    finished = done;
                    if (changed || replay || (open && listener == null)) deliver(replay);
                });
            }
        } catch (Exception e) {
            Log.i(TAG, "client gone: " + e);
        } finally {
            clients.remove(s);
            try { s.close(); } catch (Exception ignored) {}
            if (clients.isEmpty()) holdMulticast(true);
            notifyLink();
        }
    }

    /** Shows the step: on the screen if it is up, otherwise by bringing the screen up. */
    private void deliver(boolean replay) {
        Listener l = listener;
        if (l != null) {
            l.onRemoteStep(replay);
        } else {
            startActivity(new Intent(this, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP));
        }
    }

    private void notifyLink() {
        main.post(() -> {
            Listener l = listener;
            if (l != null) l.onLinkChanged();
        });
    }

    private static String message(boolean replay) {
        return "{\"step\":" + step + ",\"finished\":" + finished + (replay ? ",\"replay\":true" : "") + "}\n";
    }

    private void sendTo(final Socket s, final String m) {
        sender.execute(() -> {
            try {
                OutputStream o = s.getOutputStream();
                o.write(m.getBytes(StandardCharsets.UTF_8));
                o.flush();
            } catch (Exception e) {
                clients.remove(s);
            }
        });
    }

    private void broadcast(boolean replay) {
        String m = message(replay);
        for (Socket s : clients) sendTo(s, m);
    }

    @Override
    public void onDestroy() {
        try { if (nsd != null && nsdListener != null) nsd.unregisterService(nsdListener); } catch (Exception ignored) {}
        try { if (server != null) server.close(); } catch (Exception ignored) {}
        for (Socket s : clients) try { s.close(); } catch (Exception ignored) {}
        sender.shutdown();
        holdMulticast(false);
        instance = null;
        super.onDestroy();
    }
}
