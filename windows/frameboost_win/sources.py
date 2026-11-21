"""Video sources: capture cards (DirectShow / Media Foundation) and a built-in demo signal."""
from __future__ import annotations

import math
import sys
import threading
import time

import cv2
import numpy as np

from .core import FrameStore, now

CARD_KEYWORDS = ("elgato", "game capture", "hd60", "4k60", "4k x", "4k s", "cam link", "avermedia", "live gamer",
                 "capture", "usb video", "uvc", "hdmi", "razer ripsaw", "genki", "shadowcast", "ezcap", "magewell",
                 "acasis", "guermok", "ugreen", "hagibis", "ms2130", "ms2109")


def is_card(name: str) -> bool:
    n = name.lower()
    return any(k in n for k in CARD_KEYWORDS)


def backend() -> int:
    if sys.platform.startswith("win"):
        return cv2.CAP_DSHOW
    if sys.platform == "darwin":
        return cv2.CAP_AVFOUNDATION
    return cv2.CAP_V4L2


def device_names() -> list[str]:
    """DirectShow device names in OpenCV index order (Windows)."""
    if sys.platform.startswith("win"):
        try:
            from pygrabber.dshow_graph import FilterGraph
            return list(FilterGraph().get_input_devices())
        except Exception:
            return []
    if sys.platform.startswith("linux"):
        import glob
        names = []
        for p in sorted(glob.glob("/sys/class/video4linux/video*/name")):
            try:
                names.append(open(p).read().strip())
            except OSError:
                pass
        return names
    return []


def list_video_devices() -> list[tuple[str, int, bool]]:
    """[(name, index, is_capture_card)] - capture cards first. Uses names only (no probing = fast)."""
    names = device_names()
    devs = [(n, i, is_card(n)) for i, n in enumerate(names)]
    devs.sort(key=lambda d: (not d[2], d[1]))
    return devs


class CaptureSource:
    """Reads a capture card on its own thread and pushes unique frames into the FrameStore."""
    # best first: the full 60 Hz signal matters most (the PS5 sends every game frame inside a 60 Hz signal),
    # then 1080p, then uncompressed. Cheap USB 2.0 sticks offer 1080p only at 5-30 FPS, but 720p at 60.
    MODES = [(1920, 1080, 60, "YUY2"), (1920, 1080, 60, "NV12"), (1920, 1080, 60, "MJPG"),
             (1280, 720, 60, "YUY2"), (1280, 720, 60, "NV12"), (1280, 720, 60, "MJPG"),
             (1920, 1080, 30, "YUY2"), (1920, 1080, 30, "MJPG")]

    def __init__(self, index: int, store: FrameStore):
        self.index, self.store = index, store
        self.cap = None
        self.running = False
        self.thread = None
        self.format = ""
        self.error = ""

    @staticmethod
    def measured_rate(cap, seconds: float = 0.4, clock=time.perf_counter) -> float:
        """Frames per second the card REALLY delivers in the current mode
        (drivers often accept 60 Hz and silently deliver 5 or 30)."""
        t0 = clock()
        times = []
        while clock() - t0 < seconds and len(times) < 40:
            ok, _ = cap.read()
            if not ok:
                break
            times.append(clock())
        if len(times) < 3:
            return 0.0
        return (len(times) - 1) / max(times[-1] - times[0], 1e-6)

    @classmethod
    def negotiate(cls, cap, clock=time.perf_counter):
        """Best mode the card really delivers -> (description, first frame) or (None, None)."""
        for w, h, fps, fourcc in cls.MODES:
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
            cap.set(cv2.CAP_PROP_FPS, fps)
            ok, frame = cap.read()
            if not (ok and frame is not None and frame.shape[1] == w and frame.shape[0] == h):
                continue
            rate = cls.measured_rate(cap, clock=clock)
            if rate < fps * 0.75:      # asked for 60 Hz (or 30), got clearly less
                continue
            return f"{w}×{h} @ {round(rate)} Hz ({fourcc})", frame
        return None, None

    def open(self) -> bool:
        cap = cv2.VideoCapture(self.index, backend())
        if not cap.isOpened():
            self.error = "Capture Card lässt sich nicht öffnen (OBS / Kamera-App schließen)."
            return False
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        desc, frame = self.negotiate(cap)
        if desc is not None:
            self.format = desc
        else:
            ok, frame = cap.read()
            if not ok:
                cap.release()
                self.error = "Kein Bild von der Capture Card. PS5 an? HDCP in der PS5 ausschalten."
                return False
            self.format = f"{frame.shape[1]}×{frame.shape[0]}"
        self.cap = cap
        return True

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._loop, name="capture", daemon=True)
        self.thread.start()

    def _loop(self):
        fails = 0
        while self.running and self.cap is not None:
            ok, frame = self.cap.read()
            if not ok or frame is None:
                fails += 1
                if fails > 120:
                    self.error = "Capture Card liefert kein Bild mehr (getrennt?)."
                    break
                time.sleep(0.01)
                continue
            fails = 0
            self.store.push(frame)

    def stop(self):
        self.running = False
        if self.thread is not None:
            self.thread.join(timeout=2)
        if self.cap is not None:
            self.cap.release()
        self.cap = None


