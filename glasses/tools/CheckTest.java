import com.buildlens.glasses.CheckModel;
import com.buildlens.glasses.Frame;
import com.buildlens.glasses.MarkerPose;
import com.buildlens.glasses.PieceCheck;
import com.buildlens.glasses.QrFinder;

import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import javax.imageio.ImageIO;

/**
 * Checks the set-down check on made-up camera pictures, on a computer (no glasses needed):
 *   glasses/tools/test_check.sh
 * Each picture (pipeline/render/scenes.mjs) shows the phone with its marker and the build put
 * down on the spot at some turn, with the step's new pieces on or not. The marker is found the
 * way the glasses find it; then the check must say DONE when the pieces are on and NOT_YET when
 * they are not. UNSURE is allowed (the glasses then wait for a click); DONE when the pieces are
 * not on is the mistake that matters, because the glasses would move on.
 *
 *   java CheckTest <scenesDir> <check.bin> [--draw outDir] [--true-pose] [--turn-range degrees]
 */
public class CheckTest {
    public static void main(String[] args) throws Exception {
        File dir = new File(args[0]);
        CheckModel model = CheckModel.read(new FileInputStream(args[1]));
        File drawTo = null;
        boolean truePose = false;
        float turnRange = (float) Math.PI;
        for (int i = 2; i < args.length; i++) {
            if (args[i].equals("--draw")) { drawTo = new File(args[++i]); drawTo.mkdirs(); }
            if (args[i].equals("--true-pose")) truePose = true;
            if (args[i].equals("--turn-range")) turnRange = (float) Math.toRadians(Float.parseFloat(args[++i]));
        }
        PieceCheck check = new PieceCheck(model);
        check.turnRange = turnRange;
        List<String> lines = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new FileReader(new File(dir, "scenes.txt")))) {
            for (String l; (l = r.readLine()) != null; ) if (!l.trim().isEmpty()) lines.add(l);
        }
        int right = 0, unsure = 0, falseDone = 0, missedDone = 0, noMarker = 0, n = 0, looseCases = 0, looseFalse = 0;
        long totalMs = 0, worstMs = 0;
        int[] perStepRight = new int[model.stepCount()], perStepAll = new int[model.stepCount()];
        for (String line : lines) {
            String[] f = line.trim().split("\\s+");
            String file = f[0];
            int step = Integer.parseInt(f[1]) - 1;
            boolean fresh = f[2].equals("1"), loose = f[3].equals("1");
            float turn = Float.parseFloat(f[4]);
            int w = Integer.parseInt(f[7]), h = Integer.parseInt(f[8]);
            float fx = Float.parseFloat(f[9]), fy = Float.parseFloat(f[10]), cx = Float.parseFloat(f[11]), cy = Float.parseFloat(f[12]);
            float[] real = new float[16];
            for (int i = 0; i < 16; i++) real[i] = Float.parseFloat(f[13 + i]);

            BufferedImage img = ImageIO.read(new File(dir, file));
            int[] argb = img.getRGB(0, 0, w, h, null, 0, w);
            Frame frame = Frame.fromArgb(argb, w, h);
            float[] pose = real;
            String markerNote = "";
            if (!truePose) {
                QrFinder.Found found = new QrFinder().find(frame.y, w, h, w);
                pose = found == null ? null : MarkerPose.solve(found, fx, fy, cx, cy);
                if (pose == null) { noMarker++; System.out.printf("%s step %2d %-7s  marker not found%n", file, step + 1, fresh ? "on" : "not on"); continue; }
                float[] a = MarkerPose.project(real, PieceCheck.OFFSET, 0, -PieceCheck.DROP, fx, fy, cx, cy);
                float[] b = MarkerPose.project(pose, PieceCheck.OFFSET, 0, -PieceCheck.DROP, fx, fy, cx, cy);
                markerNote = String.format(Locale.US, " spot off by %.1f px", Math.hypot(a[0] - b[0], a[1] - b[1]));
            }
            check.testHint = new float[] {turn, Float.parseFloat(f[5]), Float.parseFloat(f[6]), fresh ? 1 : 0};
            PieceCheck.Result res = check.check(frame, fx, fy, cx, cy, pose, step);
            markerNote += String.format(Locale.US, " | real placing fits %.2f cost %.0f vs chosen %.0f, search started at %.1f,%.1f mm (real %.1f,%.1f)",
                    res.fitAtHint, res.costAtHint, res.cost, res.startX * 1000, res.startZ * 1000, Float.parseFloat(f[5]) * 1000, Float.parseFloat(f[6]) * 1000);
            n++;
            totalMs += res.ms;
            worstMs = Math.max(worstMs, res.ms);
            perStepAll[step]++;
            boolean ok = fresh ? res.verdict == PieceCheck.Verdict.DONE : res.verdict == PieceCheck.Verdict.NOT_YET;
            String mark;
            if (ok) { right++; perStepRight[step]++; mark = "ok"; }
            else if (res.verdict == PieceCheck.Verdict.UNSURE) { unsure++; mark = "unsure"; }
            else if (res.verdict == PieceCheck.Verdict.DONE) { falseDone++; mark = "WRONG: moved on"; }
            else { missedDone++; mark = "wrong: not seen"; }
            if (loose) { looseCases++; if (res.verdict == PieceCheck.Verdict.DONE) looseFalse++; }
            float turnErr = (float) Math.toDegrees(Math.abs(Math.atan2(Math.sin(res.turn - turn), Math.cos(res.turn - turn))));
            System.out.printf(Locale.US, "%s step %2d %-7s%s -> %-16s %s | turn off %.0f deg%s%n", file, step + 1, fresh ? "on" : "not on",
                    loose ? " +loose" : "", mark, res, turnErr, markerNote);
            if (drawTo != null && !ok) drawOver(img, check, new File(drawTo, file.replace(".png", "-" + res.verdict + ".png")));
        }
        System.out.println();
        System.out.printf(Locale.US, "%d pictures: %d right, %d unsure, %d moved on wrongly, %d missed a piece that was on, marker missed in %d%n",
                n, right, unsure, falseDone, missedDone, noMarker);
        System.out.printf(Locale.US, "with a loose piece lying beside the build: %d of %d moved on wrongly%n", looseFalse, looseCases);
        System.out.printf(Locale.US, "time per check: %.0f ms on average, %d ms at most (this computer)%n", n == 0 ? 0 : totalMs / (double) n, worstMs);
        StringBuilder steps = new StringBuilder("right per step:");
        for (int s = 0; s < perStepAll.length; s++) if (perStepAll[s] > 0) steps.append(String.format(" %d:%d/%d", s + 1, perStepRight[s], perStepAll[s]));
        System.out.println(steps);
    }

    /** The picture with the check's drawing over it: new pieces red, the rest green. */
    static void drawOver(BufferedImage img, PieceCheck check, File out) throws Exception {
        BufferedImage o = new BufferedImage(img.getWidth(), img.getHeight(), BufferedImage.TYPE_INT_RGB);
        o.getGraphics().drawImage(img, 0, 0, null);
        int[] labels = check.lastLabelsForTest();
        if (labels != null) {
            float x0 = check.lastX0ForTest(), y0 = check.lastY0ForTest(), s = check.lastSForTest();
            int w = check.lastWForTest();
            for (int k = 0; k < labels.length; k++) {
                if (labels[k] < 0) continue;
                int i = k % w, j = k / w;
                int tint = check.lastFreshForTest(labels[k]) ? 0xff2020 : 0x20ff40;
                for (int py = (int) (y0 + j * s); py < (int) (y0 + (j + 1) * s) && py < o.getHeight(); py++)
                    for (int px = (int) (x0 + i * s); px < (int) (x0 + (i + 1) * s) && px < o.getWidth(); px++) {
                        if (((px + py) & 1) == 0) o.setRGB(px, py, tint);
                    }
            }
        }
        ImageIO.write(o, "png", out);
    }
}
