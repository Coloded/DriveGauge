#!/usr/bin/python3
from pathlib import Path

from PIL import Image


project_root = Path(__file__).resolve().parent.parent
source = project_root / "Resources" / "AppIcon.png"
output = project_root / "Resources" / "DriveGaugeIconV2.icns"

with Image.open(source) as master:
    master = master.convert("RGBA")
    sizes = [32, 64, 128, 256, 512, 1024]
    layers = [
        master.resize((size, size), Image.Resampling.LANCZOS)
        for size in sizes
    ]
    layers[-1].save(output, format="ICNS", append_images=layers[:-1])

print(f"Иконка собрана: {output}")
