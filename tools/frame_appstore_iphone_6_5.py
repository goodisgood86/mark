#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

try:
    import pytesseract
except Exception:  # pragma: no cover
    pytesseract = None

import re


@dataclass(frozen=True)
class FrameSpec:
    canvas_w: int
    canvas_h: int
    outer_margin_x: int
    outer_margin_y: int
    device_radius: int
    device_color: tuple[int, int, int]
    shadow_color: tuple[int, int, int]
    shadow_blur: int
    shadow_offset_y: int
    bezel_left: int
    bezel_right: int
    bezel_top: int
    bezel_bottom: int
    screen_radius: int
    bg_color: tuple[int, int, int]


IPHONE_6_5 = FrameSpec(
    canvas_w=1242,
    canvas_h=2688,
    outer_margin_x=56,
    outer_margin_y=86,
    device_radius=150,
    device_color=(10, 10, 12),
    shadow_color=(0, 0, 0),
    shadow_blur=28,
    shadow_offset_y=18,
    bezel_left=36,
    bezel_right=36,
    bezel_top=82,
    bezel_bottom=112,
    screen_radius=120,
    bg_color=(255, 255, 255),
)

_EMAIL_RE = re.compile(r"(?i)\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b")


def _parse_hex_color(value: str) -> tuple[int, int, int]:
    v = value.strip().lstrip("#")
    if len(v) == 3:
        v = "".join([c * 2 for c in v])
    if len(v) != 6:
        raise ValueError(f"Invalid color: {value!r}")
    return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16))


def _fit_cover(img: Image.Image, target_w: int, target_h: int) -> Image.Image:
    # Resize with "cover" behavior, then center-crop.
    src_w, src_h = img.size
    scale = max(target_w / src_w, target_h / src_h)
    new_w = int(round(src_w * scale))
    new_h = int(round(src_h * scale))
    resized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    left = (new_w - target_w) // 2
    top = (new_h - target_h) // 2
    return resized.crop((left, top, left + target_w, top + target_h))


