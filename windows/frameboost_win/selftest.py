"""--selftest <dir>: quality vs. ground truth, speed, duplicate/scene-cut detection, sound delay accuracy."""
from __future__ import annotations

import os
import time

import cv2
import numpy as np

from .core import DelayLine, FrameStore, Interpolator
from .sources import CaptureSource, DemoSource


class FakeCard:
    """Simulated capture card driver: accepts every requested mode but delivers what the chip really can."""

    def __init__(self, modes, fallback=(640, 480, 30)):
        self.modes, self.fallback, self.req, self.t = modes, fallback, {}, 0.0

    def clock(self):
        return self.t

    def set(self, prop, value):
        self.req[prop] = value

    def read(self):
        fcc = int(self.req.get(cv2.CAP_PROP_FOURCC, 0))
        key = (int(self.req.get(cv2.CAP_PROP_FRAME_WIDTH, 0)), int(self.req.get(cv2.CAP_PROP_FRAME_HEIGHT, 0)), fcc)
        w, h, rate = self.modes.get(key, self.fallback)
        self.t += 1.0 / rate
        return True, np.zeros((h, w, 3), np.uint8)


def run(out_dir: str) -> bool:
    os.makedirs(out_dir, exist_ok=True)
    log = []

    def say(s):
        print(s)
        log.append(s)

    ok = True
    demo = DemoSource(FrameStore())
    ip = Interpolator()
    say(f"OpenCV {cv2.__version__} · Berechnung: {ip.backend}")
    say("Qualität (PSNR in dB, höher = besser) gegen das echte Zwischenbild:")
    grid_imgs = None
    for q in ("Hoch", "Schnell"):
        ip.set_quality(q)
        for fast in (False, True):
            r = []
            for base in (10, 23, 37, 52):
                ip.reset()
                ip.ingest(demo.frame_at(base, fast))
                ip.ingest(demo.frame_at(base + 1, fast))
                for t in (0.25, 0.5, 0.75):
                    truth = demo.frame_at(base + t, fast)
                    fb = ip.synthesize(ip.state, t)
                    bl = ip.synthesize(ip.state, t, "blend")
                    hold = demo.frame_at(base if t < 0.5 else base + 1, fast)
                    r.append((cv2.PSNR(fb, truth), cv2.PSNR(bl, truth), cv2.PSNR(hold, truth)))
                    if q == "Hoch" and not fast and base == 10 and t == 0.5:
                        grid_imgs = (demo.frame_at(base), demo.frame_at(base + 1), truth, bl, fb)
            m = np.mean(r, axis=0)
            say(f"  [{'schnelle Bewegung' if fast else 'normal'} | {q}] Frame wiederholen {m[2]:.1f} · Überblenden {m[1]:.1f} · FrameBoost {m[0]:.1f}")
            if m[0] < m[1] + 3:
                ok = False
                say("    -> zu schwach!")
    if grid_imgs:
        a, b, tr, bl, fb = grid_imgs
        diff = np.clip(cv2.absdiff(fb, tr).astype(np.int32) * 3, 0, 255).astype(np.uint8)
        crop = lambda im: im[380:720, 280:1000]
        labels = ["Echter Frame A (30 FPS)", "Echter Frame B (30 FPS)", "So waere es richtig",
                  "Nur ueberblenden", "FrameBoost: generiert", "Fehler (schwarz = perfekt)"]
        tiles = []
        for im, lb in zip((a, b, tr, bl, fb, diff), labels):
            c = crop(im).copy()
            cv2.rectangle(c, (0, 0), (720, 36), (0, 0, 0), -1)
            cv2.putText(c, lb, (10, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2, cv2.LINE_AA)
            tiles.append(c)
        cv2.imwrite(os.path.join(out_dir, "vergleich.png"), np.vstack([np.hstack(tiles[:3]), np.hstack(tiles[3:])]))

    # duplicates + scene cut
    st = FrameStore()
    f1 = demo.frame_at(5)
    st.push(f1, 1.0); st.push(f1.copy(), 1.016); st.push(f1.copy(), 1.033)
    dup_ok = st.take(0)[2] == 1
    st.push(np.zeros_like(f1), 1.05)
    cut_ok = st.take(1)[4] is True
    say(f"Doppelte Frames entfernen: {'OK' if dup_ok else 'FEHLER'} · Szenenwechsel-Erkennung: {'OK' if cut_ok else 'FEHLER'}")
    ok = ok and dup_ok and cut_ok
    # calm scene: only a small object moves by 1 pixel -> must count as a NEW frame
    st3 = FrameStore()
    calm = lambda x: cv2.rectangle(demo.frame_at(5).copy(), (600 + x, 300), (624 + x, 324), (255, 255, 255), -1)
    c0, c1, c2 = calm(0), calm(1), calm(2)
    for fr, tt in ((c0, 1.0), (c0.copy(), 1.016), (c1, 1.033), (c1.copy(), 1.05), (c2, 1.066)):
        st3.push(fr, tt)
    calm_ok = st3.take(0)[2] == 3
    say(f"Ruhige Szene (kleines Objekt bewegt sich 1 Pixel) wird als neues Bild erkannt: {'OK' if calm_ok else 'FEHLER'}")
    ok = ok and calm_ok

    # sound delay line: capture chunks of 10 ms, output callbacks of 512 frames with 0.1 % faster clock
    rate, C, F = 48000, 480, 512
    line = DelayLine(2, 96000)
    line.tolerance = max(int(0.02 * rate), 1536)
    line.target = int(0.06 * rate)
    ev = [((k + 1) * C / rate + (k % 3) * 0.001, 0) for k in range(int(3 * rate / C))]
    ev += [(m * F / rate * 0.999, 1) for m in range(int(3 * rate / F))]
    ev.sort()
    arrival = []
    written = 0
    lat60, lat120 = [], []
    for tm, kind in ev:
        if tm > 1.0:
            line.target = int(0.12 * rate)
        if kind == 0:
            vals = np.arange(written + 1, written + C + 1, dtype=np.float32)
            line.write(np.stack([vals, vals], 1))
            arrival += [tm] * C
            written += C
        else:
            out = line.read(F)[:, 0]
            for i in np.nonzero(out > 0)[0]:
                d = tm + i / rate - arrival[int(out[i]) - 1]
                if 0.3 < tm < 1.0:
                    lat60.append(d)
                elif tm > 1.3:
                    lat120.append(d)
    m60, m120 = np.mean(lat60) * 1000, np.mean(lat120) * 1000
    spread = max(np.ptp(lat60), np.ptp(lat120)) * 1000
    a_ok = abs(m60 - 60) < 10 and abs(m120 - 120) < 10 and spread < 30
    say(f"Ton-Puffer: Ziel 60 ms -> {m60:.1f} ms, Ziel 120 ms -> {m120:.1f} ms, Schwankung {spread:.1f} ms {'OK' if a_ok else 'FEHLER'}")
    ok = ok and a_ok

    # capture format: a cheap USB 2.0 stick accepts "1080p 60 Hz" but delivers only 5 (raw) or 30 (MJPEG) frames/s
    fcc = lambda c: cv2.VideoWriter_fourcc(*c)
    usb2 = FakeCard({(1920, 1080, fcc("YUY2")): (1920, 1080, 5), (1920, 1080, fcc("MJPG")): (1920, 1080, 30),
                     (1280, 720, fcc("YUY2")): (1280, 720, 10), (1280, 720, fcc("MJPG")): (1280, 720, 60)})
    usb3 = FakeCard({(1920, 1080, fcc("YUY2")): (1920, 1080, 60), (1920, 1080, fcc("MJPG")): (1920, 1080, 60)})
    d2, _ = CaptureSource.negotiate(usb2, clock=usb2.clock)
    d3, _ = CaptureSource.negotiate(usb3, clock=usb3.clock)
    f_ok = d2 == "1280×720 @ 60 Hz (MJPG)" and d3 == "1920×1080 @ 60 Hz (YUY2)"
    say(f"Capture-Format: USB-2.0-Stick -> {d2}, USB-3.0-Karte -> {d3}: {'OK' if f_ok else 'FEHLER'}")
    ok = ok and f_ok

    # speed at 1080p
    say("Geschwindigkeit 1920x1080 (dieser Rechner):")
    for q in ("Hoch", "Schnell"):
        ip.set_quality(q)
        ip.reset()
        frames = [cv2.resize(demo.frame_at(40 + i), (1920, 1080)) for i in range(6)]
        ta = []
        for f in frames:
            t0 = time.perf_counter(); ip.ingest(f); ta.append(time.perf_counter() - t0)
        ts = []
        for i in range(10):
            t0 = time.perf_counter(); ip.synthesize(ip.state, 0.25 + 0.05 * (i % 5)); ts.append(time.perf_counter() - t0)
        a_ms, s_ms = np.median(ta[1:]) * 1000, np.median(ts) * 1000
        say(f"  {q}: Analyse {a_ms:.1f} ms/Frame (läuft parallel), Zwischenbild {s_ms:.1f} ms -> "
            f"60 FPS {'JA' if s_ms < 30 else 'NEIN'}, 120 FPS {'JA' if 3 * s_ms < 30 else 'NEIN'}, 180 FPS {'JA' if 5 * s_ms < 30 else 'NEIN'}")
    say("ERGEBNIS: " + ("BESTANDEN" if ok else "NICHT BESTANDEN"))
    with open(os.path.join(out_dir, "ergebnis.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(log) + "\n")
    return ok
