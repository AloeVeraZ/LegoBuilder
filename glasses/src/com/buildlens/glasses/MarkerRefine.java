package com.buildlens.glasses;

/**
 * Sharpens where the marker is, once it has been found. Plain Java (tested on a computer).
 *
 * The four squares alone are too close together: half a pixel of error tips the table by a
 * few degrees, and 11 cm away, where the build stands, that is centimetres. So the whole
 * known picture of the marker is slid and warped over the camera picture until every cell
 * edge lies on top of the real one (Gauss-Newton on the eight numbers of the mapping, plus
 * the picture's brightness and contrast).
 */
public final class MarkerRefine {
    /** Samples per cell of the marker's picture. */
    private static final int PER = 4;
    /** The picture is sampled one cell beyond the marker, onto the white of the phone's screen. */
    private static final int FROM = -1, TO = QrFinder.CELLS + 1;
    private static final int SIDE = (TO - FROM) * PER;
    private static final float[] TEMPLATE = template();

    private MarkerRefine() {}

    /** The marker as a soft picture (0 dark .. 1 light), so edges have a slope to follow. */
    private static float[] template() {
        float[] hard = new float[SIDE * SIDE];
        for (int j = 0; j < SIDE; j++)
            for (int i = 0; i < SIDE; i++) {
                int u = (int) Math.floor((i + 0.5f) / PER + FROM), v = (int) Math.floor((j + 0.5f) / PER + FROM);
                boolean d = u >= 0 && v >= 0 && u < QrFinder.CELLS && v < QrFinder.CELLS && QrFinder.PICTURE[v].charAt(u) == '#';
                hard[j * SIDE + i] = d ? 0 : 1;
            }
        // Gaussian blur, a third of a cell.
        float sigma = PER * 0.33f;
        int r = (int) Math.ceil(sigma * 3);
        float[] k = new float[2 * r + 1];
        float sum = 0;
        for (int i = -r; i <= r; i++) sum += k[i + r] = (float) Math.exp(-i * i / (2 * sigma * sigma));
        for (int i = 0; i < k.length; i++) k[i] /= sum;
        float[] a = new float[hard.length], b = new float[hard.length];
        for (int j = 0; j < SIDE; j++)
            for (int i = 0; i < SIDE; i++) {
                float s = 0;
                for (int t = -r; t <= r; t++) s += k[t + r] * hard[j * SIDE + Math.max(0, Math.min(SIDE - 1, i + t))];
                a[j * SIDE + i] = s;
            }
        for (int j = 0; j < SIDE; j++)
            for (int i = 0; i < SIDE; i++) {
                float s = 0;
                for (int t = -r; t <= r; t++) s += k[t + r] * a[Math.max(0, Math.min(SIDE - 1, j + t)) * SIDE + i];
                b[j * SIDE + i] = s;
            }
        return b;
    }

