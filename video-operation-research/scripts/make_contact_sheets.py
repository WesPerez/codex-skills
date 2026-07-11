#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从本地视频生成总览拼图和可选裁剪拼图。"""

import argparse
import json
import math
import shutil
from pathlib import Path

import cv2
from PIL import Image, ImageDraw


def parse_times(value):
    if not value:
        return None
    result = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            pieces = [int(p) for p in part.split(":")]
            if len(pieces) == 2:
                result.append(pieces[0] * 60 + pieces[1])
            elif len(pieces) == 3:
                result.append(pieces[0] * 3600 + pieces[1] * 60 + pieces[2])
            else:
                raise ValueError(f"时间格式错误: {part}")
        else:
            result.append(float(part))
    return result


def parse_crop(value, width, height):
    if not value:
        return None
    value = value.strip().lower()
    if value.startswith("bottom:"):
        ratio = float(value.split(":", 1)[1])
        if not 0 < ratio <= 1:
            raise ValueError("bottom 裁剪比例必须在 (0, 1] 内")
        crop_h = int(height * ratio)
        if crop_h <= 0:
            raise ValueError("裁剪区域为空")
        return (0, height - crop_h, width, height)
    parts = [int(p.strip()) for p in value.split(",")]
    if len(parts) != 4:
        raise ValueError("裁剪参数必须是 'bottom:0.28' 或 'x1,y1,x2,y2'")
    x1, y1, x2, y2 = parts
    if x1 < 0 or y1 < 0 or x2 > width or y2 > height or x1 >= x2 or y1 >= y2:
        raise ValueError(f"裁剪区域必须位于视频范围 0,0,{width},{height} 内且具有正面积")
    return (x1, y1, x2, y2)


