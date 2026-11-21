package com.buildlens.glasses;

import android.content.Context;
import android.graphics.PixelFormat;
import android.opengl.GLES20;
import android.opengl.GLSurfaceView;
import android.os.SystemClock;
import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * The green ghost: the current step's pieces drawn where they go on the real build, on
 * black (see-through on the glasses). What is already built is drawn faintly; the new
 * pieces go in one after another, as on the phone, and the step plays again and again.
 *
 * The build stands 11 cm to the right of the marker the phone shows. Where that is on the
 * display comes from the marker's pose in the camera picture and the line-up (Lineup),
 * which says how the camera picture sits over what the eye sees.
 */
final class GhostView extends GLSurfaceView implements GLSurfaceView.Renderer {
    /** The build stands this far to the right of the marker's middle: none, so the piece shows
     *  right on the code (as AssistView.buildOffset on the Mac). */
    static final float BUILD_OFFSET = 0f;
    /** The pieces are drawn this many times their real size, so they are easy to see on the
     *  code (as AssistView.ghostScale on the Mac). The code's outline stays true to size. */
    static final float GHOST_SCALE = 3f;
    /** The wearer's own size for the LEGO on top of GHOST_SCALE (swipes while building). */
    private volatile float sizeFactor = 1f, sizeTarget = 1f;

    /** Each frame the turn and size move most of the way to where they were set: smooth,
     *  however often the phone or touchpad sends them. */
    private void glide() {
        long now = SystemClock.uptimeMillis();
        float dt = lastGlide == 0 ? 0.033f : Math.min(0.1f, (now - lastGlide) / 1000f);
        lastGlide = now;
        // A flick's push carries on and slows down, like a trackpad with momentum.
        if (spinSpeed != 0) {
            spinDegrees = ((spinDegrees + spinSpeed * dt) % 360 + 360) % 360;
            spinTarget = spinDegrees;
            spinSpeed *= (float) Math.exp(-FRICTION * dt);
            if (Math.abs(spinSpeed) < 2f) spinSpeed = 0;
        }
        if (zoomSpeed != 0) {
            sizeFactor = Math.max(MIN_SIZE, Math.min(MAX_SIZE, sizeFactor * (float) Math.exp(zoomSpeed * dt)));
            sizeTarget = sizeFactor;
            zoomSpeed *= (float) Math.exp(-FRICTION * dt);
            if (Math.abs(zoomSpeed) < 0.01f || sizeFactor == MIN_SIZE || sizeFactor == MAX_SIZE) zoomSpeed = 0;
        }
        // Set from elsewhere: the phone's own turning is followed almost at once (it only fills
        // in between the phone's ~30 updates a second, so it moves as the finger does); a new
        // step's turn glides there more slowly, as the phone's own step turn does.
        float k = 1f - (float) Math.exp(-dt / (quick ? QUICK_TAU : STEP_TAU));
        float d = ((spinTarget - spinDegrees + 540) % 360) - 180;
        spinDegrees = Math.abs(d) < 0.3f ? spinTarget : spinDegrees + d * k;
        float z = (float) Math.log(sizeTarget / sizeFactor);
        sizeFactor = Math.abs(z) < 0.002f ? sizeTarget : sizeFactor * (float) Math.exp(z * k);
        float t = tiltTarget - tiltDegrees;
        tiltDegrees = Math.abs(t) < 0.2f ? tiltTarget : tiltDegrees + t * k;
        if (moving()) requestRender();
    }

    /** How fast a push dies away (per second), and how small and big the LEGO may get. */
    static final float FRICTION = 3f, MIN_SIZE = 0.05f, MAX_SIZE = 12f;
    private volatile float spinSpeed, zoomSpeed;
    private long lastGlide;
    /** How quickly a set value is reached (seconds to go most of the way): following the
     *  phone, and turning to a new step's side. */
    private static final float QUICK_TAU = 0.03f, STEP_TAU = 0.12f;
    private volatile boolean quick;
    /** How far it leans back, seen from above (degrees): the phone's camera height. */
    static final float DEFAULT_TILT = 25f;
    private volatile float tiltDegrees = DEFAULT_TILT, tiltTarget = DEFAULT_TILT;

    /** The turn, zoom and lean the phone (or Mac) shows: followed straight away. */
    void follow(float spin, float size, float tilt) {
        spinSpeed = 0;
        zoomSpeed = 0;
        quick = true;
        spinTarget = spin;
        if (size > 0) sizeTarget = Math.max(MIN_SIZE, Math.min(MAX_SIZE, size));
        if (!Float.isNaN(tilt)) tiltTarget = Math.max(-10f, Math.min(85f, tilt));
        requestRender();
    }