def _rounded_rect_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def _draw_device_frame(spec: FrameSpec) -> Image.Image:
    canvas = Image.new("RGB", (spec.canvas_w, spec.canvas_h), spec.bg_color)

    device_left = spec.outer_margin_x
    device_top = spec.outer_margin_y
    device_right = spec.canvas_w - spec.outer_margin_x
    device_bottom = spec.canvas_h - spec.outer_margin_y
    device_box = (device_left, device_top, device_right, device_bottom)

    # Shadow (simple blurred rounded rect behind device)
    shadow = Image.new("RGBA", (spec.canvas_w, spec.canvas_h), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_box = (
        device_left,
        device_top + spec.shadow_offset_y,
        device_right,
        device_bottom + spec.shadow_offset_y,
    )
    shadow_draw.rounded_rectangle(
        shadow_box,
        radius=spec.device_radius,
        fill=(*spec.shadow_color, 160),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(spec.shadow_blur))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB")

    # Screen cutout geometry
    screen_left = device_left + spec.bezel_left
    screen_top = device_top + spec.bezel_top
    screen_right = device_right - spec.bezel_right
    screen_bottom = device_bottom - spec.bezel_bottom
    screen_w = max(1, screen_right - screen_left)
    screen_h = max(1, screen_bottom - screen_top)

    # Device body alpha mask: outer rounded rect (255) minus screen hole (0)
    alpha = Image.new("L", (spec.canvas_w, spec.canvas_h), 0)
    alpha_draw = ImageDraw.Draw(alpha)
    alpha_draw.rounded_rectangle(
        device_box,
        radius=spec.device_radius,
        fill=255,
    )
    alpha_draw.rounded_rectangle(
        (screen_left, screen_top, screen_right, screen_bottom),
        radius=spec.screen_radius,
        fill=0,
    )

    device = Image.new("RGBA", (spec.canvas_w, spec.canvas_h), (*spec.device_color, 255))
    device.putalpha(alpha)

    # Composite device over canvas
    canvas_rgba = canvas.convert("RGBA")
    canvas_rgba = Image.alpha_composite(canvas_rgba, device)
    return canvas_rgba.convert("RGB"), (screen_left, screen_top, screen_w, screen_h), alpha


def _blur_region(img: Image.Image, box: tuple[int, int, int, int], radius: int = 14) -> None:
    x0, y0, x1, y1 = box
    x0 = max(0, min(img.width, x0))
    x1 = max(0, min(img.width, x1))
    y0 = max(0, min(img.height, y0))
    y1 = max(0, min(img.height, y1))
    if x1 <= x0 or y1 <= y0:
        return
    crop = img.crop((x0, y0, x1, y1)).filter(ImageFilter.GaussianBlur(radius))
    img.paste(crop, (x0, y0))


def _blur_emails_if_present(img: Image.Image, padding: int = 14) -> Image.Image:
    if pytesseract is None:
        return img

    try:
        data = pytesseract.image_to_data(
            img,
            output_type=pytesseract.Output.DICT,
            config="--psm 6",
        )
    except Exception:
        return img

    n = len(data.get("text", []))
    if n == 0:
        return img

    mutable = img.copy()
    for i in range(n):
        text = (data["text"][i] or "").strip()
        if not text:
            continue
        cleaned = text.strip("()[]{}<>\"'`.,:;")
        if "@" not in cleaned and not _EMAIL_RE.search(cleaned):
            continue
        if not _EMAIL_RE.search(cleaned) and "@" not in cleaned:
            continue
        x = int(data["left"][i])
        y = int(data["top"][i])
        w = int(data["width"][i])
        h = int(data["height"][i])
        if w <= 0 or h <= 0:
            continue
        _blur_region(
            mutable,
            (x - padding, y - padding, x + w + padding, y + h + padding),
            radius=16,
        )
    return mutable


def frame_one(input_path: Path, output_path: Path, spec: FrameSpec) -> None:
    base_canvas, (sx, sy, sw, sh), _ = _draw_device_frame(spec)

    img = Image.open(input_path)
    img = img.convert("RGB")

    # Rotate if user accidentally exported landscape.
    if img.width > img.height:
        img = img.rotate(90, expand=True)

    img = _blur_emails_if_present(img)

    screen_img = _fit_cover(img, sw, sh)
    screen_mask = _rounded_rect_mask((sw, sh), radius=spec.screen_radius)

    composed = base_canvas.convert("RGBA")
    layer = Image.new("RGBA", composed.size, (0, 0, 0, 0))
    layer.paste(screen_img.convert("RGBA"), (sx, sy), screen_mask)
    composed = Image.alpha_composite(composed, layer).convert("RGB")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    composed.save(output_path, format="PNG", optimize=True)


def _iter_images(in_dir: Path) -> list[Path]:
    exts = {".png", ".jpg", ".jpeg", ".webp"}
    files = []
    for p in sorted(in_dir.iterdir()):
        if p.is_file() and p.suffix.lower() in exts:
            files.append(p)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Add a simple iPhone 6.5\" device frame to screenshots (no captions)."
    )
    parser.add_argument(
        "--in-dir",
        default="store_screenshots/iphone_6_5/input",
        help="Input directory containing screenshots",
    )
    parser.add_argument(
        "--out-dir",
        default="store_screenshots/iphone_6_5/output",
        help="Output directory for framed screenshots",
    )
    parser.add_argument(
        "--bg",
        default="#ffffff",
        help="Background color (hex), e.g. #ffffff",
    )
    parser.add_argument(
        "--device",
        default="#0a0a0c",
        help="Device frame color (hex), e.g. #0a0a0c",
    )
    args = parser.parse_args()

    in_dir = Path(args.in_dir)
    out_dir = Path(args.out_dir)
    if not in_dir.exists():
        raise SystemExit(f"Input dir not found: {in_dir}")

    spec = IPHONE_6_5
    spec = FrameSpec(
        **{
            **spec.__dict__,
            "bg_color": _parse_hex_color(args.bg),
            "device_color": _parse_hex_color(args.device),
        }
    )

    inputs = _iter_images(in_dir)
    if not inputs:
        print(f"No images found in {in_dir}")
        return 0

    out_dir.mkdir(parents=True, exist_ok=True)
    existing_outputs = [p for p in out_dir.iterdir() if p.is_file() and p.suffix.lower() == ".png"]

    def already_rendered(stem: str) -> bool:
        target = f"_{stem}_iphone65.png"
        for out_p in existing_outputs:
            if out_p.name.endswith(target):
                return True
        return False

    max_index = 0
    for out_p in existing_outputs:
        head = out_p.name.split("_", 1)[0]
        if head.isdigit():
            max_index = max(max_index, int(head))

    to_render = [p for p in inputs if not already_rendered(p.stem)]
    if not to_render:
        print("No new images to render (all inputs already have outputs).")
        return 0

    next_index = max_index + 1
    width = max(2, len(str(next_index + len(to_render))))
    for p in to_render:
        stem = p.stem
        out_name = f"{next_index:0{width}d}_{stem}_iphone65.png"
        frame_one(p, out_dir / out_name, spec)
        print(f"OK  {p.name} -> {out_name}")
        next_index += 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
