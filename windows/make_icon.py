"""Renders icon.ico (same design as the Mac icon)."""
from PIL import Image, ImageDraw, ImageFont

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    k = y / S
    gd.line([(0, y), (S, y)], fill=(int(242 - 152 * k), int(46 - 15 * k), int(115 + 76 * k), 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([60, 60, S - 60, S - 60], radius=200, fill=255)
img.paste(grad, (0, 0), mask)
d = ImageDraw.Draw(img)
for i, a in enumerate((90, 150, 255)):
    x = 200 + i * 150
    d.rounded_rectangle([x, 300, x + 280, 720], radius=44, fill=(255, 255, 255, a))
try:
    font = ImageFont.truetype("arialbd.ttf", 170)
except OSError:
    font = ImageFont.load_default()
d.text((560, 420), "60", fill=(110, 30, 150, 255), font=font)
img.save("icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
img.resize((256, 256)).save("icon.png")
