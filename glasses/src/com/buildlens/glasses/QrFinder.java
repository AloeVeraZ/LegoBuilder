package com.buildlens.glasses;

/**
 * Finds the table marker (the QR code the phone shows, "BUILDLENS-TABLE") in a grey camera
 * picture. Plain Java with nothing from Android, so it can be tested on a computer
 * (tools/MarkerTest.java).
 *
 * The code is not read like a normal QR code. The marker is always the same picture, so
 * this finds its three big corner squares and the small square near the fourth corner,
 * then checks every one of its 27 x 27 cells against the known picture. Another QR code,
 * or something that only looks like one, does not match.
 */
public final class QrFinder {
    /** Cells across the marker, including its one-cell white border. */
    public static final int CELLS = 27;

    /**
     * The marker cell by cell, exactly as the phone draws it (CoreImage's QR generator,
     * "BUILDLENS-TABLE", error correction H: version 2 plus a one-cell border).
     */
    static final String[] PICTURE = {
        "...........................",
        ".#######..###.##.#.#######.",
        ".#.....#..###...#..#.....#.",
        ".#.###.#..#######..#.###.#.",
        ".#.###.#..##...#...#.###.#.",
        ".#.###.#.##....#.#.#.###.#.",
        ".#.....#..#....#.#.#.....#.",
        ".#######.#.#.#.#.#.#######.",
        ".........#.#.#..#..........",
        "...##..######.#.####.#.....",
        ".#..##..###...#...##...##..",
        ".#...###.#.#.#.##.#..#.#...",
        ".##.###..###.#.#....##...#.",
        "....#.##....####..#..#..##.",
        "...#..#.#..#..#..######....",
        "..#.########.#.###..#.#.##.",
        ".#.#.#..###.#..#.#.##.##.#.",
        ".......######...#######.#..",
        ".........##.#.#.##...###.#.",
        ".#######.##.#..###.#.##....",
        ".#.....#..##.##..#...##..#.",
        ".#.###.#..####.#.#####..#..",
        ".#.###.#.#.#...#...#.#.#.#.",
        ".#.###.#.##...##..#...#.#..",
        ".#.....#..#####..###...#.#.",
        ".#######..##.###.#..#....#.",
        "...........................",
    };

    /** Where the four squares' middles are, in cells (x right, y down, 0..27). */
    public static final float[] ANCHORS = {4.5f, 4.5f, 22.5f, 4.5f, 4.5f, 22.5f, 19.5f, 19.5f};

    /** At least this share of the cells must match the marker. A different QR code scores about 0.6. */
    static final float MIN_MATCH = 0.82f;

    /** The result. */
    public static final class Found {
        /** Marker cells (x right, y down, 0..27 across) to picture pixels: h[0..8], h[8] = 1. */
        public float[] mapping;
        /** The four squares' middles as first found, in pixels, in the order of ANCHORS. */
        public final float[] points;
        public final float match;
        /** Picture pixels per cell, roughly: how near the marker is. */
        public final float cell;

        Found(float[] mapping, float[] points, float match, float cell) {
            this.mapping = mapping;
            this.points = points;
            this.match = match;
            this.cell = cell;
        }

        /** Where a point on the marker (in cells) is in the picture. */
        public float[] at(float u, float v) {
            float[] h = mapping;
            float w = h[6] * u + h[7] * v + 1;
            return new float[] {(h[0] * u + h[1] * v + h[2]) / w, (h[3] * u + h[4] * v + h[5]) / w};
        }
    }

    private int width, height;
    private byte[] dark = new byte[0];
    private int[] sums = new int[0];

