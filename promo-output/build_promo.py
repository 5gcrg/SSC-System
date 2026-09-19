from __future__ import annotations

import subprocess
import wave
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
WIDTH, HEIGHT = 1920, 1080
FPS = 30
SCENE_DURATION = 3.75
TRANSITION_DURATION = 0.47

SCREENSHOTS = [
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-3f862e66-5d06-4e38-83bf-fc4ef7752255.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-a169e3dd-b75f-4593-aee5-a572f1cee5f4.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-1224df23-288a-4bb5-b805-b8a6fa326532.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-d2196330-e3a7-47a5-882f-a3f7a4c699f7.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-81f8191c-581d-49e5-9e5e-f496404f7d65.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-87b678a3-7b60-4cb0-a77a-e8b7735abd5d.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-42b24f90-7b9c-437a-a615-2f66a6ec7b66.png"),
    Path(r"C:\Users\admir\AppData\Local\Temp\codex-clipboard-25673b11-81ba-4c6d-801b-a340746c331b.png"),
]

# Coordinates are relative to the original screenshots. They hide real names,
# student identifiers, emails, and contact details while retaining the UI story.
PRIVACY_BOXES = [
    [],
    [(600, 72, 825, 122), (1680, 0, 1919, 65), (0, 815, 260, 910)],
    [(24, 305, 302, 470), (22, 730, 735, 835)],
    [(105, 125, 370, 165), (105, 350, 370, 395), (105, 580, 370, 630)],
    [(1680, 0, 1919, 65)],
    [(12, 178, 558, 873)],
    [(748, 260, 930, 370)],
    [(560, 420, 990, 490)],
]

CAPTIONS = [
    ("One portal. Every event.", "Student services, connected from the very first click."),
    ("Plan and track", "A clear dashboard for every student submission."),
    ("Build proposals with confidence", "Preview complete event details before submission."),
    ("Upload every requirement", "Guided document checklists keep every proposal ready."),
    ("Review everything in one place", "Search, filter, and act on every campus event."),
    ("One trusted masterlist", "Centralized records with flexible numeric IDs."),
    ("Keep organizations connected", "Active organizations are clearly managed."),
    ("Structure every department", "Departments and offices stay organized and visible."),
]


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(Path(r"C:\Windows\Fonts") / name), size)


TITLE_FONT = font("seguisb.ttf", 57)
SUBTITLE_FONT = font("segoeui.ttf", 29)
LABEL_FONT = font("seguisb.ttf", 20)
FINAL_TITLE_FONT = font("seguisb.ttf", 92)
FINAL_SUBTITLE_FONT = font("segoeui.ttf", 37)


def blur_private_regions(image: Image.Image, boxes: list[tuple[int, int, int, int]]) -> Image.Image:
    image = image.convert("RGB")
    for box in boxes:
        clipped = (
            max(0, box[0]),
            max(0, box[1]),
            min(image.width, box[2]),
            min(image.height, box[3]),
        )
        region = image.crop(clipped).filter(ImageFilter.GaussianBlur(radius=15))
        image.paste(region, clipped)
    return image


def cover(image: Image.Image, width: int, height: int) -> Image.Image:
    ratio = max(width / image.width, height / image.height)
    resized = image.resize((round(image.width * ratio), round(image.height * ratio)), Image.Resampling.LANCZOS)
    left = (resized.width - width) // 2
    top = (resized.height - height) // 2
    return resized.crop((left, top, left + width, top + height))


def contain(image: Image.Image, width: int, height: int) -> Image.Image:
    ratio = min(width / image.width, height / image.height)
    return image.resize((round(image.width * ratio), round(image.height * ratio)), Image.Resampling.LANCZOS)


def rounded_shadow(canvas: Image.Image, box: tuple[int, int, int, int], radius: int = 24) -> None:
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    x1, y1, x2, y2 = box
    draw.rounded_rectangle((x1 + 5, y1 + 10, x2 + 5, y2 + 10), radius=radius, fill=(0, 0, 0, 100))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(shadow)