    float tilt() { return tiltDegrees; }

    /** A flick: pushes the turn (degrees a second) or the zoom (its log a second). */
    void pushSpin(float degreesPerSecond) { spinSpeed += degreesPerSecond; requestRender(); }
    void pushZoom(float perSecond) { zoomSpeed += perSecond; requestRender(); }

    /** Still turning or zooming (from a push or gliding to a set value). */
    boolean moving() {
        return spinSpeed != 0 || zoomSpeed != 0 || spinDegrees != spinTarget || sizeFactor != sizeTarget
                || tiltDegrees != tiltTarget;
    }

    float spin() { return spinDegrees; }
    float size() { return sizeFactor; }

    void setSizeFactor(float factor) {
        zoomSpeed = 0;
        quick = false;
        sizeTarget = Math.max(MIN_SIZE, Math.min(MAX_SIZE, factor));
        requestRender();
    }
    private static final float TURN = 0.6f, HOLD = 0.6f;

    private final GhostModel model;

    // Set from the main thread, read when drawing.
    private volatile float[] pose;                 // camera from marker, column-major
    private volatile float[] toDisplay;            // 3 x 3, row-major: camera point -> display pixel (homogeneous)
    private volatile int wantedStep = -1;
    private volatile long stepStarted = SystemClock.uptimeMillis();
    private volatile boolean showMarker;

