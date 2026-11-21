package com.buildlens.glasses;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseIntArray;
import android.view.GestureDetector;
import android.view.InputDevice;
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

import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * BuildLens on the MicroLumin M6 glasses (Android 9, 640x480, black = see-through).
 *
 * Shows the current building step the way the phone does: the new piece waits just off
 * its place while an arrow bounces towards where it goes, and moving on slots it in before
 * the next piece appears.
 *
 * Controls, on whatever the glasses have (side button, touchpad tap, ring):
 *   one click     next step
 *   two clicks    show this step again from the start
 *   three clicks  back one step
 * Swiping the touchpad forward or back zooms the picture in or out. Every key and touch is logged so
 * unknown buttons can be mapped (see KEYS below): adb logcat -s BuildLens
 *
 * Battery: nothing is rendered here. Every picture was drawn on a computer and is only
 * shown, each one decoded once; the bounce is two pictures swapped by a timer and stops
 * after a while with no input. The phone link lives in LinkService.
 */
public class MainActivity extends Activity implements LinkService.Listener {
    static final String TAG = LinkService.TAG;
    static final int GREEN = Color.rgb(92, 255, 128);

    /** Clicks closer together than this count as one double or triple click. */
    private static final int CLICK_WINDOW_MS = 400;
    private static final int BOUNCE_MS = 450, SEATED_MS = 320, BLINK_MS = 120;
    /** A piece goes in over four pictures this far apart: the same half second as on the phone. */
    private static final int SLOT_MS = 140;
    private static final String[] SLOT = {"-c", "-a", "-d", "-b"};
    /** The arrow stops bouncing after this long without input; any input starts it again. */
    private static final int BOUNCE_FOR_MS = 20_000;
    /** With nothing happening for this long the display is allowed to sleep, to save the battery. */
    private static final int AWAKE_FOR_MS = 5 * 60_000;

    private final Handler main = new Handler(Looper.getMainLooper());
    private JSONArray steps;
    private String setName = "";

    private int shownStep = -1;             // what the display shows now (-1 = nothing yet)
    private boolean shownFinished = false;
    private int shownView = 0;              // the side the shown step is seen from
    private boolean shownMilestone = false; // the "good job" text is up
    private static final int TURN_MS = 90, GOOD_JOB_MS = 2000;
    private int animation = 0;              // bumped on every change so stale timers do nothing
    private Bitmap waitFrame, pressedFrame; // the two pictures of the current step's bounce
    private int framesFor = -1;             // which step those two pictures belong to
    private int seatedStep = -1;            // the step whose piece is shown already in place
    private boolean settling;               // a step change is still playing; don't interrupt it
    private long bounceUntil;
    private boolean bouncing;
    private int clicks;