def add_caption(canvas: Image.Image, title: str, subtitle: str) -> None:
    panel = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(panel)
    draw.rounded_rectangle((90, 805, 1830, 1020), radius=28, fill=(11, 15, 23, 225))
    draw.rounded_rectangle((90, 805, 104, 1020), radius=7, fill=(255, 35, 39, 255))
    draw.text((140, 837), "SSC PORTAL", font=LABEL_FONT, fill=(255, 92, 95, 255))
    draw.text((140, 873), title, font=TITLE_FONT, fill=(255, 255, 255, 255))
    draw.text((143, 947), subtitle, font=SUBTITLE_FONT, fill=(216, 221, 230, 255))
    canvas.alpha_composite(panel)


def build_scene(source: Path, boxes: list[tuple[int, int, int, int]], title: str, subtitle: str) -> Image.Image:
    image = blur_private_regions(Image.open(source), boxes)
    background = cover(image, WIDTH, HEIGHT).filter(ImageFilter.GaussianBlur(34))
    background = ImageEnhance.Brightness(background).enhance(0.58).convert("RGBA")
    canvas = background

    foreground = contain(image, 1840, 1000)
    x = (WIDTH - foreground.width) // 2
    y = (HEIGHT - foreground.height) // 2 - 22
    rounded_shadow(canvas, (x, y, x + foreground.width, y + foreground.height))
    canvas.alpha_composite(foreground.convert("RGBA"), (x, y))
    add_caption(canvas, title, subtitle)
    return canvas.convert("RGB")


