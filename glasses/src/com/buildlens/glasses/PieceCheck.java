package com.buildlens.glasses;

import java.util.Arrays;
import java.util.Locale;

/**
 * Has the step's new piece really gone on? Looks at one camera picture of the build standing
 * on its spot beside the phone (the marker tells where that spot is) and answers DONE,
 * NOT_YET or UNSURE. Plain Java with nothing from Android, so it is tested on a computer
 * (tools/CheckTest.java on made-up pictures).
 *
 * How:
 *  1. The table's colour, from a ring of table round the spot.
 *  2. What is not table near the spot: the build's outline.
 *  3. The build may be put down at any turn and a little off the spot: try turns and
 *     shifts of the step's pieces (as dots, quick) against that outline, both as it was
 *     before the step and as it should be after it.
 *  4. The best few placings, drawn properly: the one whose colours hang together best wins.
 *  5. Where the new piece should show, pixel by pixel: does it look like the piece, or like
 *     what would be there without it (the table, or the piece behind)? Those votes decide.
 * Where the new piece is the same colour as what is behind it (a black axle into a black
 * block), or hidden from this side, there are too few votes and the answer is UNSURE.
 */
public final class PieceCheck {
    /** The build stands this far to the right of the marker's middle, clear of the phone (as on the phone). */
    public static final float OFFSET = 0.11f;
    /** The table is this far below the phone's screen, which shows the marker (a phone's thickness). */
    public static final float DROP = 0.008f;

    public enum Verdict { DONE, NOT_YET, UNSURE, NO_BUILD }

    public static final class Result {
        public Verdict verdict = Verdict.UNSURE;
        public float pDone = 0.5f;
        public int votesFor, votesAgainst, votesNeeded;
        public float turn, shiftX, shiftZ, fit;
        public boolean afterFitsBetter;
        public long ms;
        public String why = "";
        public float fitAtHint = -1, costAtHint = -1, startX, startZ, cost, placingsApartMm = -1;     // tests only

        @Override public String toString() {
            return String.format(Locale.US, "%s p=%.2f votes %d/%d (need %d) turn %.0f shift %.1f,%.1f mm fit %.2f%s %d ms %s",
                    verdict, pDone, votesFor, votesFor + votesAgainst, votesNeeded, Math.toDegrees(turn), shiftX * 1000, shiftZ * 1000,
                    fit, afterFitsBetter ? " (after fits)" : "", ms, why);
        }
    }

    private static final float FINE_PX_PER_MM = 1.6f;     // the picture is looked at with about this many pixels a millimetre
    private static final int MAX_GRID = 220;
    private static final float POINT_AREA = 4e-6f;         // one dot per 4 mm² of surface
    private static final float LUMA = 0.6f;                // brightness counts for less than colour (shading)
    /** How far off the spot the build may be put down (the ghost shows a ring there). */
    private static final float MAX_SHIFT = 0.022f;

    private final CheckModel model;
    private int prepared = -1;
    private float[] dotsBefore, dotsAfter;                 // x, y, z in the step's axes
    private int[] classBefore, classAfter;                 // each dot's colour

    public PieceCheck(CheckModel model) { this.model = model; }

    public int stepCount() { return model.stepCount(); }
    public float stepRadius(int step) { return model.step(step).radius; }
    public float stepHeight(int step) { return model.step(step).height; }

    // ------------------------------------------------------------------ the picture, resampled
    /** A patch of the picture, looked at in cells of s x s camera pixels. */
    static final class Grid {
        final int w, h;
        final float x0, y0, s, fx, fy, cx, cy;
        final float[] yuv;                                 // 3 per cell
        final float[] tx, ty;                              // where each cell's ray meets the table (marker axes)

        Grid(Frame f, float x0, float y0, float s, int w, int h, float fx, float fy, float cx, float cy, float[] pose) {
            this.x0 = x0; this.y0 = y0; this.s = s; this.w = w; this.h = h;
            this.fx = fx / s; this.fy = fy / s;
            this.cx = (cx + 0.5f - x0) / s - 0.5f;
            this.cy = (cy + 0.5f - y0) / s - 0.5f;
            yuv = new float[w * h * 3];
            tx = new float[w * h];
            ty = new float[w * h];
            float[] px = new float[3];
            // The camera's middle and the marker's axes, for meeting the table.
            float camX = -(pose[0] * pose[12] + pose[1] * pose[13] + pose[2] * pose[14]);
            float camY = -(pose[4] * pose[12] + pose[5] * pose[13] + pose[6] * pose[14]);
            float camZ = -(pose[8] * pose[12] + pose[9] * pose[13] + pose[10] * pose[14]);
            for (int j = 0; j < h; j++) {
                for (int i = 0; i < w; i++) {
                    int k = j * w + i;
                    f.average((int) (x0 + i * s), (int) (y0 + j * s), (int) (x0 + (i + 1) * s), (int) (y0 + (j + 1) * s), px);
                    yuv[3 * k] = px[0]; yuv[3 * k + 1] = px[1]; yuv[3 * k + 2] = px[2];
                    float dx = (i - this.cx) / this.fx, dy = (j - this.cy) / this.fy;
                    float mx = pose[0] * dx + pose[1] * dy + pose[2];
                    float my = pose[4] * dx + pose[5] * dy + pose[6];
                    float mz = pose[8] * dx + pose[9] * dy + pose[10];
                    float l = mz < -1e-6f ? (-DROP - camZ) / mz : 1e3f;
                    tx[k] = camX + l * mx;
                    ty[k] = camY + l * my;
                }
            }
        }

