"""Core logic: unique-frame store, motion compensated frame generation, audio delay line."""
from __future__ import annotations

import threading
import time

import cv2
import numpy as np

now = time.perf_counter


# --------------------------------------------------------------------------------------------
# Frame store: drops repeated frames (PS5 sends 30 FPS inside a 60 Hz signal), detects scene cuts
# --------------------------------------------------------------------------------------------
class FrameStore:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()
        self.dedup = True
        self.cut_threshold = 38.0

    def reset(self):
        with getattr(self, "lock", threading.Lock()):
            self.latest = None          # (frame, smoothed_time, seq, interval, is_cut)
            self.seq = 0
            self.last_samples = None
            self.last_unique = 0.0
            self.smoothed = 0.0
            self.interval = 1 / 30
            self.noise = 0.3
            self.arrivals = []
            self.signal = []
            self.dropped = 0
            self.total = 0

    @staticmethod
    def _samples(frame: np.ndarray) -> np.ndarray:
        h, w = frame.shape[:2]
        ys = (np.arange(36) * 2 + 1) * h // 72
        xs = (np.arange(64) * 2 + 1) * w // 128
        s = frame[ys][:, xs].astype(np.float32)
        return s[..., 0] * 0.114 + s[..., 1] * 0.587 + s[..., 2] * 0.299

    def push(self, frame: np.ndarray, t: float | None = None):
        t = now() if t is None else t
        samples = self._samples(frame)
        with self.lock:
            self.signal.append(t)
            self.signal = self.signal[-150:]
            self.total += 1
            diff = float("inf")
            if self.last_samples is not None and self.last_samples.shape == samples.shape:
                diff = float(np.abs(samples - self.last_samples).mean())
                thr = min(max(self.noise * 3 + 0.6, 1.0), 4.0)
                if self.dedup and diff < thr:
                    self.noise = self.noise * 0.95 + diff * 0.05
                    self.dropped += 1
                    return
            is_cut = diff != float("inf") and diff > self.cut_threshold
            self.last_samples = samples
            dt = t - self.last_unique
            if self.last_unique > 0 and 0.004 < dt < 0.1:
                self.interval = self.interval * 0.9 + dt * 0.1
            self.last_unique = t
            pred = self.smoothed + self.interval
            if self.smoothed == 0 or abs(t - pred) > self.interval * 0.6:
                self.smoothed = t
            else:
                self.smoothed = pred + (t - pred) * 0.15
            self.arrivals.append(t)
            self.arrivals = self.arrivals[-120:]
            self.seq += 1
            self.latest = (frame, self.smoothed, self.seq, self.interval, is_cut)

    def take(self, after: int):
        with self.lock:
            if self.latest is None or self.latest[2] == after:
                return None
            return self.latest

    @staticmethod
    def _rate(a):
        t = now()
        r = [x for x in a if t - x < 1.0]
        if len(r) < 2 or t - r[0] > 1.2:
            return 0.0
        return (len(r) - 1) / max(r[-1] - r[0], 1e-3)

    def stats(self):
        with self.lock:
            return (self._rate(self.arrivals), self._rate(self.signal),
                    self.dropped / self.total if self.total else 0.0)


# --------------------------------------------------------------------------------------------
# Frame generation: dense optical flow both ways + motion compensated, occlusion aware blending
# --------------------------------------------------------------------------------------------
QUALITY = {  # name: (analysis width in pixels, DIS preset) - same cost for 720p, 1080p and 4K sources
    "Hoch": (640, cv2.DISOPTICAL_FLOW_PRESET_MEDIUM),
    "Schnell": (640, cv2.DISOPTICAL_FLOW_PRESET_FAST),
}


class PairState:
    """Everything needed to generate any moment between the last two real frames (immutable once published)."""
    __slots__ = ("a", "b", "f01", "f10", "grid", "ua", "ub", "uf01", "uf10", "ugrid",
                 "cut", "pair", "time_b", "interval", "seq", "ready")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))


