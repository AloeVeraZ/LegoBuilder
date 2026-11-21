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
        /** pose: camera from marker (null when the marker is not seen); centre: its middle in the picture. */
        void onMarker(float[] pose, float[] centre, Lens lens);
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
    /** The largest picture asked of the camera: a 50 mm marker needs a few pixels per cell. */
    private static final int MAX_WIDTH = 1280;

    private final Context context;
    private final Listener listener;
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
        Frame frame;                    // the latest picture: brightness for the marker, colour for the set-down check
        float[] pose;
        long lastSeen, lastSearch, lastLog;
        int searched, seen;

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
                long now = SystemClock.uptimeMillis();
                if (now - lastSearch < EVERY_MS) return;
                lastSearch = now;
                Image.Plane[] planes = image.getPlanes();
                Image.Plane y = planes[0];
                int w = image.getWidth(), h = image.getHeight(), stride = y.getRowStride();
                ByteBuffer buf = y.getBuffer();
                if (frame == null || frame.width != w || frame.height != h) frame = new Frame(w, h);
                byte[] grey = frame.y;
                if (stride == w) {
                    buf.get(grey, 0, Math.min(buf.remaining(), w * h));
                } else {
                    for (int row = 0; row < h; row++) {
                        buf.position(row * stride);
                        buf.get(grey, row * w, w);
                    }
                }
                // Colour, only while something wants it (the set-down check): every 2 x 2 block's U and V.
                if (watcher != null && planes.length >= 3) {
                    copyChroma(planes[1], frame.u, w / 2, h / 2);
                    copyChroma(planes[2], frame.v, w / 2, h / 2);
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

        /** One U or V plane (pixelStride 1 or 2, any row stride) into a packed cw x ch array. */
        private void copyChroma(Image.Plane plane, byte[] out, int cw, int ch) {
            ByteBuffer b = plane.getBuffer();
            int ps = plane.getPixelStride(), rs = plane.getRowStride(), limit = b.limit();
            for (int row = 0; row < ch; row++) {
                int at = row * rs;
                for (int col = 0; col < cw; col++) {
                    int i = at + col * ps;
                    if (i < limit) out[row * cw + col] = b.get(i);
                }
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
            lens = Lens.guess(w, h, 0);
            Log.i(TAG, "camera: still picture " + path + ", lens " + lens);
            Runnable again = new Runnable() {
                @Override public void run() {
                    if (!live) return;
                    search(w, h);
                    background.postDelayed(this, 100);
                }
            };
            again.run();
        }

        // -------------------------------------------------------- both
        private void search(int w, int h) {
            long t0 = SystemClock.uptimeMillis();
            QrFinder.Found found = finder.find(frame.y, w, h, w);
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
                Log.i(TAG, "camera: marker seen in " + seen + " of " + searched + " pictures, last search " + (t1 - t0) + " ms"
                        + (found != null ? String.format(java.util.Locale.US, ", %.1f px a cell, match %.2f", found.cell, found.match) : ""));
                lastLog = t1;
                searched = seen = 0;
            }
            final float[] p = pose;
            final float[] centre = p == null ? null : MarkerPose.project(p, 0, 0, 0, lens.fx, lens.fy, lens.cx, lens.cy);
            final Lens l = lens;
            main.post(() -> { if (run == this && live) listener.onMarker(p, centre, l); });
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
            if (s.getWidth() > MAX_WIDTH) continue;
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