    /**
     * A better mapping from marker cells to picture pixels, starting from `h` (h[8] = 1).
     * Returns `h` unchanged if the fit does not settle.
     */
    public static float[] refine(byte[] grey, int width, int height, int stride, float[] h) {
        // A softened copy of the picture around the marker: edges a few pixels wide are
        // easier to slide onto than sharp ones, and noise matters less.
        float cell = (float) Math.hypot(h[0], h[3]);
        int x0 = width, y0 = height, x1 = 0, y1 = 0;
        for (int k = 0; k < 4; k++) {
            float u = (k == 1 || k == 2) ? TO + 1 : FROM - 1, v = k >= 2 ? TO + 1 : FROM - 1;
            float w = h[6] * u + h[7] * v + 1;
            int x = (int) ((h[0] * u + h[1] * v + h[2]) / w), y = (int) ((h[3] * u + h[4] * v + h[5]) / w);
            x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
        }
        x0 = Math.max(0, x0 - 4); y0 = Math.max(0, y0 - 4); x1 = Math.min(width - 1, x1 + 4); y1 = Math.min(height - 1, y1 + 4);
        if (x1 - x0 < 16 || y1 - y0 < 16 || (long) (x1 - x0) * (y1 - y0) > 1_500_000) return h;
        Soft soft = new Soft(grey, stride, x0, y0, x1 - x0 + 1, y1 - y0 + 1, Math.max(1, Math.round(cell * 0.3f)));
        double[] p = new double[10];
        for (int i = 0; i < 8; i++) p[i] = h[i];
        p[8] = 160; p[9] = 40;      // brightness = p8 * template + p9, guessed then fitted
        double[][] normal = new double[10][11];
        double[] g = new double[10];
        double lastError = Double.MAX_VALUE;
        boolean settled = false;
        for (int iteration = 0; iteration < 25; iteration++) {
            for (double[] row : normal) java.util.Arrays.fill(row, 0);
            double error = 0;
            int used = 0;
            for (int j = 0; j < SIDE; j += 1)
                for (int i = 0; i < SIDE; i += 1) {
                    float t = TEMPLATE[j * SIDE + i];
                    double u = (i + 0.5) / PER + FROM, v = (j + 0.5) / PER + FROM;
                    double w = p[6] * u + p[7] * v + 1;
                    double x = (p[0] * u + p[1] * v + p[2]) / w, y = (p[3] * u + p[4] * v + p[5]) / w;
                    if (!soft.inside(x, y)) continue;
                    double here = soft.at(x, y);
                    double gx = (soft.at(x + 1, y) - soft.at(x - 1, y)) / 2;
                    double gy = (soft.at(x, y + 1) - soft.at(x, y - 1)) / 2;
                    double r = p[8] * t + p[9] - here;
                    error += r * r;
                    used++;
                    // d(here)/d(p): the picture's slope times how the point moves.
                    g[0] = -gx * u / w; g[1] = -gx * v / w; g[2] = -gx / w;
                    g[3] = -gy * u / w; g[4] = -gy * v / w; g[5] = -gy / w;
                    g[6] = (gx * x + gy * y) * u / w; g[7] = (gx * x + gy * y) * v / w;
                    g[8] = t; g[9] = 1;
                    for (int a = 0; a < 10; a++) {
                        double ga = g[a];
                        if (ga == 0) continue;
                        double[] row = normal[a];
                        for (int b = a; b < 10; b++) row[b] += ga * g[b];
                        row[10] -= ga * r;
                    }
                }
            if (used < SIDE * SIDE / 2) return h;
            for (int a = 0; a < 10; a++) for (int b = 0; b < a; b++) normal[a][b] = normal[b][a];
            // A little damping keeps the first steps from overshooting.
            for (int a = 0; a < 10; a++) normal[a][a] *= 1.0001;
            double[] step = Homography.solve(normal);
            if (step == null) return h;
            for (int a = 0; a < 10; a++) p[a] += step[a];
            double moved = Math.abs(step[2]) + Math.abs(step[5]);
            if (moved < 0.003 && iteration > 1) { settled = true; break; }
            if (error > lastError * 4) return h;
            lastError = error;
        }
        // The fit is only trusted if the marker came out dark on light with a fair contrast.
        if (!settled || p[8] < 20) return h;
        float[] out = new float[9];
        for (int i = 0; i < 8; i++) out[i] = (float) p[i];
        out[8] = 1;
        return out;
    }

    /** A box-blurred copy of part of the picture, read between pixels. */
    private static final class Soft {
        final int x0, y0, w, h;
        final float[] v;

        Soft(byte[] grey, int stride, int x0, int y0, int w, int h, int r) {
            this.x0 = x0; this.y0 = y0; this.w = w; this.h = h;
            float[] a = new float[w * h];
            v = new float[w * h];
            for (int y = 0; y < h; y++) {
                int row = (y0 + y) * stride + x0;
                int sum = 0, count = 0;
                for (int x = -r; x < w; x++) {
                    if (x + r < w) { sum += grey[row + x + r] & 0xff; count++; }
                    if (x - r - 1 >= 0) { sum -= grey[row + x - r - 1] & 0xff; count--; }
                    if (x >= 0) a[y * w + x] = sum / (float) count;
                }
            }
            for (int x = 0; x < w; x++) {
                float sum = 0;
                int count = 0;
                for (int y = -r; y < h; y++) {
                    if (y + r < h) { sum += a[(y + r) * w + x]; count++; }
                    if (y - r - 1 >= 0) { sum -= a[(y - r - 1) * w + x]; count--; }
                    if (y >= 0) v[y * w + x] = sum / count;
                }
            }
        }

        boolean inside(double x, double y) {
            return x - x0 >= 1 && y - y0 >= 1 && x - x0 < w - 2 && y - y0 < h - 2;
        }

        double at(double x, double y) {
            x -= x0; y -= y0;
            int ix = (int) x, iy = (int) y;
            double fx = x - ix, fy = y - iy;
            int i = iy * w + ix;
            return (v[i] * (1 - fx) + v[i + 1] * fx) * (1 - fy) + (v[i + w] * (1 - fx) + v[i + w + 1] * fx) * fy;
        }
    }
}
