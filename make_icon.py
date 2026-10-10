"""Draws the app icon (GitHub runs this during the build)."""
from pathlib import Path
from PIL import Image, ImageDraw


def draw(size: int) -> Image.Image:
    s = size / 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # rounded square, deep indigo → violet
    for y in range(size):
        t = y / size
        c = (int(52 + 70 * t), int(40 + 20 * t), int(140 + 90 * t), 255)
        d.line([(0, y), (size, y)], fill=c)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([int(80*s), int(80*s), int(944*s), int(944*s)],
                                           radius=int(200*s), fill=255)
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg.paste(img, (0, 0), mask)
    d = ImageDraw.Draw(bg)
    white = (255, 255, 255, 255)
    # microphone
    d.rounded_rectangle([int(412*s), int(230*s), int(612*s), int(560*s)], radius=int(100*s), fill=white)
    d.arc([int(330*s), int(380*s), int(694*s), int(680*s)], 0, 180, fill=white, width=max(1, int(44*s)))
    d.rectangle([int(490*s), int(670*s), int(534*s), int(770*s)], fill=white)
    # lightning bolt (speed)
    bolt = [(700, 600), (790, 600), (750, 690), (820, 690), (690, 850), (725, 730), (660, 730)]
    d.polygon([(int(x*s), int(y*s)) for x, y in bolt], fill=(255, 210, 80, 255))
    return bg


out = Path("icon.iconset")
out.mkdir(exist_ok=True)
for base in (16, 32, 128, 256, 512):
    draw(base).save(out / f"icon_{base}x{base}.png")
    draw(base * 2).save(out / f"icon_{base}x{base}@2x.png")
