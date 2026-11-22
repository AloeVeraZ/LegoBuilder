package com.buildlens.glasses;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.util.Size;
import android.util.SizeF;

import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Collections;

/**
 * The glasses' camera, looking for the table marker. Each picture is searched for the
 * marker (QrFinder, MarkerRefine) on a background thread, and where it is in space
 * (MarkerPose) goes to the listener on the main thread.
 *
 * Everything about the camera is written to the log once (adb logcat -s BuildLens), so
 * what the real glasses have can be read off: which cameras, picture sizes, lens.
 *
 * For trying it without a camera (the emulator), it can instead look at one still picture
 * again and again: startPicture().
 */
final class CameraFeed {
    static final String TAG = LinkService.TAG;

    /** The camera's lens: focal lengths and middle in pixels, for a picture of width x height. */
    static final class Lens {
        final float fx, fy, cx, cy;
        final int width, height, rotation;

        Lens(float fx, float fy, float cx, float cy, int width, int height, int rotation) {
            this.fx = fx; this.fy = fy; this.cx = cx; this.cy = cy;
            this.width = width; this.height = height; this.rotation = rotation;
        }

        /** No lens data: an ordinary 62 degree wide view, as the phone assumes for a webcam. */
        static Lens guess(int width, int height, int rotation) {
            float f = width / (2 * (float) Math.tan(Math.toRadians(62) / 2));
            return new Lens(f, f, (width - 1) / 2f, (height - 1) / 2f, width, height, rotation);
        }

        @Override public String toString() {
            return String.format(java.util.Locale.US, "%dx%d f %.0f/%.0f middle %.0f,%.0f turned %d", width, height, fx, fy, cx, cy, rotation);
        }
    }

    interface Listener {
        /**
         * fresh: camera from marker as found in this picture (null when not found in it);
         * centre: its middle in the picture (kept for a moment after it was last seen);
         * time: when the picture was taken (HeadTracker's clock).
         */
        void onMarker(float[] fresh, float[] centre, Lens lens, long time);
        /** The set's box barcode was read (while lookForBox). */
        void onBox(String code);

        /** The camera could not be used. */
        void onNoCamera();
    }

    /** Sees every picture in which the marker was found, in colour, on the camera's thread (the set-down check). */
    interface Watcher {
        /** pose: camera from marker for exactly this picture (not smoothed). Must not keep `frame`: it is reused. */
        void onPicture(Frame frame, Lens lens, float[] pose);
    }

    private volatile Watcher watcher;

    void setWatcher(Watcher w) { watcher = w; }

    /** Pictures this far apart at most are searched; the rest are skipped, to save the battery. */
    private static final int EVERY_MS = 66;
    /** A marker lost for longer than this is gone; shorter gaps keep the last place. */
    private static final int HOLD_MS = 600;
    /** The largest picture asked of the camera. The marker needs about 4 pixels a cell to be
     *  found; with the phone flat on the table half a metre away that takes 2048 wide. */
    private static final int MAX_WIDTH = 2048;
    /** While on the box screen. The phone scans the box (and then shows its code, which the
     *  glasses look for); the glasses' own barcode reading is a bonus (their lens is fixed-focus
     *  and the bars come out thin), so the quick picture is kept and nothing restarts after. */
    static final int BOX_WIDTH = 2048;
    /** The largest picture asked of the camera now: MAX_WIDTH, or BOX_WIDTH on the box screen. */
    static volatile int maxWidth = MAX_WIDTH;
    /** Exposure below the camera's own choice, in stops: see startSession. */
    static float EXPOSURE_EV = -1.5f;

    private final Context context;
    private final Listener listener;
    /** Set to save the next camera picture as snap.pgm in the app's folder (adb: --ez snapshot true). */
    static volatile boolean snapshot;
    /** Set while the start screen wants the set's box: every picture is also read for its barcode. */
    static volatile boolean lookForBox;
    /** What onBox gets when the phone's code (rather than the box's barcode) was seen. */
    static final String PHONE_MARKER = "phone-marker";
    private final Handler main = new Handler(Looper.getMainLooper());
    /** The current run. Each start gets its own thread, camera and buffers, so a run that is
     *  still closing (or still opening) can never get in the way of the next one. */
    private Run run;

