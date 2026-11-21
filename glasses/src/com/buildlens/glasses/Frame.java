package com.buildlens.glasses;

/**
 * One camera picture in colour, the way Android cameras give it: brightness (Y) for every
 * pixel, colour (U, V) for every 2 x 2 block. Plain Java, so it is tested on a computer too.
 */
public final class Frame {
    public final int width, height;
    public final byte[] y, u, v;        // y: width x height; u, v: (width / 2) x (height / 2)

    public Frame(int width, int height) {
        this.width = width;
        this.height = height;
        y = new byte[width * height];
        u = new byte[(width / 2) * (height / 2)];
        v = new byte[(width / 2) * (height / 2)];
    }

    /** From packed 0xAARRGGBB pixels (a still picture, or a test). */
    public static Frame fromArgb(int[] argb, int width, int height) {
        Frame f = new Frame(width, height);
        int cw = width / 2;
        for (int py = 0; py < height; py++) {
            for (int px = 0; px < width; px++) {
                int c = argb[py * width + px];
                int r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
                f.y[py * width + px] = (byte) clamp(0.299f * r + 0.587f * g + 0.114f * b);
            }
        }
        for (int cy = 0; cy < height / 2; cy++) {
            for (int cx = 0; cx < cw; cx++) {
                float su = 0, sv = 0;
                for (int k = 0; k < 4; k++) {
                    int c = argb[(2 * cy + (k >> 1)) * width + 2 * cx + (k & 1)];
                    int r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
                    su += -0.1687f * r - 0.3313f * g + 0.5f * b + 128;
                    sv += 0.5f * r - 0.4187f * g - 0.0813f * b + 128;
                }
                f.u[cy * cw + cx] = (byte) clamp(su / 4);
                f.v[cy * cw + cx] = (byte) clamp(sv / 4);
            }
        }
        return f;
    }

    /** The average Y, U, V of the pixels from (x0, y0) up to (x1, y1), not included, into out[0..2]. */
    public void average(int x0, int y0, int x1, int y1, float[] out) {
        x0 = Math.max(0, x0); y0 = Math.max(0, y0);
        x1 = Math.min(width, Math.max(x1, x0 + 1)); y1 = Math.min(height, Math.max(y1, y0 + 1));
        float sy = 0, su = 0, sv = 0;
        int n = 0, m = 0, cw = width / 2, ch = height / 2;
        for (int py = y0; py < y1; py++)
            for (int px = x0; px < x1; px++) { sy += y[py * width + px] & 0xff; n++; }
        for (int py = y0 >> 1; py <= (y1 - 1) >> 1 && py < ch; py++)
            for (int px = x0 >> 1; px <= (x1 - 1) >> 1 && px < cw; px++) { su += u[py * cw + px] & 0xff; sv += v[py * cw + px] & 0xff; m++; }
        out[0] = n > 0 ? sy / n : 0;
        out[1] = m > 0 ? su / m : 128;
        out[2] = m > 0 ? sv / m : 128;
    }

    /** The brightness at a point (nearest pixel), or -1 outside the picture. */
    public int grey(float px, float py) {
        int x = Math.round(px), yy = Math.round(py);
        if (x < 0 || yy < 0 || x >= width || yy >= height) return -1;
        return y[yy * width + x] & 0xff;
    }

    static int clamp(float v) { return v < 0 ? 0 : v > 255 ? 255 : Math.round(v); }

    /** sRGB 0..1 to Y, U, V (0..255), the same way as the camera's. */
    public static float[] yuv(float[] rgb) {
        float r = rgb[0] * 255, g = rgb[1] * 255, b = rgb[2] * 255;
        return new float[] {0.299f * r + 0.587f * g + 0.114f * b,
                -0.1687f * r - 0.3313f * g + 0.5f * b + 128, 0.5f * r - 0.4187f * g - 0.0813f * b + 128};
    }
}
