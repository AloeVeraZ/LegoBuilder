package com.buildlens.glasses;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.MediaPlayer;
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
 *   two clicks    back one step (the M6 touchpad sends its double tap as F12)
 *   three clicks   flicks zoom instead of turning (back by themselves after 5 s); hold: the menu
 * Swiping the touchpad forward or back zooms the picture in or out. In the menu a swipe
 * moves up and down, one click switches the item on or off (or does it), and two clicks
 * go back to the LEGO. Every key and touch is logged so unknown buttons can be mapped
 * (see KEYS below): adb logcat -s BuildLens
 *
 * Battery: the step pictures were drawn on a computer and are only shown, each one decoded
 * once; the bounce is two pictures swapped by a timer and stops after a while with no
 * input. The phone link lives in LinkService.
 *
 * The ghost: when the camera sees the marker on the phone lying on the table, the step
 * pictures give way to the step's pieces drawn in green right where they go on the real
 * build (GhostView), and come back when the marker is out of sight. Lining the camera up
 * with the eye is done once (Lineup), started from the computer by setup.sh.
 */
public class MainActivity extends Activity implements LinkService.Listener, CameraFeed.Listener {
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

    private LinearLayout overlay;
    private GhostModel ghostModel;
    private GhostView ghost;
    private Lineup lineup;
    private CameraFeed camera;
    private HeadTracker head;
    private long lastHeldLog;
    /** The wearer's size for the LEGO (swipes while building), remembered. */
    private float legoSize = 1f;
    /** Stands in for a pose while the ghost is held in place by the head tracker. */
    private static final float[] HELD = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0.5f, 1};
    private boolean ghostOn;
    private float[] markerCentre;           // where the camera last saw the marker's middle
    private CameraFeed.Lens lens;
    /** A still picture to look at instead of the camera (for trying it on the emulator). */
    private String testPicture;
    /** After lining up, the marker's outline is shown for a while so the fit can be checked. */
    private long showMarkerUntil;

    // What is up: the set (start), looking for the phone's code, or building.
    private static final int HOME = 0, SCAN = 1, BUILD = 2, BOX = 3;
    /** The set's box barcode (printed 6 73419 42442 4), in EAN-13 form: as BuildConfig.boxBarcodes on the phone. */
    private static final String BOX_CODE = "0673419424424";
    private TextView boxLabel;
    private int screen = HOME;
    private LinearLayout home;
    private TextView scanLabel;
    private int setPieces, setMinutes;
    private String setId = "";

    // The menu (hold, or three clicks). The switches are kept between launches, as on the phone.
    // The two switches first (as on the phone's ••• menu), then scanning the phone again.
    // As simple as can be: settings are made on the phone, the glasses show the build.
    // The same settings as the phone app's ••• menu (kept the same on both: a change on
    // either goes to the other), then the two things to do. No start over on the glasses.
    private static final String[] MENU = {"FADE BUILT PIECES", "READ STEPS ALOUD", "VOICE", "SCAN PHONE AGAIN", "REPLAY STEP"};
    private static final int M_FADE = 0, M_ALOUD = 1, M_VOICE = 2, LINE_UP = 3, REPLAY = 4, START_OVER = -1;
    /** The menu's first entries that are settings. */
    private static final int MENU_SWITCHES = 3;
    /** The voices, as on the phone (AppModel.voices): name and file prefix. */
    private static final String[][] VOICES = {{"HEART", ""}, {"ONYX", "onyx-"}};
    private boolean fadeBuilt = true;
    /** How bright the pieces already built are, faded or not (the new ones are at full). A
     *  see-through display loses anything dim against the room, so even faded stays visible. */
    private static final float BUILT_FADED = 0.4f, BUILT_SHOWN = 0.7f;
    private static final int BUILT = 0, ALOUD = 1;
    private final boolean[] switches = {true, false};
    private static final String[] SWITCH_KEYS = {"showBuiltPieces", "readStepsAloud"};
    private SharedPreferences prefs;
    private LinearLayout menu;
    private TextView[] menuRows;
    private boolean menuOpen;
    private int menuAt;
    private MediaPlayer voice;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        // The display's brightness is left to the system: forcing it to full (255) blanked the
        // M6's display while it was hot. The LEGO is drawn brighter instead (GhostView).
        LinkService.start(this);
        loadSteps();
        ghostModel = GhostModel.load(getAssets());
        prefs = getSharedPreferences("buildlens", MODE_PRIVATE);
        // If the app was killed while it had the click sound muted, it still owes the unmute.
        mutedClicks = prefs.getBoolean("mutedClicks", false);
        // The settings are the phone's now: built pieces shown (faded as the phone says), and
        // reading aloud off until the phone says otherwise (onSettings). With glasses linked
        // they read through their own speaker and the phone is quiet; a phone on its own reads.
        switches[BUILT] = true;
        switches[ALOUD] = false;
        buildUi();
        ghost.setShowBuilt(switches[BUILT]);
        legoSize = prefs.getFloat("legoSize", 1f);
        ghost.setSizeFactor(legoSize);
        camera = new CameraFeed(this, this);
        head = new HeadTracker(this);
        ghost.setHead(head.works() ? head : null);
        LiveFeed.start();
        gestures = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            // Without this the view is only ever sent the first touch and no tap or swipe is seen.
            @Override public boolean onDown(MotionEvent e) { return true; }
            @Override public boolean onSingleTapUp(MotionEvent e) { click(); return true; }
            @Override public boolean onFling(MotionEvent a, MotionEvent b, float vx, float vy) {
                if (!directStepAllowed()) return true;
                boolean forward = Math.abs(vx) > Math.abs(vy) ? vx < 0 : vy < 0;
                if (menuOpen) moveMenu(forward); else zoom(forward);
                return true;
            }
        });
        logInputDevices();
        getExternalFilesDir(null);          // makes the app's own folder, for test pictures
        showScreen(HOME);
        readIntent(getIntent());
        // First the set's box, then the phone's code.
        if (!lineup.active()) startBox();
    }

    /**
     * Extras from setup.sh / adb:  --ez lineup true  starts lining up the camera with the eye;
     * --es picture /sdcard/x.png  looks at that picture instead of the camera.
     */
    private void readIntent(Intent intent) {
        if (intent == null) return;
        if (intent.hasExtra("picture")) {
            // A plain name is looked for in the app's own folder, which needs no permission:
            // adb push x.png /sdcard/Android/data/com.buildlens.glasses/files/
            String name = intent.getStringExtra("picture");
            java.io.File folder = getExternalFilesDir(null);
            testPicture = name == null || name.isEmpty() || name.equals("camera") ? null       // back to the camera
                    : name.startsWith("/") || folder == null ? name : new java.io.File(folder, name).getPath();
        }
        if (intent.getBooleanExtra("snapshot", false)) {
            intent.removeExtra("snapshot");
            CameraFeed.snapshot = true;
        }
        if (intent.getBooleanExtra("lineup", false)) {
            intent.removeExtra("lineup");
            startLineup();
        }
    }

    /**
     * Scanning the phone: a circle in the middle; the wearer looks so the code on the phone
     * sits in it and clicks. That finds the phone and lines the camera up with this
     * wearer's eye in one go, then the build starts with the next piece on the table.
     * From the start screen, the menu, or setup.sh.
     */
    private void startLineup() {
        closeMenu();
        setGhost(false);
        ghost.clearAnchor();                 // a new scan: placed afresh
        hush();
        showScreen(SCAN);
        LinkService.askForMarker(true);
        lineup.begin(linedUp -> {
            LinkService.askForMarker(false);
            // No tap for a while: keep waiting on the scan (no dead end on a start screen).
            if (!linedUp) { startLineup(); return; }
            showScreen(BUILD);
            shownStep = -1;
            show();
            LinkService.announcePlaced();          // the phone puts its code away and opens the steps
            // The code's outline shows on the real one for a while; swipes grow or shrink it.
            showMarkerUntil = SystemClock.uptimeMillis() + OUTLINE_MS;
            // For setup.sh, which can read this folder: the glasses are lined up.
            java.io.File folder = getExternalFilesDir(null);
            if (folder != null) {
                try (java.io.FileOutputStream out = new java.io.FileOutputStream(new java.io.File(folder, "lined-up"))) {
                    out.write("yes\n".getBytes(StandardCharsets.UTF_8));
                } catch (Exception e) {
                    Log.w(TAG, "lined-up file", e);
                }
            }
        });
    }

    private static final int OUTLINE_MS = 12_000;
    /** Logs a line for every sight of the code, for tools/axes.py. Off: it is about 15 lines a second. */
    private static final boolean LOG_AXES = false;

    /** The start: look at the set's box (its barcode) with the glasses' camera. */
    private void startBox() {
        closeMenu();
        // The phone leads at the start: it scans the box and tells the glasses (they also try
        // with their own camera, in case the box is held up to them).
        boxLabel.setText("SCAN THE " + setName.toUpperCase() + " BOX WITH YOUR PHONE");
        showScreen(BOX);
    }

    /** Turned or zoomed on the phone or Mac: the same here (not sent back). */
    @Override
    public void onRemoteView(float turned, float zoom, float tilt) {
        Log.i(TAG, String.format(java.util.Locale.US, "remote view: spin %.0f, zoom %.2f, tilt %.0f", turned, zoom, tilt));
        // Exactly as the phone shows it, as it moves: no glide of our own on top.
        main.removeCallbacks(followRun);
        spin = ((turned % 360) + 360) % 360;
        if (zoom > 0) legoSize = Math.max(GhostView.MIN_SIZE, Math.min(GhostView.MAX_SIZE, zoom));
        ghost.follow(spin, zoom > 0 ? legoSize : -1, tilt);
        main.removeCallbacks(saveSize);
        main.postDelayed(saveSize, 1000);
    }

    private final Runnable saveSize = () -> prefs.edit().putFloat("legoSize", legoSize).apply();

    /** The phone's settings. */
    private String voicePrefix = "";

    @Override
    public void onSettings(boolean fade, String voice, boolean aloud) {
        Log.i(TAG, "settings from the phone: fade " + fade + ", voice '" + voice + "', aloud " + aloud);
        fadeBuilt = fade;
        ghost.setBuiltFaint(fade ? BUILT_FADED : BUILT_SHOWN);
        if (menuOpen) drawMenu();
        boolean changed = !voicePrefix.equals(voice == null ? "" : voice) || switches[ALOUD] != aloud;
        voicePrefix = voice == null ? "" : voice;
        // Read aloud through the glasses' own speaker, as the phone is set (the phone is quiet).
        switches[ALOUD] = aloud;
        if (changed && aloud && screen == BUILD && !menuOpen) say(String.format(java.util.Locale.US, "step-%03d", LinkService.step + 1));
        if (!aloud) hush();
    }

    @Override
    public void onBoxScanned() {
        Log.i(TAG, "box: scanned on the phone or Mac");
        onBox(BOX_CODE);
    }

    @Override
    public void onBox(String code) {
        if (screen != BOX || !CameraFeed.lookForBox) return;   // once: the phone's code and the link can both say so
        if (!BOX_CODE.equals(code) && !CameraFeed.PHONE_MARKER.equals(code)) { Log.i(TAG, "box: " + code + " is another set"); return; }
        Log.i(TAG, "box: set found");
        LinkService.announceBox();             // the Mac (and through it the phone) move on too
        CameraFeed.lookForBox = false;
        boxLabel.setText("SET " + setId + " FOUND \u2713");
        main.postDelayed(() -> { if (screen == BOX) startLineup(); }, 900);
    }

    // ------------------------------------------------------------ turning the model
    /**
     * What a swipe does while building: zoom (the LEGO bigger or smaller) or spin (turn it).
     * The M6 touchpad sends the same keys for one finger and two, so a triple tap switches.
     */
    private boolean swipeSpins;
    private TextView modeLabel;

    private void toggleSwipe() {
        if (screen != BUILD) { openMenu(); return; }
        swipeSpins = !swipeSpins;
        modeLabel.setText(swipeSpins ? "ZOOM" : "TURN");
        modeLabel.setVisibility(View.VISIBLE);
        main.removeCallbacks(hideMode);
        main.postDelayed(hideMode, 1500);
        main.removeCallbacks(backToTurn);
        if (swipeSpins) main.postDelayed(backToTurn, ZOOM_IDLE_MS);
        Log.i(TAG, "swipe: " + (swipeSpins ? "zoom" : "turn"));
    }

    private final Runnable hideMode = () -> modeLabel.setVisibility(View.GONE);

    /** Zooming goes back to turning by itself after a moment without a flick. */
    private static final int ZOOM_IDLE_MS = 5000;
    private final Runnable backToTurn = () -> { if (swipeSpins) toggleSwipe(); };

    /** Drawing an O on the touchpad: the LEGO bigger; a C: smaller. Remembered, and shared. */
    private long lastZoom;
    private boolean lastZoomBigger;
    private int zoomRun;

    private void resize(boolean bigger) {
        if (screen != BUILD || !ghostOn) return;
        // Three times what it was per flick (1.2 cubed), and more with each flick the same
        // way in a row, like a trackpad speeding up.
        // A push that carries on and slows; flicks in a row add up, like a trackpad. It stops
        // at the smallest (GhostView.MIN_SIZE) and the closest (MAX_SIZE).
        ghost.pushZoom(bigger ? ZOOM_PUSH : -ZOOM_PUSH);
        followMotion();
        Log.i(TAG, String.format(java.util.Locale.US, "ghost: %s, %.2f x", bigger ? "bigger" : "smaller", legoSize));
    }

    /**
     * The side the app shows each step from (BuildModel.viewYaws on the phone: 0.65 rad either
     * side of the front, or of the back), as the LEGO's turn here. A new step turns the LEGO
     * to it, gliding, as the app's camera does; swipes turn it from there.
     */
    private static final float[] SIDE_SPIN = {-37.24f, 37.24f, -142.76f, 142.76f};

    private void turnToStepSide(int step) {
        JSONObject s = steps.optJSONObject(step);
        int side = s == null ? 0 : Math.max(0, Math.min(3, s.optInt("view", 0)));
        spin = ((SIDE_SPIN[side] % 360) + 360) % 360;
        ghost.setSpin(spin);
    }

    /** How far the wearer has spun the model, in degrees. */
    private float spin;
    private static final float SPIN_STEP = 90f;
    /** Degrees a second a flick adds; with FRICTION 3 it carries about SPIN_STEP in all. */
    private static final float SPIN_PUSH = SPIN_STEP * GhostView.FRICTION;
    /** The same for zoom: one flick zooms about 1.7 times (3 x the old 1.2 a flick). */
    private static final float ZOOM_PUSH = (float) Math.log(1.728) * GhostView.FRICTION;

    /** While the LEGO moves, its turn and zoom go to the phone and Mac, and are kept. */
    private final Runnable followRun = new Runnable() {
        @Override public void run() {
            spin = ghost.spin();
            legoSize = ghost.size();
            LinkService.sendView(spin, legoSize, ghost.tilt());
            // (Its motion only runs down while it is drawn: not behind the menu, at the finish or paused.)
            if (ghost.moving() && ghostOn && resumed) main.postDelayed(this, 33);
            else prefs.edit().putFloat("legoSize", legoSize).apply();
        }
    };

    private void followMotion() {
        main.removeCallbacks(followRun);
        main.postDelayed(followRun, 33);
    }

    /** Spins the green LEGO about its upright; the step picture follows the nearest side. */
    private void rotate(boolean forward) {
        if (screen != BUILD) return;
        // A push that carries on and slows: about a quarter turn for one flick, more for
        // flicks in a row (they add up), like a trackpad.
        ghost.pushSpin(forward ? SPIN_PUSH : -SPIN_PUSH);
        followMotion();
        // (The step picture is hidden while the LEGO shows, so its side is left alone.)
        Log.i(TAG, "turned: " + (int) spin + " degrees");
    }

    /** Shows one of the three screens. */
    private void showScreen(int which) {
        screen = which;
        boolean wasBox = CameraFeed.lookForBox;
        CameraFeed.lookForBox = which == BOX;
        // The box screen wants the camera's bigger picture; the rest the quicker one.
        int width = which == BOX ? CameraFeed.BOX_WIDTH : 2048;
        // (The exposure is set when the camera starts: normal for the printed box, darker for the lit code.)
        if (CameraFeed.maxWidth != width || wasBox != CameraFeed.lookForBox) {
            CameraFeed.maxWidth = width;
            if (resumed) startCamera();
        }
        boxLabel.setVisibility(which == BOX ? View.VISIBLE : View.GONE);
        home.setVisibility(which == HOME ? View.VISIBLE : View.GONE);
        scanLabel.setVisibility(which == SCAN ? View.VISIBLE : View.GONE);
        frame.setVisibility(which == BUILD ? View.VISIBLE : View.GONE);
        overlay.setVisibility(which == BUILD ? View.VISIBLE : View.INVISIBLE);
        if (which != BUILD) setGhost(false);
        Log.i(TAG, "screen: " + (which == HOME ? "start" : which == SCAN ? "scan" : which == BOX ? "box" : "build"));
    }

    private boolean resumed;

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        LinkService.setListener(this);
        // What the phone said while this screen was away.
        if (LinkService.haveSettings) onSettings(LinkService.settingsFade, LinkService.settingsVoice, LinkService.settingsAloud);
        if (LinkService.boxWaiting) { LinkService.boxWaiting = false; onBoxScanned(); }
        quietClicks(true);
        head.start();
        show();
        ghost.onResume();
        startCamera();
    }

    private boolean askedCamera;

    private void startCamera() {
        if (testPicture != null) { camera.stop(); camera.startPicture(testPicture); return; }
        if (checkSelfPermission(android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) camera.start();
        else if (!askedCamera) { askedCamera = true; requestPermissions(new String[] {android.Manifest.permission.CAMERA}, 1); }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) camera.start();
        else Log.w(TAG, "no camera permission: the ghost stays off (setup.sh grants it)");
    }

    @Override
    protected void onPause() {
        LinkService.setListener(null);
        camera.stop();
        setGhost(false);
        ghost.onPause();
        animation++;                        // stop every timer while nothing is visible
        bouncing = false;
        settling = false;
        shownStep = -1;                     // coming back draws the step afresh
        seatedStep = -1;
        main.removeCallbacks(resolveClicks);
        main.removeCallbacks(endGesture);
        main.removeCallbacks(followRun);
        main.removeCallbacks(allowSleep);
        clicks = 0;
        sawDoubleTap = false;
        hush();
        quietClicks(false);
        head.stop();
        resumed = false;
        super.onPause();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        readIntent(intent);                  // onResume follows and starts the camera or picture
    }

    // ------------------------------------------------------------ the ghost
    @Override
    public void onMarker(float[] pose, float[] centre, CameraFeed.Lens lens, long time) {
        markerCentre = centre;
        this.lens = lens;
        // Each sight of the code while building puts the kept place right. After that the
        // ghost stays on the table, following the head, whether the code is seen or not.
        if (pose != null && screen == BUILD && lineup.linedUp()) {
            float[] at = head.cameraToRefAt(time);
            // How well the head tracker kept it (shows up wrong axes or drift): logged now and then.
            float[] guess = ghost.predicted(at);
            long now = SystemClock.uptimeMillis();
            if (guess != null && now - lastHeldLog > 1000) {
                lastHeldLog = now;
                Log.i(TAG, String.format(java.util.Locale.US, "held: off by %.1f cm (code at %.0f cm)",
                        100 * Math.hypot(Math.hypot(guess[12] - pose[12], guess[13] - pose[13]), guess[14] - pose[14]),
                        100 * Math.hypot(Math.hypot(pose[12], pose[13]), pose[14])));
            }
            ghost.anchor(pose, at);
            // For finding how the gyroscope sits against the camera (tools/axes.py): set LOG_AXES.
            double[] q = LOG_AXES ? head.turnAt(time) : null;
            if (q != null) Log.i(TAG, String.format(java.util.Locale.US, "axes: %d %.6f %.6f %.6f %.6f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f",
                    time, q[0], q[1], q[2], q[3], pose[0], pose[4], pose[8], pose[1], pose[5], pose[9], pose[2], pose[6], pose[10]));
        }
        // Following the view, the LEGO shows the whole time while building (once placed).
        if (GhostView.FOLLOW_VIEW ? screen == BUILD && lineup.linedUp() : head.works() && ghost.anchored()) pose = HELD;
        // Only once lined up: before that the ghost would land somewhere other than where the
        // wearer is looking. (The Mac's live view draws it from the camera either way.)
        boolean on = pose != null && screen == BUILD && lineup.linedUp() && !menuOpen && !lineup.active()
                && !LinkService.finished && ghostModel != null;
        if (on) {
            ghost.setStep(LinkService.step);
            ghost.setShowMarker(SystemClock.uptimeMillis() < showMarkerUntil);
            ghost.show(pose, lineup.toDisplay(lens, ghost.getWidth(), ghost.getHeight()));
        }
        setGhost(on);
    }

    @Override
    public void onNoCamera() {
        setGhost(false);
    }

    /**
     * The ghost on the real build. The step picture never goes away: while the ghost is up it
     * moves small into the top right corner, clear of the table, and comes back full size
     * when the ghost goes.
     */
    private void setGhost(boolean on) {
        if (!on && ghost != null) ghost.show(null, null);
        if (on == ghostOn) return;
        ghostOn = on;
        Log.i(TAG, on ? "ghost: marker seen" : "ghost: marker gone");
        if (GhostView.FOLLOW_VIEW) {
            // The green LEGO in the middle of the view is the step: no picture beside it.
            frame.setLayoutParams(new FrameLayout.LayoutParams(-1, -1));
            frame.setVisibility(on || screen != BUILD ? View.GONE : View.VISIBLE);
        } else {
            frame.setLayoutParams(on ? cornerFrame() : new FrameLayout.LayoutParams(-1, -1));
        }
        if (!on) wake(); else if (ghost.moving()) followMotion();
    }

    /** The step picture's small place in the top right corner, below the glasses' status bar. */
    private static FrameLayout.LayoutParams cornerFrame() {
        FrameLayout.LayoutParams corner = new FrameLayout.LayoutParams(240, 180, android.view.Gravity.TOP | android.view.Gravity.END);
        corner.topMargin = 34;
        return corner;
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
            setId = root.optString("id");
            setPieces = root.optInt("pieces");
            setMinutes = root.optInt("minutes");
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
        root.setSoundEffectsEnabled(false);
        // The ghost is drawn over everything, see-through where it has nothing; the step
        // pictures are hidden while it shows.
        ghost = new GhostView(this, ghostModel);
        root.addView(ghost, new FrameLayout.LayoutParams(-1, -1));
        frame = new ImageView(this);
        frame.setScaleType(ImageView.ScaleType.FIT_CENTER);
        frame.setBackgroundColor(Color.BLACK);
        root.addView(frame, new FrameLayout.LayoutParams(-1, -1));

        overlay = new LinearLayout(this);
        overlay.setOrientation(LinearLayout.VERTICAL);
        // The M6 launcher draws its own 34 px status bar (time, Wi-Fi, battery) over every
        // app, so the heading starts below it.
        overlay.setPadding(18, 40, 18, 14);
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
        menu = new LinearLayout(this);
        menu.setOrientation(LinearLayout.VERTICAL);
        menu.setBackgroundColor(Color.BLACK);
        menu.setPadding(18, 44, 18, 14);
        TextView title = label(22, true);
        title.setText("MENU");
        title.setPadding(8, 0, 8, 10);
        menu.addView(title);
        menuRows = new TextView[MENU.length];
        for (int i = 0; i < MENU.length; i++) {
            menuRows[i] = label(18, true);
            menuRows[i].setPadding(8, 6, 8, 6);
            menu.addView(menuRows[i], new LinearLayout.LayoutParams(-1, -2));
        }
        menu.setVisibility(View.GONE);
        root.addView(menu, new FrameLayout.LayoutParams(-1, -1));
        lineup = new Lineup(this);
        root.addView(lineup, new FrameLayout.LayoutParams(-1, -1));

        // The start screen: the set, as on the phone's home.
        home = new LinearLayout(this);
        home.setOrientation(LinearLayout.VERTICAL);
        home.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
        home.setBackgroundColor(Color.BLACK);
        home.setPadding(18, 40, 18, 14);
        TextView setLine = label(13, true);
        setLine.setText("SET " + setId);
        TextView nameLine = label(30, true);
        nameLine.setText(setName.toUpperCase());
        ImageView truck = new ImageView(this);
        truck.setScaleType(ImageView.ScaleType.FIT_CENTER);
        if (finishFrames > 0) truck.setImageBitmap(load("hud/hud-finish-01.png"));
        TextView facts = label(15, false);
        facts.setText(setPieces + " PIECES  \u00b7  " + steps.length() + " STEPS  \u00b7  " + setMinutes + " MIN");
        TextView start = label(18, true);
        start.setText("TAP TO START");
        start.setBackgroundColor(GREEN);
        start.setTextColor(Color.BLACK);
        start.setShadowLayer(0, 0, 0, Color.BLACK);
        start.setPadding(22, 6, 22, 6);
        home.addView(setLine);
        home.addView(nameLine);
        home.addView(truck, new LinearLayout.LayoutParams(-1, 0, 1f));
        home.addView(facts);
        LinearLayout.LayoutParams startAt = new LinearLayout.LayoutParams(-2, -2);
        startAt.topMargin = 8;
        home.addView(start, startAt);
        root.addView(home, new FrameLayout.LayoutParams(-1, -1));

        // ZOOM / SPIN, for a moment after a triple tap switches what swiping does.
        modeLabel = label(22, true);
        modeLabel.setGravity(android.view.Gravity.CENTER);
        modeLabel.setVisibility(View.GONE);
        FrameLayout.LayoutParams modeAt = new FrameLayout.LayoutParams(-2, -2, android.view.Gravity.BOTTOM | android.view.Gravity.END);
        modeAt.bottomMargin = 60;
        modeAt.rightMargin = 24;
        root.addView(modeLabel, modeAt);

        // The start: the set's box.
        boxLabel = label(18, true);
        boxLabel.setGravity(android.view.Gravity.CENTER);
        boxLabel.setPadding(24, 40, 24, 24);
        boxLabel.setVisibility(View.GONE);
        root.addView(boxLabel, new FrameLayout.LayoutParams(-1, -1, android.view.Gravity.CENTER));

        // While scanning: the circle (Lineup) and what to do.
        scanLabel = label(16, true);
        scanLabel.setText(setName.toUpperCase() + "\n\nPUT THE CODE ON YOUR PHONE IN THE CIRCLE, THEN TAP");
        scanLabel.setGravity(android.view.Gravity.CENTER);
        scanLabel.setPadding(24, 0, 24, 24);
        scanLabel.setVisibility(View.GONE);
        root.addView(scanLabel, new FrameLayout.LayoutParams(-1, -2, android.view.Gravity.BOTTOM));
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
        if (ghost != null) ghost.setStep(step);
        if (finished && ghostOn) setGhost(false);
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
                    say("finish");
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
                say(String.format(java.util.Locale.US, "step-%03d", step + 1));
                // Only a new step turns it back to the app's side; anything else redrawing the
                // step (the picture's side, the phone) leaves the wearer's turn alone.
                if (step != shownStep) turnToStepSide(step);
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
        say(String.format(java.util.Locale.US, "done-%03d", step + 1));
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
        say(String.format(java.util.Locale.US, "step-%03d", LinkService.step + 1));
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
        // With the green LEGO up (or right after a scan), a swipe makes it, and everything
        // drawn on the table, bigger or smaller; the code's outline shows for a moment so
        // the fit with the real phone can be seen. Remembered. Otherwise it zooms the picture.
        // Right after a scan, while the code's outline shows: fit the outline to the real code
        // (where everything is placed).
        // (Not while the LEGO follows the view: there is no outline to fit then.)
        if (!GhostView.FOLLOW_VIEW && screen == BUILD && SystemClock.uptimeMillis() < showMarkerUntil) {
            lineup.adjustSize(in ? 1.06f : 1 / 1.06f);
            showMarkerUntil = SystemClock.uptimeMillis() + OUTLINE_MS;
            Log.i(TAG, "outline: " + (in ? "bigger" : "smaller"));
            return;
        }
        // While building with the LEGO up: a swipe one way turns it one way, the other way
        // the other (zooming is drawing an O or a C: see resize).
        if (screen == BUILD && ghostOn) {
            // (swipeSpins, switched by a hold, now means swipes zoom.)
            if (swipeSpins) {
                resize(in);
                main.removeCallbacks(backToTurn);
                main.postDelayed(backToTurn, ZOOM_IDLE_MS);
            } else {
                rotate(in);
            }
            return;
        }
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
        sawDoubleTap = false;
        Log.i(TAG, n + (n == 1 ? " click" : " clicks") + (menuOpen ? " in the menu" : ""));
        if (screen == HOME) { startBox(); return; }          // any click: scan the box
        if (screen == BOX) return;
        if (menuOpen) {
            if (n == 1) pickMenu(); else closeMenu();      // two (or three) clicks: back to the LEGO
            return;
        }
        if (n == 1) next(); else if (n == 2) back(); else if (n >= 3) toggleSwipe();
    };

    // ------------------------------------------------------------ menu
    private static final int MENU_IDLE_MS = 20_000;
    private final Runnable menuIdle = this::closeMenu;

    private void openMenu() {
        Log.i(TAG, "menu: open");
        main.removeCallbacks(menuIdle);
        main.postDelayed(menuIdle, MENU_IDLE_MS);
        menuOpen = true;
        menuAt = 0;
        setGhost(false);
        hush();
        drawMenu();
        menu.setVisibility(View.VISIBLE);
        stayAwake();
    }

    private void closeMenu() {
        main.removeCallbacks(menuIdle);
        if (!menuOpen) return;
        Log.i(TAG, "menu: closed");
        menuOpen = false;
        menu.setVisibility(View.GONE);
        wake();
    }

    private void moveMenu(boolean down) {
        main.removeCallbacks(menuIdle);
        main.postDelayed(menuIdle, MENU_IDLE_MS);
        menuAt = (menuAt + (down ? 1 : MENU.length - 1)) % MENU.length;
        drawMenu();
        stayAwake();
    }

    /** One click in the menu: a switch flips; anything else is done and the menu closes. */
    private void pickMenu() {
        main.removeCallbacks(menuIdle);
        main.postDelayed(menuIdle, MENU_IDLE_MS);
        if (menuAt < MENU_SWITCHES) {
            if (menuAt == M_FADE) {
                fadeBuilt = !fadeBuilt;
                ghost.setBuiltFaint(fadeBuilt ? BUILT_FADED : BUILT_SHOWN);
            } else if (menuAt == M_ALOUD) {
                switches[ALOUD] = !switches[ALOUD];
            } else {
                int next = 0;
                for (int v = 0; v < VOICES.length; v++) if (VOICES[v][1].equals(voicePrefix)) next = (v + 1) % VOICES.length;
                voicePrefix = VOICES[next][1];
            }
            Log.i(TAG, "menu: " + menuValue(menuAt) + " for " + MENU[menuAt]);
            // The phone (through the Mac) changes the same setting.
            LinkService.settingsFade = fadeBuilt; LinkService.settingsVoice = voicePrefix; LinkService.settingsAloud = switches[ALOUD];
            LinkService.haveSettings = true;
            LinkService.sendSettings(fadeBuilt, voicePrefix, switches[ALOUD]);
            drawMenu();
            return;
        }
        int picked = menuAt;
        Log.i(TAG, "menu: " + MENU[picked]);
        closeMenu();
        if (picked == REPLAY) replay();
        else if (picked == LINE_UP) startLineup();        // SCAN PHONE AGAIN
        else if (picked == START_OVER) startOver();
    }

    private void drawMenu() {
        for (int i = 0; i < MENU.length; i++) {
            String text = MENU[i];
            if (i < MENU_SWITCHES) text = String.format(java.util.Locale.US, "%-19s%5s", text, menuValue(i));
            menuRows[i].setText(text);
            boolean here = i == menuAt;
            menuRows[i].setBackgroundColor(here ? GREEN : Color.TRANSPARENT);
            menuRows[i].setTextColor(here ? Color.BLACK : GREEN);
            menuRows[i].setShadowLayer(here ? 0 : 2, 0, 0, Color.BLACK);
        }
    }

    /** A setting's value as the menu shows it. */
    private String menuValue(int i) {
        if (i == M_FADE) return fadeBuilt ? "ON" : "OFF";
        if (i == M_ALOUD) return switches[ALOUD] ? "ON" : "OFF";
        for (String[] v : VOICES) if (v[1].equals(voicePrefix)) return v[0];
        return VOICES[0][0];
    }

    private void startOver() {
        LinkService.step = 0;
        LinkService.finished = false;
        LinkService.milestone = false;
        LinkService.view = -1;
        shownStep = -1;
        show();
        LinkService.send(false);
    }

    // ------------------------------------------------------------ read aloud
    /** Plays one of the phone's recorded lines (voice-<name>.m4a) when READ STEPS ALOUD is on. */
    private void say(String name) {
        if (!switches[ALOUD] || screen != BUILD || menuOpen) return;
        hush();
        try {
            // Copied out once: a player can't always read straight from inside the app.
            java.io.File file = new java.io.File(getCacheDir(), "voice-" + voicePrefix + name + ".m4a");
            if (!file.exists()) {
                try (InputStream in = getAssets().open("voice/voice-" + voicePrefix + name + ".m4a");
                     java.io.FileOutputStream out = new java.io.FileOutputStream(file)) {
                    byte[] buf = new byte[16384];
                    for (int r; (r = in.read(buf)) > 0; ) out.write(buf, 0, r);
                }
            }
            MediaPlayer player = new MediaPlayer();
            // The alarm channel: the media one is muted to silence the touchpad's clicks.
            player.setAudioAttributes(new android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build());
            player.setDataSource(file.getPath());
            player.setOnPreparedListener(p -> { p.start(); Log.i(TAG, "voice: " + name); });
            player.setOnCompletionListener(p -> { if (voice == p) voice = null; p.release(); });
            player.setOnErrorListener((p, what, extra) -> { Log.w(TAG, "voice " + name + ": error " + what); return false; });
            player.prepareAsync();
            voice = player;
        } catch (java.io.FileNotFoundException e) {
            // No recording for this line (not every step ends a part of the build).
        } catch (Exception e) {
            Log.w(TAG, "voice " + name, e);
        }
    }

    /**
     * The M6 plays a click on the media channel for every touchpad gesture (from the system,
     * not this app). While BuildLens is in front that channel is muted, and put back as it
     * was when BuildLens goes; the voice plays on the alarm channel instead (see say()).
     */
    private boolean mutedClicks;

    private void quietClicks(boolean quiet) {
        android.media.AudioManager audio = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
        if (audio == null) return;
        try {
            if (quiet && !mutedClicks && !audio.isStreamMute(android.media.AudioManager.STREAM_MUSIC)) {
                audio.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_MUTE, 0);
                mutedClicks = true;
                prefs.edit().putBoolean("mutedClicks", true).apply();
            } else if (!quiet && mutedClicks) {
                audio.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_UNMUTE, 0);
                mutedClicks = false;
                prefs.edit().putBoolean("mutedClicks", false).apply();
            }
        } catch (Exception e) {
            Log.w(TAG, "click sound", e);
        }
    }

    private void hush() {
        MediaPlayer p = voice;
        voice = null;
        if (p != null) { try { p.stop(); } catch (Exception ignored) { } p.release(); }
    }

    /** One press of the main button or a tap. Waits a moment to see if more follow. */
    private void click() {
        tapEvent(1);
    }

    /**
     * Taps add up into one gesture. The touchpad does its own counting first and sends a
     * double tap as F12 or as two taps, and a triple as F12 + a tap, two F12s, or three taps,
     * depending on speed. So a tap counts 1 and its double tap 2, and anything within
     * TAP_GAP_MS of the last joins the same gesture: 1 = next, 2 = back, 3 or more = the
     * triple (at once). Taps straight after a triple belong to it and are dropped.
     */
    private static final int TAP_GAP_MS = 550, AFTER_TRIPLE_MS = 550;
    /** After the touchpad's double tap its own next tap comes later (it was still counting): up to 0.62 s seen. */
    private static final int TAP_GAP_AFTER_DOUBLE_MS = 850;
    private long quietUntil;

    /** While building, how far this gesture has already moved the steps (+1 next, -1 back). */
    private int applied, gestureFrom;

    /** The gesture is over: a double tap goes back now; a single tap has already gone on. */
    private final Runnable endGesture = () -> {
        if (clicks == 2) moveStepsTo(-1);
        clicks = 0;
        applied = 0;
    };

    /** Moves the steps so this gesture has moved them `target` from where it began. */
    private void moveStepsTo(int target) {
        for (int d = target - (place() - gestureFrom); d > 0; d--) next();
        for (int d = target - (place() - gestureFrom); d < 0; d++) back();
    }

    /** Where the build is: the step, and one further once it is finished. */
    private static int place() {
        return LinkService.step + (LinkService.finished ? 1 : 0);
    }

    private void tapEvent(int count) {
        if (lineup.active()) { lineup.click(markerCentre, lens); return; }
        long now = SystemClock.uptimeMillis();
        // Still tapping after a triple (spamming): ignored until the taps stop for a moment,
        // so a burst is one gesture, not several.
        if (now < quietUntil) { quietUntil = now + AFTER_TRIPLE_MS; return; }
        if (screen == BUILD && !menuOpen) {
            // A single tap acts at once (next step). A double tap waits to see if a third tap
            // follows, so a triple never moves the steps back and forth on its way.
            if (clicks == 0) gestureFrom = place();
            clicks += count;
            main.removeCallbacks(endGesture);
            if (clicks >= 3) {
                quietUntil = now + AFTER_TRIPLE_MS;
                moveStepsTo(0);                       // undo a single tap's next, if any
                Log.i(TAG, clicks + " clicks");
                toggleSwipe();
                clicks = 0;
                return;
            }
            if (clicks == 1) moveStepsTo(1);
            Log.i(TAG, clicks + (clicks == 1 ? " click (at once)" : " clicks (waiting for a third)"));
            main.postDelayed(endGesture, count == 2 ? TAP_GAP_AFTER_DOUBLE_MS : TAP_GAP_MS);
            return;
        }
        clicks += count;
        main.removeCallbacks(resolveClicks);
        if (clicks >= 3) {
            quietUntil = now + AFTER_TRIPLE_MS;
            resolveClicks.run();
            return;
        }
        main.postDelayed(resolveClicks, count == 2 ? TAP_GAP_AFTER_DOUBLE_MS : TAP_GAP_MS);
    }

    /**
     * The M6 touchpad spots a double tap itself and sends F12 (a third tap follows as a
     * plain tap about 0.6 s later), so F12 counts as two clicks. The glasses then send a
     * Back key of their own; that one is ignored (see dispatchKeyEvent).
     */
    private static final int AFTER_DOUBLE_TAP_MS = 850, DOUBLE_TAP_BACK_MS = 800;
    private static final int TRIPLE_AS_TWO_DOUBLES_MS = 600;
    private long lastDoubleTap;
    private boolean sawDoubleTap;

    private void doubleTap() {
        lastDoubleTap = SystemClock.uptimeMillis();
        // (While scanning, tapEvent makes it the tap: two quick taps are easy to make.)
        tapEvent(2);
    }

    /** Click and hold: the menu (or out of it again). */
    private static final int HOLD_MS = 500;
    private boolean holdHandled;

    private void hold() {
        main.removeCallbacks(resolveClicks);
        clicks = 0;
        sawDoubleTap = false;
        if (screen == BOX) { Log.i(TAG, "box: skipped"); startLineup(); return; }
        if (lineup.active() || screen != BUILD) return;
        Log.i(TAG, "hold");
        // Hold: the menu (a slow slide also reads as a hold, so it must be something harmless).
        if (menuOpen) closeMenu(); else openMenu();
    }

    // What each key does. Nothing public documents the M6's key codes, so this follows what
    // similar glasses send (tap = centre/enter, swipes = left/right) and is the one place to
    // edit once `adb logcat -s BuildLens` shows what the real buttons send.
    private static final int CLICK = 1, NEXT = 2, BACK = 3, ZOOM_IN = 4, ZOOM_OUT = 5, ROTATE = 6, ROTATE_BACK = 7,
            BIGGER = 8, SMALLER = 9;
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
        // The M6 touchpad reports no fingers or direction, only finished gestures: taps, swipes,
        // and letters drawn on it (W E O S L Z C V M, from its key list). Drawing an O (a
        // circle) makes the LEGO bigger, a C smaller (E too, which it sends for a rough C).
        KEYS.put(KeyEvent.KEYCODE_O, BIGGER);
        KEYS.put(KeyEvent.KEYCODE_C, SMALLER);
        KEYS.put(KeyEvent.KEYCODE_E, SMALLER);
    }
    private static final int SWIPE_TAP_MS = 500;
    private long lastSwipe;

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
        if (code == KeyEvent.KEYCODE_F12) {
            if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) doubleTap();
            return true;
        }
        // The glasses' own Back after a double tap: the double tap has already been counted.
        if (code == KeyEvent.KEYCODE_BACK && SystemClock.uptimeMillis() - lastDoubleTap < DOUBLE_TAP_BACK_MS) return true;
        // A long press on the touchpad (F11 on the M6), or a click held down: the menu.
        if (code == KeyEvent.KEYCODE_F11) {
            if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0) hold();
            return true;
        }
        int action = KEYS.get(code);
        // A swipe that runs off the edge of the touchpad ends with a tap of its own as the
        // finger leaves: a tap this soon after a swipe is part of the swipe, not a click.
        boolean swipeKey = code == KeyEvent.KEYCODE_DPAD_LEFT || code == KeyEvent.KEYCODE_DPAD_RIGHT
                || code == KeyEvent.KEYCODE_DPAD_UP || code == KeyEvent.KEYCODE_DPAD_DOWN;
        if (swipeKey) {
            lastSwipe = SystemClock.uptimeMillis();
            // ...and sometimes the tap comes first, just before the swipe: drop it too.
            if (clicks > 0 && !lineup.active()) {
                main.removeCallbacks(resolveClicks);
                clicks = 0;
                sawDoubleTap = false;
                Log.i(TAG, "tap before a swipe: ignored");
            }
        }
        if (action == CLICK && SystemClock.uptimeMillis() - lastSwipe < SWIPE_TAP_MS) {
            if (e.getAction() == KeyEvent.ACTION_UP) Log.i(TAG, "tap after a swipe: ignored");
            return true;
        }
        // The M6 turns a touchpad gesture (it arrives as F12) into a Back key a moment later.
        // Back goes back a step or closes the menu, and never drops out of the app: a stray
        // gesture mid-build must not leave the instructions.
        if (code == KeyEvent.KEYCODE_BACK) action = BACK;
        if (action == 0) return super.dispatchKeyEvent(e);
        // Clicks count when the key comes up, so a held key is one click; arrows act on the way down.
        if (action == CLICK) {
            if (e.getAction() == KeyEvent.ACTION_DOWN) {
                if (e.getRepeatCount() == 0) holdHandled = false;
                else if (!holdHandled && (e.isLongPress() || e.getEventTime() - e.getDownTime() >= HOLD_MS)) { holdHandled = true; hold(); }
            } else if (e.getAction() == KeyEvent.ACTION_UP && !e.isCanceled()) {
                if (holdHandled) holdHandled = false;
                else if (e.getEventTime() - e.getDownTime() >= HOLD_MS) hold();
                else click();
            }
        } else if (e.getAction() == KeyEvent.ACTION_DOWN && e.getRepeatCount() == 0 && directStepAllowed()) {
            if (menuOpen) {
                if (action == BACK) closeMenu(); else moveMenu(action == ZOOM_IN || action == NEXT);
            } else if (action == ROTATE || action == ROTATE_BACK) rotate(action == ROTATE);
            else if (action == BIGGER || action == SMALLER) resize(action == BIGGER);
            else if (action == NEXT) next(); else if (action == BACK) back(); else zoom(action == ZOOM_IN);
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
