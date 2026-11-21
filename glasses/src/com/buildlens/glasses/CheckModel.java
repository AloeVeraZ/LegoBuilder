package com.buildlens.glasses;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Every step's pieces with their colours, for the set-down check (assets/check.bin, made by
 * make_assets.py). Plain Java with nothing from Android, so it is tested on a computer too
 * (tools/CheckTest.java).
 *
 * Pieces stand in the step's own axes like the ghost's: x right, y up, centred on the
 * assembly; a step's build rests on its lowest point.
 */
public final class CheckModel {
    /** The colours pieces come in, sRGB 0..1. */
    public final float[][] colours;
    /** Each part's triangles, 9 floats each (metres). */
    final float[][] parts;
    final Step[] steps;

    /** One step: the pieces built so far and the ones it adds. */
    public static final class Step {
        public final float radius, height;
        final int[] part, colour;
        final boolean[] fresh;
        final float[][] matrix;          // 3 x 4, column by column
        /** Lowest point of the build before / after the step (it stands on that). */
        float groundBefore, groundAfter;
        boolean emptyBefore;             // a sub-build's first step starts from nothing

        Step(float radius, float height, int n) {
            this.radius = radius;
            this.height = height;
            part = new int[n];
            colour = new int[n];
            fresh = new boolean[n];
            matrix = new float[n][];
        }

        public int pieces() { return part.length; }
    }

    private CheckModel(float[][] colours, float[][] parts, Step[] steps) {
        this.colours = colours;
        this.parts = parts;
        this.steps = steps;
    }

    public int stepCount() { return steps.length; }

    public Step step(int index) { return steps[index]; }

    public static CheckModel read(InputStream in) throws IOException {
        ByteArrayOutputStream all = new ByteArrayOutputStream();
        byte[] buf = new byte[65536];
        int r;
        while ((r = in.read(buf)) > 0) all.write(buf, 0, r);
        ByteBuffer b = ByteBuffer.wrap(all.toByteArray()).order(ByteOrder.LITTLE_ENDIAN);
        if (b.get() != 'B' || b.get() != 'L' || b.get() != 'C' || b.get() != 'K') throw new IOException("not a check model");
        if (b.getInt() != 1) throw new IOException("unknown check model version");
        float[][] colours = new float[b.getInt()][3];
        for (float[] c : colours) for (int i = 0; i < 3; i++) c[i] = b.getFloat();
        float[][] parts = new float[b.getInt()][];
        for (int p = 0; p < parts.length; p++) {
            parts[p] = new float[b.getInt() * 9];
            for (int i = 0; i < parts[p].length; i++) parts[p][i] = b.getFloat();
        }
        Step[] steps = new Step[b.getInt()];
        for (int s = 0; s < steps.length; s++) {
            float radius = b.getFloat(), height = b.getFloat();
            Step st = steps[s] = new Step(radius, height, b.getInt());
            for (int i = 0; i < st.pieces(); i++) {
                st.part[i] = b.getInt();
                st.colour[i] = b.getInt();
                st.fresh[i] = b.getInt() != 0;
                st.matrix[i] = new float[12];
                for (int k = 0; k < 12; k++) st.matrix[i][k] = b.getFloat();
            }
        }
        CheckModel model = new CheckModel(colours, parts, steps);
        for (Step st : steps) model.findGround(st);
        return model;
    }

    private void findGround(Step st) {
        float before = Float.MAX_VALUE, after = Float.MAX_VALUE;
        boolean any = false;
        for (int i = 0; i < st.pieces(); i++) {
            float[] m = st.matrix[i], t = parts[st.part[i]];
            for (int v = 0; v < t.length; v += 3) {
                float y = m[1] * t[v] + m[4] * t[v + 1] + m[7] * t[v + 2] + m[10];
                if (y < after) after = y;
                if (!st.fresh[i] && y < before) before = y;
            }
            any |= !st.fresh[i];
        }
        st.groundAfter = after;
        st.groundBefore = any ? before : after;
        st.emptyBefore = !any;
    }
}
