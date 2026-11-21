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
    /** The build stands this far to the right of the marker's middle, clear of the phone (as on the phone). */
    static final float BUILD_OFFSET = PieceCheck.OFFSET;
    private static final float TURN = 1.1f, HOLD = 0.9f;

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

    /** Where the marker is now (null: not seen), and how camera points land on the display. */
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
        }
    }

    /** Draws the marker's outline too, while lining up. */
    void setShowMarker(boolean show) { showMarker = show; }

    // ------------------------------------------------------------ GL
    private static final String VERTEX =
            "uniform mat4 uMvp; uniform mat4 uMv; uniform float uTime; uniform float uFaint;\n"
            + "attribute vec3 aPos; attribute vec3 aNormal; attribute vec3 aShift; attribute float aTurn;\n"
            + "varying float vLight;\n"
            + "void main() {\n"
            + "  float since = uTime - aTurn * " + TURN + ";\n"
            + "  if (since < 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vLight = 0.0; return; }\n"
            + "  float travel = clamp((since - 0.35) / 0.55, 0.0, 1.0);\n"
            + "  float eased = travel * travel * (3.0 - 2.0 * travel);\n"
            + "  vec3 p = aPos - aShift * (1.0 - eased);\n"
            + "  vec3 eye = (uMv * vec4(p, 1.0)).xyz;\n"
            + "  vec3 n = normalize((uMv * vec4(aNormal, 0.0)).xyz);\n"
            + "  float facing = abs(dot(n, normalize(eye)));\n"
            + "  vLight = uFaint > 0.0 ? uFaint * (0.5 + 0.5 * facing) : 0.35 + 0.65 * facing;\n"
            + "  gl_Position = uMvp * vec4(p, 1.0);\n"
            + "}\n";
    private static final String FRAGMENT =
            "precision mediump float; varying float vLight;\n"
            + "void main() { gl_FragColor = vec4(vec3(0.36, 1.0, 0.5) * vLight, 1.0); }\n";

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

        // Model (+Y up, on its own ground) onto the table beside the marker: up is out of the
        // screen, and the table is a phone's thickness below the screen showing the marker.
        float[] onTable = {1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, BUILD_OFFSET, 0, -PieceCheck.DROP, 1};
        float[] mv = multiply(pose, onTable);
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
            // Marker corners in model axes (model x = marker x, model -z = marker y).
            for (int i = 0; i < 16; i += 2) lines.put(c[i] - BUILD_OFFSET).put(0).put(-c[i + 1]);
        }
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
        GLES20.glUniform1f(uFaint, 0.22f);
        draw(vbo[0], step.builtCount);
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
