import com.buildlens.glasses.CheckModel;
import com.buildlens.glasses.Frame;
import com.buildlens.glasses.MarkerPose;
import com.buildlens.glasses.PieceCheck;
import com.buildlens.glasses.QrFinder;
import com.buildlens.glasses.SetDown;

import java.awt.image.BufferedImage;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;
import javax.imageio.ImageIO;

/**
 * Checks SetDown's timing on a computer: a build left on its spot is checked once it has been
 * still for a moment, moves on only after two checks agree, and is not checked again until
 * something moves. Uses the made-up pictures of tools/test_check.sh (picture = one look).
 *   java SetDownTest <scenesDir> <check.bin>
 */
public class SetDownTest {
    static int checks, advances;

    public static void main(String[] args) throws Exception {
        CheckModel model = CheckModel.read(new FileInputStream(args[1]));
        PieceCheck check = new PieceCheck(model);
        check.turnRange = (float) Math.toRadians(45);
        SetDown setDown = new SetDown(check, (step, r, advance) -> {
            checks++;
            if (advance) advances++;
            System.out.println("    check " + checks + ", step " + (step + 1) + ": " + r.verdict + (advance ? "  -> next step" : ""));
        });
        List<String[]> scenes = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new FileReader(new File(args[0], "scenes.txt")))) {
            for (String l; (l = r.readLine()) != null; ) if (!l.trim().isEmpty()) scenes.add(l.trim().split("\\s+"));
        }
        // A scene where the check says DONE and one where it says NOT_YET, each left still for 20 looks.
        int failures = 0;
        long t = 0;
        for (String[] s : scenes) {
            Look look = new Look(args[0], s);
            PieceCheck.Result once = check.check(look.frame, look.fx, look.fy, look.cx, look.cy, look.pose, look.step);
            if (once.verdict != PieceCheck.Verdict.DONE && once.verdict != PieceCheck.Verdict.NOT_YET) continue;
            System.out.println(s[0] + " (step " + (look.step + 1) + ", " + once.verdict + "), left still for 20 looks:");
            setDown.reset();
            checks = advances = 0;
            for (int i = 0; i < 20; i++) setDown.look(look.frame, look.fx, look.fy, look.cx, look.cy, look.pose, look.step, t += 80);
            boolean want = once.verdict == PieceCheck.Verdict.DONE;
            int wantChecks = want ? 2 : 1, wantAdvances = want ? 1 : 0;
            boolean ok = checks == wantChecks && advances == wantAdvances;
            System.out.println("  " + checks + " checks, " + advances + " moves on (want " + wantChecks + " and " + wantAdvances + ") " + (ok ? "ok" : "WRONG"));
            if (!ok) failures++;
            if (want) {
                // A hand passes over the spot for a few looks, then the build is still again: checked afresh.
                Frame hand = withHand(look);
                checks = advances = 0;
                for (int i = 0; i < 3; i++) setDown.look(hand, look.fx, look.fy, look.cx, look.cy, look.pose, look.step, t += 80);
                for (int i = 0; i < 20; i++) setDown.look(look.frame, look.fx, look.fy, look.cx, look.cy, look.pose, look.step, t += 80);
                boolean again = checks == 2 && advances == 1;
                System.out.println("  after a movement: " + checks + " checks, " + advances + " moves on (want 2 and 1) " + (again ? "ok" : "WRONG"));
                if (!again) failures++;
            }
            if (scenes.indexOf(s) > 12) break;
        }
        System.out.println(failures == 0 ? "SetDown: all as expected" : "SetDown: " + failures + " unexpected");
    }

    /** The picture with a skin-coloured hand-sized patch over the spot. */
    static Frame withHand(Look look) {
        Frame f = look.frame, out = new Frame(f.width, f.height);
        System.arraycopy(f.y, 0, out.y, 0, f.y.length);
        System.arraycopy(f.u, 0, out.u, 0, f.u.length);
        System.arraycopy(f.v, 0, out.v, 0, f.v.length);
        float[] c = MarkerPose.project(look.pose, PieceCheck.OFFSET, 0, -PieceCheck.DROP, look.fx, look.fy, look.cx, look.cy);
        int r = (int) (look.fx * 0.04f / c[2]);
        for (int y = (int) c[1] - r; y < c[1] + r; y++)
            for (int x = (int) c[0] - 2 * r; x < c[0] + r / 2; x++) {
                if (x < 0 || y < 0 || x >= f.width || y >= f.height) continue;
                out.y[y * f.width + x] = (byte) 170;
                out.u[(y / 2) * (f.width / 2) + x / 2] = (byte) 110;
                out.v[(y / 2) * (f.width / 2) + x / 2] = (byte) 155;
            }
        return out;
    }

    static final class Look {
        final Frame frame;
        final float fx, fy, cx, cy;
        final float[] pose;
        final int step;

        Look(String dir, String[] f) throws Exception {
            step = Integer.parseInt(f[1]) - 1;
            int w = Integer.parseInt(f[7]), h = Integer.parseInt(f[8]);
            fx = Float.parseFloat(f[9]); fy = Float.parseFloat(f[10]); cx = Float.parseFloat(f[11]); cy = Float.parseFloat(f[12]);
            BufferedImage img = ImageIO.read(new File(dir, f[0]));
            frame = Frame.fromArgb(img.getRGB(0, 0, w, h, null, 0, w), w, h);
            QrFinder.Found found = new QrFinder().find(frame.y, w, h, w);
            pose = MarkerPose.solve(found, fx, fy, cx, cy);
        }
    }
}
