package com.buildlens.glasses;

/**
 * Notices the build being put down on its spot and has it checked (PieceCheck): when the
 * spot has changed (hands, the build picked up and put back) and then stays still for about
 * half a second, the step is checked; two checks on different pictures must both say the new
 * piece is on before the glasses move on. Nothing is checked again until the spot changes, so
 * a build left alone is checked once, and after moving on the next step waits for the next
 * piece. Plain Java, run on the camera's thread for every picture in which the marker is seen.
 */
public final class SetDown {
    /** Mean brightness change (0..255) between two looks at the spot: above MOVING something moved, below STILL nothing did. */
    static final float MOVING = 9, STILL = 4.5f;
    /** Looks in a row that must be still before checking (pictures are looked at about 10-15 times a second). */
    static final int STILL_LOOKS = 6;
    /** After UNSURE, check once more if it stays still this much longer (a steadier picture may do). */
    static final long RETRY_MS = 1200;

    public interface Listener {
        /** Every check, for the log. advance: the new piece is on, move on from `step`. */
        void onChecked(int step, PieceCheck.Result result, boolean advance);
    }

    private static final int SIDE = 24;
    private final PieceCheck check;
    private final Listener listener;
    private final float[] last = new float[SIDE * SIDE], now = new float[SIDE * SIDE], atCheck = new float[SIDE * SIDE];
    private boolean haveLast, haveChecked, changed = true, oneDone, retried;
    private int stillLooks, lastStep = -1;
    private long unsureAt;

    public SetDown(PieceCheck check, Listener listener) {
        this.check = check;
        this.listener = listener;
    }

    /** Forget the spot (the marker was lost, or checking was switched off): the next look starts afresh. */
    public void reset() {
        haveLast = false;
        haveChecked = false;
        changed = true;
        oneDone = false;
        retried = false;
        stillLooks = 0;
    }

    /**
     * One picture in which the marker was seen. step: the step being built (0-based); lens
     * and pose as for PieceCheck. Returns the check's result when one ran, else null.
     */
    public PieceCheck.Result look(Frame f, float fx, float fy, float cx, float cy, float[] pose, int step, long nowMs) {
        if (step != lastStep) { lastStep = step; oneDone = false; retried = false; }
        if (step < 0 || step >= check.stepCount()) return null;
        float move = sample(f, fx, fy, cx, cy, pose, check.stepRadius(step) + 0.02f, check.stepHeight(step));
        if (move < 0) { reset(); return null; }
        if (move > MOVING) { changed = true; oneDone = false; retried = false; stillLooks = 0; return null; }
        stillLooks = move < STILL ? stillLooks + 1 : 0;
        // A small change that lasts (a piece pressed in with little movement) also counts.
        if (!changed && haveChecked && difference(now, atCheck) > MOVING) changed = true;
        boolean retry = !changed && unsureAt > 0 && !retried && nowMs - unsureAt > RETRY_MS && stillLooks >= STILL_LOOKS;
        if (!(changed && stillLooks >= STILL_LOOKS) && !oneDone && !retry) return null;
        if (retry) retried = true;
        PieceCheck.Result r = check.check(f, fx, fy, cx, cy, pose, step);
        System.arraycopy(now, 0, atCheck, 0, now.length);
        haveChecked = true;
        boolean advance = false;
        unsureAt = 0;
        if (r.verdict == PieceCheck.Verdict.DONE) {
            if (oneDone) { advance = true; oneDone = false; changed = false; }
            else { oneDone = true; changed = false; }               // check again on the next picture
        } else {
            oneDone = false;
            changed = false;
            if (r.verdict == PieceCheck.Verdict.UNSURE) unsureAt = nowMs;
        }
        listener.onChecked(step, r, advance);
        return r;
    }

    /**
     * Looks at the spot: brightness on a SIDE x SIDE grid over a square of table round it, at
     * half the build's height (so moving the head moves the grid with the table). Returns the
     * mean change since the last look, with the overall brightness taken out (the camera's
     * exposure drifts), 0 for the first look, or -1 if the spot is not all in the picture.
     */
    private float sample(Frame f, float fx, float fy, float cx, float cy, float[] pose, float half, float height) {
        for (int j = 0; j < SIDE; j++) {
            for (int i = 0; i < SIDE; i++) {
                float x = PieceCheck.OFFSET - half + 2 * half * (i + 0.5f) / SIDE;
                float y = -half + 2 * half * (j + 0.5f) / SIDE;
                float[] p = MarkerPose.project(pose, x, y, -PieceCheck.DROP + height / 2, fx, fy, cx, cy);
                int g = p[2] > 0 ? f.grey(p[0], p[1]) : -1;
                if (g < 0) return -1;
                now[j * SIDE + i] = g;
            }
        }
        float diff = difference(now, last);
        boolean first = !haveLast;
        System.arraycopy(now, 0, last, 0, now.length);
        haveLast = true;
        return first ? 0 : diff;
    }

    /** Mean change between two looks, with the overall brightness taken out. */
    private static float difference(float[] a, float[] b) {
        float ma = 0, mb = 0;
        for (int k = 0; k < a.length; k++) { ma += a[k]; mb += b[k]; }
        ma /= a.length;
        mb /= b.length;
        float diff = 0;
        for (int k = 0; k < a.length; k++) diff += Math.abs((a[k] - ma) - (b[k] - mb));
        return diff / a.length;
    }
}
