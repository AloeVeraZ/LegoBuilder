package com.buildlens.glasses;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.NotFoundException;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.oned.MultiFormatUPCEANReader;

import java.util.Arrays;
import java.util.EnumMap;
import java.util.Map;

/**
 * Reads the barcode on the set's box (EAN-13 / UPC-A) in a grey camera picture, with ZXing
 * (libs/core-3.5.3.jar, Apache 2.0). Plain Java, nothing from Android, so it can be tested on
 * a computer. The picture is read as it is and turned a quarter turn, so the box can be held
 * any way up (ZXing tries each row both ways round itself).
 */
public final class BarcodeReader {
    private BarcodeReader() {}

    private static final Map<DecodeHintType, Object> HINTS = new EnumMap<>(DecodeHintType.class);
    static {
        HINTS.put(DecodeHintType.POSSIBLE_FORMATS, Arrays.asList(BarcodeFormat.EAN_13, BarcodeFormat.UPC_A));
        HINTS.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
    }

    private static byte[] turned = new byte[0];

    /** The barcode's digits (13, EAN-13 form), or null. Only the middle 90% of a big picture is read. */
    public static String read(byte[] grey, int width, int height) {
        // The middle 90% of a big picture: the box is held in front; reading less is quicker.
        int cw = width, ch = height, cx = 0, cy = 0;
        if (width > 1500) { cw = width * 9 / 10; ch = height * 9 / 10; cx = (width - cw) / 2; cy = (height - ch) / 2; }
        String code = readOnce(grey, width, height, cx, cy, cw, ch);
        if (code != null) return code;
        // A quarter turn of that part, for a box held on its side.
        if (turned.length < cw * ch) turned = new byte[cw * ch];
        for (int y = 0; y < ch; y++) {
            int row = (cy + y) * width + cx;
            for (int x = 0; x < cw; x++) turned[x * ch + (ch - 1 - y)] = grey[row + x];
        }
        return readOnce(turned, ch, cw, 0, 0, ch, cw);
    }

    private static String readOnce(byte[] grey, int width, int height, int left, int top, int w, int h) {
        try {
            PlanarYUVLuminanceSource source = new PlanarYUVLuminanceSource(grey, width, height, left, top, w, h, false);
            Result result = new MultiFormatUPCEANReader(HINTS).decode(new BinaryBitmap(new HybridBinarizer(source)), HINTS);
            String text = result.getText();
            // UPC-A comes back as 12 digits; the same code as EAN-13 has a 0 in front.
            return result.getBarcodeFormat() == BarcodeFormat.UPC_A ? "0" + text : text;
        } catch (NotFoundException | com.google.zxing.FormatException | RuntimeException e) {
            return null;
        }
    }
}