def label_image(img, label, thumb_width):
    img = img.copy()
    img.thumbnail((thumb_width, int(thumb_width * 9 / 16)), Image.LANCZOS)
    canvas = Image.new("RGB", (thumb_width, img.height + 26), "white")
    canvas.paste(img, ((thumb_width - img.width) // 2, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, img.height, thumb_width, img.height + 26], fill=(0, 0, 0))
    draw.text((8, img.height + 6), label, fill="white")
    return canvas


class SheetWriter:
    def __init__(self, out_dir, prefix, columns, max_sheets):
        self.out_dir = out_dir
        self.prefix = prefix
        self.columns = columns
        self.max_sheets = max_sheets
        self.per_sheet = columns * 6
        self.items = []
        self.paths = []

    def can_accept(self):
        return len(self.paths) < self.max_sheets

    def add(self, image):
        if len(self.paths) >= self.max_sheets:
            image.close()
            return False
        self.items.append(image)
        if len(self.items) == self.per_sheet:
            self.flush()
        return True

    def flush(self):
        if not self.items or len(self.paths) >= self.max_sheets:
            return
        first = self.items[0]
        rows = math.ceil(len(self.items) / self.columns)
        sheet = Image.new(
            "RGB",
            (self.columns * first.width, rows * first.height),
            (240, 240, 240),
        )
        for i, image in enumerate(self.items):
            sheet.paste(image, ((i % self.columns) * first.width, (i // self.columns) * first.height))
        path = self.out_dir / f"{self.prefix}_{len(self.paths) + 1:03d}.jpg"
        sheet.save(path, quality=92)
        sheet.close()
        for image in self.items:
            image.close()
        self.items.clear()
        self.paths.append(str(path))

    def finish(self):
        self.flush()
        return self.paths


def main():
    parser = argparse.ArgumentParser(
        description="从本地视频生成总览拼图和可选裁剪拼图。",
        add_help=False,
    )
    parser._optionals.title = "可选参数"
    parser.add_argument("-h", "--help", action="help", help="显示帮助并退出")
    parser.add_argument("--video", required=True, help="本地视频路径")
    parser.add_argument("--out", required=True, help="输出目录")
    parser.add_argument("--interval", type=float, default=5.0, help="抽样间隔，单位秒")
    parser.add_argument("--times", help="逗号分隔的秒数或 mm:ss 时间戳")
    parser.add_argument("--columns", type=int, default=4)
    parser.add_argument("--thumb-width", type=int, default=320)
    parser.add_argument("--max-samples", type=int, default=600, help="最多抽样帧数")
    parser.add_argument("--max-sheets", type=int, default=30, help="每类最多输出拼图数")
    parser.add_argument("--overwrite", action="store_true", help="删除并重建已存在的输出目录")
    parser.add_argument(
        "--subtitle-crop",
        help="可选文字放大裁剪区域：bottom:0.28 或 x1,y1,x2,y2",
    )
    args = parser.parse_args()

    for name, value in (("interval", args.interval), ("columns", args.columns), ("thumb-width", args.thumb_width),
                        ("max-samples", args.max_samples), ("max-sheets", args.max_sheets)):
        if value <= 0:
            parser.error(f"--{name} 必须大于 0")

    video_path = Path(args.video)
    out_dir = Path(args.out)
    if not video_path.is_file():
        raise SystemExit(f"视频不存在: {video_path}")
    if out_dir.exists():
        if not args.overwrite:
            raise SystemExit(f"输出目录已存在；如确认覆盖请加 --overwrite: {out_dir}")
        if out_dir.resolve() in {Path(out_dir.anchor).resolve(), Path.home().resolve()}:
            raise SystemExit(f"拒绝覆盖高风险目录: {out_dir}")
        shutil.rmtree(out_dir)
    frames_dir = out_dir / "frames"
    crops_dir = out_dir / "crops"
    out_dir.mkdir(parents=True, exist_ok=True)
    frames_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise SystemExit(f"无法打开视频: {video_path}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 0)
    frame_count = float(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = frame_count / fps if fps else 0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    times = parse_times(args.times)
    if times is None:
        end = max(0, int(math.floor(duration)))
        times = [t for t in frange(0, end, args.interval)]
    if len(times) > args.max_samples:
        times = times[: args.max_samples]
    crop_box = parse_crop(args.subtitle_crop, width, height)
    if crop_box:
        crops_dir.mkdir(parents=True, exist_ok=True)

    frame_writer = SheetWriter(out_dir, "contact_sheet", args.columns, args.max_sheets)
    crop_writer = SheetWriter(out_dir, "crop_sheet", 2, args.max_sheets)
    samples = []
    for t in times:
        if not frame_writer.can_accept() or (crop_box and not crop_writer.can_accept()):
            break
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0, t) * 1000)
        ok, frame = cap.read()
        if not ok:
            samples.append({"time": t, "ok": False})
            continue
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        image = Image.fromarray(rgb)
        label = seconds_label(t)
        frame_path = frames_dir / f"frame_{int(round(t * 1000)):09d}.jpg"
        image.save(frame_path, quality=92)
        if not frame_writer.add(label_image(image, label, args.thumb_width)):
            image.close()
            break

        crop_path = None
        if crop_box:
            crop = image.crop(crop_box)
            crop = crop.resize((crop.width * 2, crop.height * 2), Image.LANCZOS)
            crop_path = crops_dir / f"crop_{int(round(t * 1000)):09d}.jpg"
            crop.save(crop_path, quality=92)
            crop_writer.add(label_image(crop, label, args.thumb_width * 2))
            crop.close()

        samples.append(
            {
                "time": t,
                "label": label,
                "ok": True,
                "frame": str(frame_path),
                "crop": str(crop_path) if crop_path else None,
            }
        )
        image.close()

    cap.release()
    sheets = frame_writer.finish()
    crop_sheets = crop_writer.finish()
    manifest = {
        "video": str(video_path),
        "fps": fps,
        "frame_count": frame_count,
        "duration_seconds": duration,
        "width": width,
        "height": height,
        "interval": args.interval,
        "max_samples": args.max_samples,
        "max_sheets": args.max_sheets,
        "subtitle_crop": args.subtitle_crop,
        "contact_sheets": sheets,
        "crop_sheets": crop_sheets,
        "samples": samples,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps({"manifest": str(manifest_path), "sheets": sheets, "crop_sheets": crop_sheets}, indent=2))


def frange(start, stop, step):
    x = float(start)
    while x <= stop:
        yield round(x, 3)
        x += step


def seconds_label(seconds):
    seconds = int(round(seconds))
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


if __name__ == "__main__":
    main()