    /**
     * Looks for the marker in a grey picture (one byte per pixel, `stride` bytes per row).
     * Returns null when it is not there.
     */
    public Found find(byte[] grey, int width, int height, int stride) {
        this.width = width;
        this.height = height;
        threshold(grey, stride);
        float[] c = new float[4 * 512];         // x, y, cell size, times seen
        int n = 0;
        int[] runs = new int[5];
        for (int y = 0; y < height; y += 1) {
            int state = 0;
            runs[0] = runs[1] = runs[2] = runs[3] = runs[4] = 0;
            int row = y * width;
            for (int x = 0; x < width; x++) {
                boolean d = dark[row + x] != 0;
                if (d == ((state & 1) == 0)) {          // still in the run this state counts
                    runs[state]++;
                    continue;
                }
                if (state < 4) {
                    if (state == 0 && !d && runs[0] == 0) continue;  // light before the first dark
                    runs[++state] = 1;
                    continue;
                }
                // Five runs: dark light dark light dark, now light again.
                if (ratioOk(runs)) {
                    float cx = x - runs[4] - runs[3] - (runs[2] + 1) / 2f;
                    n = add(c, n, cx, y, runs);
                }
                // Keep the last two runs as the start of the next try.
                runs[0] = runs[2]; runs[1] = runs[3]; runs[2] = runs[4]; runs[3] = 1; runs[4] = 0;
                state = 3;
            }
            if (state == 4 && ratioOk(runs)) n = add(c, n, width - runs[4] - runs[3] - (runs[2] + 1) / 2f, y, runs);
        }
        Found found = pick(c, n);
        if (found != null) found.mapping = MarkerRefine.refine(grey, width, height, stride, found.mapping);
        return found;
    }

    // ------------------------------------------------------------ dark and light
    /** Dark is darker than the area around it, so uneven light and screen glare do not matter. */
    private void threshold(byte[] grey, int stride) {
        int w = width, h = height;
        if (dark.length < w * h) dark = new byte[w * h];
        if (sums.length < (w + 1) * (h + 1)) sums = new int[(w + 1) * (h + 1)];
        for (int y = 0; y < h; y++) {
            int line = 0, from = y * stride, at = (y + 1) * (w + 1);
            sums[at] = 0;
            for (int x = 0; x < w; x++) {
                line += grey[from + x] & 0xff;
                sums[at + x + 1] = sums[at - (w + 1) + x + 1] + line;
            }
        }
        int r = Math.max(6, Math.min(w, h) / 24);
        for (int y = 0; y < h; y++) {
            int y0 = Math.max(0, y - r), y1 = Math.min(h, y + r + 1);
            for (int x = 0; x < w; x++) {
                int x0 = Math.max(0, x - r), x1 = Math.min(w, x + r + 1);
                int total = sums[y1 * (w + 1) + x1] - sums[y0 * (w + 1) + x1] - sums[y1 * (w + 1) + x0] + sums[y0 * (w + 1) + x0];
                int count = (x1 - x0) * (y1 - y0);
                int v = grey[y * stride + x] & 0xff;
                dark[y * w + x] = (byte) (v * count * 16 < total * 15 - count * 16 * 3 ? 1 : 0);
            }
        }
    }

    // ------------------------------------------------------------ the three big squares
    /** Runs across a big square: 1 dark, 1 light, 3 dark, 1 light, 1 dark. */
    private static boolean ratioOk(int[] r) {
        int total = r[0] + r[1] + r[2] + r[3] + r[4];
        if (total < 7) return false;
        float m = total / 7f, slack = m * 0.7f;
        return Math.abs(m - r[0]) < slack && Math.abs(m - r[1]) < slack && Math.abs(3 * m - r[2]) < 3 * slack
                && Math.abs(m - r[3]) < slack && Math.abs(m - r[4]) < slack;
    }

