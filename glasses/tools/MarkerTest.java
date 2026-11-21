import com.buildlens.glasses.MarkerPose;
import com.buildlens.glasses.QrFinder;

import java.util.Random;

/**
 * Checks the marker finder on made-up camera pictures, on a computer (no glasses needed):
 *   glasses/tools/test_marker.sh
 * Each picture shows the phone lying on a cluttered table, seen from a known place; the
 * finder must find the marker there and nowhere else, and the pose must come out right.
 */
public class MarkerTest {
    static final int W = 1280, H = 960;
    static final float F = W / (2 * (float) Math.tan(Math.toRadians(62) / 2));   // 62 degree wide lens
    static final String[] OTHER = {
"...........................",
".#######.#.#..#.#..#######.",
".#.....#..######.#.#.....#.",
".#.###.#..##....##.#.###.#.",
".#.###.#.#.#.##..#.#.###.#.",
".#.###.#..#..#.#.#.#.###.#.",
".#.....#..##.###.#.#.....#.",
".#######.#.#.#.#.#.#######.",
"............##.###.........",
"...#.###.##.#....##...#..#.",
".#..#...##...#......#..#.#.",
".....#.#.#...###.#.#.#..##.",
"..####..####..##.#########.",
".###..##.#...##.##.#..####.",
"...#.#....#..#..##.........",
".#....##.##.#...##.#.##.#..",
"..#.#...#.#......##...###..",
".#..####.#..#..#########.#.",
".........###.#.#.#...#..##.",
".#######...###.#.#.#.#.#...",
".#.....#.#.#..#.##...#...#.",
".#.###.#.##.#.#..#####..##.",
".#.###.#..#.#.##..#.##.##..",
".#.###.#.###.###.#.#..##.#.",
".#.....#..#.#####..#..#.##.",
".#######...#...##...####.#.",
"...........................",
    };

    public static void main(String[] args) throws Exception {
        String[] mine = picture();
        Random random = new Random(7);
        int found = 0, tries = 0, wrong = 0;
        double worstMm = 0, worstDeg = 0;
        // distance (m), tilt from straight down (deg), turn about the table (deg), blur, noise
        double[][] cases = {
            {0.30, 0, 0, 0, 2}, {0.40, 30, 20, 1, 4}, {0.45, 45, 160, 1, 6}, {0.50, 55, -70, 1, 6},
            {0.35, 20, 95, 2, 8}, {0.60, 40, 10, 1, 4}, {0.55, 50, 200, 2, 6}, {0.70, 35, 45, 1, 4},
            {0.40, 60, -30, 1, 4}, {0.50, 25, 300, 2, 10},
        };
        for (double[] c : cases) {
            float[] pose = place(c[0], c[1], c[2], random);
            byte[] grey = render(mine, pose, (int) c[3], c[4], random);
            QrFinder finder = new QrFinder();
            long t0 = System.nanoTime();
            QrFinder.Found f = finder.find(grey, W, H, W);
            long ms = (System.nanoTime() - t0) / 1_000_000;
            tries++;
            if (f == null) { System.out.printf("MISS  %.2fm tilt %2.0f turn %4.0f blur %.0f  (%d ms)%n", c[0], c[1], c[2], c[3], ms); continue; }
            found++;
            float[] got = MarkerPose.solve(f, F, F, (W - 1) / 2f, (H - 1) / 2f);
            // Error where the build stands: 11 cm beside the marker, 3 cm up.
            float[] a = apply(pose, 0.11f, 0, 0.03f), b = apply(got, 0.11f, 0, 0.03f);
            double mm = 1000 * Math.sqrt(sq(a[0] - b[0]) + sq(a[1] - b[1]) + sq(a[2] - b[2]));
            double deg = Math.toDegrees(Math.acos(Math.min(1, pose[8] * got[8] + pose[9] * got[9] + pose[10] * got[10])));
            // And what that does on screen, in camera pixels.
            double px = Math.hypot(a[0] / a[2] * F - b[0] / b[2] * F, a[1] / a[2] * F - b[1] / b[2] * F);
            worstMm = Math.max(worstMm, mm); worstDeg = Math.max(worstDeg, deg);
            System.out.printf("found %.2fm tilt %2.0f turn %4.0f blur %.0f  match %.2f  cell %.1fpx  build spot off by %.1f mm (%.1f px), up off by %.1f deg  (%d ms)%n",
                    c[0], c[1], c[2], c[3], f.match, f.cell, mm, px, deg, ms);
        }
        // A different QR code in the same place, and pictures with no marker: nothing found.
        for (int i = 0; i < 4; i++) {
            float[] pose = place(0.4, 30, 90 * i, random);
            if (new QrFinder().find(render(OTHER, pose, 1, 4, random), W, H, W) != null) { wrong++; System.out.println("WRONG: found another QR code"); }
            if (new QrFinder().find(render(null, pose, 1, 4, random), W, H, W) != null) { wrong++; System.out.println("WRONG: found a marker in clutter"); }
        }
        System.out.printf("%nfound %d of %d, %d false finds; worst build spot error %.1f mm, worst tilt error %.1f deg%n", found, tries, wrong, worstMm, worstDeg);
        // The last cases are near the limit (cells of 2-3 pixels at 1280 x 960); two may be missed.
        if (found < tries - 2 || wrong > 0 || worstMm > 3) { System.out.println("FAIL"); System.exit(1); }
        System.out.println("OK");
    }

