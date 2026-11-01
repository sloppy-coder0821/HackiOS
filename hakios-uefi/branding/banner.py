#!/usr/bin/env python3
"""The pictures HakiOS's UEFI shows in place of Mu-Silicium's: the boot logo, the "no system to boot" screen and the USB mass
storage screen. They are the site's mark (hakios-web: a lowercase h and a red dot, the core), white on black: the phone's screen
is black when the firmware draws them. Drawn here from the mark's shapes, smoothed, with a 5x7 pixel font for the two captions,
with nothing to install, so that anyone can change them and make them again.

The files are what Mu-Silicium's SiliciumPkg/Include/Resources/ holds (Extra.fdf.inc puts them into the firmware volume):
8-bit BMPs with a 256-colour palette, BootLogo.bmp and NoBootOS.bmp 300x300, MassStorage.bmp 500x500. The palette is 128 greys
(black to white) and 128 reds (black to the mark's red), which is every colour the smoothing makes.

usage: branding/banner.py OUTDIR        (uefi/apply.sh runs it into the Mu-Silicium tree)
"""
import os
import struct
import sys

RED = (0xE8, 0x17, 0x0F)
SS = 4                                          # drawn this many times larger, then averaged
FONT = {
    "A": [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "B": ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
    "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    "G": [" ####", "#    ", "#    ", "#  ##", "#   #", "#   #", " ### "],
    "M": ["#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "Y": ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    " ": ["     "] * 7,
}


class Canvas:
    def __init__(self, size):
        self.size, self.n = size, size * SS
        self.px = [(0, 0, 0)] * (self.n * self.n)

    def disc(self, cx, cy, r, c):
        n = self.n
        for y in range(max(0, int(cy - r) - 1), min(n, int(cy + r) + 2)):
            for x in range(max(0, int(cx - r) - 1), min(n, int(cx + r) + 2)):
                if (x + .5 - cx) ** 2 + (y + .5 - cy) ** 2 <= r * r:
                    self.px[y * n + x] = c

    def stroke(self, points, width, c):
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            steps = int(max(abs(x1 - x0), abs(y1 - y0)) / 1.5) + 1
            for i in range(steps + 1):
                t = i / steps
                self.disc(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, width / 2, c)

    def mark(self, cx, top, size):
        """The site's mark (a 64-unit square: a lowercase h, and the red dot top right), SIZE pixels wide, its square black."""
        u = size * SS / 64
        ox, oy = cx * SS - 32 * u, top * SS
        p = lambda x, y: (ox + x * u, oy + y * u)

        def cubic(p0, p1, p2, p3, k=48):
            return [tuple((1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t * t * c + t ** 3 * d
                          for a, b, c, d in zip(p0, p1, p2, p3)) for t in (i / k for i in range(k + 1))]
        white = (255, 255, 255)
        self.stroke([p(22, 14), p(22, 50)], 7 * u, white)
        arch = cubic(p(22, 33), p(22, 27), p(26.5, 23.5), p(31.5, 23.5)) + cubic(p(31.5, 23.5), p(36.5, 23.5), p(41, 27), p(41, 33))
        self.stroke(arch + [p(41, 50)], 7 * u, white)
        self.disc(*p(45.5, 16.5), 4.5 * u, RED)

    def text(self, s, y, scale, grey):
        scale *= SS
        width = len(s) * 6 * scale - scale
        x0 = (self.n - width) / 2
        for i, ch in enumerate(s):
            for row, bits in enumerate(FONT[ch]):
                for col, bit in enumerate(bits):
                    if bit == "#":
                        for yy in range(int(y * SS + row * scale), int(y * SS + (row + 1) * scale)):
                            for xx in range(int(x0 + (i * 6 + col) * scale), int(x0 + (i * 6 + col + 1) * scale)):
                                self.px[yy * self.n + xx] = (grey, grey, grey)

    def bmp(self, path):
        """An 8-bit BMP (BITMAPINFOHEADER, the grey-and-red palette, rows bottom-up, each a multiple of 4 bytes)."""
        size, n = self.size, self.n
        palette = [(round(255 * i / 127),) * 3 for i in range(128)] + \
                  [tuple(round(c * i / 127) for c in RED) for i in range(128)]
        index = bytearray(size * size)
        for y in range(size):
            for x in range(size):
                acc = [0, 0, 0]
                for dy in range(SS):
                    base = (y * SS + dy) * n + x * SS
                    for dx in range(SS):
                        q = self.px[base + dx]
                        acc[0] += q[0]; acc[1] += q[1]; acc[2] += q[2]
                r, g, b = (v / (SS * SS) for v in acc)
                if r > g + 24:                  # a red the dot made, on black
                    index[y * size + x] = 128 + min(127, round(r / RED[0] * 127))
                else:
                    index[y * size + x] = min(127, round((r + g + b) / 3 / 255 * 127))
        stride = (size + 3) & ~3
        pal = b"".join(struct.pack("<BBBB", b, g, r, 0) for r, g, b in palette)
        rows = b"".join(bytes(index[y * size:(y + 1) * size]) + b"\0" * (stride - size) for y in reversed(range(size)))
        offset = 14 + 40 + len(pal)
        header = struct.pack("<2sIHHI", b"BM", offset + len(rows), 0, 0, offset)
        info = struct.pack("<IiiHHIIiiII", 40, size, size, 1, 8, 0, len(rows), 3779, 3779, 256, 256)
        with open(path, "wb") as f:
            f.write(header + info + pal + rows)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)

    logo = Canvas(300)
    logo.mark(150, 60, 180)
    logo.bmp(os.path.join(out, "BootLogo.bmp"))

    none = Canvas(300)
    none.mark(150, 46, 150)
    none.text("NO SYSTEM TO BOOT", 232, 2, 150)
    none.bmp(os.path.join(out, "NoBootOS.bmp"))

    storage = Canvas(500)
    storage.mark(250, 80, 240)
    storage.text("USB MASS STORAGE", 372, 3, 150)
    storage.bmp(os.path.join(out, "MassStorage.bmp"))
    print("banner: BootLogo.bmp, NoBootOS.bmp, MassStorage.bmp written to %s" % out)


if __name__ == "__main__":
    main()