    CameraFeed(Context context, Listener listener) {
        this.context = context;
        this.listener = listener;
    }

    /** One start of the camera (or of a still picture), until stop(). */
    private final class Run {
        final HandlerThread thread = new HandlerThread("BuildLensCamera");
        final Handler background;
        volatile boolean live = true;
        CameraDevice camera;
        CameraCaptureSession session;
        ImageReader reader;
        Lens lens;
        final QrFinder finder = new QrFinder();
        /** The latest picture: brightness for the marker, colour for the Mac's live view and the set-down check. */
        Frame frame;
        /** frame's planes, by their own names. */
        byte[] grey = new byte[0], u = new byte[0], v = new byte[0];
        /** The colour was copied for this picture (the Mac is watching, LiveFeed). */
        boolean colour;
        float[] pose;
        long imageTime;
        /** The marker as found in the last picture, to follow it from there. */
        QrFinder.Found last;
        long lastSeen, lastSearch, lastLog;
        int searched, seen, followedCount;

        Run() {
            thread.start();
            background = new Handler(thread.getLooper());
        }

        /** Runs `r` on this run's thread; anything going wrong only stops the ghost, never the app. */
        void post(Runnable r) {
            background.post(() -> {
                if (!live) return;
                try { r.run(); } catch (Throwable e) { fail("camera: " + e); }
            });
        }

        void fail(String why) {
            Log.w(TAG, why);
            close();
            main.post(() -> { if (run == this) listener.onNoCamera(); });
        }

        /** On this run's thread. */
        void close() {
            live = false;
            try { if (session != null) session.close(); } catch (Throwable ignored) { }
            try { if (camera != null) camera.close(); } catch (Throwable ignored) { }
            try { if (reader != null) reader.close(); } catch (Throwable ignored) { }
            session = null;
            camera = null;
            reader = null;
            thread.quitSafely();
        }

