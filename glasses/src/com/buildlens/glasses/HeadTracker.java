package com.buildlens.glasses;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.SystemClock;
import android.util.Log;

/**
 * Which way the head points, from the glasses' gyroscope, so the ghost can stay put on the
 * table while the head turns and while the phone's code is out of sight (or under the
 * hands). Once the code has been seen, its place is kept in this tracker's fixed frame;
 * every frame the ghost is drawn from there, turned by how far the head has turned since.
 *
 * Only turning is followed, not moving: the wearer sits still at the table and turns the
 * head. Each new sight of the code puts any drift right.
 *
 * Camera axes (x right, y down, z forward) against the glasses' own (x right, y up, z out of
 * the display towards the eye): the camera looks forward, so y and z are flipped.
 */
final class HeadTracker implements SensorEventListener {
    static final String TAG = LinkService.TAG;

    private final SensorManager sensors;
    private final Sensor gyro;
    /** The glasses' turn from where tracking started, as a unit quaternion (w, x, y, z). */
    private double qw = 1, qx, qy, qz;
    private long last;

    /** A short history (time, quaternion), to know where the head pointed when a picture was taken. */
    private static final int HISTORY = 256;
    private final long[] times = new long[HISTORY];
    private final double[][] turns = new double[HISTORY][4];
    private int newest = -1;

    HeadTracker(Context context) {
        sensors = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
        gyro = sensors == null ? null : sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        if (gyro == null) Log.w(TAG, "head: no gyroscope, the ghost only shows while the code is seen");
    }

    boolean works() {
        return gyro != null;
    }

    void start() {
        if (gyro != null) sensors.registerListener(this, gyro, SensorManager.SENSOR_DELAY_FASTEST);
    }

    void stop() {
        if (gyro != null) sensors.unregisterListener(this);
        last = 0;
    }

    @Override
    public synchronized void onSensorChanged(SensorEvent e) {
        if (last != 0) {
            double dt = (e.timestamp - last) * 1e-9;
            if (dt > 0 && dt < 0.2) {
                // Turned by (wx, wy, wz) * dt about the glasses' own axes: q = q * dq.
                double wx = e.values[0], wy = e.values[1], wz = e.values[2];
                double angle = Math.sqrt(wx * wx + wy * wy + wz * wz) * dt;
                if (angle > 1e-9) {
                    double s = Math.sin(angle / 2) / (angle / dt), c = Math.cos(angle / 2);
                    double dx = wx * s, dy = wy * s, dz = wz * s;
                    double w = qw * c - qx * dx - qy * dy - qz * dz;
                    double x = qw * dx + qx * c + qy * dz - qz * dy;
                    double y = qw * dy - qx * dz + qy * c + qz * dx;
                    double z = qw * dz + qx * dy - qy * dx + qz * c;
                    double n = Math.sqrt(w * w + x * x + y * y + z * z);
                    qw = w / n; qx = x / n; qy = y / n; qz = z / n;
                }
            }
        }
        last = e.timestamp;
        newest = (newest + 1) % HISTORY;
        times[newest] = e.timestamp;
        turns[newest][0] = qw; turns[newest][1] = qx; turns[newest][2] = qy; turns[newest][3] = qz;
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {}

    /** Camera to the tracker's fixed frame now: 3 x 3, row-major. */
    synchronized float[] cameraToRef() {
        return cameraMatrix(qw, qx, qy, qz);
    }

    /**
     * The same at the time a camera picture was taken (nanoseconds, the camera's clock, which
     * on Android is the sensors' clock too). The nearest moment kept; now, if none is near.
     */
    synchronized float[] cameraToRefAt(long time) {
        if (newest < 0) return cameraToRef();
        int best = -1;
        long bestGap = Long.MAX_VALUE;
        for (int i = 0; i < HISTORY; i++) {
            if (times[i] == 0) continue;
            long gap = Math.abs(times[i] - time);
            if (gap < bestGap) { bestGap = gap; best = i; }
        }
        if (best < 0 || bestGap > 300_000_000L) return cameraToRef();
        double[] q = turns[best];
        return cameraMatrix(q[0], q[1], q[2], q[3]);
    }

    /** The glasses' turn (w, x, y, z) at a camera picture's time, for checking the axes. */
    synchronized double[] turnAt(long time) {
        int best = -1;
        long bestGap = Long.MAX_VALUE;
        for (int i = 0; i < HISTORY; i++) {
            if (times[i] == 0) continue;
            long gap = Math.abs(times[i] - time);
            if (gap < bestGap) { bestGap = gap; best = i; }
        }
        return best < 0 ? new double[] {qw, qx, qy, qz} : turns[best].clone();
    }

    /** The clock the gyroscope uses, for pictures that come with no time of their own. */
    static long clock() {
        return SystemClock.elapsedRealtimeNanos();
    }

    private static float[] cameraMatrix(double w, double x, double y, double z) {
        // Glasses to fixed frame...
        double r00 = 1 - 2 * (y * y + z * z), r01 = 2 * (x * y - w * z), r02 = 2 * (x * z + w * y);
        double r10 = 2 * (x * y + w * z), r11 = 1 - 2 * (x * x + z * z), r12 = 2 * (y * z - w * x);
        double r20 = 2 * (x * z - w * y), r21 = 2 * (y * z + w * x), r22 = 1 - 2 * (x * x + y * y);
        // ...after camera to glasses (y and z flipped).
        return new float[] {
            (float) r00, (float) -r01, (float) -r02,
            (float) r10, (float) -r11, (float) -r12,
            (float) r20, (float) -r21, (float) -r22,
        };
    }
}