def build_final_scene(source: Path) -> Image.Image:
    image = cover(Image.open(source).convert("RGB"), WIDTH, HEIGHT).filter(ImageFilter.GaussianBlur(7))
    image = ImageEnhance.Brightness(image).enhance(0.27).convert("RGBA")
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 55))
    image.alpha_composite(overlay)
    draw = ImageDraw.Draw(image)

    title = "SSC PORTAL"
    tagline = "Campus event management, made simple."
    title_box = draw.textbbox((0, 0), title, font=FINAL_TITLE_FONT)
    sub_box = draw.textbbox((0, 0), tagline, font=FINAL_SUBTITLE_FONT)
    tx = (WIDTH - (title_box[2] - title_box[0])) // 2
    sx = (WIDTH - (sub_box[2] - sub_box[0])) // 2
    draw.rounded_rectangle((WIDTH // 2 - 55, 315, WIDTH // 2 + 55, 327), radius=6, fill=(255, 35, 39, 255))
    draw.text((tx, 370), title, font=FINAL_TITLE_FONT, fill=(255, 255, 255, 255))
    draw.text((sx, 500), tagline, font=FINAL_SUBTITLE_FONT, fill=(235, 238, 244, 255))
    draw.rounded_rectangle((WIDTH // 2 - 190, 600, WIDTH // 2 + 190, 675), radius=37, fill=(255, 35, 39, 255))
    cta = "PLAN  •  SUBMIT  •  APPROVE"
    cta_box = draw.textbbox((0, 0), cta, font=LABEL_FONT)
    draw.text(((WIDTH - (cta_box[2] - cta_box[0])) // 2, 625), cta, font=LABEL_FONT, fill=(255, 255, 255, 255))
    return image.convert("RGB")


def mix_audio(narration_path: Path, output_path: Path) -> None:
    with wave.open(str(narration_path), "rb") as wav:
        channels = wav.getnchannels()
        sample_rate = wav.getframerate()
        width = wav.getsampwidth()
        frames = wav.readframes(wav.getnframes())
    if width != 2:
        raise RuntimeError(f"Expected 16-bit narration WAV, got {width * 8}-bit")

    narration = np.frombuffer(frames, dtype=np.int16).astype(np.float32)
    if channels > 1:
        narration = narration.reshape(-1, channels).mean(axis=1)
    narration /= 32768.0

    total_samples = round(30 * sample_rate)
    timeline = np.arange(total_samples, dtype=np.float32) / sample_rate
    music = np.zeros(total_samples, dtype=np.float32)
    chord_sets = [
        (130.81, 196.00, 261.63),
        (146.83, 220.00, 293.66),
        (164.81, 246.94, 329.63),
        (130.81, 196.00, 261.63),
    ]
    segment = 3.75
    for index in range(8):
        start = round(index * segment * sample_rate)
        end = min(total_samples, round((index + 1) * segment * sample_rate))
        local_t = np.arange(end - start, dtype=np.float32) / sample_rate
        fade_len = max(1, round(0.55 * sample_rate))
        envelope = np.ones(end - start, dtype=np.float32)
        ramp = np.linspace(0, 1, min(fade_len, len(envelope)), dtype=np.float32)
        envelope[: len(ramp)] *= ramp
        envelope[-len(ramp) :] *= ramp[::-1]
        chord = sum(np.sin(2 * np.pi * frequency * local_t) for frequency in chord_sets[index % len(chord_sets)]) / 3
        music[start:end] += chord * envelope * 0.055

    # Add a restrained transition chime to give each section a clear pulse.
    for second in (3.28, 6.56, 9.84, 13.12, 16.40, 19.68, 22.96, 26.24):
        start = round(second * sample_rate)
        length = min(round(0.55 * sample_rate), total_samples - start)
        local_t = np.arange(length, dtype=np.float32) / sample_rate
        chime = np.sin(2 * np.pi * 523.25 * local_t) * np.exp(-6 * local_t) * 0.035
        music[start : start + length] += chime

    mixed = music
    narration_start = round(0.45 * sample_rate)
    usable = min(len(narration), total_samples - narration_start)
    mixed[narration_start : narration_start + usable] += narration[:usable] * 0.88
    peak = max(1.0, float(np.max(np.abs(mixed))) / 0.96)
    pcm = np.clip(mixed / peak, -1, 1)
    pcm = (pcm * 32767).astype(np.int16)

    with wave.open(str(output_path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm.tobytes())


def encode_video(scene_paths: list[Path], audio_path: Path, output_path: Path) -> None:
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    command = [ffmpeg, "-y"]
    for scene in scene_paths:
        command.extend(["-loop", "1", "-t", str(SCENE_DURATION), "-i", str(scene)])
    command.extend(["-i", str(audio_path)])

    filters: list[str] = []
    frame_count = round(SCENE_DURATION * FPS)
    for index in range(len(scene_paths)):
        zoom = "min(zoom+0.00048,1.055)" if index % 2 == 0 else "min(zoom+0.00038,1.045)"
        filters.append(
            f"[{index}:v]scale=2200:1238,"
            f"zoompan=z='{zoom}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':"
            f"d={frame_count}:s={WIDTH}x{HEIGHT}:fps={FPS},format=yuv420p[v{index}]"
        )

    previous = "v0"
    step = SCENE_DURATION - TRANSITION_DURATION
    for index in range(1, len(scene_paths)):
        output = f"x{index}"
        offset = step * index
        filters.append(
            f"[{previous}][v{index}]xfade=transition=fade:duration={TRANSITION_DURATION}:offset={offset:.2f}[{output}]"
        )
        previous = output
    filters.append(f"[{previous}]tpad=stop_mode=clone:stop_duration=0.1,trim=duration=30,setpts=PTS-STARTPTS[vout]")

    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            "[vout]",
            "-map",
            f"{len(scene_paths)}:a",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "18",
            "-r",
            str(FPS),
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
            "-t",
            "30",
            str(output_path),
        ]
    )
    subprocess.run(command, check=True)


def main() -> None:
    missing = [str(path) for path in SCREENSHOTS if not path.exists()]
    if missing:
        raise FileNotFoundError("Missing screenshots: " + ", ".join(missing))

    frames_dir = ROOT / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    scene_paths: list[Path] = []
    for index, (source, boxes, caption) in enumerate(zip(SCREENSHOTS, PRIVACY_BOXES, CAPTIONS), start=1):
        output = frames_dir / f"scene-{index:02d}.png"
        build_scene(source, boxes, *caption).save(output, quality=95)
        scene_paths.append(output)

    final_scene = frames_dir / "scene-09.png"
    build_final_scene(SCREENSHOTS[0]).save(final_scene, quality=95)
    scene_paths.append(final_scene)

    narration = ROOT / "narration.wav"
    if not narration.exists():
        raise FileNotFoundError("Generate narration.wav before running this script")
    audio = ROOT / "promo-audio.wav"
    mix_audio(narration, audio)
    encode_video(scene_paths, audio, ROOT / "ssc-portal-promo-30s.mp4")


if __name__ == "__main__":
    main()