class DemoSource:
    """30 FPS 'game' inside a 60 Hz signal (every frame twice) + sync test (white square + beep)."""
    W, H = 1280, 720

    def __init__(self, store: FrameStore, audio_sink=None):
        self.store, self.audio_sink = store, audio_sink
        self.running = False
        self.thread = None
        self.format = "Demo 1280×720 · 60 Hz (Spiel 30 FPS)"
        self.error = ""
        rng = np.random.default_rng(6)
        self.bld = [(int(x), int(rng.integers(120, 420)), int(rng.integers(50, 120)),
                     tuple(int(c) for c in rng.integers(40, 110, 3))) for x in np.arange(0, 4000, 90)]
        g = np.random.default_rng(99)
        self.grit = [(int(g.integers(0, 1600)), int(g.integers(0, 260)), int(g.integers(40, 100))) for _ in range(420)]
        self.sky = self._sky()

    def _sky(self):
        h = self.H // 2 + 60
        k = np.linspace(0, 1, h, dtype=np.float32)[:, None]
        top, bot = np.array([140, 46, 77], np.float32), np.array([115, 140, 255], np.float32)  # BGR
        col = top * (1 - k) + bot * k
        return np.repeat(col[:, None, :], self.W, axis=1).astype(np.uint8)

    def frame_at(self, n: float, fast: bool = False, sync_test: bool = False) -> np.ndarray:
        w, h = self.W, self.H
        horizon = h // 2 + 60
        img = np.empty((h, w, 3), np.uint8)
        img[:horizon] = self.sky
        cv2.circle(img, (w - 220, horizon - 160), 60, (90, 205, 255), -1, cv2.LINE_AA)
        off = (n * (34 if fast else 9)) % 4000
        for x, bh, bw, col in self.bld:
            for rep in (0, 4000):
                xx = int(round(x - off + rep))
                if -bw < xx < w:
                    cv2.rectangle(img, (xx, horizon - bh), (xx + bw, horizon), col, -1)
                    for wy in range(horizon - bh + 10, horizon - 12, 22):
                        for wx in range(xx + 8, xx + bw - 12, 16):
                            cv2.rectangle(img, (wx, wy), (wx + 6, wy + 10), (128, 230, 255), -1)
        img[horizon:] = (61, 61, 61)
        road = (n * 24) % 1600
        for gx, gy, shade in self.grit:
            for rep in (0, 1600):
                xx = int(round(gx - road + rep))
                if -8 < xx < w:
                    cv2.rectangle(img, (xx, horizon + 8 + gy), (xx + 5, horizon + 11 + gy), (shade,) * 3, -1)
        dash = (n * 24) % 120
        for i in range(-1, w // 120 + 2):
            x = int(round(i * 120 - dash))
            cv2.rectangle(img, (x, h - 150), (x + 60, h - 140), (230, 230, 230), -1)
        cx = int(round(w / 2 + (380 if fast else 250) * math.sin(n / (9 if fast else 25))))
        cv2.rectangle(img, (cx - 90, h - 230), (cx + 90, h - 170), (40, 40, 220), -1)
        cv2.rectangle(img, (cx - 50, h - 270), (cx + 50, h - 230), (60, 60, 200), -1)
        for dx in (-55, 55):
            cv2.circle(img, (cx + dx, h - 165), 22, (20, 20, 20), -1, cv2.LINE_AA)
        cv2.rectangle(img, (30, h - 200), (200, h - 30), (80, 255, 80), 3)
        if sync_test and int(n) % 30 == 0 and n == int(n):
            cv2.rectangle(img, (30, 30), (140, 140), (255, 255, 255), -1)
        return img

    def open(self) -> bool:
        return True

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._loop, name="demo", daemon=True)
        self.thread.start()

    def _loop(self):
        period = 1 / 60
        t_next = now()
        tick = 0
        frame = None
        rate = 48000
        phase_samples = 0
        beep_until = -1
        while self.running:
            if tick % 2 == 0 or frame is None:
                g = tick // 2
                frame = self.frame_at(g, sync_test=True)
                if g % 30 == 0:
                    beep_until = phase_samples + int(0.04 * rate)
            self.store.push(frame)
            if self.audio_sink is not None:
                n = rate // 60
                idx = np.arange(phase_samples, phase_samples + n)
                tone = np.where(idx < beep_until, 0.25 * np.sin(2 * np.pi * 1000 * idx / rate), 0).astype(np.float32)
                self.audio_sink(np.stack([tone, tone], 1))
                phase_samples += n
            tick += 1
            t_next += period
            d = t_next - now()
            if d > 0:
                time.sleep(d)
            elif d < -0.1:
                t_next = now()

    def stop(self):
        self.running = False
        if self.thread is not None:
            self.thread.join(timeout=2)