    private int add(float[] c, int n, float cx, int cy, int[] runs) {
        int total = runs[0] + runs[1] + runs[2] + runs[3] + runs[4];
        // Check the other way through the middle, and then across again from there.
        float y = across(Math.round(cx), cy, total, false);
        if (Float.isNaN(y)) return n;
        float x = across(Math.round(y), Math.round(cx), total, true);
        if (Float.isNaN(x)) return n;
        float cell = total / 7f;
        for (int i = 0; i < n; i++) {
            float dx = c[4 * i] - x, dy = c[4 * i + 1] - y;
            if (dx * dx + dy * dy < cell * cell * 2.5f) {
                float k = c[4 * i + 3];
                c[4 * i] = (c[4 * i] * k + x) / (k + 1);
                c[4 * i + 1] = (c[4 * i + 1] * k + y) / (k + 1);
                c[4 * i + 2] = (c[4 * i + 2] * k + cell) / (k + 1);
                c[4 * i + 3] = k + 1;
                return n;
            }
        }
        if (4 * n + 4 > c.length) return n;
        c[4 * n] = x; c[4 * n + 1] = y; c[4 * n + 2] = cell; c[4 * n + 3] = 1;
        return n + 1;
    }

    /**
     * Counts the five runs through (fixed, from) along one line, checks them and returns the
     * middle of the centre run, or NaN. `horizontal`: the line is the row `fixed`.
     */
    private float across(int fixed, int from, int expected, boolean horizontal) {
        int limit = horizontal ? width : height;
        if (fixed < 0 || fixed >= (horizontal ? height : width) || from < 0 || from >= limit) return Float.NaN;
        if (!isDark(fixed, from, horizontal)) return Float.NaN;
        int max = expected * 2;
        int[] r = new int[5];
        int i = from;
        while (i >= 0 && isDark(fixed, i, horizontal)) { r[2]++; i--; }
        while (i >= 0 && !isDark(fixed, i, horizontal) && r[1] <= max) { r[1]++; i--; }
        while (i >= 0 && isDark(fixed, i, horizontal) && r[0] <= max) { r[0]++; i--; }
        int start = i + 1 + r[0] + r[1];
        i = from + 1;
        while (i < limit && isDark(fixed, i, horizontal)) { r[2]++; i++; }
        while (i < limit && !isDark(fixed, i, horizontal) && r[3] <= max) { r[3]++; i++; }
        while (i < limit && isDark(fixed, i, horizontal) && r[4] <= max) { r[4]++; i++; }
        int total = r[0] + r[1] + r[2] + r[3] + r[4];
        if (r[0] == 0 || r[1] == 0 || r[3] == 0 || r[4] == 0) return Float.NaN;
        if (Math.abs(total - expected) * 2 > expected * 1.4f + 4) return Float.NaN;
        if (!ratioOk(r)) return Float.NaN;
        return start + (r[2] - 1) / 2f;     // pixel centres are at whole numbers
    }

    private boolean isDark(int fixed, int i, boolean horizontal) {
        return horizontal ? dark[fixed * width + i] != 0 : dark[i * width + fixed] != 0;
    }

