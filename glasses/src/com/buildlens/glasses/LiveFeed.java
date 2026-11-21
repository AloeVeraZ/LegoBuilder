package com.buildlens.glasses;

import android.graphics.Bitmap;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * The camera's picture (in colour) and where the glasses found the marker, for the Mac's Glasses
 * preview while the glasses are plugged in. The Mac reaches it over the USB cable
 * (adb forward tcp:52734 tcp:52734); it listens on the glasses themselves only, so it
 * cannot be reached over Wi-Fi. Nothing is encoded or sent until the Mac connects.
 *
 * Each picture: one line of JSON, then that many bytes of JPEG:
 *   {"w":640,"h":480,"fx":..,"fy":..,"cx":..,"cy":..,"step":3,"finished":false,"pose":[16 numbers]|null,"jpeg":12345}
 * The pose is camera from marker, column-major, as MarkerPose (and the Mac's MarkerTracker).
 */
final class LiveFeed {
    static final String TAG = LinkService.TAG;
    static final int PORT = 52734;
    /** The picture is halved until it is at most this wide: enough to see by, quick to send. */
    private static final int WIDTH = 640;

    private static final Object lock = new Object();
    private static Thread server;
    private static volatile Socket viewer;

    /** The picture waiting to be sent (null = none); filled by the camera, emptied by the sender. */
    private static byte[] pending, pendingU, pendingV;
    private static boolean pendingColour;
    private static int pendingW, pendingH;
    private static String pendingHeader;
    private static boolean busy;

    private LiveFeed() {}

    /** Starts listening, once. */
    static void start() {
        synchronized (lock) {
            if (server != null) return;
            server = new Thread(LiveFeed::serve, "BuildLensLive");
            server.setDaemon(true);
            server.start();
        }
    }

    /** True while the Mac is watching, so the camera only does the extra work then. */
    static boolean watched() {
        return viewer != null;
    }

    /**
     * Offers the camera's latest picture (grey, w x h, one byte a pixel; u and v its colour
     * at half that size, or null for none) with the lens and pose it was searched with.
     * Dropped if the last one is still on its way. Camera thread.
     */
    static void offer(byte[] grey, byte[] u, byte[] v, int w, int h, CameraFeed.Lens lens, float[] pose) {
        if (viewer == null || lens == null) return;
        synchronized (lock) {
            if (busy) return;
            int k = 1;
            while (w / k > WIDTH) k *= 2;
            int sw = w / k, sh = h / k;
            if (pending == null || pending.length != sw * sh) pending = new byte[sw * sh];
            for (int y = 0; y < sh; y++) {
                int from = y * k * w;
                for (int x = 0; x < sw; x++) pending[y * sw + x] = grey[from + x * k];
            }
            pendingColour = u != null && v != null;
            if (pendingColour) {
                if (pendingU == null || pendingU.length != sw * sh) { pendingU = new byte[sw * sh]; pendingV = new byte[sw * sh]; }
                int cw = w / 2;
                for (int y = 0; y < sh; y++) {
                    int from = (y * k / 2) * cw;
                    for (int x = 0; x < sw; x++) {
                        pendingU[y * sw + x] = u[from + x * k / 2];
                        pendingV[y * sw + x] = v[from + x * k / 2];
                    }
                }
            }
            pendingW = sw;
            pendingH = sh;
            StringBuilder head = new StringBuilder(256);
            // Pixel centres stay pixel centres when the picture is shrunk by k.
            head.append(String.format(Locale.US, "{\"w\":%d,\"h\":%d,\"fx\":%.3f,\"fy\":%.3f,\"cx\":%.3f,\"cy\":%.3f,\"step\":%d,\"finished\":%b,\"pose\":",
                    sw, sh, lens.fx / k, lens.fy / k, (lens.cx + 0.5f) / k - 0.5f, (lens.cy + 0.5f) / k - 0.5f,
                    LinkService.step, LinkService.finished));
            if (pose == null) {
                head.append("null");
            } else {
                head.append('[');
                for (int i = 0; i < 16; i++) head.append(i == 0 ? "" : ",").append(String.format(Locale.US, "%.6f", pose[i]));
                head.append(']');
            }
            pendingHeader = head.toString();
            busy = true;
            lock.notifyAll();
        }
    }

    private static void serve() {
        try (ServerSocket listening = new ServerSocket(PORT, 1, InetAddress.getLoopbackAddress())) {
            Log.i(TAG, "live feed: waiting for the Mac on port " + PORT);
            while (true) {
                Socket s = listening.accept();
                s.setTcpNoDelay(true);
                Log.i(TAG, "live feed: the Mac is watching");
                synchronized (lock) { busy = false; pending = null; }
                viewer = s;
                try {
                    send(s);
                } catch (Throwable e) {
                    Log.i(TAG, "live feed: the Mac stopped watching (" + e.getMessage() + ")");
                } finally {
                    viewer = null;
                    try { s.close(); } catch (Throwable ignored) { }
                }
            }
        } catch (Throwable e) {
            Log.w(TAG, "live feed: can't listen: " + e);
            synchronized (lock) { server = null; }
        }
    }

    /** Sends pictures as the camera offers them, until the Mac goes away. */
    private static void send(Socket s) throws Exception {
        OutputStream out = s.getOutputStream();
        ByteArrayOutputStream jpeg = new ByteArrayOutputStream(64 * 1024);
        int[] argb = new int[0];
        // A quiet Mac is noticed by the next write failing; this wait just keeps that prompt.
        s.setSoTimeout(1000);
        while (true) {
            byte[] grey, u, v;
            int w, h;
            String header;
            synchronized (lock) {
                while (!busy) {
                    lock.wait(2000);
                    if (!busy && s.isClosed()) return;
                }
                grey = pending;
                u = pendingColour ? pendingU : null;
                v = pendingColour ? pendingV : null;
                w = pendingW;
                h = pendingH;
                header = pendingHeader;
            }
            if (argb.length != w * h) argb = new int[w * h];
            if (u == null) {
                for (int i = 0; i < w * h; i++) argb[i] = 0xff000000 | (grey[i] & 0xff) * 0x010101;
            } else {
                // The camera's YUV (full range) to RGB.
                for (int i = 0; i < w * h; i++) {
                    int y = grey[i] & 0xff, cb = (u[i] & 0xff) - 128, cr = (v[i] & 0xff) - 128;
                    int r = y + ((359 * cr) >> 8);
                    int g = y - ((88 * cb + 183 * cr) >> 8);
                    int b = y + ((454 * cb) >> 8);
                    r = r < 0 ? 0 : r > 255 ? 255 : r;
                    g = g < 0 ? 0 : g > 255 ? 255 : g;
                    b = b < 0 ? 0 : b > 255 ? 255 : b;
                    argb[i] = 0xff000000 | r << 16 | g << 8 | b;
                }
            }
            Bitmap picture = Bitmap.createBitmap(argb, w, h, Bitmap.Config.ARGB_8888);
            jpeg.reset();
            picture.compress(Bitmap.CompressFormat.JPEG, 70, jpeg);
            picture.recycle();
            synchronized (lock) { busy = false; }
            out.write((header + ",\"jpeg\":" + jpeg.size() + "}\n").getBytes(StandardCharsets.UTF_8));
            jpeg.writeTo(out);
            out.flush();
        }
    }
}
