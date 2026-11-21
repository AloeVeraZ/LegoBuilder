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

    /** For tools/: prints why a try was turned down. */
    public static boolean debug;
    public static int debugX0 = 0, debugX1 = 0;

    private static Found no(String why) {
        if (debug) System.out.println("  no: " + why);
        return null;
    }

    /** The result. */
    public static final class Found {
        /** Marker cells (x right, y down, 0..27 across) to picture pixels: h[0..8], h[8] = 1. */
        public float[] mapping;
        /** The four squares' middles as first found, in pixels, in the order of ANCHORS. */
        public final float[] points;
        public final float match;
        /** Picture pixels per cell, roughly: how near the marker is. */
        public float cell;

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
    /** The picture being searched, for fitting the whole marker when a big square is missing. */
    private byte[] grey;
    private int stride;
    private byte[] dark = new byte[0];
    private int[] sums = new int[0];

    /**
     * Looks for the marker in a grey picture (one byte per pixel, `stride` bytes per row).
     * Returns null when it is not there.
     */
    public Found find(byte[] grey, int width, int height, int stride) {
        this.width = width;
        this.height = height;
        this.grey = grey;
        this.stride = stride;
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
        if (debug) System.out.println("candidates: " + n + " of " + c.length / 4);
        Found found = pick(c, n);
        if (found == null) found = pickTwo(c, n);
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
        boolean watch = debug && cx > debugX0 && cx < debugX1;
        if (watch) System.out.printf("row %d: square across at %.0f (runs %d %d %d %d %d), down: %s%n", cy, cx, runs[0], runs[1], runs[2], runs[3], runs[4], Float.isNaN(y) ? "no" : "" + y);
        if (Float.isNaN(y)) return n;
        float x = across(Math.round(y), Math.round(cx), total, true);
        if (watch && Float.isNaN(x)) System.out.println("   across again: no");
        if (watch && !Float.isNaN(x)) System.out.println("   kept at " + x + "," + y);
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
        // Specks of up to a third of a cell are stepped over: on a screen seen at a slant a
        // single stray pixel beside the square's middle would otherwise count as a ring.
        int g = expected / 21;
        int[] r = new int[5];
        r[2] = run(fixed, from, -1, true, limit, Integer.MAX_VALUE, g, horizontal);
        int i = from - r[2];
        r[1] = run(fixed, i, -1, false, limit, max, g, horizontal);
        i -= r[1];
        r[0] = run(fixed, i, -1, true, limit, max, g, horizontal);
        i -= r[0];
        int start = i + 1 + r[0] + r[1];
        i = from + 1;
        int more = run(fixed, i, 1, true, limit, Integer.MAX_VALUE, g, horizontal);
        r[2] += more;
        i += more;
        r[3] = run(fixed, i, 1, false, limit, max, g, horizontal);
        i += r[3];
        r[4] = run(fixed, i, 1, true, limit, max, g, horizontal);
        int total = r[0] + r[1] + r[2] + r[3] + r[4];
        if (r[0] == 0 || r[1] == 0 || r[3] == 0 || r[4] == 0) return Float.NaN;
        if (Math.abs(total - expected) * 2 > expected * 1.4f + 4) return Float.NaN;
        if (!ratioOk(r)) return Float.NaN;
        return start + (r[2] - 1) / 2f;     // pixel centres are at whole numbers
    }

    /**
     * How many pixels from i, stepping by dir, are dark (want) or light (!want), counting
     * specks of the other kind of up to `gap` pixels as part of the run. Stops past cap.
     */
    private int run(int fixed, int i, int dir, boolean want, int limit, int cap, int gap, boolean horizontal) {
        int n = 0;
        while (i >= 0 && i < limit && n <= cap) {
            if (isDark(fixed, i, horizontal) == want) { n++; i += dir; continue; }
            int j = i, k = 0;
            while (k < gap && j >= 0 && j < limit && isDark(fixed, j, horizontal) != want) { k++; j += dir; }
            if (k == 0 || j < 0 || j >= limit || isDark(fixed, j, horizontal) != want) break;
            n += k;
            i = j;
        }
        return n;
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
        if (debug) for (int i = 0; i < n; i++)
            System.out.printf("square at %.0f,%.0f cell %.1f seen %.0f%n", c[4 * i], c[4 * i + 1], c[4 * i + 2], c[4 * i + 3]);
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
        if (big > small * 2f) return no("sizes differ");
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
        if (la < 9 || la > 36 || lb < 9 || lb > 36) return no("spacing " + la + ", " + lb);
        float cos = (ax * bx + ay * by) / (float) (Math.hypot(ax, ay) * Math.hypot(bx, by));
        if (Math.abs(cos) > 0.85f) return no("angle cos " + cos);

        float[] pts = {x0, y0, c[4 * p], c[4 * p + 1], c[4 * q], c[4 * q + 1], 0, 0};
        // The small square, first guessed as if there were no perspective, then searched for.
        float ex = ax / 18f, ey = ay / 18f, fx = bx / 18f, fy = by / 18f;
        float gx = x0 + 15 * ex + 15 * fx, gy = y0 + 15 * ey + 15 * fy;
        float[] at = findSmallSquare(gx, gy, ex, ey, fx, fy, cell);
        if (at == null) return no("small square not near " + gx + "," + gy);
        pts[6] = at[0];
        pts[7] = at[1];
        float[] h = Homography.fit(ANCHORS, pts);
        if (h == null) return null;
        float match = check(h);
        if (match < MIN_MATCH) return no("match " + match);
        return new Found(h, pts, match, cell);
    }

    // ------------------------------------------------------------ following it
    /** Following needs less than finding: where it was a moment ago already rules out the rest. */
    static final float MIN_MATCH_FOLLOW = 0.72f;

    /**
     * The marker again, starting from where it was in the last picture: the whole known
     * picture is slid onto the new one and checked cell by cell. Every cell helps, so it
     * holds on even when a lamp's reflection covers one or two of the big squares (which
     * find() needs). Null when it has moved too far or is gone; then find() looks afresh.
     */
    public Found follow(byte[] grey, int width, int height, int stride, Found last) {
        this.width = width;
        this.height = height;
        this.grey = grey;
        this.stride = stride;
        // Light and dark only around where the marker was, so following costs little.
        float[] box = bounds(last.mapping);
        if (box == null) return null;
        thresholdBox(grey, stride, box);
        // The head moves between pictures: first the best shift, every half cell up to four
        // cells, scored cell by cell; then the whole picture is fitted from there.
        float[] h = last.mapping;
        float cellPx = Math.max(1, (float) Math.hypot(h[0], h[3]));
        int step = Math.max(1, Math.round(cellPx / 2)), reach = Math.round(cellPx * 4);
        float bestMatch = -1;
        float[] best = h;
        for (int dy = -reach; dy <= reach; dy += step)
            for (int dx = -reach; dx <= reach; dx += step) {
                float[] moved = shifted(h, dx, dy);
                float m = check(moved);
                if (m > bestMatch) { bestMatch = m; best = moved; }
            }
        if (bestMatch < 0.6f) return null;
        h = MarkerRefine.refine(grey, width, height, stride, best);
        if (h == null) return null;
        float match = check(h);
        if (match < bestMatch) { h = best; match = bestMatch; }
        if (debug) System.out.println("follow: match " + match);
        if (match < MIN_MATCH_FOLLOW) return null;
        float[] pts = new float[8];
        Found found = new Found(h, pts, match, last.cell);
        for (int k = 0; k < 4; k++) {
            float[] at = found.at(ANCHORS[2 * k], ANCHORS[2 * k + 1]);
            pts[2 * k] = at[0];
            pts[2 * k + 1] = at[1];
        }
        found.cell = (float) Math.hypot(h[0], h[3]);
        return found;
    }

    /** The mapping moved by (dx, dy) pixels in the picture. */
    private static float[] shifted(float[] h, float dx, float dy) {
        return new float[] {h[0] + dx * h[6], h[1] + dx * h[7], h[2] + dx, h[3] + dy * h[6], h[4] + dy * h[7], h[5] + dy, h[6], h[7], 1};
    }

    /** The marker's box in the picture, with some room, or null if it is not in the picture. */
    private float[] bounds(float[] h) {
        float x0 = Float.MAX_VALUE, y0 = Float.MAX_VALUE, x1 = -Float.MAX_VALUE, y1 = -Float.MAX_VALUE;
        for (int k = 0; k < 4; k++) {
            float u = (k == 1 || k == 2) ? CELLS : 0, v = k >= 2 ? CELLS : 0;
            float w = h[6] * u + h[7] * v + 1;
            if (w <= 0) return null;
            float x = (h[0] * u + h[1] * v + h[2]) / w, y = (h[3] * u + h[4] * v + h[5]) / w;
            x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
        }
        float pad = Math.max(x1 - x0, y1 - y0) * 0.5f;
        x0 = Math.max(0, x0 - pad); y0 = Math.max(0, y0 - pad);
        x1 = Math.min(width - 1, x1 + pad); y1 = Math.min(height - 1, y1 + pad);
        if (x1 - x0 < 8 || y1 - y0 < 8) return null;
        return new float[] {x0, y0, x1, y1};
    }

    /** threshold() for just one box of the picture (the rest is left as it was). */
    private void thresholdBox(byte[] grey, int stride, float[] box) {
        int w = width, h = height;
        if (dark.length < w * h) dark = new byte[w * h];
        int bx0 = (int) box[0], by0 = (int) box[1], bx1 = (int) box[2], by1 = (int) box[3];
        int r = Math.max(6, Math.min(w, h) / 24);
        int sx0 = Math.max(0, bx0 - r), sy0 = Math.max(0, by0 - r), sx1 = Math.min(w, bx1 + r + 1), sy1 = Math.min(h, by1 + r + 1);
        int sw = sx1 - sx0, sh = sy1 - sy0;
        if (sums.length < (sw + 1) * (sh + 1)) sums = new int[(sw + 1) * (sh + 1)];
        for (int x = 0; x <= sw; x++) sums[x] = 0;
        for (int y = 0; y < sh; y++) {
            int line = 0, from = (sy0 + y) * stride + sx0, at = (y + 1) * (sw + 1);
            sums[at] = 0;
            for (int x = 0; x < sw; x++) {
                line += grey[from + x] & 0xff;
                sums[at + x + 1] = sums[at - (sw + 1) + x + 1] + line;
            }
        }
        for (int y = by0; y <= by1; y++) {
            int ya = Math.max(sy0, y - r) - sy0, yb = Math.min(sy1, y + r + 1) - sy0;
            for (int x = bx0; x <= bx1; x++) {
                int xa = Math.max(sx0, x - r) - sx0, xb = Math.min(sx1, x + r + 1) - sx0;
                int total = sums[yb * (sw + 1) + xb] - sums[ya * (sw + 1) + xb] - sums[yb * (sw + 1) + xa] + sums[ya * (sw + 1) + xa];
                int count = (xb - xa) * (yb - ya);
                int v = grey[y * stride + x] & 0xff;
                dark[y * w + x] = (byte) (v * count * 16 < total * 15 - count * 16 * 3 ? 1 : 0);
            }
        }
    }

    // ------------------------------------------------------------ two big squares
    /** The three big squares' middles, in cells: top left, top right, bottom left. */
    private static final float[][] CORNERS = {{4.5f, 4.5f}, {22.5f, 4.5f}, {4.5f, 22.5f}};
    /** How much shorter the marker may look across the line between the two squares. */
    private static final float[] SQUASH = {1f, 0.75f, 0.55f};

    /**
     * Two big squares and the small one, when the third big square can't be seen: a lamp
     * reflected on the phone's screen often lies right across one of them. Which two they
     * are is tried every way round; the small square has to be where that puts it, and then
     * the whole marker is fitted and checked cell by cell, so a wrong guess never passes.
     */
    private Found pickTwo(float[] c, int n) {
        // A square half under a reflection may be crossed by only one row: take those too
        // (the cell-by-cell check afterwards keeps out anything that isn't the marker).
        int[] order = new int[n];
        int seen = 0;
        for (int i = 0; i < n; i++) if (c[4 * i + 2] >= 2) order[seen++] = i;
        int keep = Math.min(seen, 8);
        for (int i = 0; i < keep; i++)
            for (int j = i + 1; j < seen; j++)
                if (c[4 * order[j] + 3] > c[4 * order[i] + 3]) { int t = order[i]; order[i] = order[j]; order[j] = t; }
        Found best = null;
        for (int a = 0; a < keep; a++)
            for (int b = a + 1; b < keep; b++) {
                int i = order[a], j = order[b];
                float si = c[4 * i + 2], sj = c[4 * j + 2];
                if (Math.max(si, sj) > Math.min(si, sj) * 2f) continue;
                float cell = (si + sj) / 2, apart = dist(c, i, j) / cell;
                if (apart < 9 || apart > 40) continue;
                for (int x = 0; x < 3; x++)
                    for (int y = 0; y < 3; y++) {
                        if (x == y) continue;
                        for (float squash : SQUASH) {
                            Found f = tryTwo(c, i, j, x, y, squash, cell);
                            if (f != null && (best == null || f.match > best.match)) best = f;
                        }
                    }
            }
        return best;
    }

    /** Square i is big square x and square j is big square y (0 top left, 1 top right, 2 bottom left). */
    private Found tryTwo(float[] c, int i, int j, int x, int y, float squash, float cell) {
        float ax = c[4 * i], ay = c[4 * i + 1], bx = c[4 * j], by = c[4 * j + 1];
        float[] p = CORNERS[x], q = CORNERS[y];
        // Cells to pixels as a turn and a size (z), from the two squares...
        float dpx = q[0] - p[0], dpy = q[1] - p[1], dax = bx - ax, day = by - ay;
        float dd = dpx * dpx + dpy * dpy;
        float zr = (dax * dpx + day * dpy) / dd, zi = (day * dpx - dax * dpy) / dd;
        // ...then squashed across the line between them, as a marker seen at a slant is.
        float len = (float) Math.hypot(dax, day), ux = dax / len, uy = day / len, wx = -uy, wy = ux;
        float[] e = squashed(zr, zi, ux, uy, wx, wy, squash), f = squashed(-zi, zr, ux, uy, wx, wy, squash);
        float gx = ax + (19.5f - p[0]) * e[0] + (19.5f - p[1]) * f[0];
        float gy = ay + (19.5f - p[0]) * e[1] + (19.5f - p[1]) * f[1];
        if (gx < 0 || gy < 0 || gx >= width || gy >= height) return null;
        float[] small = findSmallSquareCoarse(gx, gy, e[0], e[1], f[0], f[1], cell);
        if (small == null) return null;
        // Cells to pixels exactly through the three (an affine map), for the missing square.
        float c1x = q[0] - p[0], c1y = q[1] - p[1], c2x = 19.5f - p[0], c2y = 19.5f - p[1];
        float det = c1x * c2y - c2x * c1y;
        if (Math.abs(det) < 1e-3f) return null;
        float p1x = bx - ax, p1y = by - ay, p2x = small[0] - ax, p2y = small[1] - ay;
        float l00 = (p1x * c2y - p2x * c1y) / det, l01 = (p2x * c1x - p1x * c2x) / det;
        float l10 = (p1y * c2y - p2y * c1y) / det, l11 = (p2y * c1x - p1y * c2x) / det;
        float[] pts = new float[8];
        for (int k = 0; k < 3; k++) {
            float u = CORNERS[k][0] - p[0], v = CORNERS[k][1] - p[1];
            pts[2 * k] = ax + l00 * u + l01 * v;
            pts[2 * k + 1] = ay + l10 * u + l11 * v;
        }
        pts[6] = small[0];
        pts[7] = small[1];
        float[] h = Homography.fit(ANCHORS, pts);
        if (h == null) return null;
        h = MarkerRefine.refine(grey, width, height, stride, h);
        float match = check(h);
        if (debug) System.out.printf("  two squares as %d,%d squash %.2f: match %.2f%n", x, y, squash, match);
        if (match < MIN_MATCH) return null;
        Found found = new Found(h, pts, match, cell);
        for (int k = 0; k < 4; k++) {
            float[] at = found.at(ANCHORS[2 * k], ANCHORS[2 * k + 1]);
            pts[2 * k] = at[0];
            pts[2 * k + 1] = at[1];
        }
        return found;
    }

    /** Vector (vx, vy) with its part across the line (u along, w across) scaled by k. */
    private static float[] squashed(float vx, float vy, float ux, float uy, float wx, float wy, float k) {
        float along = vx * ux + vy * uy, across = (vx * wx + vy * wy) * k;
        return new float[] {along * ux + across * wx, along * uy + across * wy};
    }

    /** The small square near a rough guess: first every half cell, then pixel by pixel. */
    private float[] findSmallSquareCoarse(float gx, float gy, float ex, float ey, float fx, float fy, float cell) {
        int reach = Math.round(cell * 4), step = Math.max(1, Math.round(cell / 2));
        int best = -1;
        float bx = gx, by = gy;
        for (int dy = -reach; dy <= reach; dy += step)
            for (int dx = -reach; dx <= reach; dx += step) {
                int score = smallSquareScore(gx + dx, gy + dy, ex, ey, fx, fy);
                if (score > best) { best = score; bx = gx + dx; by = gy + dy; }
            }
        if (best < 52) return null;              // of 81: worth a closer look
        return findSmallSquare(bx, by, ex, ey, fx, fy, cell / 4);
    }

    private int smallSquareScore(float cx, float cy, float ex, float ey, float fx, float fy) {
        int score = 0;
        for (int v = -4; v <= 4; v++)
            for (int u = -4; u <= 4; u++) {
                boolean want = PICTURE[19 + v].charAt(19 + u) == '#';
                int px = Math.round(cx + u * ex + v * fx), py = Math.round(cy + u * ey + v * fy);
                if (px < 0 || py < 0 || px >= width || py >= height) continue;
                if ((dark[py * width + px] != 0) == want) score++;
            }
        return score;
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
        if (debug) System.out.println("  small square best " + best + " of 81 at " + sx / ties + "," + sy / ties);
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