        /** Half as many cells each way, averaged. */
        Grid half() { return new Grid(this); }

        private Grid(Grid g) {
            w = g.w / 2; h = g.h / 2; s = g.s * 2; x0 = g.x0; y0 = g.y0;
            fx = g.fx / 2; fy = g.fy / 2;
            cx = (g.cx + 0.5f) / 2 - 0.5f; cy = (g.cy + 0.5f) / 2 - 0.5f;
            yuv = new float[w * h * 3];
            tx = new float[w * h];
            ty = new float[w * h];
            for (int j = 0; j < h; j++)
                for (int i = 0; i < w; i++) {
                    int k = j * w + i;
                    for (int c = 0; c < 3; c++) {
                        float sum = 0;
                        for (int q = 0; q < 4; q++) sum += g.yuv[3 * ((2 * j + (q >> 1)) * g.w + 2 * i + (q & 1)) + c];
                        yuv[3 * k + c] = sum / 4;
                    }
                    int a = (2 * j) * g.w + 2 * i, b = (2 * j + 1) * g.w + 2 * i + 1;
                    tx[k] = (g.tx[a] + g.tx[b]) / 2;
                    ty[k] = (g.ty[a] + g.ty[b]) / 2;
                }
        }
    }

    /** Squared colour distance, brightness counting for less (and darker for less still: shadows). */
    static float dist2(float y1, float u1, float v1, float y2, float u2, float v2) {
        float dy = (y1 - y2) * LUMA, du = u1 - u2, dv = v1 - v2;
        return dy * dy + du * du + dv * dv;
    }

    // ------------------------------------------------------------------ placing the build
    /** Camera from the step's axes (3 x 4, column-major): turned, shifted, standing on `ground`, beside the marker. */
    static float[] place(float[] pose, float turn, float sx, float sz, float ground) {
        float c = (float) Math.cos(turn), s = (float) Math.sin(turn);
        float[] a = new float[12];
        for (int r = 0; r < 3; r++) {
            float p0 = pose[r], p1 = pose[4 + r], p2 = pose[8 + r];
            a[r] = c * p0 + s * p1;                        // the build's x
            a[3 + r] = p2;                                 // its up: out of the table
            a[6 + r] = s * p0 - c * p1;                    // its z: towards the phone's bottom
            a[9 + r] = (sx + OFFSET) * p0 - sz * p1 + (-ground - DROP) * p2 + pose[12 + r];
        }
        return a;
    }

    static float[] times(float[] a, float[] m) {           // 3 x 4 by 3 x 4 (as 4 x 4 with 0 0 0 1 below)
        float[] o = new float[12];
        for (int col = 0; col < 4; col++)
            for (int r = 0; r < 3; r++) {
                float v = a[r] * m[3 * col] + a[3 + r] * m[3 * col + 1] + a[6 + r] * m[3 * col + 2];
                o[3 * col + r] = col == 3 ? v + a[9 + r] : v;
            }
        return o;
    }

