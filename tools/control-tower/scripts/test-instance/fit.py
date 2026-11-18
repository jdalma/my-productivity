#!/usr/bin/env python3
"""Says when the test window will not fit the screen, and what does (T109).

Usage: fit.py <WIDTHxHEIGHT wanted> <text scale wanted> <WIDTHxHEIGHT visible on the screen, or empty>
macOS shrinks a window larger than the screen's visible area to fit it, so a layout seen at 1920x1080 cannot be
made on a smaller screen. What the layout depends on most is how much text fits: the window's size over the text
scale. The app's scale goes from 0.8 to 2.0 in 0.1 steps, so this prints the largest of those scales at which a
window with the same size-to-scale ratio fits. Sizes that do not scale with the text (margins, the pane
terminal's cell grid) are not the same there: it is a stand-in, not the same screen.
Prints nothing when the window fits or the screen's size is unknown.
"""
import re
import sys


def fit(wanted, scale, visible):
    (w, h), (vw, vh) = wanted, visible
    if w <= vw and h <= vh:
        return None
    for tenths in range(20, 7, -1):
        s = tenths / 10
        fw, fh = int(w / scale * s), int(h / scale * s)
        if fw <= vw and fh <= vh:
            return fw, fh, s
    return ()


def message(wanted, scale, visible):
    found = fit(wanted, scale, visible)
    if found is None:
        return ""
    head = (f"test-instance.sh: CT_TEST_SIZE {wanted[0]}x{wanted[1]} is larger than the screen's visible "
            f"{visible[0]}x{visible[1]}; macOS shrinks the window to fit.")
    if not found:
        return head + " No text scale from 0.8 keeps that ratio of window to text on this screen."
    fw, fh, s = found
    return head + (f" The same ratio of window to text fits as CT_TEST_SIZE={fw}x{fh} CT_TEST_FONT_SCALE={s}"
                   " (a stand-in: sizes that do not scale with the text differ).")


def size(text):
    m = re.fullmatch(r"([1-9][0-9]*)x([1-9][0-9]*)", text)
    if not m:
        sys.exit(f"fit.py: '{text}' is not WIDTHxHEIGHT")
    return int(m[1]), int(m[2])


def text_scale(text):
    if not re.fullmatch(r"[0-9](\.[0-9])?", text) or not 0.8 <= float(text) <= 2.0:
        sys.exit(f"fit.py: text scale '{text}' is not 0.8 to 2.0")
    return float(text)


def demo():
    assert fit((1200, 760), 1.0, (1512, 949)) is None
    assert fit((1920, 1080), 1.1, (1512, 949)) == (1396, 785, 0.8)
    assert fit((1600, 900), 1.0, (1512, 949)) == (1440, 810, 0.9)
    assert fit((4000, 3000), 1.0, (1512, 949)) == ()
    assert message((1200, 760), 1.0, (1512, 949)) == ""
    assert "CT_TEST_SIZE=1396x785 CT_TEST_FONT_SCALE=0.8" in message((1920, 1080), 1.1, (1512, 949))
    for bad in ["1x1x2", "0x10", "x", "10x", "1920 x1080"]:
        try:
            size(bad)
            raise AssertionError(bad)
        except SystemExit:
            pass
    for bad in ["0", "0.1", "9.9", "2.1", "1.15", "-1"]:
        try:
            text_scale(bad)
            raise AssertionError(bad)
        except SystemExit:
            pass
    assert text_scale("0.8") == 0.8 and text_scale("2.0") == 2.0 and text_scale("1") == 1.0


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
    elif len(sys.argv) == 4 and sys.argv[3]:
        text = message(size(sys.argv[1]), text_scale(sys.argv[2]), size(sys.argv[3]))
        if text:
            print(text)
