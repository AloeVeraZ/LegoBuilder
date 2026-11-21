package com.buildlens.glasses;

/** The flat-to-picture mapping between two sets of four points. Plain Java (tested on a computer). */
public final class Homography {
    private Homography() {}

    /**
     * h (h[8] = 1) taking each (x, y) in `from` to the matching point in `to`; both are
     * four points as x0, y0, x1, y1, ... Null if the points are degenerate.
     */
    public static float[] fit(float[] from, float[] to) {
        double[][] rows = new double[8][9];
        for (int i = 0; i < 4; i++) {
            double x = from[2 * i], y = from[2 * i + 1], u = to[2 * i], v = to[2 * i + 1];
            rows[2 * i] = new double[] {x, y, 1, 0, 0, 0, -u * x, -u * y, u};
            rows[2 * i + 1] = new double[] {0, 0, 0, x, y, 1, -v * x, -v * y, v};
        }
        double[] h = solve(rows);
        if (h == null) return null;
        float[] out = new float[9];
        for (int i = 0; i < 8; i++) out[i] = (float) h[i];
        out[8] = 1;
        return out;
    }

    /** Solves rows of [a1 ... an | b] by elimination. */
    static double[] solve(double[][] m) {
        int n = m.length;
        for (int col = 0; col < n; col++) {
            int pivot = col;
            for (int r = col + 1; r < n; r++) if (Math.abs(m[r][col]) > Math.abs(m[pivot][col])) pivot = r;
            if (Math.abs(m[pivot][col]) < 1e-12) return null;
            double[] t = m[col]; m[col] = m[pivot]; m[pivot] = t;
            for (int r = 0; r < n; r++) {
                if (r == col) continue;
                double k = m[r][col] / m[col][col];
                if (k != 0) for (int c = col; c <= n; c++) m[r][c] -= k * m[col][c];
            }
        }
        double[] out = new double[n];
        for (int i = 0; i < n; i++) out[i] = m[i][n] / m[i][i];
        return out;
    }
}
