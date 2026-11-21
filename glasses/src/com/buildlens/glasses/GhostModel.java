package com.buildlens.glasses;

import android.content.res.AssetManager;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.charset.StandardCharsets;

/**
 * Every step's pieces as triangles, standing where the build stands (made by
 * make_assets.py from the app's build package: assets/ghost.json + ghost.bin).
 *
 * Each corner is 10 numbers: position (3), the face's direction (3), how far off its place
 * the piece waits (3, along the way it goes in) and its turn (1): pieces go in one turn
 * after another, as on the phone.
 */
final class GhostModel {
    static final int FLOATS = 10;

    /** One step, ready to draw. */
    static final class Step {
        FloatBuffer built, fresh;
        int builtCount, freshCount;      // corners
        int turns;
        float radius;
        /** The middle of everything shown in the step (built and new, in place), model axes. */
        float cx, cy, cz;
    }

    private final JSONArray steps;
    private final JSONArray parts;
    private final ByteBuffer shapes;

    private GhostModel(JSONArray steps, JSONArray parts, ByteBuffer shapes) {
        this.steps = steps;
        this.parts = parts;
        this.shapes = shapes;
    }

    static GhostModel load(AssetManager assets) {
        try {
            JSONObject root = new JSONObject(new String(read(assets, "ghost.json"), StandardCharsets.UTF_8));
            ByteBuffer shapes = ByteBuffer.wrap(read(assets, "ghost.bin")).order(ByteOrder.LITTLE_ENDIAN);
            return new GhostModel(root.getJSONArray("steps"), root.getJSONArray("parts"), shapes);
        } catch (Exception e) {
            Log.e(LinkService.TAG, "ghost data", e);
            return null;
        }
    }

    int stepCount() { return steps.length(); }

    /** Steps already built, and a thread that builds the neighbours ahead of time, so a tap
     *  shows the next step at once instead of waiting for its triangles to be made. */
    private final java.util.Map<Integer, Step> built = new java.util.concurrent.ConcurrentHashMap<>();
    private final java.util.concurrent.ExecutorService ahead = java.util.concurrent.Executors.newSingleThreadExecutor();

    /** Builds steps index-1 and index+1 in the background. */
    void prefetch(int index) {
        for (int i : new int[] {index + 1, index - 1, index + 2}) {
            if (i < 0 || i >= steps.length() || built.containsKey(i)) continue;
            final int at = i;
            ahead.execute(() -> step(at));
        }
    }

    /** One step's triangles (built once, then kept). */
    Step step(int index) {
        Step known = built.get(index);
        if (known != null) return known;
        Step made = make(index);
        if (made != null) built.put(index, made);
        return made;
    }

    private synchronized Step make(int index) {
        Step known = built.get(index);
        if (known != null) return known;
        try {
            JSONObject s = steps.getJSONObject(index);
            Step out = new Step();
            out.turns = s.optInt("turns", 1);
            out.radius = (float) s.optDouble("radius", 0.04);
            JSONArray built = s.getJSONArray("built"), fresh = s.getJSONArray("fresh");
            out.builtCount = corners(built);
            out.freshCount = corners(fresh);
            out.built = buffer(out.builtCount);
            out.fresh = buffer(out.freshCount);
            for (int i = 0; i < built.length(); i++) add(out.built, built.getJSONObject(i), false);
            for (int i = 0; i < fresh.length(); i++) add(out.fresh, fresh.getJSONObject(i), true);
            out.built.position(0);
            out.fresh.position(0);
            middle(out);
            return out;
        } catch (Exception e) {
            Log.e(LinkService.TAG, "ghost step " + index, e);
            return null;
        }
    }

    /** The middle of the box around all the step's corners (positions are the first 3 of 10 floats). */
    private static void middle(Step s) {
        float[] lo = {Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE}, hi = {-Float.MAX_VALUE, -Float.MAX_VALUE, -Float.MAX_VALUE};
        FloatBuffer[] buffers = {s.built, s.fresh};
        int[] counts = {s.builtCount, s.freshCount};
        for (int which = 0; which < 2; which++) {
            FloatBuffer b = buffers[which];
            int n = counts[which];
            for (int i = 0; i < n; i++)
                for (int k = 0; k < 3; k++) {
                    float v = b.get(i * FLOATS + k);
                    if (v < lo[k]) lo[k] = v;
                    if (v > hi[k]) hi[k] = v;
                }
        }
        if (lo[0] > hi[0]) return;
        s.cx = (lo[0] + hi[0]) / 2; s.cy = (lo[1] + hi[1]) / 2; s.cz = (lo[2] + hi[2]) / 2;
    }

    private int corners(JSONArray pieces) throws Exception {
        int n = 0;
        for (int i = 0; i < pieces.length(); i++) n += parts.getJSONObject(pieces.getJSONObject(i).getInt("part")).getInt("count") * 3;
        return n;
    }

    private static FloatBuffer buffer(int corners) {
        return ByteBuffer.allocateDirect(Math.max(1, corners) * FLOATS * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
    }

    private void add(FloatBuffer to, JSONObject piece, boolean moving) throws Exception {
        JSONObject part = parts.getJSONObject(piece.getInt("part"));
        int offset = part.getInt("offset"), count = part.getInt("count");
        JSONArray mj = piece.getJSONArray("m");
        float[] m = new float[16];
        for (int i = 0; i < 16; i++) m[i] = (float) mj.getDouble(i);
        float sx = 0, sy = 0, sz = 0, turn = 0;
        if (moving) {
            JSONArray push = piece.getJSONArray("push");
            float gap = (float) piece.optDouble("gap", 0);
            sx = (float) push.getDouble(0) * gap;
            sy = (float) push.getDouble(1) * gap;
            sz = (float) push.getDouble(2) * gap;
            turn = piece.optInt("turn", 0);
        }
        float[] c = new float[9];
        for (int t = 0; t < count; t++) {
            for (int k = 0; k < 3; k++) {
                int at = offset + (t * 9 + k * 3) * 4;
                float x = shapes.getFloat(at), y = shapes.getFloat(at + 4), z = shapes.getFloat(at + 8);
                c[3 * k] = m[0] * x + m[4] * y + m[8] * z + m[12];
                c[3 * k + 1] = m[1] * x + m[5] * y + m[9] * z + m[13];
                c[3 * k + 2] = m[2] * x + m[6] * y + m[10] * z + m[14];
            }
            float ax = c[3] - c[0], ay = c[4] - c[1], az = c[5] - c[2];
            float bx = c[6] - c[0], by = c[7] - c[1], bz = c[8] - c[2];
            float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
            float l = (float) Math.sqrt(nx * nx + ny * ny + nz * nz);
            if (l > 0) { nx /= l; ny /= l; nz /= l; }
            for (int k = 0; k < 3; k++) {
                to.put(c[3 * k]).put(c[3 * k + 1]).put(c[3 * k + 2]).put(nx).put(ny).put(nz).put(sx).put(sy).put(sz).put(turn);
            }
        }
    }

    private static byte[] read(AssetManager assets, String name) throws Exception {
        try (InputStream in = assets.open(name)) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[65536];
            int r;
            while ((r = in.read(buf)) > 0) out.write(buf, 0, r);
            return out.toByteArray();
        }
    }
}