    private ImageView frame;
    private ConfettiView confetti;
    private int finishFrames;               // pictures of the finished truck turning round
    private TextView header, sub, parts, status;
    private GestureDetector gestures;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        LinkService.start(this);
        loadSteps();
        buildUi();
        gestures = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            // Without this the view is only ever sent the first touch and no tap or swipe is seen.
            @Override public boolean onDown(MotionEvent e) { return true; }
            @Override public boolean onSingleTapUp(MotionEvent e) { click(); return true; }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                if (!directStepAllowed()) return true;
                boolean forward = Math.abs(vx) > Math.abs(vy) ? vx < 0 : vy < 0;
                zoom(forward);
                return true;
            }
        });
        logInputDevices();
    }

    @Override
    protected void onResume() {
        super.onResume();
        LinkService.setListener(this);
        show();
    }

    @Override
    protected void onPause() {
        LinkService.setListener(null);
        animation++;                        // stop every timer while nothing is visible
        bouncing = false;
        settling = false;
        shownStep = -1;                     // coming back draws the step afresh
        seatedStep = -1;
        main.removeCallbacks(resolveClicks);
        main.removeCallbacks(allowSleep);
        clicks = 0;
        super.onPause();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
    }

    // ------------------------------------------------------------ phone link
    @Override
    public void onRemoteStep(boolean replay) {
        if (replay) replayStep(); else show();
    }

    @Override
    public void onLinkChanged() {
        status.setText(LinkService.phoneLinked() ? "phone: linked" : "phone: not linked");
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
            finishFrames = root.optInt("finish", 0);
        } catch (Exception e) {
            Log.e(TAG, "steps.json", e);
            steps = new JSONArray();
        }
    }

    /** A picture of a step: from side `view`, in state "" (waiting), "-w", "-a" or "-b". */
    private String frameOf(int index, int view, String state) throws Exception {
        return steps.getJSONObject(index).getString("frame") + "-q" + view + state + ".png";
    }

    /** Frame n (1-based) of step `index` turning towards the next step's side. */
    private String turnOf(int index, int n) throws Exception {
        return steps.getJSONObject(index).getString("frame") + "-r" + n + ".png";
    }

    /** The side a step is seen from: where the phone was turned to, else the step's own. */
    private int viewOf(int index) {
        if (LinkService.view >= 0 && LinkService.view <= 3) return LinkService.view;
        return steps.optJSONObject(index) == null ? 0 : steps.optJSONObject(index).optInt("view", 0);
    }

    private Bitmap load(String asset) {
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inPreferredConfig = Bitmap.Config.RGB_565;     // half the memory; the display is one colour
        try (InputStream in = getAssets().open(asset)) {
            return BitmapFactory.decodeStream(in, null, options);
        } catch (Exception e) {
            Log.e(TAG, "frame " + asset, e);
            return null;
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
        confetti = new ConfettiView(this);
        root.addView(confetti, new FrameLayout.LayoutParams(-1, -1));
        root.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        root.setOnTouchListener((v, e) -> {
            if (e.getActionMasked() != MotionEvent.ACTION_MOVE) {
                Log.i(TAG, "touch " + MotionEvent.actionToString(e.getAction()) + " source 0x"
                        + Integer.toHexString(e.getSource()) + " at " + e.getX() + "," + e.getY());
            }
            return gestures.onTouchEvent(e);
        });
        setContentView(root);
    }

    /** Brings the display in line with the current step. Only a real change animates. */
    private void show() {
        int count = steps.length();
        if (count == 0) { header.setText("NO STEPS"); return; }
        int step = Math.max(0, Math.min(LinkService.step, count - 1));
        boolean finished = LinkService.finished;
        boolean milestone = LinkService.milestone && !finished;
        int view = viewOf(step);
        LinkService.step = step;
        onLinkChanged();
        if (step == shownStep && finished == shownFinished && view == shownView && milestone == shownMilestone) { wake(); return; }
        stayAwake();
        confetti.stop();
        try {
            if (finished) {
                // The piece clicks in first, at its own pace; only then "done" and the spin.
                final int run = ++animation;
                final int seenFrom = step == shownStep ? shownView : view;
                bouncing = false;
                settling = false;
                int seated = slotIn(step, seenFrom, run);
                main.postDelayed(() -> {
                    if (run != animation) return;
                    header.setText("DONE \u2713");
                    sub.setText(setName.toUpperCase());
                    parts.setText("");
                    playSpin(step, seenFrom, run);
                }, seated);
            } else if (milestone) {
                final int run = ++animation;
                bouncing = false;
                settling = false;
                int seated = slotIn(step, step == shownStep ? shownView : view, run);
                main.postDelayed(() -> { if (run == animation) showGoodJob(step); }, seated);
            } else {
                // Leaving the last step of a part of the build by a click on the glasses:
                // the piece clicks in, then the "good job", then the new step.
                boolean forward = shownStep >= 0 && step == shownStep + 1 && !shownFinished;
                if (forward && !shownMilestone && steps.getJSONObject(shownStep).optJSONArray("done") != null) {
                    final int run = ++animation;
                    final int from = shownStep;
                    settling = true;
                    bouncing = false;
                    int seated = slotIn(from, shownView, run);
                    main.postDelayed(() -> { if (run == animation) showGoodJob(from); }, seated);
                    main.postDelayed(() -> { if (run == animation) { shownMilestone = false; shownStep = -1; show(); } }, seated + GOOD_JOB_MS);
                    shownMilestone = true;
                    return;
                }
                JSONObject s = steps.getJSONObject(step);
                header.setText("STEP " + (step + 1) + "/" + count);
                String section = s.optString("sub");
                sub.setText(section.isEmpty() ? "MAIN BUILD" : section);
                JSONArray lines = s.getJSONArray("parts");
                StringBuilder b = new StringBuilder();
                for (int i = 0; i < lines.length() && i < 4; i++) b.append(lines.getString(i)).append('\n');
                if (lines.length() > 4) b.append("+").append(lines.length() - 4).append(" MORE\n");
                parts.setText(b.toString().trim());
                // A step forward slots the last piece in first, unless the "good job" already did.
                playStep(step, view, forward);
            }
        } catch (Exception e) {
            Log.e(TAG, "show", e);
        }
        shownStep = step;
        shownFinished = finished;
        shownView = view;
        shownMilestone = milestone;
    }

    /** The same words as the phone's card, in the glasses' own type. */
    private void showGoodJob(int step) {
        JSONObject info = steps.optJSONObject(step);
        JSONArray done = info == null ? null : info.optJSONArray("done");
        header.setText(done == null ? "GOOD JOB!" : done.optString(0));
        sub.setText(done == null ? "" : done.optString(1));
        parts.setText("");
    }

    private void setFrame(int step, int view, String state) {
        try { frame.setImageBitmap(load(frameOf(step, view, state))); } catch (Exception e) { Log.e(TAG, "frame", e); }
    }

    // ------------------------------------------------------------ pictures
    /**
     * The new piece waits off its place while the arrow bounces. Coming from the step
     * before, that step's piece first slots in (part-way, then seated), and where the new
     * step is seen from another side the finished step turns round to it.
     */
    private void playStep(final int step, final int view, boolean slotInPrevious) throws Exception {
        final int run = ++animation;
        int delay = 0;
        bouncing = false;
        settling = true;
        if (slotInPrevious) {
            final int before = step - 1, beforeView = shownView;
            delay = slotIn(before, beforeView, run);
            if (delay > 0) delay += SEATED_MS - SLOT_MS;
            // Turning frames exist for the step's own side going to the next step's own side.
            JSONObject b = steps.getJSONObject(before);
            int turns = b.optInt("turns", 0);
            if (turns > 0 && beforeView == b.optInt("view", 0) && view == steps.getJSONObject(step).optInt("view", 0)) {
                for (int n = 1; n <= turns; n++) {
                    final String turn = turnOf(before, n);
                    main.postDelayed(() -> { if (run == animation) frame.setImageBitmap(load(turn)); }, delay);
                    delay += TURN_MS;
                }
            }
        }
        final String asset = frameOf(step, view, ""), pressedAsset = frameOf(step, view, "-w");
        main.postDelayed(() -> {
            if (run != animation) return;
            seatedStep = -1;
            waitFrame = load(asset);
            pressedFrame = load(pressedAsset);
            framesFor = step * 4 + view;
            startBounce(run);
        }, delay);
    }

    /**
     * The waiting piece goes into its place, picture by picture, and stays there. Returns
     * how long that takes (nothing, if this step's piece is already shown in place).
     */
    private int slotIn(final int step, final int view, final int run) {
        if (seatedStep == step) { setFrame(step, view, "-b"); return 0; }
        seatedStep = step;
        for (int i = 0; i < SLOT.length; i++) {
            final String state = SLOT[i];
            main.postDelayed(() -> { if (run == animation) setFrame(step, view, state); }, (long) i * SLOT_MS);
        }
        return SLOT.length * SLOT_MS;
    }

    /**
     * The finish, once the last piece is in: the truck spins twice (fast, slowing to a stop
     * where it began) and confetti goes off. Same timing as the phone's glasses preview.
     */
    private void playSpin(final int step, final int view, final int run) {
        if (finishFrames <= 0) return;
        final int total = finishFrames * 2;
        for (int k = 1; k <= total; k++) {
            final int n = (k - 1) % finishFrames + 1;
            long at = (long) (2800 * (1 - Math.pow(1 - k / (double) total, 0.25)));
            main.postDelayed(() -> {
                if (run == animation) frame.setImageBitmap(load(String.format(java.util.Locale.US, "hud/hud-finish-%02d.png", n)));
            }, at);
        }
        main.postDelayed(() -> {
            if (run != animation) return;
            setFrame(step, view, "-b");
            confetti.burst();
        }, 2850);
    }

    /** Confetti in the display's one colour: a burst up from the bottom that falls away. */
    private static class ConfettiView extends View {
        private static final float DURATION = 2.6f;
        private final Paint paint = new Paint();
        private long started = -1;

        ConfettiView(Context context) {
            super(context);
            paint.setColor(GREEN);
        }

        void burst() {
            started = SystemClock.uptimeMillis();
            invalidate();
        }

        void stop() {
            started = -1;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (started < 0) return;
            float t = (SystemClock.uptimeMillis() - started) / 1000f;
            if (t >= DURATION) { started = -1; return; }
            float unit = getWidth() / 640f;
            paint.setAlpha((int) (255 * Math.min(1f, (DURATION - t) * 2)));
            long seed = 42;
            double[] r = new double[6];
            for (int i = 0; i < 70; i++) {
                for (int j = 0; j < 6; j++) {
                    seed = seed * 6364136223846793005L + 1442695040888963407L;
                    r[j] = (seed >>> 33) / (double) (1L << 31);
                }
                double x0 = 320 + (r[0] - 0.5) * 120, vx = (r[1] - 0.5) * 520;
                double vy = -(420 + r[2] * 420), spin = r[3] * 12, w = 6 + r[4] * 8;
                double x = x0 + vx * t, y = 500 + vy * t + 520 * t * t;
                double squash = Math.abs(Math.cos(spin * t));
                float h = (float) Math.max(1.5, w * squash);
                canvas.drawRect((float) (x - w / 2) * unit, (float) (y - h / 2) * unit,
                        (float) (x + w / 2) * unit, (float) (y + h / 2) * unit, paint);
            }
            postInvalidateOnAnimation();
        }
    }

    /** Two clicks: the step again from the start, with a short blank so it reads as a restart. */
    private void replayStep() {
        stayAwake();
        // Anything out of line with what should be showing: draw the step afresh instead.
        if (LinkService.finished != shownFinished || LinkService.step != shownStep || framesFor != shownStep * 4 + shownView) {
            shownStep = -1;
            shownFinished = false;
            show();
            return;
        }
        if (LinkService.finished) return;
        final int run = ++animation;
        bouncing = false;
        settling = true;
        frame.setImageBitmap(null);
        main.postDelayed(() -> { if (run == animation) startBounce(run); }, BLINK_MS);
    }

    private void startBounce(int run) {
        bounceUntil = SystemClock.uptimeMillis() + BOUNCE_FOR_MS;
        bouncing = true;
        settling = false;
        bounce(run, false);
    }

    private void bounce(final int run, final boolean pressed) {
        if (run != animation) return;
        if (SystemClock.uptimeMillis() > bounceUntil) {     // idle: leave the still picture up
            frame.setImageBitmap(waitFrame);
            bouncing = false;
            return;
        }
        frame.setImageBitmap(pressed ? pressedFrame : waitFrame);
        main.postDelayed(() -> bounce(run, !pressed), BOUNCE_MS);
    }

    private final Runnable allowSleep = () -> getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

    /** The display stays on while someone is building, and may sleep once they have stopped. */
    private void stayAwake() {
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        main.removeCallbacks(allowSleep);
        main.postDelayed(allowSleep, AWAKE_FOR_MS);
    }

    /** Any input brings a stopped bounce back. */
    private void wake() {
        stayAwake();
        if (LinkService.finished || settling || shownMilestone || framesFor != shownStep * 4 + shownView) return;
        if (bouncing) bounceUntil = SystemClock.uptimeMillis() + BOUNCE_FOR_MS;
        else startBounce(++animation);
    }

    // ------------------------------------------------------------ zoom
    /** The picture can be enlarged in place; the text stays the same size. */
    private static final float[] ZOOMS = {1f, 1.5f, 2.2f, 3.2f};
    private int zoomLevel = 0;

    /** Swipe forward to zoom in, back to zoom out. It keeps its level from step to step. */
    private void zoom(boolean in) {
        zoomLevel = Math.max(0, Math.min(ZOOMS.length - 1, zoomLevel + (in ? 1 : -1)));
        frame.animate().scaleX(ZOOMS[zoomLevel]).scaleY(ZOOMS[zoomLevel]).setDuration(180).start();
        wake();
    }

    // ------------------------------------------------------------ actions
    private void next() {
        if (LinkService.finished) return;
        LinkService.view = -1;
        LinkService.milestone = false;
        if (LinkService.step + 1 < steps.length()) LinkService.step++; else LinkService.finished = true;
        show();
        LinkService.send(false);
    }

    private void back() {
        LinkService.view = -1;
        LinkService.milestone = false;
        if (LinkService.finished) LinkService.finished = false;
        else if (LinkService.step > 0) LinkService.step--;
        else { wake(); return; }
        show();
        LinkService.send(false);
    }

    private void replay() {
        replayStep();
        LinkService.send(true);
    }

    // ------------------------------------------------------------ input
    private final Runnable resolveClicks = () -> {
        int n = clicks;
        clicks = 0;
        if (n == 1) next(); else if (n == 2) replay(); else if (n >= 3) back();
    };

    /** One press of the main button or a tap. Waits a moment to see if more follow. */
    private void click() {
        clicks++;
        main.removeCallbacks(resolveClicks);
        if (clicks >= 3) resolveClicks.run();
        else main.postDelayed(resolveClicks, CLICK_WINDOW_MS);
    }

    // What each key does. Nothing public documents the M6's key codes, so this follows what
    // similar glasses send (tap = centre/enter, swipes = left/right) and is the one place to
    // edit once `adb logcat -s BuildLens` shows what the real buttons send.
    private static final int CLICK = 1, NEXT = 2, BACK = 3, ZOOM_IN = 4, ZOOM_OUT = 5;
    private static final SparseIntArray KEYS = new SparseIntArray();
    static {
        for (int code : new int[] {KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER,
                KeyEvent.KEYCODE_SPACE, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_CAMERA}) KEYS.put(code, CLICK);
        // A swipe on the touchpad (arrow keys on most glasses) zooms the picture; steps are clicks.
        for (int code : new int[] {KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_ZOOM_IN, KeyEvent.KEYCODE_VOLUME_UP}) KEYS.put(code, ZOOM_IN);
        for (int code : new int[] {KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_UP,
                KeyEvent.KEYCODE_ZOOM_OUT, KeyEvent.KEYCODE_VOLUME_DOWN}) KEYS.put(code, ZOOM_OUT);
        for (int code : new int[] {KeyEvent.KEYCODE_PAGE_DOWN, KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_TAB}) KEYS.put(code, NEXT);
        for (int code : new int[] {KeyEvent.KEYCODE_PAGE_UP, KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_DEL}) KEYS.put(code, BACK);
    }
    /** A swipe on a touchpad often arrives as a burst of arrow keys: one step per burst. */
    private static final int STEP_EVERY_MS = 300;
    private long lastDirectStep;

    private boolean directStepAllowed() {
        long now = SystemClock.uptimeMillis();
        if (now - lastDirectStep < STEP_EVERY_MS) return false;
        lastDirectStep = now;
        return true;
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
        int code = e.getKeyCode();
        Log.i(TAG, "key " + (e.getAction() == KeyEvent.ACTION_DOWN ? "down " : "up ") + KeyEvent.keyCodeToString(code)
                + " scan " + e.getScanCode() + " repeat " + e.getRepeatCount() + " flags 0x" + Integer.toHexString(e.getFlags())
                + " source 0x" + Integer.toHexString(e.getSource()) + " held " + (e.getEventTime() - e.getDownTime()) + "ms"
                + " device " + (e.getDevice() == null ? "?" : e.getDevice().getName()));
        int action = KEYS.get(code);
        // Some glasses send their double tap as a Back key. Use it to go back a step while
        // there is one to go back to; on step 1 it leaves the app as usual.
        if (code == KeyEvent.KEYCODE_BACK && (LinkService.step > 0 || LinkService.finished)) action = BACK;
        if (action == 0) return super.dispatchKeyEvent(e);
        // Clicks count when the key comes up, so a held key is one click; arrows act on the way down.
        if (action == CLICK) {
            if (e.getAction() == KeyEvent.ACTION_UP && !e.isCanceled()) click();
        } else if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0 && directStepAllowed()) {
            if (action == NEXT) next(); else if (action == BACK) back(); else zoom(action == ZOOM_IN);
        }
        return true;
    }

    private void logInputDevices() {
        for (int id : InputDevice.getDeviceIds()) {
            InputDevice d = InputDevice.getDevice(id);
            if (d != null) Log.i(TAG, "input device " + d.getName() + " sources 0x" + Integer.toHexString(d.getSources())
                    + " keyboard " + d.getKeyboardType());
        }
    }

    @Override
    public boolean onTrackballEvent(MotionEvent e) {
        return gestures.onTouchEvent(e) || super.onTrackballEvent(e);
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent e) {
        if (e.getActionMasked() != MotionEvent.ACTION_MOVE && e.getActionMasked() != MotionEvent.ACTION_HOVER_MOVE)
            Log.i(TAG, "motion " + MotionEvent.actionToString(e.getAction()) + " source 0x" + Integer.toHexString(e.getSource())
                + " at " + e.getX() + "," + e.getY());
        return gestures.onTouchEvent(e) || super.onGenericMotionEvent(e);
    }
}