    static String[] picture() throws Exception {
        java.lang.reflect.Field f = QrFinder.class.getDeclaredField("PICTURE");
        f.setAccessible(true);
        return (String[]) f.get(null);
    }

    static double sq(double v) { return v * v; }

    /** A camera looking down at the marker from distance, tipped by tilt, turned by turn. */
    static float[] place(double distance, double tilt, double turn, Random random) {
        double t = Math.toRadians(tilt), r = Math.toRadians(turn);
        // Marker axes in the camera: start facing the camera (marker z towards it = camera -z).
        double[] x = {Math.cos(r), Math.sin(r), 0}, y = {Math.sin(r), -Math.cos(r), 0}, z = {0, 0, -1};
        // Tip about the camera's x axis.
        x = tip(x, t); y = tip(y, t); z = tip(z, t);
        double ox = (random.nextDouble() - 0.5) * distance * 0.3, oy = (random.nextDouble() - 0.5) * distance * 0.2;
        return new float[] {(float) x[0], (float) x[1], (float) x[2], 0, (float) y[0], (float) y[1], (float) y[2], 0,
                (float) z[0], (float) z[1], (float) z[2], 0, (float) ox, (float) oy, (float) distance, 1};
    }

    static double[] tip(double[] v, double t) {
        return new double[] {v[0], v[1] * Math.cos(t) - v[2] * Math.sin(t), v[1] * Math.sin(t) + v[2] * Math.cos(t)};
    }

    static float[] apply(float[] m, float x, float y, float z) {
        return new float[] {m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]};
    }

    /** The table (random blocks), the phone (dark body, white screen) and the marker on it. */
    static byte[] render(String[] code, float[] pose, int blur, double noise, Random random) {
        float[] p = pose;
        // Plane through t with normal z; points on it are t + a*x + b*y.
        double[] blocks = new double[60 * 5];
        for (int i = 0; i < 60; i++) {
            blocks[5 * i] = (random.nextDouble() - 0.5) * 0.8; blocks[5 * i + 1] = (random.nextDouble() - 0.5) * 0.8;
            blocks[5 * i + 2] = 0.005 + random.nextDouble() * 0.03; blocks[5 * i + 3] = 0.005 + random.nextDouble() * 0.03;
            blocks[5 * i + 4] = random.nextDouble() * 255;
        }
        int ss = 3;
        float[] acc = new float[W * H];
        for (int py = 0; py < H; py++)
            for (int px = 0; px < W; px++) {
                float sum = 0;
                for (int sy = 0; sy < ss; sy++)
                    for (int sx = 0; sx < ss; sx++) {
                        double dx = (px - (W - 1) / 2.0 + (sx + 0.5) / ss - 0.5) / F, dy = (py - (H - 1) / 2.0 + (sy + 0.5) / ss - 0.5) / F;
                        // ray (dx, dy, 1) * s hits the plane where dot(ray*s - t, z) = 0
                        double den = dx * p[8] + dy * p[9] + p[10];
                        double s = (p[12] * p[8] + p[13] * p[9] + p[14] * p[10]) / den;
                        double hx = dx * s - p[12], hy = dy * s - p[13], hz = s - p[14];
                        double a = hx * p[0] + hy * p[1] + hz * p[2], b = hx * p[4] + hy * p[5] + hz * p[6];
                        sum += shade(code, a, b, blocks);
                    }
                acc[py * W + px] = sum / (ss * ss);
            }
        for (int k = 0; k < blur; k++) acc = boxBlur(acc);
        byte[] out = new byte[W * H];
        for (int i = 0; i < out.length; i++) {
            double v = acc[i] + random.nextGaussian() * noise;
            out[i] = (byte) Math.max(0, Math.min(255, (int) Math.round(v)));
        }
        return out;
    }

    static float shade(String[] code, double a, double b, double[] blocks) {
        double cell = MarkerPose.SIDE / QrFinder.CELLS;
        // The phone: 78 mm x 163 mm, screen to 2 mm from its edges, marker in the middle.
        if (Math.abs(a) < 0.039 && Math.abs(b) < 0.0815) {
            if (Math.abs(a) > 0.037 || Math.abs(b) > 0.0795) return 25;
            if (code == null) return 235;
            int u = (int) Math.floor(a / cell + QrFinder.CELLS / 2.0), v = (int) Math.floor(-b / cell + QrFinder.CELLS / 2.0);
            if (u < 0 || v < 0 || u >= QrFinder.CELLS || v >= QrFinder.CELLS) return 235;
            return code[v].charAt(u) == '#' ? 30 : 235;
        }
        for (int i = 0; i < 60; i++) {
            if (Math.abs(a - blocks[5 * i]) < blocks[5 * i + 2] && Math.abs(b - blocks[5 * i + 1]) < blocks[5 * i + 3]) return (float) blocks[5 * i + 4];
        }
        return 150 + (float) (20 * Math.sin(a * 40) * Math.cos(b * 33));
    }

    static float[] boxBlur(float[] in) {
        float[] out = new float[in.length];
        for (int y = 1; y < H - 1; y++)
            for (int x = 1; x < W - 1; x++) {
                float s = 0;
                for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) s += in[(y + j) * W + x + i];
                out[y * W + x] = s / 9;
            }
        return out;
    }
}