class VideoFileSource:
    """A video file as virtual capture card: real-time playback as a 60 Hz signal
    (a 30 FPS video repeats every frame twice - like a PS5 with a 30 FPS game). Loops at the end."""
    SIGNAL_HZ = 60.0

    def __init__(self, path: str, store: FrameStore, start_seconds: float = 0.0):
        self.path, self.store, self.start_seconds = path, store, start_seconds
        self.cap = None
        self.fps = 30.0
        self.running = False
        self.thread = None
        self.format = ""
        self.error = ""

    def _open_cap(self):
        for api in ((cv2.CAP_MSMF,) if sys.platform.startswith("win") else ()) + (cv2.CAP_ANY,):
            cap = cv2.VideoCapture(self.path, api)
            if cap.isOpened():
                return cap
            cap.release()
        return None

    def open(self) -> bool:
        cap = self._open_cap()
        if cap is None:
            self.error = "Die Videodatei lässt sich nicht öffnen."
            return False
        fps = cap.get(cv2.CAP_PROP_FPS)
        self.fps = fps if 1 <= fps <= 240 else 30.0
        if self.start_seconds > 0:
            cap.set(cv2.CAP_PROP_POS_MSEC, self.start_seconds * 1000)
        ok, frame = cap.read()
        if not ok or frame is None:
            cap.release()
            self.error = "Die Videodatei enthält kein lesbares Bild."
            return False
        self.first = frame
        self.cap = cap
        import os
        self.format = f"Video {frame.shape[1]}×{frame.shape[0]} · {self.fps:.0f} FPS → 60-Hz-Signal ({os.path.basename(self.path)})"
        return True

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._loop, name="videofile", daemon=True)
        self.thread.start()

    def _loop(self):
        period = 1 / self.SIGNAL_HZ
        t0 = now()
        t_next = t0
        shown = 0                # index of the source frame currently on the "HDMI cable"
        frame = self.first
        while self.running:
            want = int((now() - t0) * self.fps)
            if want - shown > 3:
                # decoding is slower than real time: skip the backlog instead of blocking the signal
                t0 += (want - shown - 1) / self.fps
                want = shown + 1
            reads = 0
            while shown < want and self.running and reads < 2:
                reads += 1
                ok, f = self.cap.read()
                if not ok or f is None:      # end -> loop
                    self.cap.set(cv2.CAP_PROP_POS_MSEC, self.start_seconds * 1000)
                    ok, f = self.cap.read()
                    if not ok:
                        self.error = "Videodatei konnte nicht weitergelesen werden."
                        self.running = False
                        break
                frame = f
                shown += 1
            self.store.push(frame)
            t_next += period
            d = t_next - now()
            if d > 0:
                time.sleep(d)
            elif d < -0.1:
                t_next = now()

    def stop(self):
        self.running = False
        if self.thread is not None:
            self.thread.join(timeout=2)
        if self.cap is not None:
            self.cap.release()
        self.cap = None
