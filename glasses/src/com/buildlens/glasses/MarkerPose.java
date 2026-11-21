package com.buildlens.glasses;

/**
 * Where the marker is in space, from where its four squares are in the camera picture.
 * Plain Java (tested on a computer). The same maths as the phone's MarkerTracker.
 *
 * Camera axes: x right, y down, z forward. Marker axes: x to its right, y to its top, z out
 * of the phone's screen. Poses are 4 x 4, column-major (OpenGL order), camera from marker.
 */
public final class MarkerPose {
    /** How wide the marker is on the phone's screen, border included, in metres (as the phone draws it). */
    public static final float SIDE = 0.05f;

    private MarkerPose() {}

    /** The four squares' middles on the marker itself, in metres. */
    public static float[] anchorsInMetres() {
        float cell = SIDE / QrFinder.CELLS, half = QrFinder.CELLS / 2f;
        float[] a = QrFinder.ANCHORS, out = new float[8];
        for (int i = 0; i < 4; i++) {
            out[2 * i] = (a[2 * i] - half) * cell;
            out[2 * i + 1] = -(a[2 * i + 1] - half) * cell;
        }
        return out;
    }

    /**
     * The pose from the squares' picture positions (pixels, centre of the first pixel at 0,0)
     * and the camera's lens: focal lengths and middle, in pixels. Null if it makes no sense.
     */
    public static float[] solve(float[] points, float fx, float fy, float cx, float cy) {
        return solve(anchorsInMetres(), points, fx, fy, cx, cy);
    }

    /** The pose from four points on the marker (metres) and where they are in the picture. */
    public static float[] solve(float[] metres, float[] points, float fx, float fy, float cx, float cy) {
        float[] rays = new float[8];
        for (int i = 0; i < 4; i++) {
            rays[2 * i] = (points[2 * i] - cx) / fx;
            rays[2 * i + 1] = (points[2 * i + 1] - cy) / fy;
        }
        float[] h = Homography.fit(metres, rays);
        if (h == null) return null;
        double[] r1 = {h[0], h[3], h[6]}, r2 = {h[1], h[4], h[7]}, t = {h[2], h[5], 1};
        double scale = 2 / (len(r1) + len(r2));
        for (int i = 0; i < 3; i++) { r1[i] *= scale; r2[i] *= scale; t[i] *= scale; }
        if (t[2] < 0) for (int i = 0; i < 3; i++) { r1[i] = -r1[i]; r2[i] = -r2[i]; t[i] = -t[i]; }
        // Square the two directions up with each other.
        normalise(r1);
        double d = dot(r1, r2);
        for (int i = 0; i < 3; i++) r2[i] -= r1[i] * d;
        normalise(r2);
        double[] r3 = cross(r1, r2);
        if (!(t[2] > 0.02) || Double.isNaN(r1[0]) || Double.isNaN(r2[0])) return null;
        return new float[] {
            (float) r1[0], (float) r1[1], (float) r1[2], 0,
            (float) r2[0], (float) r2[1], (float) r2[2], 0,
            (float) r3[0], (float) r3[1], (float) r3[2], 0,
            (float) t[0], (float) t[1], (float) t[2], 1,
        };
    }

    /** The pose from a found marker: its four outer corners, from the fitted mapping. */
    public static float[] solve(QrFinder.Found found, float fx, float fy, float cx, float cy) {
        float n = QrFinder.CELLS, cell = SIDE / n, half = n / 2;
        float[] cells = {0, 0, n, 0, n, n, 0, n}, metres = new float[8], pixels = new float[8];
        for (int i = 0; i < 4; i++) {
            metres[2 * i] = (cells[2 * i] - half) * cell;
            metres[2 * i + 1] = -(cells[2 * i + 1] - half) * cell;
            float[] p = found.at(cells[2 * i], cells[2 * i + 1]);
            pixels[2 * i] = p[0];
            pixels[2 * i + 1] = p[1];
        }
        return solve(metres, pixels, fx, fy, cx, cy);
    }

    /** Half way from `old` to `found`, so the ghost does not shiver with every pixel of noise. */
    public static float[] blend(float[] old, float[] found, float k) {
        if (old == null) return found;
        double[] a = new double[3], b = new double[3];
        for (int i = 0; i < 3; i++) {
            a[i] = old[i] + (found[i] - old[i]) * k;
            b[i] = old[4 + i] + (found[4 + i] - old[4 + i]) * k;
        }
        normalise(a);
        double d = dot(a, b);
        for (int i = 0; i < 3; i++) b[i] -= a[i] * d;
        normalise(b);
        double[] c = cross(a, b);
        float[] out = new float[16];
        for (int i = 0; i < 3; i++) {
            out[i] = (float) a[i];
            out[4 + i] = (float) b[i];
            out[8 + i] = (float) c[i];
            out[12 + i] = old[12 + i] + (found[12 + i] - old[12 + i]) * k;
        }
        out[15] = 1;
        return out;
    }

    /** Where a point on the marker (metres) lands in the picture, in pixels. */
    public static float[] project(float[] pose, float x, float y, float z, float fx, float fy, float cx, float cy) {
        float px = pose[0] * x + pose[4] * y + pose[8] * z + pose[12];
        float py = pose[1] * x + pose[5] * y + pose[9] * z + pose[13];
        float pz = pose[2] * x + pose[6] * y + pose[10] * z + pose[14];
        return new float[] {px / pz * fx + cx, py / pz * fy + cy, pz};
    }

    private static double len(double[] v) { return Math.sqrt(dot(v, v)); }
    private static double dot(double[] a, double[] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
    private static void normalise(double[] v) { double l = len(v); for (int i = 0; i < 3; i++) v[i] /= l; }
    private static double[] cross(double[] a, double[] b) {
        return new double[] {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
    }
}