    private void prepare(int step) {
        if (prepared == step) return;
        CheckModel.Step st = model.step(step);
        float[] before = new float[0], after = new float[0];
        int[] cb = new int[0], ca = new int[0];
        int nb = 0, na = 0;
        float carry = 0;
        int seq = 0;
        for (int p = 0; p < st.pieces(); p++) {
            float[] m = st.matrix[p], t = model.parts[st.part[p]];
            for (int k = 0; k < t.length; k += 9) {
                float[] v = new float[9];
                for (int q = 0; q < 3; q++) {
                    float x = t[k + 3 * q], y = t[k + 3 * q + 1], z = t[k + 3 * q + 2];
                    for (int r = 0; r < 3; r++) v[3 * q + r] = m[r] * x + m[3 + r] * y + m[6 + r] * z + m[9 + r];
                }
                float ax = v[3] - v[0], ay = v[4] - v[1], az = v[5] - v[2], bx = v[6] - v[0], by = v[7] - v[1], bz = v[8] - v[2];
                float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
                carry += (float) Math.sqrt(nx * nx + ny * ny + nz * nz) / 2 / POINT_AREA;
                while (carry >= 1) {
                    carry -= 1;
                    // Spread over the triangle by a fixed sequence (the same dots every time).
                    float r1 = ((seq * 0.618034f) % 1), r2 = ((seq * 0.754878f + 0.31f) % 1);
                    seq++;
                    if (r1 + r2 > 1) { r1 = 1 - r1; r2 = 1 - r2; }
                    float x = v[0] + r1 * ax + r2 * bx, y = v[1] + r1 * ay + r2 * by, z = v[2] + r1 * az + r2 * bz;
                    if (na * 3 + 3 > after.length) { after = Arrays.copyOf(after, Math.max(96, after.length * 2)); ca = Arrays.copyOf(ca, after.length / 3); }
                    after[3 * na] = x; after[3 * na + 1] = y; after[3 * na + 2] = z; ca[na] = st.colour[p]; na++;
                    if (!st.fresh[p]) {
                        if (nb * 3 + 3 > before.length) { before = Arrays.copyOf(before, Math.max(96, before.length * 2)); cb = Arrays.copyOf(cb, before.length / 3); }
                        before[3 * nb] = x; before[3 * nb + 1] = y; before[3 * nb + 2] = z; cb[nb] = st.colour[p]; nb++;
                    }
                }
            }
        }
        dotsBefore = Arrays.copyOf(before, nb * 3);
        dotsAfter = Arrays.copyOf(after, na * 3);
        classBefore = Arrays.copyOf(cb, nb);
        classAfter = Arrays.copyOf(ca, na);
        prepared = step;
    }

    /** The dots drawn into a mask: 1 where the build covers the cell. Returns how many cells. */
    private static int dots(float[] pts, float[] a, Grid g, byte[] mask) {
        Arrays.fill(mask, (byte) 0);
        int n = 0;
        for (int k = 0; k < pts.length; k += 3) {
            float x = pts[k], y = pts[k + 1], z = pts[k + 2];
            float cz = a[2] * x + a[5] * y + a[8] * z + a[11];
            if (cz < 0.02f) continue;
            float gx = (a[0] * x + a[3] * y + a[6] * z + a[9]) / cz * g.fx + g.cx;
            float gy = (a[1] * x + a[4] * y + a[7] * z + a[10]) / cz * g.fy + g.cy;
            int ix = (int) Math.floor(gx), iy = (int) Math.floor(gy);
            for (int q = 0; q < 4; q++) {
                int px = ix + (q & 1), py = iy + (q >> 1);
                if (px < 0 || py < 0 || px >= g.w || py >= g.h) continue;
                int idx = py * g.w + px;
                if (mask[idx] == 0) { mask[idx] = 1; n++; }
            }
        }
        return n;
    }

    private static float iou(byte[] mask, byte[] fg) {
        int both = 0, either = 0;
        for (int i = 0; i < mask.length; i++) {
            if (mask[i] != 0 && fg[i] != 0) both++;
            if (mask[i] != 0 || fg[i] != 0) either++;
        }
        return either == 0 ? 0 : both / (float) either;
    }

    /** The step's pieces drawn properly: each cell gets the nearest piece's number, or -1 for none. */
    private void draw(CheckModel.Step st, boolean withFresh, float[] a, Grid g, int[] label, float[] depth) {
        Arrays.fill(label, -1);
        Arrays.fill(depth, Float.MAX_VALUE);
        float[] q = new float[9];
        for (int p = 0; p < st.pieces(); p++) {
            if (st.fresh[p] && !withFresh) continue;
            float[] m = times(a, st.matrix[p]), t = model.parts[st.part[p]];
            triangles:
            for (int k = 0; k < t.length; k += 9) {
                for (int c = 0; c < 3; c++) {
                    float x = t[k + 3 * c], y = t[k + 3 * c + 1], z = t[k + 3 * c + 2];
                    float cz = m[2] * x + m[5] * y + m[8] * z + m[11];
                    if (cz < 0.02f) continue triangles;
                    q[3 * c] = (m[0] * x + m[3] * y + m[6] * z + m[9]) / cz * g.fx + g.cx;
                    q[3 * c + 1] = (m[1] * x + m[4] * y + m[7] * z + m[10]) / cz * g.fy + g.cy;
                    q[3 * c + 2] = cz;
                }
                fill(q, p, g, label, depth);
            }
        }
    }