        // -------------------------------------------------------- the real camera
        @SuppressLint("MissingPermission")
        void openCamera() throws Exception {
            CameraManager manager = (CameraManager) context.getSystemService(Context.CAMERA_SERVICE);
            String id = chooseCamera(manager);
            if (id == null) { fail("no camera"); return; }
            CameraCharacteristics info = manager.getCameraCharacteristics(id);
            Size size = chooseSize(info);
            lens = lensOf(info, size);
            Log.i(TAG, "camera: using " + id + ", lens " + lens);
            reader = ImageReader.newInstance(size.getWidth(), size.getHeight(), ImageFormat.YUV_420_888, 2);
            reader.setOnImageAvailableListener(this::took, background);
            manager.openCamera(id, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice device) {
                    if (!live) { device.close(); return; }
                    camera = device;
                    try { startSession(info); } catch (Throwable e) { fail("camera session: " + e); }
                }
                @Override public void onDisconnected(CameraDevice device) {
                    device.close();
                    if (live) fail("camera disconnected");
                }
                @Override public void onError(CameraDevice device, int error) {
                    device.close();
                    if (live) fail("camera error " + error);
                }
            }, background);
        }

        private void startSession(CameraCharacteristics info) throws CameraAccessException {
            camera.createCaptureSession(Collections.singletonList(reader.getSurface()), new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession s) {
                    if (!live) { s.close(); return; }
                    session = s;
                    try {
                        CaptureRequest.Builder request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                        request.addTarget(reader.getSurface());
                        int[] af = info.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES);
                        if (af != null && contains(af, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO))
                            request.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
                        // The marker is a lit screen, far brighter than the room: exposed for the
                        // room, its white blooms over the black cells and they come out thin and
                        // grey. Darker pictures keep the cells black.
                        android.util.Range<Integer> range = info.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
                        android.util.Rational step = info.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP);
                        if (range != null && step != null && step.floatValue() > 0) {
                            // The box is printed, not lit: normal exposure for it (brighter, crisper bars).
                            int want = Math.round((lookForBox ? 0 : EXPOSURE_EV) / step.floatValue());
                            int ev = Math.max(range.getLower(), Math.min(range.getUpper(), want));
                            request.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, ev);
                            Log.i(TAG, "camera: exposure " + ev + " x " + step + " EV (range " + range + ")");
                        }
                        s.setRepeatingRequest(request.build(), null, background);
                    } catch (Throwable e) {
                        fail("camera request: " + e);
                    }
                }
                @Override public void onConfigureFailed(CameraCaptureSession s) { if (live) fail("camera session failed"); }
            }, background);
        }

        private void took(ImageReader r) {
            Image image = null;
            try {
                image = r.acquireLatestImage();
                if (image == null || !live) return;
                imageTime = image.getTimestamp();
                long now = SystemClock.uptimeMillis();
                if (now - lastSearch < EVERY_MS) return;
                lastSearch = now;
                Image.Plane[] planes = image.getPlanes();
                Image.Plane y = planes[0];
                int w = image.getWidth(), h = image.getHeight(), stride = y.getRowStride();
                ByteBuffer buf = y.getBuffer();
                if (frame == null || frame.width != w || frame.height != h) {
                    frame = new Frame(w, h);
                    grey = frame.y; u = frame.u; v = frame.v;
                }
                if (stride == w) {
                    buf.get(grey, 0, Math.min(buf.remaining(), w * h));
                } else {
                    for (int row = 0; row < h; row++) {
                        buf.position(row * stride);
                        buf.get(grey, row * w, w);
                    }
                }
                // The colour is only copied while something wants it: the Mac's live view or the
                // set-down check (every 2 x 2 block's U and V).
                colour = LiveFeed.watched() && planes.length >= 3;
                if ((colour || watcher != null) && planes.length >= 3) {
                    copyPlane(planes[1], u, w / 2, h / 2);
                    copyPlane(planes[2], v, w / 2, h / 2);
                }
                image.close();
                image = null;
                search(w, h);
            } catch (Throwable e) {
                Log.e(TAG, "camera picture", e);
            } finally {
                if (image != null) image.close();
            }
        }

        // -------------------------------------------------------- a still picture instead
        void openPicture(String path) {
            Bitmap bitmap = BitmapFactory.decodeFile(path);
            if (bitmap == null) { fail("no picture at " + path); return; }
            int w = bitmap.getWidth(), h = bitmap.getHeight();
            int[] argb = new int[w * h];
            bitmap.getPixels(argb, 0, w, 0, 0, w, h);
            frame = Frame.fromArgb(argb, w, h);             // the picture never changes, so it is made once
            grey = frame.y; u = frame.u; v = frame.v;
            lens = Lens.guess(w, h, 0);
            colour = false;
            Log.i(TAG, "camera: still picture " + path + ", lens " + lens);
            Runnable again = new Runnable() {
                @Override public void run() {
                    if (!live) return;
                    imageTime = HeadTracker.clock();
                    search(w, h);
                    background.postDelayed(this, 100);
                }
            };
            again.run();
        }

        // -------------------------------------------------------- both
        private void search(int w, int h) {
            if (snapshot) {
                snapshot = false;
                java.io.File folder = context.getExternalFilesDir(null);
                try (java.io.FileOutputStream out = new java.io.FileOutputStream(new java.io.File(folder, "snap.pgm"))) {
                    out.write(("P5\n" + w + " " + h + "\n255\n").getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                    out.write(grey, 0, w * h);
                    Log.i(TAG, "camera: saved snap.pgm " + w + "x" + h);
                } catch (Exception e) {
                    Log.w(TAG, "snapshot", e);
                }
            }
            if (lookForBox) {
                // Only the barcode while on the box screen (the phone's code is not wanted yet).
                long b0 = SystemClock.uptimeMillis();
                String code = BarcodeReader.read(grey, w, h);
                long b1 = SystemClock.uptimeMillis();
                if (b1 - lastLog > 3000) {
                    Log.i(TAG, "camera: box " + w + "x" + h + ", barcode read in " + (b1 - b0) + " ms" + (code == null ? ", none" : ""));
                    lastLog = b1;
                }
                if (code != null) {
                    Log.i(TAG, "camera: barcode " + code);
                    main.post(() -> { if (run == this && live) listener.onBox(code); });
                } else if (finder.find(grey, w, h, w) != null) {
                    // The phone's code: the phone only shows it once it has scanned the box,
                    // so seeing it means the box is done (no link needed for the hand-off).
                    Log.i(TAG, "camera: the phone's code, so the box was scanned on the phone");
                    main.post(() -> { if (run == this && live) listener.onBox(PHONE_MARKER); });
                }
                LiveFeed.offer(grey, colour ? u : null, colour ? v : null, w, h, lens, null);
                return;
            }
            long t0 = SystemClock.uptimeMillis();
            // Follow it from the last picture when there is one (it holds on through a lamp's
            // reflection on the screen); look afresh otherwise.
            QrFinder.Found found = last != null && t0 - lastSeen < HOLD_MS ? finder.follow(grey, w, h, w, last) : null;
            boolean followed = found != null;
            if (found == null) found = finder.find(grey, w, h, w);
            last = found;
            if (followed) followedCount++;
            float[] now = found == null ? null : MarkerPose.solve(found, lens.fx, lens.fy, lens.cx, lens.cy);
            long t1 = SystemClock.uptimeMillis();
            searched++;
            if (now != null) {
                seen++;
                lastSeen = t1;
                pose = MarkerPose.blend(pose, now, 0.5f);
            } else if (t1 - lastSeen > HOLD_MS) {
                pose = null;
            }
            if (t1 - lastLog > 3000) {
                Log.i(TAG, "camera: marker seen in " + seen + " of " + searched + " pictures (" + followedCount + " followed), last search " + (t1 - t0) + " ms"
                        + (found != null ? String.format(java.util.Locale.US, ", %.1f px a cell, match %.2f", found.cell, found.match) : ""));
                lastLog = t1;
                searched = seen = followedCount = 0;
            }
            final float[] p = pose;
            LiveFeed.offer(grey, colour ? u : null, colour ? v : null, w, h, lens, p);
            final float[] centre = p == null ? null : MarkerPose.project(p, 0, 0, 0, lens.fx, lens.fy, lens.cx, lens.cy);
            final Lens l = lens;
            final float[] fresh = now;
            final long time = imageTime;
            main.post(() -> { if (run == this && live) listener.onMarker(fresh, centre, l, time); });
            // The set-down check looks at this very picture, with the pose found in it.
            Watcher wt = watcher;
            if (wt != null && now != null) {
                try { wt.onPicture(frame, lens, now); } catch (Throwable e) { Log.e(TAG, "set-down check", e); }
            }
        }
    }

    /** Starts the camera. Main thread. */
    void start() {
        stop();
        Run r = run = new Run();
        r.post(() -> {
            try { r.openCamera(); } catch (Throwable e) { r.fail("camera: " + e); }
        });
    }

    /** Looks at one picture (a file on the glasses) ten times a second, as if it came from the camera. Main thread. */
    void startPicture(String path) {
        stop();
        Run r = run = new Run();
        r.post(() -> r.openPicture(path));
    }

    /** Main thread. */
    void stop() {
        Run r = run;
        run = null;
        if (r == null) return;
        r.live = false;
        r.background.post(r::close);
    }

    /** One colour plane of the picture (cw x ch), whatever its row and pixel spacing. */
    private static void copyPlane(Image.Plane plane, byte[] out, int cw, int ch) {
        ByteBuffer buf = plane.getBuffer();
        int rowStride = plane.getRowStride(), pixelStride = plane.getPixelStride();
        if (pixelStride == 1 && rowStride == cw) {
            buf.position(0);
            buf.get(out, 0, Math.min(buf.remaining(), cw * ch));
            return;
        }
        byte[] row = new byte[rowStride];
        for (int y = 0; y < ch; y++) {
            int start = y * rowStride, length = Math.min(rowStride, buf.capacity() - start);
            if (length <= 0) break;
            buf.position(start);
            buf.get(row, 0, length);
            for (int x = 0, i = 0; x < cw && i < length; x++, i += pixelStride) out[y * cw + x] = row[i];
        }
    }

    private static boolean contains(int[] list, int value) {
        for (int v : list) if (v == value) return true;
        return false;
    }

    private static String chooseCamera(CameraManager manager) throws CameraAccessException {
        String[] ids = manager.getCameraIdList();
        String chosen = null;
        for (String id : ids) {
            CameraCharacteristics c = manager.getCameraCharacteristics(id);
            Integer facing = c.get(CameraCharacteristics.LENS_FACING);
            Log.i(TAG, "camera " + id + ": facing " + facing + " (0 front, 1 back, 2 external), turned "
                    + c.get(CameraCharacteristics.SENSOR_ORIENTATION) + ", level " + c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL));
            if (chosen == null || (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK)) chosen = id;
        }
        return chosen;
    }

    private static Size chooseSize(CameraCharacteristics info) {
        StreamConfigurationMap map = info.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        Size[] sizes = map == null ? null : map.getOutputSizes(ImageFormat.YUV_420_888);
        if (sizes == null || sizes.length == 0) return new Size(640, 480);
        Log.i(TAG, "camera sizes " + Arrays.toString(sizes));
        Size best = null;
        for (Size s : sizes) {
            if (s.getWidth() > maxWidth) continue;
            // The sensor's own 4:3 shape, lying down: anything else is cut from it (a narrower
            // view) or stands on end.
            if (s.getWidth() * 3 != s.getHeight() * 4) continue;
            if (best == null || s.getWidth() * s.getHeight() > best.getWidth() * best.getHeight()) best = s;
        }
        return best != null ? best : sizes[sizes.length - 1];
    }

    /** The lens from what the camera says about itself, scaled to the picture size used. */
    private static Lens lensOf(CameraCharacteristics info, Size size) {
        int w = size.getWidth(), h = size.getHeight();
        Integer turned = info.get(CameraCharacteristics.SENSOR_ORIENTATION);
        int rotation = turned == null ? 0 : turned;
        float[] k = info.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION);
        Rect array = info.get(CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE);
        if (array == null) array = info.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
        Log.i(TAG, "camera lens data: intrinsic " + Arrays.toString(k) + ", array " + array
                + ", focal " + Arrays.toString(info.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS))
                + " mm, sensor " + info.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) + " mm"
                + ", distortion " + Arrays.toString(info.get(CameraCharacteristics.LENS_RADIAL_DISTORTION)));
        if (array == null || array.width() <= 0) return Lens.guess(w, h, rotation);
        // The picture is the sensor area scaled down to fill w x h, cut evenly at the sides.
        float scale = Math.max(w / (float) array.width(), h / (float) array.height());
        float ox = (w - array.width() * scale) / 2, oy = (h - array.height() * scale) / 2;
        if (k != null && k[0] > 0 && k[1] > 0) {
            return new Lens(k[0] * scale, k[1] * scale, (k[2] - array.left) * scale + ox, (k[3] - array.top) * scale + oy, w, h, rotation);
        }
        float[] focal = info.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
        SizeF sensor = info.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE);
        Size pixels = info.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE);
        if (focal != null && focal.length > 0 && sensor != null && sensor.getWidth() > 0 && pixels != null) {
            float f = focal[0] / sensor.getWidth() * pixels.getWidth() * scale;
            if (f > w * 0.3f && f < w * 5) return new Lens(f, f, (w - 1) / 2f, (h - 1) / 2f, w, h, rotation);
        }
        return Lens.guess(w, h, rotation);
    }
}
