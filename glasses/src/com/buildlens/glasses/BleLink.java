package com.buildlens.glasses;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.content.Context;
import android.os.ParcelUuid;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The phone link over Bluetooth Low Energy, for when there is no Wi-Fi and no Mac: the phone
 * finds the glasses by this service, with no pairing. The same lines as over TCP (one JSON
 * object per line) go both ways: the phone writes them to RX, and the glasses send theirs as
 * notifications on TX, cut to the link's packet size (a line may span several; the newline
 * ends it).
 */
final class BleLink {
    static final UUID SERVICE = UUID.fromString("6b1d0001-6c6f-4a7e-9b5a-42756c644c6e");
    static final UUID RX = UUID.fromString("6b1d0002-6c6f-4a7e-9b5a-42756c644c6e");   // phone -> glasses
    static final UUID TX = UUID.fromString("6b1d0003-6c6f-4a7e-9b5a-42756c644c6e");   // glasses -> phone
    /** The camera's picture, small, for the phone to pass on to the Mac: each one is its
     *  length (4 bytes, big-endian), then a JSON line (LiveFeed's header), then the JPEG. */
    static final UUID FEED = UUID.fromString("6b1d0004-6c6f-4a7e-9b5a-42756c644c6e");
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final String TAG = LinkService.TAG;

    interface Lines {
        void onLine(String line);
        void onPhoneChanged();
        /** A phone has subscribed: greet it. */
        void onPhoneReady(BluetoothDevice phone);
    }

    private final Context context;
    private final Lines lines;
    private BluetoothGattServer server;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothGattCharacteristic tx, feed;

    /** Per phone: subscribed, packet size, lines being received, packets waiting to go. */
    private static final class Phone {
        volatile boolean subscribed;
        volatile int payload = 20;
        final ByteArrayOutputStream incoming = new ByteArrayOutputStream();
        final ArrayDeque<byte[]> outgoing = new ArrayDeque<>();
        /** The picture being sent: only ever the newest, and only after the lines. */
        final ArrayDeque<byte[]> picture = new ArrayDeque<>();
        volatile boolean wantsPictures;
        boolean sending;
    }
    private final Map<String, Phone> phones = new ConcurrentHashMap<>();
    /** Advertising right now (the system says so); false after Bluetooth goes off or fails. */
    volatile boolean advertising;

    BleLink(Context context, Lines lines) {
        this.context = context;
        this.lines = lines;
    }

    boolean linked() {
        for (Phone p : phones.values()) if (p.subscribed) return true;
        return false;
    }