    private static void fill(float[] q, int piece, Grid g, int[] label, float[] depth) {
        float x0 = q[0], y0 = q[1], x1 = q[3], y1 = q[4], x2 = q[6], y2 = q[7];
        float area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
        if (Math.abs(area) < 1e-6f) return;
        int minX = Math.max(0, (int) Math.ceil(Math.min(x0, Math.min(x1, x2))));
        int maxX = Math.min(g.w - 1, (int) Math.floor(Math.max(x0, Math.max(x1, x2))));
        int minY = Math.max(0, (int) Math.ceil(Math.min(y0, Math.min(y1, y2))));
        int maxY = Math.min(g.h - 1, (int) Math.floor(Math.max(y0, Math.max(y1, y2))));
        float inv = 1 / area;
        for (int py = minY; py <= maxY; py++) {
            for (int px = minX; px <= maxX; px++) {
                float w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) * inv;
                float w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) * inv;
                float w2 = 1 - w0 - w1;
                if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                float z = w0 * q[2] + w1 * q[5] + w2 * q[8];
                int idx = py * g.w + px;
                if (z < depth[idx]) { depth[idx] = z; label[idx] = piece; }
            }
        }
    }

    // ------------------------------------------------------------------ the check
    /**
     * Checks step `step` (0-based) in one picture. Lens in camera pixels; pose = camera from
     * marker, column-major (MarkerPose).
     */
    public Result check(Frame frame, float fx, float fy, float cx, float cy, float[] pose, int step) {
        long t0 = System.nanoTime();
        Result res = new Result();
        try {
            run(frame, fx, fy, cx, cy, pose, step, res);
        } finally {
            res.ms = (System.nanoTime() - t0) / 1000000;
        }
        return res;
    }

    private void run(Frame frame, float fx, float fy, float cx, float cy, float[] pose, int step, Result res) {
        CheckModel.Step st = model.step(step);
        prepare(step);
        float reach = st.radius + 0.03f;                   // how far from the spot the build may be
        // The patch of picture round the spot, sized so a millimetre is about FINE_PX_PER_MM cells.
        float[] mid = MarkerPose.project(pose, OFFSET, 0, -DROP + st.height / 2, fx, fy, cx, cy);
        if (mid[2] < 0.05f) { res.verdict = Verdict.UNSURE; res.why = "spot behind the camera"; return; }
        float pxPerMm = fx / mid[2] / 1000;
        float s = Math.max(1, pxPerMm / FINE_PX_PER_MM);
        float minX = Float.MAX_VALUE, minY = Float.MAX_VALUE, maxX = -Float.MAX_VALUE, maxY = -Float.MAX_VALUE;
        for (int c = 0; c < 8; c++) {
            float[] p = MarkerPose.project(pose, OFFSET + ((c & 1) == 0 ? -reach : reach), (c & 2) == 0 ? -reach : reach,
                    -DROP + ((c & 4) == 0 ? 0 : st.height + 0.01f), fx, fy, cx, cy);
            minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]);
            minY = Math.min(minY, p[1]); maxY = Math.max(maxY, p[1]);
        }
        float full = (maxX - minX) * (maxY - minY);
        minX = Math.max(0, minX); minY = Math.max(0, minY);
        maxX = Math.min(frame.width, maxX); maxY = Math.min(frame.height, maxY);
        if ((maxX - minX) * (maxY - minY) < full * 0.6f) { res.why = "the spot is not all in view"; return; }
        s = Math.max(s, Math.max(maxX - minX, maxY - minY) / MAX_GRID);
        int gw = (int) Math.ceil((maxX - minX) / s) & ~1, gh = (int) Math.ceil((maxY - minY) / s) & ~1;
        Grid fine = new Grid(frame, minX, minY, s, gw, gh, fx, fy, cx, cy, pose);
        Grid coarse = fine.half();
        float fineCellsPerMm = pxPerMm / s;

        // 1. The table: the ring of cells round the spot, away from the phone.
        float[] table = new float[3];
        float spread = tableColour(fine, st.radius + 0.012f, table);
        if (spread < 0) { res.why = "no table to be seen round the spot"; return; }
        float limit = Math.max(22, 3 * spread);

        // 2. What is not table (a shadow on the table still counts as table), near the spot.
        boolean[] near = new boolean[coarse.w * coarse.h];
        byte[] fg = new byte[near.length];
        float sumX = 0, sumY = 0;
        int fgCount = 0;
        for (int k = 0; k < fg.length; k++) {
            float ddx = coarse.tx[k] - OFFSET, ddy = coarse.ty[k];
            if (ddx * ddx + ddy * ddy > reach * reach) continue;
            near[k] = true;
            // Anything not the table's own colour, shadows included: they are next to the build anyway.
            if (dist2(coarse.yuv[3 * k], coarse.yuv[3 * k + 1], coarse.yuv[3 * k + 2], table[0], table[1], table[2]) > limit * limit) {
                fg[k] = 1; fgCount++; sumX += coarse.tx[k]; sumY += coarse.ty[k];
            }
        }
        byte[] mask = new byte[fg.length];
        int expected = dots(dotsAfter, place(pose, 0, 0, 0, st.groundAfter), coarse, mask);
        if (fgCount < expected * 0.15f) {
            // Only say so if the step's pieces would stand out from this table at all.
            boolean wouldShow = false;
            for (int p = 0; p < st.pieces(); p++) {
                float[] c = Frame.yuv(model.colours[st.colour[p]]);
                wouldShow |= dist2(c[0], c[1], c[2], table[0], table[1], table[2]) > 4 * limit * limit;
            }
            if (!wouldShow) { res.why = "the build's colours are too close to the table's"; return; }
            res.verdict = st.emptyBefore ? Verdict.NOT_YET : Verdict.NO_BUILD;
            res.pDone = 0;
            res.why = "nothing on the spot";
            return;
        }

        // 3. Turns and shifts, the step's pieces as dots: before the step and after it, from the
        // spot and from the middle of what is not table. The cost of a placing is how badly the
        // picture's colours fit it (see cost()).
        float midX = clampTo(sumX / fgCount - OFFSET, MAX_SHIFT), midZ = clampTo(-(sumY / fgCount), MAX_SHIFT);
        float[][] starts = {{0, 0}, {midX, midZ}, {midX + 0.008f, midZ}, {midX - 0.008f, midZ}, {midX, midZ + 0.008f}, {midX, midZ - 0.008f}};
        int ns = starts.length;
        int[] lab = new int[fg.length];
        float[] dep = new float[fg.length];
        float[][] candidates = new float[8][];            // turn, x, z, cost, hypothesis (1 = after)
        int nc = 0;
        for (int hyp = st.emptyBefore ? 1 : 0; hyp <= 1; hyp++) {
            float[] pts = hyp == 1 ? dotsAfter : dotsBefore;
            int[] cls = hyp == 1 ? classAfter : classBefore;
            float ground = hyp == 1 ? st.groundAfter : st.groundBefore;
            float[] costs = new float[24 * ns];
            for (int i = 0; i < costs.length; i++) {
                float[] start = starts[i / 24];
                float turn = (float) (i % 24 * Math.PI / 12);
                if (Math.abs(Math.atan2(Math.sin(turn), Math.cos(turn))) > turnRange + 1e-3) { costs[i] = -1; continue; }
                dotLabels(pts, cls, place(pose, turn, start[0], start[1], ground), coarse, lab, dep);
                costs[i] = cost(coarse, lab, near, table);
            }
            // The three best turns, not next to each other, each fine-tuned.
            for (int pick = 0; pick < 3; pick++) {
                int best = -1;
                for (int i = 0; i < costs.length; i++) if (costs[i] >= 0 && (best < 0 || costs[i] < costs[best])) best = i;
                if (best < 0) break;
                for (int o = -1; o <= 1; o++) for (int st0 = 0; st0 < ns; st0++) costs[st0 * 24 + (best % 24 + 24 + o) % 24] = -1;
                float[] start = starts[best / 24];
                candidates[nc++] = refine(pts, cls, ground, pose, coarse, near, table, lab, dep, (float) (best % 24 * Math.PI / 12), start[0], start[1], hyp);
            }
        }

        if (testHint != null) {                            // tests: how well the real placing fits, for comparison
            boolean after = st.emptyBefore || testHint[3] == 1;
            float[] a = place(pose, testHint[0], testHint[1], testHint[2], after ? st.groundAfter : st.groundBefore);
            dots(after ? dotsAfter : dotsBefore, a, coarse, mask);
            res.fitAtHint = iou(mask, fg);
            dotLabels(after ? dotsAfter : dotsBefore, after ? classAfter : classBefore, a, coarse, lab, dep);
            res.costAtHint = cost(coarse, lab, near, table);
            res.startX = starts[1][0]; res.startZ = starts[1][1];
        }

        // 4. Draw the best placings properly; keep the one the picture's colours fit best.
        int[] la = new int[fine.w * fine.h], lb = new int[la.length], fineCls = new int[la.length];
        float[] depth = new float[la.length];
        boolean[] nearFine = new boolean[la.length];
        for (int k = 0; k < la.length; k++) {
            float ddx = fine.tx[k] - OFFSET, ddy = fine.ty[k];
            nearFine[k] = ddx * ddx + ddy * ddy <= reach * reach;
        }
        float bestScore = Float.MAX_VALUE;
        float[] chosen = null;
        float bestAfter = Float.MAX_VALUE, bestBefore = Float.MAX_VALUE;
        Arrays.sort(candidates, 0, nc, (p, q) -> Float.compare(p[3], q[3]));
        float[] bestBeforeCand = null;
        int[] tried = new int[2];
        for (int c = 0; c < nc; c++) {
            float[] cand = candidates[c];
            boolean after = cand[4] == 1;
            if (tried[after ? 1 : 0]++ >= 2) continue;        // the two best of each
            draw(st, after, place(pose, cand[0], cand[1], cand[2], after ? st.groundAfter : st.groundBefore), fine, la, depth);
            for (int k = 0; k < la.length; k++) fineCls[k] = la[k] < 0 ? -1 : st.colour[la[k]];
            float score = cost(fine, fineCls, nearFine, table);
            if (after) bestAfter = Math.min(bestAfter, score);
            else if (score < bestBefore) { bestBefore = score; bestBeforeCand = cand; }
            if (score < bestScore) { bestScore = score; chosen = cand; }
        }
        if (chosen == null) { res.why = "build not found"; return; }
        res.turn = chosen[0]; res.shiftX = chosen[1]; res.shiftZ = chosen[2];
        res.afterFitsBetter = bestAfter < bestBefore;
        // How much of where the build is drawn shows something other than plain table.
        int drawn = dots(chosen[4] == 1 ? dotsAfter : dotsBefore, place(pose, chosen[0], chosen[1], chosen[2],
                chosen[4] == 1 ? st.groundAfter : st.groundBefore), coarse, mask), covered = 0;
        for (int k = 0; k < mask.length; k++) if (mask[k] != 0 && fg[k] != 0) covered++;
        res.fit = drawn == 0 ? 0 : covered / (float) drawn;
        dotLabels(chosen[4] == 1 ? dotsAfter : dotsBefore, chosen[4] == 1 ? classAfter : classBefore, place(pose, chosen[0], chosen[1], chosen[2],
                chosen[4] == 1 ? st.groundAfter : st.groundBefore), coarse, lab, dep);
        res.cost = cost(coarse, lab, near, table);
        if (res.fit < 0.35f) { res.why = "the build does not look like this step"; return; }

        // 5. Votes where the new piece should show, with the build where it fits best.
        voteAt(st, pose, chosen, fine, la, lb, depth, table, fineCellsPerMm, res);
        lastLabels = la.clone(); lastFresh = st.fresh; lastX0 = fine.x0; lastY0 = fine.y0; lastS = fine.s; lastW = fine.w; lastH = fine.h;
        // A copy of the new piece lying beside the build can pull the placing over onto it.
        // With the piece really on, the build placed without it lands in the same place (it
        // is the same build, less one piece); pulled over, the two disagree. Both must agree.
        if (res.verdict == Verdict.DONE && bestBeforeCand != null && bestBeforeCand != chosen) {
            float dx = bestBeforeCand[1] - chosen[1], dz = bestBeforeCand[2] - chosen[2];
            double dt = Math.abs(Math.atan2(Math.sin(bestBeforeCand[0] - chosen[0]), Math.cos(bestBeforeCand[0] - chosen[0])));
            res.placingsApartMm = (float) Math.sqrt(dx * dx + dz * dz) * 1000;
            if (res.placingsApartMm > 8 || dt > Math.toRadians(25)) {
                res.verdict = Verdict.UNSURE;
                res.why = String.format(Locale.US, "with and without the new piece, the build fits %.0f mm / %.0f deg apart",
                        res.placingsApartMm, Math.toDegrees(dt));
            }
        }
    }

    private void voteAt(CheckModel.Step st, float[] pose, float[] at, Grid fine, int[] la, int[] lb, float[] depth, float[] table,
                        float cellsPerMm, Result res) {
        draw(st, true, place(pose, at[0], at[1], at[2], st.groundAfter), fine, la, depth);
        if (st.emptyBefore) Arrays.fill(lb, -1);
        else draw(st, false, place(pose, at[0], at[1], at[2], st.groundBefore), fine, lb, depth);
        vote(st, fine, la, lb, table, cellsPerMm, res);
    }

    // For tests (tools/CheckTest.java draws them over the picture): the last check's drawing of
    // the build after the step, cell by cell, and where that patch is in the picture.
    /**
     * How far from the ghost's turn the build may have been put down, in radians. The ghost
     * shows the build on the spot at turn 0, so people put it down about that way; looking
     * only near it avoids taking the build for itself turned round. Math.PI = any turn.
     */
    public float turnRange = (float) Math.PI;

    /** Tests: the real placing (turn, x, z, 1 = new pieces on), to report how well it fits. */
    public float[] testHint;
    int[] lastLabels;
    boolean[] lastFresh;
    float lastX0, lastY0, lastS;
    int lastW, lastH;

    public int[] lastLabelsForTest() { return lastLabels; }
    public boolean lastFreshForTest(int piece) { return lastFresh[piece]; }
    public float lastX0ForTest() { return lastX0; }
    public float lastY0ForTest() { return lastY0; }
    public float lastSForTest() { return lastS; }
    public int lastWForTest() { return lastW; }

    private static float clampTo(float v, float r) { return Math.max(-r, Math.min(r, v)); }

    /**
     * How far a colour is from the table's: the table as it is, or the table in shadow
     * (darker, same colour) with a little added for being darker, so a deep black piece is
     * not taken for a shadow. Squared, like dist2.
     */
    static float tableCost(float y, float u, float v, float[] t) {
        float d = dist2(y, u, v, t[0], t[1], t[2]);
        float k = y / Math.max(8, t[0]);
        if (k > 0.25f && k < 1) {
            float dark = (1 - k) * t[0] * 0.25f;
            float ds = dist2(y, u, v, y, 128 + (t[1] - 128) * k, 128 + (t[2] - 128) * k) + dark * dark;
            d = Math.min(d, ds);
        }
        return d;
    }

    private static final float CAP = 60 * 60;

    /**
     * How badly the picture fits a placing (lower is better): every cell near the spot is
     * either table (its distance from the table's colour, shadows allowed) or a piece of some
     * colour (its distance from the mean colour of all cells given that colour). The right
     * placing covers what is not table and gives each colour one look.
     */
    private float cost(Grid g, int[] cls, boolean[] near, float[] table) {
        int nc = model.colours.length;
        float[] sum = new float[nc * 3];
        int[] count = new int[nc];
        for (int k = 0; k < cls.length; k++) {
            if (!near[k] || cls[k] < 0) continue;
            for (int q = 0; q < 3; q++) sum[3 * cls[k] + q] += g.yuv[3 * k + q];
            count[cls[k]]++;
        }
        for (int c = 0; c < nc; c++) if (count[c] > 0) for (int q = 0; q < 3; q++) sum[3 * c + q] /= count[c];
        float total = 0;
        int n = 0;
        for (int k = 0; k < cls.length; k++) {
            if (!near[k]) continue;
            float y = g.yuv[3 * k], u = g.yuv[3 * k + 1], v = g.yuv[3 * k + 2];
            int c = cls[k];
            float d = c < 0 ? tableCost(y, u, v, table) : dist2(y, u, v, sum[3 * c], sum[3 * c + 1], sum[3 * c + 2]);
            total += Math.min(d, CAP);
            n++;
        }
        return n == 0 ? Float.MAX_VALUE : total / n;
    }

    /** The dots drawn with their colours: each cell gets the nearest dot's colour, or -1. */
    private static void dotLabels(float[] pts, int[] cls, float[] a, Grid g, int[] lab, float[] dep) {
        Arrays.fill(lab, -1);
        Arrays.fill(dep, Float.MAX_VALUE);
        for (int k = 0, d = 0; k < pts.length; k += 3, d++) {
            float x = pts[k], y = pts[k + 1], z = pts[k + 2];
            float cz = a[2] * x + a[5] * y + a[8] * z + a[11];
            if (cz < 0.02f) continue;
            float gx = (a[0] * x + a[3] * y + a[6] * z + a[9]) / cz * g.fx + g.cx;
            float gy = (a[1] * x + a[4] * y + a[7] * z + a[10]) / cz * g.fy + g.cy;
            int ix = (int) Math.floor(gx), iy = (int) Math.floor(gy);
            for (int q = 0; q < 4; q++) {
                int px = ix + (q & 1), py = iy + (q >> 1);
                if (px < 0 || py < 0 || px >= g.w || py >= g.h) continue;
                int idx = py * g.w + px;
                if (cz < dep[idx]) { dep[idx] = cz; lab[idx] = cls[d]; }
            }
        }
    }

    /** Fine-tunes a placing: shift and turn in shrinking steps while the cost goes down. */
    private float[] refine(float[] pts, int[] cls, float ground, float[] pose, Grid g, boolean[] near, float[] table,
                           int[] lab, float[] dep, float turn, float x, float z, int hyp) {
        dotLabels(pts, cls, place(pose, turn, x, z, ground), g, lab, dep);
        float best = cost(g, lab, near, table);
        float step = 0.004f, turnStep = (float) Math.toRadians(7.5);
        for (int round = 0; round < 4; round++) {
            boolean better = true;
            for (int tries = 0; better && tries < 8; tries++) {
                better = false;
                float[][] moves = {{step, 0, 0}, {-step, 0, 0}, {0, step, 0}, {0, -step, 0}, {0, 0, turnStep}, {0, 0, -turnStep}};
                for (float[] m : moves) {
                    float nx = clampTo(x + m[0], MAX_SHIFT), nz = clampTo(z + m[1], MAX_SHIFT), nt = turn + m[2];
                    dotLabels(pts, cls, place(pose, nt, nx, nz, ground), g, lab, dep);
                    float f = cost(g, lab, near, table);
                    if (f < best - 1e-3f) { best = f; x = nx; z = nz; turn = nt; better = true; }
                }
            }
            step /= 2;
            turnStep /= 2;
        }
        return new float[] {turn, x, z, best, hyp};
    }

    /** The table's colour (median Y, U, V) from cells on the table between r and r + 2.5 cm of the spot, away from the phone. */
    private static float tableColour(Grid g, float r, float[] out) {
        int n = 0;
        float[] ys = new float[g.w * g.h], us = new float[ys.length], vs = new float[ys.length];
        for (int k = 0; k < g.w * g.h; k++) {
            float dx = g.tx[k] - OFFSET, dy = g.ty[k], d = (float) Math.sqrt(dx * dx + dy * dy);
            if (d < r || d > r + 0.025f || g.tx[k] < 0.048f) continue;
            ys[n] = g.yuv[3 * k]; us[n] = g.yuv[3 * k + 1]; vs[n] = g.yuv[3 * k + 2];
            n++;
        }
        if (n < 30) return -1;
        out[0] = median(ys, n); out[1] = median(us, n); out[2] = median(vs, n);
        float[] dev = new float[n];
        for (int i = 0; i < n; i++) dev[i] = (float) Math.sqrt(dist2(ys[i], us[i], vs[i], out[0], out[1], out[2]));
        return median(dev, n) * 1.4826f;
    }

    private static float median(float[] a, int n) {
        float[] c = Arrays.copyOf(a, n);
        Arrays.sort(c);
        return c[n / 2];
    }

    private static boolean edge(int[] label, CheckModel.Step st, Grid g, int k) {
        int i = k % g.w, j = k / g.w;
        int c = cls(st, label[k]);
        return (i > 0 && cls(st, label[k - 1]) != c) || (i < g.w - 1 && cls(st, label[k + 1]) != c)
                || (j > 0 && cls(st, label[k - g.w]) != c) || (j < g.h - 1 && cls(st, label[k + g.w]) != c);
    }

    /** A cell's colour class: the piece's colour, or the table (one past the last colour). */
    private static int cls(CheckModel.Step st, int piece) { return piece < 0 ? -1 : st.colour[piece]; }

    /** Step 5: each cell where the new piece should show votes for "piece there" or "not". */
    private void vote(CheckModel.Step st, Grid g, int[] la, int[] lb, float[] table, float cellsPerMm, Result res) {
        int nc = model.colours.length;
        // What each colour looks like in this picture: from cells that show the same colour with or without the new piece.
        float[] sum = new float[nc * 3];
        int[] count = new int[nc];
        for (int k = 0; k < la.length; k++) {
            if (la[k] < 0 || lb[k] < 0 || st.colour[la[k]] != st.colour[lb[k]] || edge(la, st, g, k) || edge(lb, st, g, k)) continue;
            int c = st.colour[la[k]];
            for (int q = 0; q < 3; q++) sum[3 * c + q] += g.yuv[3 * k + q];
            count[c]++;
        }
        // A colour not seen elsewhere: its own colour, as bright as the others turned out.
        float gain = 1;
        float[] ratios = new float[nc];
        int nr = 0;
        for (int c = 0; c < nc; c++) {
            float[] want = Frame.yuv(model.colours[c]);
            if (count[c] >= 20 && want[0] > 50) ratios[nr++] = (sum[3 * c] / count[c]) / want[0];
        }
        if (nr > 0) gain = Math.max(0.5f, Math.min(1.8f, median(ratios, nr)));
        float[][] seen = new float[nc + 1][];
        for (int c = 0; c < nc; c++) {
            if (count[c] >= 20) seen[c] = new float[] {sum[3 * c] / count[c], sum[3 * c + 1] / count[c], sum[3 * c + 2] / count[c]};
            else {
                float[] want = Frame.yuv(model.colours[c]);
                seen[c] = new float[] {want[0] * gain, (want[1] - 128) * gain + 128, (want[2] - 128) * gain + 128};
            }
        }
        seen[nc] = table;
        int yes = 0, no = 0;
        for (int k = 0; k < la.length; k++) {
            if (la[k] < 0 || !st.fresh[la[k]] || edge(la, st, g, k)) continue;
            float[] a = seen[st.colour[la[k]]], b = lb[k] < 0 ? seen[nc] : seen[st.colour[lb[k]]];
            if (dist2(a[0], a[1], a[2], b[0], b[1], b[2]) < 20 * 20) continue;    // looks the same either way
            float da = dist2(g.yuv[3 * k], g.yuv[3 * k + 1], g.yuv[3 * k + 2], a[0], a[1], a[2]);
            float db = dist2(g.yuv[3 * k], g.yuv[3 * k + 1], g.yuv[3 * k + 2], b[0], b[1], b[2]);
            if (da < 0.64f * db) yes++;
            else if (db < 0.64f * da) no++;
        }
        res.votesFor = yes;
        res.votesAgainst = no;
        res.votesNeeded = Math.max(6, Math.round(8 * cellsPerMm * cellsPerMm));
        if (yes + no < res.votesNeeded) {
            res.verdict = Verdict.UNSURE;
            res.pDone = 0.5f;
            res.why = "the new piece can't be told apart from here";
            return;
        }
        res.pDone = yes / (float) (yes + no);
        res.verdict = res.pDone >= 0.7f ? Verdict.DONE : res.pDone <= 0.3f ? Verdict.NOT_YET : Verdict.UNSURE;
    }
}