    // ------------------------------------------------------------ which three, and the check
    private Found pick(float[] c, int n) {
        // Keep the most often seen candidates; noise is rarely seen on more than one row.
        int[] order = new int[n];
        int seen = 0;
        for (int i = 0; i < n; i++) if (c[4 * i + 3] >= 2) order[seen++] = i;
        int keep = Math.min(seen, 12);
        for (int i = 0; i < keep; i++)
            for (int j = i + 1; j < seen; j++)
                if (c[4 * order[j] + 3] > c[4 * order[i] + 3]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
        Found best = null;
        for (int a = 0; a < keep; a++)
            for (int b = a + 1; b < keep; b++)
                for (int d = b + 1; d < keep; d++) {
                    Found f = tryThree(c, order[a], order[b], order[d]);
                    if (f != null && (best == null || f.match > best.match)) best = f;
                }
        return best;
    }

    private Found tryThree(float[] c, int i, int j, int k) {
        float si = c[4 * i + 2], sj = c[4 * j + 2], sk = c[4 * k + 2];
        float big = Math.max(si, Math.max(sj, sk)), small = Math.min(si, Math.min(sj, sk));
        if (big > small * 2f) return null;
        // The corner square is the one across from the longest side.
        float dij = dist(c, i, j), djk = dist(c, j, k), dik = dist(c, i, k);
        int tl, p, q;
        if (djk >= dij && djk >= dik) { tl = i; p = j; q = k; }
        else if (dik >= dij) { tl = j; p = i; q = k; }
        else { tl = k; p = i; q = j; }
        float x0 = c[4 * tl], y0 = c[4 * tl + 1];
        float ax = c[4 * p] - x0, ay = c[4 * p + 1] - y0, bx = c[4 * q] - x0, by = c[4 * q + 1] - y0;
        if (ax * by - ay * bx < 0) { int t = p; p = q; q = t; float u = ax; ax = bx; bx = u; u = ay; ay = by; by = u; }
        float cell = (si + sj + sk) / 3f;
        float la = (float) Math.hypot(ax, ay) / cell, lb = (float) Math.hypot(bx, by) / cell;
        if (la < 9 || la > 36 || lb < 9 || lb > 36) return null;
        float cos = (ax * bx + ay * by) / (float) (Math.hypot(ax, ay) * Math.hypot(bx, by));
        if (Math.abs(cos) > 0.85f) return null;

        float[] pts = {x0, y0, c[4 * p], c[4 * p + 1], c[4 * q], c[4 * q + 1], 0, 0};
        // The small square, first guessed as if there were no perspective, then searched for.
        float ex = ax / 18f, ey = ay / 18f, fx = bx / 18f, fy = by / 18f;
        float gx = x0 + 15 * ex + 15 * fx, gy = y0 + 15 * ey + 15 * fy;
        float[] at = findSmallSquare(gx, gy, ex, ey, fx, fy, cell);
        if (at == null) return null;
        pts[6] = at[0];
        pts[7] = at[1];
        float[] h = Homography.fit(ANCHORS, pts);
        if (h == null) return null;
        float match = check(h);
        if (match < MIN_MATCH) return null;
        return new Found(h, pts, match, cell);
    }

    private static float dist(float[] c, int a, int b) {
        return (float) Math.hypot(c[4 * a] - c[4 * b], c[4 * a + 1] - c[4 * b + 1]);
    }

    /**
     * The small square, with the cells around it as the marker has them (9 x 9 cells): the
     * best fitting place near the guess.
     */
    private float[] findSmallSquare(float gx, float gy, float ex, float ey, float fx, float fy, float cell) {
        int reach = Math.max(3, Math.round(cell * 4));
        int best = -1;
        float sx = 0, sy = 0, ties = 0;
        for (int dy = -reach; dy <= reach; dy++)
            for (int dx = -reach; dx <= reach; dx++) {
                float cx = gx + dx, cy = gy + dy;
                int score = 0;
                for (int v = -4; v <= 4; v++)
                    for (int u = -4; u <= 4; u++) {
                        boolean want = PICTURE[19 + v].charAt(19 + u) == '#';
                        int px = Math.round(cx + u * ex + v * fx), py = Math.round(cy + u * ey + v * fy);
                        if (px < 0 || py < 0 || px >= width || py >= height) continue;
                        if ((dark[py * width + px] != 0) == want) score++;
                    }
                if (score > best) { best = score; sx = cx; sy = cy; ties = 1; }
                else if (score == best) { sx += cx; sy += cy; ties++; }
            }
        if (best < 62) return null;              // of 81 cells
        return new float[] {sx / ties, sy / ties};
    }

    /** The share of the marker's cells that match the picture where they should be. */
    private float check(float[] h) {
        int good = 0, seen = 0;
        for (int v = 0; v < CELLS; v++) {
            String row = PICTURE[v];
            for (int u = 0; u < CELLS; u++) {
                float x = u + 0.5f, y = v + 0.5f;
                float w = h[6] * x + h[7] * y + 1;
                int px = Math.round((h[0] * x + h[1] * y + h[2]) / w), py = Math.round((h[3] * x + h[4] * y + h[5]) / w);
                if (px < 0 || py < 0 || px >= width || py >= height) continue;
                seen++;
                if ((dark[py * width + px] != 0) == (row.charAt(u) == '#')) good++;
            }
        }
        return seen < CELLS * CELLS * 0.9f ? 0 : good / (float) seen;
    }
}