    void start() {
        try {
            BluetoothManager manager = (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
            if (adapter == null || !adapter.isEnabled()) { Log.w(TAG, "bluetooth: off or missing"); return; }
            server = manager.openGattServer(context, callback);
            if (server == null) { Log.w(TAG, "bluetooth: no GATT server"); return; }
            BluetoothGattService service = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
            BluetoothGattCharacteristic rx = new BluetoothGattCharacteristic(RX,
                    BluetoothGattCharacteristic.PROPERTY_WRITE | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                    BluetoothGattCharacteristic.PERMISSION_WRITE);
            tx = new BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                    BluetoothGattCharacteristic.PERMISSION_READ);
            tx.addDescriptor(new BluetoothGattDescriptor(CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
            feed = new BluetoothGattCharacteristic(FEED, BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                    BluetoothGattCharacteristic.PERMISSION_READ);
            feed.addDescriptor(new BluetoothGattDescriptor(CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
            service.addCharacteristic(rx);
            service.addCharacteristic(tx);
            service.addCharacteristic(feed);
            server.addService(service);
            advertiser = adapter.getBluetoothLeAdvertiser();
            if (advertiser == null) { Log.w(TAG, "bluetooth: this device cannot advertise"); return; }
            AdvertiseSettings settings = new AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                    .setConnectable(true).build();
            AdvertiseData data = new AdvertiseData.Builder().addServiceUuid(new ParcelUuid(SERVICE)).build();
            AdvertiseData name = new AdvertiseData.Builder().setIncludeDeviceName(true).build();
            advertiser.startAdvertising(settings, data, name, advertiseCallback);
        } catch (Exception e) {
            Log.w(TAG, "bluetooth: " + e);
        }
    }

    void stop() {
        advertising = false;
        try { if (advertiser != null) advertiser.stopAdvertising(advertiseCallback); } catch (Exception ignored) { }
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        phones.clear();
    }

    /** Sends one line (ending in a newline) to every subscribed phone. */
    void send(String line) {
        if (server == null) return;
        byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
        for (Map.Entry<String, Phone> e : phones.entrySet()) {
            Phone p = e.getValue();
            if (!p.subscribed) continue;
            synchronized (p) {
                // A phone that has fallen far behind gets only what is new.
                if (p.outgoing.size() > 200) p.outgoing.clear();
                for (int at = 0; at < bytes.length; at += p.payload) {
                    int n = Math.min(p.payload, bytes.length - at);
                    byte[] piece = new byte[n];
                    System.arraycopy(bytes, at, piece, 0, n);
                    p.outgoing.add(piece);
                }
            }
            pump(e.getKey(), p);
        }
    }

    /** True while a phone takes pictures (it has subscribed to them). */
    boolean wantsPictures() {
        for (Phone p : phones.values()) if (p.wantsPictures) return true;
        return false;
    }

    /** A camera picture (already framed: length, header line, JPEG) for the phones taking them.
     *  One that has not finished going yet is replaced by this newer one. */
    void sendPicture(byte[] framed) {
        if (server == null) return;
        for (Map.Entry<String, Phone> e : phones.entrySet()) {
            Phone p = e.getValue();
            if (!p.wantsPictures) continue;
            synchronized (p) {
                if (!p.picture.isEmpty()) continue;       // still sending the last one: skip this
                for (int at = 0; at < framed.length; at += p.payload) {
                    int n = Math.min(p.payload, framed.length - at);
                    byte[] piece = new byte[n];
                    System.arraycopy(framed, at, piece, 0, n);
                    p.picture.add(piece);
                }
            }
            pump(e.getKey(), p);
        }
    }

    /** Sends the next waiting packet unless one is still on its way (one at a time): the
     *  lines first, then the picture. */
    private void pump(String address, Phone p) {
        byte[] piece;
        BluetoothGattCharacteristic on;
        synchronized (p) {
            if (p.sending) return;
            if (!p.outgoing.isEmpty()) { piece = p.outgoing.poll(); on = tx; }
            else if (!p.picture.isEmpty()) { piece = p.picture.poll(); on = feed; }
            else return;
            p.sending = true;
        }
        try {
            BluetoothDevice device = BluetoothAdapter.getDefaultAdapter().getRemoteDevice(address);
            synchronized (this) {
                on.setValue(piece);
                if (!server.notifyCharacteristicChanged(device, on, false)) {
                    synchronized (p) { p.sending = false; }
                }
            }
        } catch (Exception e) {
            synchronized (p) { p.sending = false; }
        }
    }

    private final AdvertiseCallback advertiseCallback = new AdvertiseCallback() {
        @Override public void onStartSuccess(AdvertiseSettings s) { advertising = true; Log.i(TAG, "bluetooth: advertising"); }
        @Override public void onStartFailure(int error) {
            // 3 = already advertising (a restart that overlapped): that is fine.
            advertising = error == ADVERTISE_FAILED_ALREADY_STARTED;
            Log.w(TAG, "bluetooth: advertising failed " + error);
        }
    };

    private final BluetoothGattServerCallback callback = new BluetoothGattServerCallback() {
        @Override
        public void onConnectionStateChange(BluetoothDevice device, int status, int state) {
            if (state == BluetoothProfile.STATE_CONNECTED) {
                phones.put(device.getAddress(), new Phone());
                Log.i(TAG, "bluetooth: phone connected");
            } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                phones.remove(device.getAddress());
                Log.i(TAG, "bluetooth: phone gone");
                lines.onPhoneChanged();
            }
        }

        @Override
        public void onMtuChanged(BluetoothDevice device, int mtu) {
            Phone p = phones.get(device.getAddress());
            if (p != null) p.payload = Math.max(20, mtu - 3);
        }

        @Override
        public void onDescriptorWriteRequest(BluetoothDevice device, int requestId, BluetoothGattDescriptor descriptor,
                                             boolean prepared, boolean needResponse, int offset, byte[] value) {
            Phone p = phones.get(device.getAddress());
            if (p != null && CCCD.equals(descriptor.getUuid())) {
                boolean on = value != null && value.length > 0 && (value[0] & 1) != 0;
                if (FEED.equals(descriptor.getCharacteristic().getUuid())) {
                    p.wantsPictures = on;
                    Log.i(TAG, "bluetooth: phone " + (on ? "takes" : "stopped taking") + " pictures");
                } else {
                    p.subscribed = on;
                    if (on) { lines.onPhoneReady(device); lines.onPhoneChanged(); }
                }
            }
            if (needResponse) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, value);
        }

        @Override
        public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId, BluetoothGattCharacteristic c,
                                                 boolean prepared, boolean needResponse, int offset, byte[] value) {
            if (needResponse) server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null);
            Phone p = phones.get(device.getAddress());
            if (p == null || value == null || !RX.equals(c.getUuid())) return;
            for (byte b : value) {
                if (b == '\n') {
                    String line = new String(p.incoming.toByteArray(), StandardCharsets.UTF_8);
                    p.incoming.reset();
                    if (!line.isEmpty()) lines.onLine(line);
                } else if (p.incoming.size() < 64 * 1024) {
                    p.incoming.write(b);
                }
            }
        }

        @Override
        public void onNotificationSent(BluetoothDevice device, int status) {
            Phone p = phones.get(device.getAddress());
            if (p == null) return;
            synchronized (p) { p.sending = false; }
            pump(device.getAddress(), p);
        }
    };
}
