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
import android.os.PowerManager;
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
        /** The phone or Mac scanned the set's box ("box": true): no need to scan it here. */
        void onBoxScanned();
        /** The phone's settings: fade the pieces already built; the voice's file prefix; read aloud. */
        void onSettings(boolean fade, String voice, boolean aloud);
        /** The model was turned or zoomed on the phone (or Mac): "spin" degrees, "zoom" (or -1),
         *  "tilt" degrees seen from above (NaN: not sent, e.g. turned in AR). */
        void onRemoteView(float spin, float zoom, float tilt);
        /** The phone is at its box scan: the glasses go back to theirs. */
        void onPhoneAtStart();
        /** The phone closed the finished build: back to the start page. */
        void onEnd();
        /** The phone closed its code with its X: start the build without scanning it. */
        void onScanSkipped();
    }

    /** A skip that came while the screen was away. */
    static volatile boolean skipWaiting, endWaiting, startWaiting;

    static volatile int step = 0;
    static volatile boolean finished = false;
    /** The side to show the step from when the phone was turned by hand; -1 = the step's own. */
    static volatile int view = -1;
    /** The phone is showing its "good job" card for this step; the next step follows. */
    static volatile boolean milestone = false;
    /** The phone's settings as last heard (or as last set in the glasses' menu), and a "box"
     *  that came while the screen was not in front: the screen takes them up when it is. */
    static volatile boolean haveSettings, settingsFade, settingsAloud, boxWaiting;
    static volatile String settingsVoice = "";
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
        return s != null && (!s.clients.isEmpty() || (s.ble != null && s.ble.linked()));
    }

    /** True while the glasses are scanning for the phone's code: every message then asks the
     *  phone to show it ("scan": true), so nobody has to open it by hand. */
    static volatile boolean scanning;

    /** The glasses have placed the build (the tag is scanned): the phone can leave its code. */
    static void announcePlaced() {
        LinkService s = instance;
        if (s == null) return;
        String m = "{\"step\":" + step + ",\"finished\":" + finished + ",\"placed\":true,\"hello\":true}\n";
        s.toAll(m);
    }

    /** A setting was changed on the glasses: the phone (through the Mac) changes it too. */
    static void sendSettings(boolean fade, String voice, boolean aloud) {
        LinkService s = instance;
        if (s == null) return;
        String m = "{\"step\":" + step + ",\"finished\":" + finished + ",\"fade\":" + fade + ",\"voice\":\"" + voice
                + "\",\"aloud\":" + aloud + ",\"hello\":true}\n";
        s.toAll(m);
    }

    /** Tells the phone and Mac how the model is turned and zoomed here. */
    static void sendView(float spin, float zoom, float tilt) {
        LinkService s = instance;
        if (s == null) return;
        String m = String.format(java.util.Locale.US, "{\"step\":%d,\"finished\":%b,\"spin\":%.1f,\"zoom\":%.3f,\"tilt\":%.1f}\n",
                step, finished, spin, zoom, tilt);
        s.toAll(m);
    }

    /** Tells the phone and Mac the set's box is done (so their own box scan moves on). */
    static void announceBox() {
        LinkService s = instance;
        if (s == null) return;
        String m = "{\"step\":" + step + ",\"finished\":" + finished + ",\"box\":true,\"hello\":true}\n";
        s.toAll(m);
    }

    /** Starts or stops asking the phone to show its code (Table marker). */
    static void askForMarker(boolean ask) {
        scanning = ask;
        if (ask) send(false);
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
        startBluetooth();
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
                    // Say where we are. While its instructions are open the phone leads and
                    // ignores this; when they are closed it just remembers the place, so
                    // opening them picks up where the glasses are.
                    sendTo(s, "{\"step\":" + step + ",\"finished\":" + finished + ",\"hello\":true"
                            + (scanning ? ",\"scan\":true" : "") + "}\n");
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
            while ((line = r.readLine()) != null) handle(line);
        } catch (Exception e) {
            Log.i(TAG, "client gone: " + e);
        } finally {
            clients.remove(s);
            try { s.close(); } catch (Exception ignored) {}
            if (clients.isEmpty()) holdMulticast(true);
            notifyLink();
        }
    }

    // ------------------------------------------------------------ Bluetooth
    private volatile BleLink ble;

    private void startBluetooth() {
        main.post(() -> {
            ble = new BleLink(this, new BleLink.Lines() {
                @Override public void onLine(String line) {
                    try { handle(line); } catch (Exception e) { Log.w(TAG, "bluetooth line: " + e); }
                }
                @Override public void onPhoneChanged() { notifyLink(); }
                @Override public void onPhoneReady(android.bluetooth.BluetoothDevice phone) {
                    // The same greeting as over TCP.
                    String hello = "{\"step\":" + step + ",\"finished\":" + finished + ",\"hello\":true"
                            + (scanning ? ",\"scan\":true" : "") + "}\n";
                    BleLink b = ble;
                    if (b != null) sender.execute(() -> b.send(hello));
                }
            });
            ble.start();
            // The glasses' own phone-connect service turns Bluetooth off and on now and then,
            // which drops this app's Bluetooth service: put it back whenever Bluetooth comes
            // on, and check now and then that it is still being advertised.
            registerReceiver(new android.content.BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    int state = i.getIntExtra(android.bluetooth.BluetoothAdapter.EXTRA_STATE, -1);
                    Log.i(TAG, "bluetooth: adapter state " + state);
                    if (state == android.bluetooth.BluetoothAdapter.STATE_ON) restartBluetooth();
                    else if (state == android.bluetooth.BluetoothAdapter.STATE_OFF) { BleLink b = ble; if (b != null) b.stop(); }
                }
            }, new android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED));
            main.postDelayed(bluetoothCheck, 20_000);
            // A cable plugged in (the phone's USB-C): open the app on the glasses.
            android.content.IntentFilter plug = new android.content.IntentFilter(Intent.ACTION_POWER_CONNECTED);
            plug.addAction("android.hardware.usb.action.USB_STATE");
            registerReceiver(new android.content.BroadcastReceiver() {
                private boolean wasUsb;
                @Override public void onReceive(Context c, Intent i) {
                    boolean usb = i.getBooleanExtra("connected", false);
                    if (Intent.ACTION_POWER_CONNECTED.equals(i.getAction())) {
                        Log.i(TAG, "cable: power connected");
                    } else {
                        boolean plugged = usb && !wasUsb;
                        wasUsb = usb;
                        if (!plugged) return;
                        Log.i(TAG, "cable: usb connected");
                    }
                    if (isInitialStickyBroadcast()) return;
                    main.post(() -> { if (listener == null) deliver(false); });
                }
            }, plug);
        });
    }

    /** A small camera picture for phones taking them over Bluetooth (they pass it to the Mac). */
    static boolean picturesWanted() {
        LinkService s = instance;
        BleLink b = s == null ? null : s.ble;
        return b != null && b.wantsPictures();
    }

    static void sendPicture(byte[] framed) {
        LinkService s = instance;
        BleLink b = s == null ? null : s.ble;
        if (b != null) s.sender.execute(() -> b.sendPicture(framed));
    }

    private void restartBluetooth() {
        BleLink b = ble;
        if (b == null) return;
        b.stop();
        main.postDelayed(b::start, 500);
        notifyLink();
    }

    private final Runnable bluetoothCheck = new Runnable() {
        @Override public void run() {
            BleLink b = ble;
            if (b != null && !b.advertising && !b.linked()) {
                Log.i(TAG, "bluetooth: not advertising, starting again");
                restartBluetooth();
            }
            main.postDelayed(this, 20_000);
        }
    };

    /** One line from the phone or Mac, by any link. */
    private void handle(String line) throws Exception {
        JSONObject msg = new JSONObject(line);
        // "wake": the phone app has just linked; bring BuildLens up on the glasses.
        if (msg.optBoolean("wake", false)) {
            final boolean atStart = msg.optBoolean("start", false);
            main.post(() -> {
                if (atStart) { Listener l = listener; if (l != null) l.onPhoneAtStart(); else startWaiting = true; }
                if (listener == null) deliver(false);
            });
            if (!msg.has("step")) return;
        }
        if (msg.optBoolean("end", false)) {
            main.post(() -> {
                step = 0; finished = false; milestone = false; view = -1;
                Listener l = listener; if (l != null) l.onEnd(); else endWaiting = true;
            });
            return;
        }
        if (msg.optBoolean("noscan", false)) {
            main.post(() -> { Listener l = listener; if (l != null) l.onScanSkipped(); else skipWaiting = true; });
            if (!msg.has("step")) return;
        }
        if (msg.optBoolean("box", false)) {
            main.post(() -> { Listener l = listener; if (l != null) l.onBoxScanned(); else boxWaiting = true; });
        }
        if (msg.has("fade")) {
            final boolean fade = msg.optBoolean("fade", false);
            final String voice = msg.optString("voice", "");
            final boolean aloud = msg.optBoolean("aloud", false);
            settingsFade = fade; settingsVoice = voice; settingsAloud = aloud; haveSettings = true;
            main.post(() -> { Listener l = listener; if (l != null) l.onSettings(fade, voice, aloud); });
            if (!msg.has("step")) return;
        }
        if (msg.has("spin")) {
            final float spin = (float) msg.optDouble("spin", 0), zoom = (float) msg.optDouble("zoom", -1);
            final float tilt = (float) msg.optDouble("tilt", Double.NaN);
            main.post(() -> { Listener l = listener; if (l != null) l.onRemoteView(spin, zoom, tilt); });
            return;
        }
        if (!msg.has("step")) return;
        final int n = msg.getInt("step");
        final boolean done = msg.optBoolean("finished", false);
        final boolean replay = msg.optBoolean("replay", false);
        // "open": the instructions are on screen on the phone, so ours should be too.
        final boolean open = msg.optBoolean("open", false);
        final int side = msg.optInt("view", -1);
        final boolean celebrate = msg.optBoolean("milestone", false);
        main.post(() -> {
            boolean changed = n != step || done != finished || side != view || celebrate != milestone;
            step = n;
            finished = done;
            view = side;
            milestone = celebrate;
            if (changed || replay || (open && listener == null)) deliver(replay);
        });
    }

    /** Shows the step: on the screen if it is up, otherwise by bringing the screen up. */
    @SuppressWarnings("deprecation")
    private void deliver(boolean replay) {
        // If the display has gone to sleep, wake it for the new step.
        try {
            PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
            if (power != null && !power.isInteractive()) {
                power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP, "buildlens:step")
                        .acquire(3000);
            }
        } catch (Exception e) {
            Log.w(TAG, "wake: " + e);
        }
        Listener l = listener;
        if (l != null) {
            l.onRemoteStep(replay);
        } else {
            // From the accessibility service when it is on (as MicroLumin's template opens its
            // app): the glasses let it open a screen from the background.
            Context from = OpenService.instance != null ? OpenService.instance : this;
            Log.i(TAG, "opening the screen (" + (from == this ? "link" : "open service") + ")");
            try {
                from.startActivity(new Intent(this, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP));
            } catch (Exception e) {
                Log.w(TAG, "open screen: " + e);
            }
        }
    }

    private void notifyLink() {
        main.post(() -> {
            Listener l = listener;
            if (l != null) l.onLinkChanged();
        });
    }

    private static String message(boolean replay) {
        return "{\"step\":" + step + ",\"finished\":" + finished + (replay ? ",\"replay\":true" : "")
                + (scanning ? ",\"scan\":true" : "") + "}\n";
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
        toAll(message(replay));
    }

    /** One line to every phone and Mac: over Wi-Fi or USB (TCP) and over Bluetooth. */
    private void toAll(String m) {
        for (Socket c : clients) sendTo(c, m);
        BleLink b = ble;
        if (b != null) sender.execute(() -> b.send(m));
    }

    @Override
    public void onDestroy() {
        try { if (nsd != null && nsdListener != null) nsd.unregisterService(nsdListener); } catch (Exception ignored) {}
        try { if (server != null) server.close(); } catch (Exception ignored) {}
        if (ble != null) ble.stop();
        for (Socket s : clients) try { s.close(); } catch (Exception ignored) {}
        sender.shutdown();
        holdMulticast(false);
        instance = null;
        super.onDestroy();
    }
}
