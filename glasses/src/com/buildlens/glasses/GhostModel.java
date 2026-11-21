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

    /** Builds one step's triangles. */
    Step step(int index) {
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
            return out;
        } catch (Exception e) {
            Log.e(LinkService.TAG, "ghost step " + index, e);
            return null;
        }
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
