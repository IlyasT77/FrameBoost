"""Sound: capture card input -> delay line (same delay as the picture) -> speakers/headphones."""
from __future__ import annotations

import numpy as np

from .core import DelayLine
from .sources import is_card

try:
    import sounddevice as sd
except Exception:  # PortAudio missing
    sd = None


def input_devices() -> list[tuple[str, int]]:
    """[(name, index)] of input devices, WASAPI preferred, capture cards first."""
    if sd is None:
        return []
    try:
        apis = sd.query_hostapis()
        devs = sd.query_devices()
    except Exception:
        return []
    pref = None
    for i, a in enumerate(apis):
        if "WASAPI" in a["name"]:
            pref = i
    out = []
    for i, d in enumerate(devs):
        if d["max_input_channels"] > 0 and (pref is None or d["hostapi"] == pref):
            out.append((d["name"], i))
    out.sort(key=lambda x: (not is_card(x[0]), x[0]))
    return out


def matching_input(video_name: str, devices: list[tuple[str, int]]):
    first = video_name.lower().split(" ")[0] if video_name else ""
    for name, idx in devices:
        if first and first in name.lower():
            return idx
    for name, idx in devices:
        if is_card(name):
            return idx
    return None


class AudioPlayer:
    RATE = 48000

    def __init__(self):
        self.line = DelayLine(2, self.RATE * 2)
        self.delay = 0.06
        self.volume = 1.0
        self.out_stream = None
        self.in_stream = None
        self.output_latency = 0.0
        self.error = ""

    def set_delay(self, seconds: float):
        self.delay = max(0.0, min(seconds, 0.5))
        self.line.target = int(max(0.0, self.delay - self.output_latency) * self.RATE)
        self.line.tolerance = max(int(0.02 * self.RATE), 1536)

    def _out_cb(self, outdata, frames, time_info, status):
        outdata[:] = self.line.read(frames) * self.volume

    def _in_cb(self, indata, frames, time_info, status):
        self.line.write(np.asarray(indata, np.float32))

    def push(self, samples: np.ndarray):
        self.line.write(samples)

    def start_output(self) -> bool:
        if sd is None:
            self.error = "Ton nicht verfügbar (Audio-Bibliothek fehlt) – das Bild läuft ohne Ton weiter."
            return False
        try:
            self.line.reset()
            self.out_stream = sd.OutputStream(samplerate=self.RATE, channels=2, dtype="float32",
                                              callback=self._out_cb, latency="low")
            self.out_stream.start()
            self.output_latency = float(self.out_stream.latency or 0)
            self.set_delay(self.delay)
            return True
        except Exception as e:
            self.error = "Kein Lautsprecher/Kopfhörer gefunden – das Bild läuft ohne Ton weiter."
            from .applog import log
            log.info("Ton-Ausgabe nicht verfügbar: %s", e)
            self.out_stream = None
            return False

    def start_input(self, device: int) -> bool:
        if sd is None:
            return False
        try:
            info = sd.query_devices(device)
            ch = 2 if info["max_input_channels"] >= 2 else 1
            self.in_stream = sd.InputStream(device=device, samplerate=self.RATE, channels=ch, dtype="float32",
                                            callback=self._in_cb, latency="low")
            self.in_stream.start()
            return True
        except Exception as e:
            self.error = "Der Ton der Capture Card lässt sich nicht öffnen (in den Einstellungen eine andere Audio-Quelle wählen)."
            from .applog import log
            log.info("Ton-Eingang nicht verfügbar: %s", e)
            self.in_stream = None
            return False

    def stop(self):
        for s in (self.in_stream, self.out_stream):
            if s is not None:
                try:
                    s.stop()
                    s.close()
                except Exception:
                    pass
        self.in_stream = self.out_stream = None
        self.line.reset()
