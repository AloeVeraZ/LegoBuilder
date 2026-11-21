package com.buildlens.glasses;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.os.SystemClock;
import android.util.Log;
import android.view.View;

/**
 * How the camera's picture sits over what the eye sees through the display.
 *
 * The camera and the eye are in different places, so a point the camera sees in the middle
 * of its picture is not in the middle of what the wearer sees. Lining up once fixes that:
 * a crosshair is shown in two places, and each time the wearer looks so that the phone's
 * marker sits under it and clicks. From where the camera saw the marker at those two
 * clicks comes the mapping (a turn, a size and a shift) from camera picture to display.
 * It is saved, so it is done once per glasses.
 *
 * Before any line-up the camera picture is taken to fill the display.
 */
final class Lineup extends View {
    private static final String PREFS = "lineup";
    /** The two crosshairs, as parts of the display's width and height. */
    private static final float[][] TARGETS = {{0.32f, 0.38f}, {0.68f, 0.64f}};

    /** Called when lining up ends: done, or given up after a while with no clicks. */
    interface Done { void onLineupEnded(boolean linedUp); }
    /** An unfinished line-up gives up after this long, so clicks go back to the steps. */
    private static final int GIVE_UP_MS = 120_000;
    private final Runnable giveUp = () -> {
        if (Lineup.this.target < 0) return;
        Log.i(LinkService.TAG, "line-up: given up");
        end(false);
    };

    private final SharedPreferences prefs;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private Done done;
    private int target = -1;                 // -1: not lining up
    private final float[] seen = new float[4];
    private int seenWidth;
    private long missedAt;

    Lineup(Context context) {
        super(context);
        prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        paint.setColor(MainActivity.GREEN);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(3);
        setVisibility(GONE);
    }

    boolean active() { return target >= 0; }

    boolean linedUp() { return prefs.contains("ar"); }

    void begin(Done done) {
        this.done = done;
        target = 0;
        setVisibility(VISIBLE);
        invalidate();
        removeCallbacks(giveUp);
        postDelayed(giveUp, GIVE_UP_MS);
        Log.i(LinkService.TAG, "line-up: started");
    }

    /**
     * A click while lining up: where the camera sees the marker's middle now (null: not seen).
     * Returns true while there is more to do.
     */
    void click(float[] centre, CameraFeed.Lens lens) {
        if (target < 0) return;
        removeCallbacks(giveUp);
        postDelayed(giveUp, GIVE_UP_MS);
        if (centre == null || lens == null) {
            Log.i(LinkService.TAG, "line-up: click, but the marker is not seen");
            missedAt = SystemClock.uptimeMillis();
            invalidate();
            postDelayed(this::invalidate, 400);
            return;
        }
        seen[2 * target] = centre[0];
        seen[2 * target + 1] = centre[1];
        seenWidth = lens.width;
        Log.i(LinkService.TAG, "line-up: crosshair " + (target + 1) + " at camera " + centre[0] + "," + centre[1]);
        if (target == 0) { target = 1; invalidate(); return; }
        // a = (t2 - t1) / (c2 - c1) as complex numbers: the turn and size; then the shift.
        float w = getWidth(), h = getHeight();
        float t1x = TARGETS[0][0] * w, t1y = TARGETS[0][1] * h, t2x = TARGETS[1][0] * w, t2y = TARGETS[1][1] * h;
        float dx = seen[2] - seen[0], dy = seen[3] - seen[1], tx = t2x - t1x, ty = t2y - t1y;
        float d = dx * dx + dy * dy;
        if (d < 30 * 30) {                      // the marker hardly moved: start again
            Log.i(LinkService.TAG, "line-up: the two places were too close; again");
            target = 0;
            missedAt = SystemClock.uptimeMillis();
            invalidate();
            return;
        }
        float ar = (tx * dx + ty * dy) / d, ai = (ty * dx - tx * dy) / d;
        float bx = t1x - (ar * seen[0] - ai * seen[1]), by = t1y - (ai * seen[0] + ar * seen[1]);
        prefs.edit().putFloat("ar", ar).putFloat("ai", ai).putFloat("bx", bx).putFloat("by", by)
                .putInt("camera", seenWidth).putInt("w", (int) w).putInt("h", (int) h).apply();
        Log.i(LinkService.TAG, String.format(java.util.Locale.US, "line-up: done, size %.3f turn %.1f deg shift %.0f,%.0f",
                Math.hypot(ar, ai), Math.toDegrees(Math.atan2(ai, ar)), bx, by));
        end(true);
    }

    private void end(boolean linedUp) {
        target = -1;
        removeCallbacks(giveUp);
        setVisibility(GONE);
        if (done != null) done.onLineupEnded(linedUp);
    }

    /**
     * Camera point (x right, y down, z forward) to display pixel, as a 3 x 3 row-major matrix
     * on homogeneous points: the lens, then the line-up.
     */
    float[] toDisplay(CameraFeed.Lens lens, int width, int height) {
        float ar, ai, bx, by;
        if (linedUp()) {
            float k = prefs.getInt("camera", lens.width) / (float) lens.width;   // a different picture size
            float sx = width / (float) prefs.getInt("w", width), sy = height / (float) prefs.getInt("h", height);
            ar = prefs.getFloat("ar", 1) * k * sx;
            ai = prefs.getFloat("ai", 0) * k * sx;
            bx = prefs.getFloat("bx", 0) * sx;
            by = prefs.getFloat("by", 0) * sy;
        } else {
            // The camera picture, turned upright, fills the display.
            double turn = Math.toRadians(lens.rotation);
            boolean sideways = lens.rotation % 180 != 0;
            float pw = sideways ? lens.height : lens.width, ph = sideways ? lens.width : lens.height;
            float s = Math.max(width / pw, height / ph);
            ar = (float) (s * Math.cos(turn));
            ai = (float) (s * Math.sin(turn));
            float cx = (lens.width - 1) / 2f, cy = (lens.height - 1) / 2f;
            bx = (width - 1) / 2f - (ar * cx - ai * cy);
            by = (height - 1) / 2f - (ai * cx + ar * cy);
        }
        // [ar -ai bx; ai ar by; 0 0 1] x [fx 0 cx; 0 fy cy; 0 0 1]
        return new float[] {
            ar * lens.fx, -ai * lens.fy, ar * lens.cx - ai * lens.cy + bx,
            ai * lens.fx, ar * lens.fy, ai * lens.cx + ar * lens.cy + by,
            0, 0, 1,
        };
    }

    @Override
    protected void onDraw(Canvas canvas) {
        if (target < 0) return;
        boolean missed = SystemClock.uptimeMillis() - missedAt < 400;
        float x = TARGETS[target][0] * getWidth(), y = TARGETS[target][1] * getHeight();
        float r = getWidth() / 24f;
        paint.setAlpha(missed ? 90 : 255);
        canvas.drawCircle(x, y, r, paint);
        canvas.drawLine(x - r * 2, y, x - r * 0.4f, y, paint);
        canvas.drawLine(x + r * 0.4f, y, x + r * 2, y, paint);
        canvas.drawLine(x, y - r * 2, x, y - r * 0.4f, paint);
        canvas.drawLine(x, y + r * 0.4f, x, y + r * 2, paint);
    }
}