class Interpolator:
    """Dense optical flow (DIS) both ways at half resolution, once per real frame (worker thread);
    each display refresh warps both frames to the exact moment t and blends them (UI thread).
    With OpenCL (most NVIDIA / AMD / Intel GPUs) the per-frame work runs on the graphics card."""

    def __init__(self, quality: str = "Auto", use_opencl: bool | None = None):
        self.use_ocl = bool(cv2.ocl.haveOpenCL()) if use_opencl is None else use_opencl
        cv2.ocl.setUseOpenCL(self.use_ocl)
        self.set_quality(quality)
        self.state: PairState | None = None
        self._grid = None
        self._ugrid = None
        self.analysis_ms = 0.0

    @property
    def backend(self) -> str:
        b = "GPU (OpenCL)" if self.use_ocl else "CPU"
        return f"{b} · {self.level}" if self.auto else b

    def set_quality(self, q: str):
        """'Auto' starts with 'Hoch' and switches to 'Schnell' when the analysis cannot keep up with the game."""
        self.auto = q not in QUALITY
        self.quality = "Auto" if self.auto else q
        self._apply_level("Hoch" if self.auto else q)

    def _apply_level(self, level: str):
        self.level = level
        self.work_width, preset = QUALITY[level]
        self.dis = cv2.DISOpticalFlow_create(preset)
        self._level_since = now()

    def _adapt(self, interval: float):
        if not self.auto or now() - self._level_since < 3.0:
            return
        budget = interval * 1000
        if self.level == "Hoch" and self.analysis_ms > budget * 0.8:
            self._apply_level("Schnell")
        elif self.level == "Schnell" and self.analysis_ms < budget * 0.3:
            self._apply_level("Hoch")

    def reset(self):
        self.state = None

    def ingest(self, frame: np.ndarray, is_cut: bool = False, time_b: float = 0.0, interval: float = 1 / 30, seq: int = 0):
        """New real frame -> motion analysis between the previous and this one; publishes a new PairState."""
        t0 = now()
        prev = self.state
        h, w = frame.shape[:2]
        a = prev.b if prev is not None and prev.b is not None and prev.b.shape == frame.shape else None
        st = PairState(a=a, b=frame, cut=is_cut, pair=False, time_b=time_b, interval=interval, seq=seq)
        if a is None or is_cut:
            st.ready = now()
            self.state = st
            return
        if self._grid is None or self._grid.shape[:2] != (h, w):
            gx, gy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
            self._grid = np.dstack([gx, gy])
            self._ugrid = cv2.UMat(self._grid) if self.use_ocl else None
        sw = min(w, self.work_width)
        sh = max(32, round(h * sw / w))
        ga = cv2.cvtColor(cv2.resize(a, (sw, sh), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        gb = cv2.cvtColor(cv2.resize(frame, (sw, sh), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        k = np.float32(w / sw)
        st.f01 = cv2.resize(self.dis.calc(ga, gb, None), (w, h)) * k
        st.f10 = cv2.resize(self.dis.calc(gb, ga, None), (w, h)) * k
        st.grid = self._grid
        if self.use_ocl:
            st.ua, st.ub = cv2.UMat(a), cv2.UMat(frame)
            st.uf01, st.uf10, st.ugrid = cv2.UMat(st.f01), cv2.UMat(st.f10), self._ugrid
        st.pair = True
        st.ready = now()      # the in-between images run from here (analysis time is part of the delay)
        self.state = st
        self.analysis_ms = self.analysis_ms * 0.8 + (now() - t0) * 1000 * 0.2
        self._adapt(interval)

    def synthesize(self, st: PairState | None, t: float, mode: str = "interpolate") -> np.ndarray | None:
        """Moment t between A (0) and B (1). mode: interpolate | blend | passthrough"""
        if st is None or st.b is None:
            return None
        if mode == "passthrough" or not st.pair or t >= 0.999:
            return st.b
        if t <= 0.001:
            return st.a
        if st.cut:
            return st.a if t < 0.5 else st.b
        if mode == "blend":
            return cv2.addWeighted(st.a, 1 - t, st.b, t, 0)
        t = float(t)
        gpu = self.use_ocl and st.uf01 is not None
        a, b = (st.ua, st.ub) if gpu else (st.a, st.b)
        f01, f10, grid = (st.uf01, st.uf10, st.ugrid) if gpu else (st.f01, st.f10, st.grid)
        try:
            # where the pixel at time t comes from in A and in B (linear motion, quadratic approximation)
            m0 = cv2.add(grid, cv2.addWeighted(f01, -t * (1 - t), f10, t * t, 0))
            m1 = cv2.add(grid, cv2.addWeighted(f01, (1 - t) * (1 - t), f10, -t * (1 - t), 0))
            wa = cv2.remap(a, m0, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            wb = cv2.remap(b, m1, None, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
            out = cv2.addWeighted(wa, 1 - t, wb, t, 0)
            return out.get() if gpu else out
        except cv2.error:
            if gpu:   # broken OpenCL driver -> CPU from now on
                self.use_ocl = False
                cv2.ocl.setUseOpenCL(False)
                return self.synthesize(st, t, mode)
            raise


# --------------------------------------------------------------------------------------------
# Audio delay line: keeps "delay" of sound in flight; skips / holds on clock drift
# --------------------------------------------------------------------------------------------
class DelayLine:
    def __init__(self, channels: int = 2, capacity: int = 96000):
        self.ch = channels
        self.cap = capacity
        self.buf = np.zeros((capacity, channels), np.float32)
        self.w = 0
        self.r = 0
        self.primed = False
        self.filling = False
        self.target = 0
        self.tolerance = 1536
        self.skips = 0
        self.holds = 0
        self.lock = threading.Lock()

    def reset(self):
        with self.lock:
            self.w = self.r = 0
            self.primed = self.filling = False

    @property
    def available(self):
        return self.w - self.r

    def write(self, data: np.ndarray):
        n = len(data)
        if n == 0:
            return
        with self.lock:
            if n > self.cap:
                data = data[-self.cap:]
                n = self.cap
            i = self.w % self.cap
            first = min(n, self.cap - i)
            self.buf[i:i + first] = data[:first, :self.ch] if data.shape[1] >= self.ch else np.repeat(data[:first, :1], self.ch, 1)
            if first < n:
                rest = data[first:]
                self.buf[:n - first] = rest[:, :self.ch] if rest.shape[1] >= self.ch else np.repeat(rest[:, :1], self.ch, 1)
            self.w += n
            if self.w - self.r > self.cap:
                self.r = self.w - self.cap

    def read(self, n: int) -> np.ndarray:
        out = np.zeros((n, self.ch), np.float32)
        with self.lock:
            avail = self.w - self.r
            if not self.primed:
                if avail < self.target:
                    return out
                self.primed = True
            if avail > self.target + self.tolerance:
                self.r += avail - self.target
                avail = self.target
                self.skips += 1
            if avail < self.target - self.tolerance:
                self.filling = True
                self.holds += 1
            hold = 0
            if self.filling:
                hold = min(n, max(0, self.target - avail))
                if hold < n:
                    self.filling = False
            k = min(n - hold, avail)
            if k > 0:
                i = self.r % self.cap
                first = min(k, self.cap - i)
                out[hold:hold + first] = self.buf[i:i + first]
                if first < k:
                    out[hold + first:hold + k] = self.buf[:k - first]
                self.r += k
        return out
