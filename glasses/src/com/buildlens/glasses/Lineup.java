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
 * of its picture is not in the middle of what the wearer sees. Lining up fixes that, in one
 * click: a circle is shown in the middle of the display, the wearer looks so that the
 * phone's marker sits in it and clicks. Where the camera saw the marker then gives the
 * shift; the size comes from the display's assumed width of view (DISPLAY_F), and the
 * wearer can grow or shrink it afterwards with swipes while the marker's outline shows
 * (adjustSize). Two clicks at two places were tried first, but nobody could hold the
 * marker in a small circle precisely enough for the size and turn to come out right.
 * It is saved, and done again with every scan of the phone (it is part of scanning).
 *
 * Before any line-up the camera picture is taken to fill the display.
 */
final class Lineup extends View {
    private static final String PREFS = "lineup";
    /** The two crosshairs, as parts of the display's width and height. */
    private static final float[][] TARGETS = {{0.5f, 0.5f}};
    /** The display's focal length in its own pixels: about 17 degrees across 640, as found by
     *  lining up on the M6 (the outline matched the real code at 1.545 x the camera's 1874). Put
     *  right by the wearer with adjustSize(), which is remembered ("displayF2": an older saved
     *  value was mixed up with making the LEGO bigger, and is left behind). */
    private static final float DISPLAY_F = 2895f;

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

    /** Lined up, with a line-up that makes sense (one saved before that was checked may not). */
    boolean linedUp() {
        if (!prefs.contains("ar")) return false;
        float size = (float) Math.hypot(prefs.getFloat("ar", 1), prefs.getFloat("ai", 0));
        return size >= 0.1f && size <= 2.5f;
    }

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
        if (TARGETS.length == 1) {
            float w = getWidth(), h = getHeight();
            float displayF = prefs.getFloat("displayF2", DISPLAY_F);
            save(displayF / lens.fx, centre[0], centre[1], lens.fx, TARGETS[0][0] * w, TARGETS[0][1] * h, w, h);
            end(true);
            return;
        }
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
        // Display pixels per camera pixel can only be about so much: the display covers a
        // narrower view than the camera. Anything far off means a click came too early.
        float size = (float) Math.hypot(ar, ai);
        if (size < 0.1f || size > 2.5f) {
            Log.i(LinkService.TAG, String.format(java.util.Locale.US, "line-up: size %.2f makes no sense; again", size));
            target = 0;
            missedAt = SystemClock.uptimeMillis();
            invalidate();
            return;
        }
        float bx = t1x - (ar * seen[0] - ai * seen[1]), by = t1y - (ai * seen[0] + ar * seen[1]);
        prefs.edit().putFloat("ar", ar).putFloat("ai", ai).putFloat("bx", bx).putFloat("by", by)
                .putInt("camera", seenWidth).putInt("w", (int) w).putInt("h", (int) h).apply();
        Log.i(LinkService.TAG, String.format(java.util.Locale.US, "line-up: done, size %.3f turn %.1f deg shift %.0f,%.0f",
                Math.hypot(ar, ai), Math.toDegrees(Math.atan2(ai, ar)), bx, by));
        end(true);
    }

    /** Saves a line-up of size `size` (display pixels per camera pixel) through one point. */
    private void save(float size, float sx, float sy, float fx, float tx, float ty, float w, float h) {
        float bx = tx - size * sx, by = ty - size * sy;
        prefs.edit().putFloat("ar", size).putFloat("ai", 0).putFloat("bx", bx).putFloat("by", by)
                .putFloat("sx", sx).putFloat("sy", sy).putFloat("tx", tx).putFloat("ty", ty).putFloat("fx", fx)
                .putFloat("displayF2", size * fx)
                .putInt("camera", seenWidth).putInt("w", (int) w).putInt("h", (int) h).apply();
        Log.i(LinkService.TAG, String.format(java.util.Locale.US, "line-up: done, size %.3f, shift %.0f,%.0f", size, bx, by));
    }

    /** A swipe after lining up: the green outline bigger or smaller, around the same middle. */
    void adjustSize(float factor) {
        if (!prefs.contains("sx")) return;
        float size = prefs.getFloat("ar", 1) * factor;
        if (size < 0.1f || size > 2.5f) return;
        seenWidth = prefs.getInt("camera", seenWidth);
        save(size, prefs.getFloat("sx", 0), prefs.getFloat("sy", 0), prefs.getFloat("fx", 1),
                prefs.getFloat("tx", 0), prefs.getFloat("ty", 0), prefs.getInt("w", getWidth()), prefs.getInt("h", getHeight()));
    }

    /** Stops lining up without changing anything. */
    void cancel() {
        if (target >= 0) end(false);
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