    // GL thread only.
    private int program, aPos, aNormal, aShift, aTurn, uMvp, uMv, uTime, uFaint;
    private int width = 640, height = 480;
    private int shownStep = -1;
    private GhostModel.Step step;
    private final int[] vbo = new int[2];
    private final FloatBuffer lines = ByteBuffer.allocateDirect(200 * 3 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();

    GhostView(Context context, GhostModel model) {
        super(context);
        this.model = model;
        setEGLContextClientVersion(2);
        setEGLConfigChooser(8, 8, 8, 8, 16, 0);
        // Above the window, see-through where nothing is drawn: under the window, Android 9
        // does not always open the window up again after a pause, and the ghost stays hidden.
        getHolder().setFormat(PixelFormat.TRANSLUCENT);
        setZOrderMediaOverlay(true);
        setRenderer(this);
        setRenderMode(RENDERMODE_WHEN_DIRTY);
    }

    // ------------------------------------------------------------ staying put
    private volatile HeadTracker head;
    /** The marker in the head tracker's fixed frame (column-major 4 x 4), once seen. */
    private volatile float[] anchor;

    void setHead(HeadTracker head) { this.head = head; }

    /** The model's spin about its upright, in degrees (the wearer's rotate gesture). */
    private volatile float spinDegrees, spinTarget;

    void setSpin(float degrees) {
        spinSpeed = 0;
        quick = false;
        spinTarget = degrees;
        requestRender();
    }

    /**
     * Where the LEGO is drawn: in the middle of the wearer's view, following the head (true),
     * or standing on the phone's code on the table (false). The code's place is kept either
     * way (anchor), for when pieces are shown on the real build.
     */
    static final boolean FOLLOW_VIEW = true;
    /** How far in front of the eye the LEGO hangs when following the view, in metres. */
    private static final float VIEW_DISTANCE = 0.45f;

    /** The model's stand (as if on a marker) in the middle of the view, from the line-up `k`. */
    /** How big the LEGO is drawn when following the view: its round, in display pixels from the middle. */
    private static final float VIEW_RADIUS = 220f;

    private static float[] inView(float[] k, int width, int height, float lift, float tiltDegrees) {
        // The camera ray that lands on the middle of the display: solve k * (x, y, 1) = middle.
        float u = width / 2f - k[2], v = height / 2f - k[5];
        float det = k[0] * k[4] - k[1] * k[3];
        float x = det == 0 ? 0 : (u * k[4] - v * k[1]) / det, y = det == 0 ? 0 : (v * k[0] - u * k[3]) / det;
        float n = (float) Math.sqrt(x * x + y * y + 1), d = VIEW_DISTANCE / n;
        double t = Math.toRadians(tiltDegrees);
        float c = (float) Math.cos(t), s = (float) Math.sin(t);
        // Stand axes in camera axes: x right; up = towards the top of the view, leaning back;
        // y (the third) completes them. The stand sits a little below the middle, so the
        // pieces on it are centred.
        float upY = -c, upZ = -s;
        return new float[] {
            1, 0, 0, 0,
            0, -s, c, 0,
            0, upY, upZ, 0,
            x * d, y * d - upY * lift, d - upZ * lift, 1,
        };
    }

    /**
     * A new sight of the marker: `pose` (camera from marker) with `cameraToRef`, which way
     * the head pointed when that picture was taken. Kept in the fixed frame, smoothed there,
     * so it holds still while the head turns.
     */
    void anchor(float[] pose, float[] cameraToRef) {
        float[] seen = turned(cameraToRef, pose, false);
        float[] old = anchor;
        float jump = old == null ? 1 : (float) Math.hypot(Math.hypot(seen[12] - old[12], seen[13] - old[13]), seen[14] - old[14]);
        anchor = old == null || jump > 0.05f ? seen : MarkerPose.blend(old, seen, 0.3f);
    }

    void clearAnchor() { anchor = null; }

    /** Where the kept marker should be in a picture taken with the head at cameraToRef (null: none kept). */
    float[] predicted(float[] cameraToRef) {
        float[] kept = anchor;
        return kept == null ? null : turned(cameraToRef, kept, true);
    }

    boolean anchored() { return anchor != null; }

    /** `pose` turned by the 3 x 3 row-major `r` (or by its transpose). */
    private static float[] turned(float[] r, float[] pose, boolean transpose) {
        float[] out = new float[16];
        for (int c = 0; c < 4; c++) {
            for (int i = 0; i < 3; i++) {
                float v = 0;
                for (int k = 0; k < 3; k++) v += (transpose ? r[k * 3 + i] : r[i * 3 + k]) * pose[c * 4 + k];
                out[c * 4 + i] = v;
            }
            out[c * 4 + 3] = pose[c * 4 + 3];
        }
        return out;
    }

    /** Where the marker is now (null: not shown), and how camera points land on the display. */
    void show(float[] pose, float[] toDisplay) {
        boolean was = this.pose != null;
        this.pose = pose;
        this.toDisplay = toDisplay;
        requestRender();
        if (pose != null && !was) { removeCallbacks(tick); postDelayed(tick, FRAME_MS); }
    }

    /** The pieces move at this many frames a second while the ghost is up; nothing is drawn otherwise. */
    private static final int FRAME_MS = 33;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (pose == null) return;
            requestRender();
            postDelayed(this, FRAME_MS);
        }
    };

    void setStep(int index) {
        if (index != wantedStep) {
            wantedStep = index;
            stepStarted = SystemClock.uptimeMillis();
            requestRender();
        }
        if (model != null) model.prefetch(index);
    }

    /** Draws the marker's outline too, while lining up. */
    void setShowMarker(boolean show) { showMarker = show; }

    /** What is already built, drawn faintly under the new pieces (menu: SHOW BUILT PIECES). */
    private volatile boolean showBuilt = true;

    /** How faint the pieces already built are drawn (the phone's "Fade pieces already built"). */
    private volatile float builtFaint = 0.4f;

    void setBuiltFaint(float faint) {
        builtFaint = faint;
        requestRender();
    }

    void setShowBuilt(boolean show) {
        showBuilt = show;
        requestRender();
    }

    // ------------------------------------------------------------ GL
    private static final String VERTEX =
            "uniform mat4 uMvp; uniform mat4 uMv; uniform float uTime; uniform float uFaint;\n"
            + "attribute vec3 aPos; attribute vec3 aNormal; attribute vec3 aShift; attribute float aTurn;\n"
            + "varying float vLight;\n"
            + "void main() {\n"
            + "  float since = uTime - aTurn * " + TURN + ";\n"
            + "  if (since < 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vLight = 0.0; return; }\n"
            + "  float travel = clamp((since - 0.08) / 0.35, 0.0, 1.0);\n"
            + "  float eased = travel * travel * (3.0 - 2.0 * travel);\n"
            + "  vec3 p = aPos - aShift * (1.0 - eased);\n"
            + "  vec3 eye = (uMv * vec4(p, 1.0)).xyz;\n"
            + "  vec3 n = normalize((uMv * vec4(aNormal, 0.0)).xyz);\n"
            + "  float facing = abs(dot(n, normalize(eye)));\n"
            + "  vLight = uFaint > 0.0 ? uFaint * (0.75 + 0.25 * facing) : 0.6 + 0.4 * facing;\n"
            + "  gl_Position = uMvp * vec4(p, 1.0);\n"
            + "}\n";
    private static final String FRAGMENT =
            "precision mediump float; varying float vLight;\n"
            + "void main() { gl_FragColor = vec4(vec3(0.45, 1.0, 0.6) * vLight, 1.0); }\n";

    @Override
    public void onSurfaceCreated(GL10 unused, EGLConfig config) {
        program = GLES20.glCreateProgram();
        GLES20.glAttachShader(program, shader(GLES20.GL_VERTEX_SHADER, VERTEX));
        GLES20.glAttachShader(program, shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT));
        GLES20.glLinkProgram(program);
        int[] ok = new int[1];
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) Log.e(LinkService.TAG, "ghost program: " + GLES20.glGetProgramInfoLog(program));
        aPos = GLES20.glGetAttribLocation(program, "aPos");
        aNormal = GLES20.glGetAttribLocation(program, "aNormal");
        aShift = GLES20.glGetAttribLocation(program, "aShift");
        aTurn = GLES20.glGetAttribLocation(program, "aTurn");
        uMvp = GLES20.glGetUniformLocation(program, "uMvp");
        uMv = GLES20.glGetUniformLocation(program, "uMv");
        uTime = GLES20.glGetUniformLocation(program, "uTime");
        uFaint = GLES20.glGetUniformLocation(program, "uFaint");
        GLES20.glGenBuffers(2, vbo, 0);
        GLES20.glClearColor(0, 0, 0, 0);
        shownStep = -1;
    }

    private static int shader(int type, String source) {
        int s = GLES20.glCreateShader(type);
        GLES20.glShaderSource(s, source);
        GLES20.glCompileShader(s);
        int[] ok = new int[1];
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) Log.e(LinkService.TAG, "ghost shader: " + GLES20.glGetShaderInfoLog(s));
        return s;
    }

    @Override
    public void onSurfaceChanged(GL10 unused, int w, int h) {
        width = w;
        height = h;
        GLES20.glViewport(0, 0, w, h);
    }

    @Override
    public void onDrawFrame(GL10 unused) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT | GLES20.GL_DEPTH_BUFFER_BIT);
        float[] pose = this.pose, k = this.toDisplay;
        if (pose == null || k == null || model == null) return;
        // Held in place: the kept marker, turned by how the head points right now.
        float[] kept = anchor;
        HeadTracker tracker = head;
        if (!FOLLOW_VIEW && kept != null && tracker != null) pose = turned(tracker.cameraToRef(), kept, true);
        int wanted = Math.max(0, Math.min(wantedStep, model.stepCount() - 1));
        if (wanted != shownStep) {
            step = model.step(wanted);
            shownStep = wanted;
            if (step != null) {
                upload(vbo[0], step.built, step.builtCount);
                upload(vbo[1], step.fresh, step.freshCount);
            }
        }
        if (step == null) return;

        // Model (+Y up, on its own ground) onto the table beside the marker: up is out of the screen.
        glide();
        float g = GHOST_SCALE * sizeFactor;
        if (FOLLOW_VIEW) {
            // Sized by how much of the view it fills (its round about VIEW_RADIUS display pixels
            // across the middle), whatever the display's width of view; centred on its middle.
            float f = (float) Math.hypot(k[0], k[3]);
            g = VIEW_RADIUS * VIEW_DISTANCE / (f * Math.max(step.radius, 0.005f)) * sizeFactor;
            pose = inView(k, getWidth(), getHeight(), 0, tiltDegrees);
        }
        float[] onTable = {g, 0, 0, 0, 0, 0, g, 0, 0, -g, 0, 0, BUILD_OFFSET, 0, 0, 1};
        float[] mv = multiply(pose, onTable);
        if (spinDegrees != 0) {
            double a = Math.toRadians(spinDegrees);
            float c = (float) Math.cos(a), sn = (float) Math.sin(a);
            mv = multiply(mv, new float[] {c, 0, -sn, 0, 0, 1, 0, 0, sn, 0, c, 0, 0, 0, 0, 1});
        }
        // Following the view, the whole assembly turns and grows about its own middle, which
        // sits in the middle of the view.
        if (FOLLOW_VIEW) mv = multiply(mv, new float[] {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -step.cx, -step.cy, -step.cz, 1});
        float[] mvp = multiply(projection(k), mv);
        float loop = step.turns * TURN + HOLD;
        float time = ((SystemClock.uptimeMillis() - stepStarted) / 1000f) % loop;

        GLES20.glUseProgram(program);
        GLES20.glUniformMatrix4fv(uMvp, 1, false, mvp, 0);
        GLES20.glUniformMatrix4fv(uMv, 1, false, mv, 0);
        GLES20.glEnable(GLES20.GL_DEPTH_TEST);

        // Where the build stands: a dashed ring on the table. And the marker, while lining up.
        lines.clear();
        for (int i = 0; i < 48; i += 2) {
            for (int j = 0; j < 2; j++) {
                double a = (i + j) / 48.0 * 2 * Math.PI;
                lines.put((float) Math.cos(a) * step.radius).put(0).put((float) Math.sin(a) * step.radius);
            }
        }
        if (showMarker) {
            float h = MarkerPose.SIDE / 2;
            float[] c = {-h, h, h, h, h, h, h, -h, h, -h, -h, -h, -h, -h, -h, h};
            // Marker corners in model axes (model x = marker x, model -z = marker y), divided by
            // the pieces' blow-up so the outline stays the code's real size.
            for (int i = 0; i < 16; i += 2) lines.put((c[i] - BUILD_OFFSET) / g).put(0).put(-c[i + 1] / g);
        }
        // Following the view there is no table and no code to outline.
        if (FOLLOW_VIEW) lines.clear();
        int lineCorners = lines.position() / 3;
        lines.position(0);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
        GLES20.glUniform1f(uTime, 100);
        GLES20.glUniform1f(uFaint, 0.6f);
        GLES20.glEnableVertexAttribArray(aPos);
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, 12, lines);
        GLES20.glDisableVertexAttribArray(aNormal);
        GLES20.glDisableVertexAttribArray(aShift);
        GLES20.glDisableVertexAttribArray(aTurn);
        GLES20.glVertexAttrib3f(aNormal, 0, 1, 0);
        GLES20.glVertexAttrib3f(aShift, 0, 0, 0);
        GLES20.glVertexAttrib1f(aTurn, 0);
        GLES20.glLineWidth(2);
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, lineCorners);

        // What is already built, faintly: the real pieces are on top of it.
        if (showBuilt) {
            GLES20.glUniform1f(uFaint, builtFaint);
            draw(vbo[0], step.builtCount);
        }
        // The new pieces over everything, one after another.
        GLES20.glClear(GLES20.GL_DEPTH_BUFFER_BIT);
        GLES20.glUniform1f(uTime, time);
        GLES20.glUniform1f(uFaint, 0);
        draw(vbo[1], step.freshCount);
    }

    private void upload(int buffer, FloatBuffer data, int corners) {
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, buffer);
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, Math.max(1, corners) * GhostModel.FLOATS * 4, data, GLES20.GL_STATIC_DRAW);
    }

    private void draw(int buffer, int corners) {
        if (corners == 0) return;
        int stride = GhostModel.FLOATS * 4;
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, buffer);
        GLES20.glEnableVertexAttribArray(aPos);
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, stride, 0);
        GLES20.glEnableVertexAttribArray(aNormal);
        GLES20.glVertexAttribPointer(aNormal, 3, GLES20.GL_FLOAT, false, stride, 12);
        GLES20.glEnableVertexAttribArray(aShift);
        GLES20.glVertexAttribPointer(aShift, 3, GLES20.GL_FLOAT, false, stride, 24);
        GLES20.glEnableVertexAttribArray(aTurn);
        GLES20.glVertexAttribPointer(aTurn, 1, GLES20.GL_FLOAT, false, stride, 36);
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, corners);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
    }

    /**
     * Camera points (x right, y down, z forward) to OpenGL's clip space, through `k`, which
     * takes a camera point to display pixels (homogeneous; y down).
     */
    private float[] projection(float[] k) {
        float near = 0.03f, far = 5f;
        float a = (far + near) / (far - near), b = -2 * far * near / (far - near);
        float w = width, h = height;
        float[] p = new float[16];   // column-major
        for (int c = 0; c < 3; c++) {
            p[c * 4] = 2 / w * k[c] - k[6 + c];
            p[c * 4 + 1] = -2 / h * k[3 + c] + k[6 + c];
            p[c * 4 + 3] = k[6 + c];
        }
        p[2 * 4 + 2] = a;
        p[3 * 4 + 2] = b;
        return p;
    }

    private static float[] multiply(float[] a, float[] b) {
        float[] out = new float[16];
        for (int c = 0; c < 4; c++)
            for (int r = 0; r < 4; r++) {
                float s = 0;
                for (int i = 0; i < 4; i++) s += a[i * 4 + r] * b[c * 4 + i];
                out[c * 4 + r] = s;
            }
        return out;
    }
}
