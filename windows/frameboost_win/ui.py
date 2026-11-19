"""FrameBoost for Windows - user interface (PySide6)."""
from __future__ import annotations

import math
import os
import platform
import sys
import threading
import time
from collections import deque

import cv2
import numpy as np
from PySide6.QtCore import QRectF, QSettings, Qt, QTimer, QUrl
from PySide6.QtGui import (QColor, QDesktopServices, QFont, QFontMetrics, QIcon, QImage, QKeySequence, QLinearGradient, QPainter,
                           QPainterPath, QPen, QShortcut, QSurfaceFormat)
from PySide6.QtWidgets import (QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog, QFormLayout, QFrame,
                               QHBoxLayout, QLabel, QMainWindow, QMessageBox, QPushButton, QSlider, QVBoxLayout,
                               QWidget)

from . import __version__, applog
from .audio import AudioPlayer, input_devices, matching_input
from .core import FrameStore, Interpolator, now
from .sources import CaptureSource, DemoSource, list_video_devices

log = applog.log
ACCENT = "#ff4f8b"
MODES = ["Aus", "Auto", "2×", "3×", "4×", "6×"]
MODE_STEPS = {"2×": 2, "3×": 3, "4×": 4, "6×": 6}
MODE_HELP = {"Aus": "Keine Frame Generation (Original)",
             "Auto": "So viele Bilder wie dein Bildschirm kann (60 Hz → 60, 180 Hz → 180 FPS)",
             "2×": "30 → 60 FPS", "3×": "30 → 90 FPS", "4×": "30 → 120 FPS", "6×": "30 → 180 FPS"}
REPO_URL = "https://github.com/IlyasT77/FrameBoost"

STYLE = f"""
* {{ font-family: 'Segoe UI Variable Text', 'Segoe UI', 'Inter', sans-serif; font-size: 13px; }}
QMainWindow, QDialog {{ background: #0b0d12; }}
QWidget {{ color: #e9e9f0; }}
QFrame#topbar {{ background: #13151c; border-bottom: 1px solid #22252f; }}
QLabel#brand {{ font-size: 15px; font-weight: 700; color: #ffffff; padding-right: 6px; }}
QComboBox {{ background: #1a1d26; border: 1px solid #2a2e3b; border-radius: 7px; padding: 5px 10px; min-width: 210px; }}
QComboBox:hover {{ border-color: #3a3f50; }}
QComboBox QAbstractItemView {{ background: #1a1d26; border: 1px solid #2a2e3b; selection-background-color: #2b3040; }}
QPushButton {{ background: #1a1d26; border: 1px solid #2a2e3b; border-radius: 7px; padding: 6px 13px; }}
QPushButton:hover {{ background: #222632; }}
QPushButton:pressed {{ background: #191c24; }}
QPushButton#seg {{ border-radius: 0px; border-right-width: 0px; padding: 6px 11px; min-width: 30px; }}
QPushButton#segL {{ border-top-right-radius: 0px; border-bottom-right-radius: 0px; border-right-width: 0px; padding: 6px 11px; }}
QPushButton#segR {{ border-top-left-radius: 0px; border-bottom-left-radius: 0px; padding: 6px 11px; }}
QPushButton#seg:checked, QPushButton#segL:checked, QPushButton#segR:checked {{ background: {ACCENT}; border-color: {ACCENT}; color: white; font-weight: 600; }}
QPushButton#primary {{ background: {ACCENT}; border: none; color: white; font-weight: 600; padding: 6px 18px; }}
QPushButton#primary:hover {{ background: #ff6a9c; }}
QPushButton#primary[running="true"] {{ background: #2b9a47; }}
QLabel#banner {{ background: #4a1820; color: #ffd9df; padding: 9px 14px; border-top: 1px solid #6b2430; }}
QLabel#hint {{ color: #9a9caa; font-size: 12px; }}
QLabel#section {{ color: #ffffff; font-weight: 600; font-size: 13px; padding-top: 10px; }}
QSlider::groove:horizontal {{ height: 4px; background: #2a2e3b; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: #ffffff; width: 14px; margin: -6px 0; border-radius: 7px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QCheckBox::indicator {{ width: 16px; height: 16px; border-radius: 4px; border: 1px solid #3a3f50; background: #1a1d26; }}
QCheckBox::indicator:checked {{ background: {ACCENT}; border-color: {ACCENT}; }}
QToolTip {{ background: #1a1d26; color: #e9e9f0; border: 1px solid #2a2e3b; padding: 4px; }}
"""


# ----------------------------------------------------------------------------------------------
class Engine:
    """Source -> unique frames -> analysis worker -> per-refresh synthesis; sound through the delay line."""

    def __init__(self):
        self.store = FrameStore()
        self.interp = Interpolator()
        self.audio = AudioPlayer()
        self.source = None
        self.source_name = ""
        self.running = False
        self.mode = "Auto"
        self.blend_only = False
        self.audio_sync = True
        self.audio_offset_ms = 0.0
        self.audio_device = None
        self.error = ""
        self._stop = threading.Event()
        self._worker = None
        self.synth_ms = 0.0
        self.out_times: deque = deque(maxlen=600)
        self.draw_period = 1 / 60
        self._last_draw = 0.0
        self._cache_key = None
        self._cache_img = None

    # -- lifecycle ----------------------------------------------------------------------------
    def start(self, video) -> bool:
        """video: ('demo', None) or (name, index)."""
        self.stop()
        self.error = ""
        self.store.reset()
        self.interp.reset()
        self._cache_key = None
        name, index = video
        self.source_name = "Demo-Signal" if index is None else name
        if index is None:
            self.source = DemoSource(self.store, audio_sink=self.audio.push)
        else:
            self.source = CaptureSource(index, self.store)
        if not self.source.open():
            self.error = self.source.error
            self.source = None
            return False
        self.audio.error = ""
        if self.audio.start_output():
            if index is not None and self.audio_device is not None:
                self.audio.start_input(self.audio_device)
        self.update_audio_delay()
        self._stop.clear()
        self.source.start()
        self._worker = threading.Thread(target=self._analyse, name="analysis", daemon=True)
        self._worker.start()
        self.running = True
        log.info("Start: %s · Modus %s · Qualität %s · %s", self.source_name, self.mode, self.interp.quality, self.interp.backend)
        return True

    def stop(self):
        if self.source is None and not self.running:
            return
        self._stop.set()
        if self._worker is not None:
            self._worker.join(timeout=2)
        self._worker = None
        if self.source is not None:
            self.source.stop()
        self.source = None
        self.audio.stop()
        self.running = False
        self.interp.reset()
        log.info("Stop")

    def _analyse(self):
        last = 0
        while not self._stop.is_set():
            f = self.store.take(last)
            if f is None:
                time.sleep(0.002)
                continue
            frame, t_b, seq, interval, cut = f
            last = seq
            self.interp.ingest(frame, cut, t_b, interval, seq)

    # -- per display refresh -----------------------------------------------------------------
    def frame_for_display(self):
        t_now = now()
        if self._last_draw:
            dp = min(max(t_now - self._last_draw, 0.004), 0.05)
            self.draw_period = self.draw_period * 0.95 + dp * 0.05
        self._last_draw = t_now
        st = self.interp.state
        if st is None or not self.running:
            return None
        if self.mode == "Aus":
            t, mode = 1.0, "passthrough"
        else:
            phase = min(max((t_now - max(st.time_b, st.ready or 0)) / max(st.interval, 0.004), 0.0), 1.0)
            # never ask for more in-between images than this PC can generate in time
            budget = max(1, int(st.interval * 1000 * 0.85 / max(self.synth_ms, 0.5)))
            want = MODE_STEPS.get(self.mode) or max(1, round(st.interval / max(self.draw_period, 0.002)))
            steps = max(1, min(want, budget))
            t = min(math.floor(phase * steps + 0.25) / steps, 1.0) if steps > 1 else (1.0 if phase > 0.5 else 0.0)
            mode = "blend" if self.blend_only else "interpolate"
        key = (st.seq, round(t, 3), mode)
        if key == self._cache_key:
            return self._cache_img
        t0 = now()
        img = self.interp.synthesize(st, t, mode)
        if mode == "interpolate" and 0.001 < t < 0.999 and st.pair:
            self.synth_ms = self.synth_ms * 0.85 + (now() - t0) * 1000 * 0.15
        self._cache_key, self._cache_img = key, img
        self.out_times.append(t_now)
        return img

    def output_fps(self) -> float:
        t = now()
        r = [x for x in self.out_times if t - x < 1.0]
        if len(r) < 2 or t - r[0] > 1.2:
            return 0.0
        return (len(r) - 1) / max(r[-1] - r[0], 1e-3)

    def video_delay(self) -> float:
        st = self.interp.state
        interval = st.interval if st is not None else 1 / 30
        fg = 0.0 if self.mode == "Aus" else interval + self.interp.analysis_ms / 1000
        return fg + 1.5 * self.draw_period + self.synth_ms / 1000

    def update_audio_delay(self):
        d = max(0.0, self.video_delay() + self.audio_offset_ms / 1000) if self.audio_sync else 0.0
        self.audio.set_delay(d)


# ----------------------------------------------------------------------------------------------
def paint_view(widget: QWidget, p: QPainter, engine: Engine, show_hud: bool, stats: dict):
    r = widget.rect()
    p.fillRect(r, QColor(0, 0, 0))
    img = engine.frame_for_display() if engine.running else None
    if img is not None:
        h, w = img.shape[:2]
        img = np.ascontiguousarray(img)
        q = QImage(img.data, w, h, 3 * w, QImage.Format_BGR888)
        s = min(r.width() / w, r.height() / h)
        tw, th = w * s, h * s
        target = QRectF((r.width() - tw) / 2, (r.height() - th) / 2, tw, th)
        p.setRenderHint(QPainter.SmoothPixmapTransform, abs(s - 1) > 0.01)
        p.drawImage(target, q)
        widget._keep = img
    elif not engine.running:
        paint_placeholder(widget, p)
    if show_hud and engine.running:
        paint_hud(widget, p, stats)


def paint_placeholder(widget: QWidget, p: QPainter):
    r = widget.rect()
    p.setRenderHint(QPainter.Antialiasing, True)
    cx, cy = r.width() / 2, r.height() / 2 - 40
    # logo: three frames
    for i, a in enumerate((70, 140, 255)):
        path = QPainterPath()
        path.addRoundedRect(QRectF(cx - 46 + i * 22, cy - 92, 46, 62), 9, 9)
        p.fillPath(path, QColor(255, 79, 139, a))
    p.setPen(QColor("#ffffff"))
    p.setFont(QFont("Segoe UI", 26, QFont.Bold))
    p.drawText(QRectF(0, cy - 20, r.width(), 44), Qt.AlignCenter, "FrameBoost")
    p.setPen(QColor("#9a9caa"))
    p.setFont(QFont("Segoe UI", 11))
    p.drawText(QRectF(0, cy + 26, r.width(), 24), Qt.AlignCenter,
               "PS5 → Capture Card → PC anschließen. Die Karte wird erkannt und startet automatisch.")
    steps = ["In der PS5: Einstellungen → System → HDMI → „HDCP aktivieren“ aus",
             "In der PS5: Videoausgabe 1080p, HDR aus",
             "OBS und Kamera-Apps schließen (sonst ist die Karte belegt)"]
    p.setFont(QFont("Segoe UI", 10))
    y = cy + 70
    for s in steps:
        p.setPen(QColor(ACCENT))
        p.drawText(QRectF(cx - 230, y, 20, 20), Qt.AlignLeft | Qt.AlignVCenter, "•")
        p.setPen(QColor("#c9cad4"))
        p.drawText(QRectF(cx - 214, y, 460, 20), Qt.AlignLeft | Qt.AlignVCenter, s)
        y += 24


def paint_hud(widget: QWidget, p: QPainter, s: dict):
    lines = [f"Spiel {s.get('game', 0):.0f} FPS · Signal {s.get('signal', 0):.0f} Hz · Bildschirm {s.get('hz', 0):.0f} Hz",
             f"Zwischenbild {s.get('synth', 0):.1f} ms · Analyse {s.get('analysis', 0):.1f} ms · {s.get('backend', '')}",
             f"Duplikate {s.get('dupes', 0) * 100:.0f} % · Ton-Puffer {s.get('audio', 0):.0f} ms",
             s.get("format", "")]
    small = QFont("Consolas", 9)
    fm = QFontMetrics(small)
    width = max([fm.horizontalAdvance(x) for x in lines] + [160]) + 28
    p.setRenderHint(QPainter.Antialiasing, True)
    box = QRectF(widget.width() - width - 12, 12, width, 40 + 15 * len(lines) + 6)
    path = QPainterPath()
    path.addRoundedRect(box, 10, 10)
    p.fillPath(path, QColor(0, 0, 0, 160))
    p.setPen(QColor("#5fe08a"))
    p.setFont(QFont("Consolas", 20, QFont.Bold))
    p.drawText(box.adjusted(0, 6, -14, 0), Qt.AlignRight | Qt.AlignTop, f"{s.get('out', 0):.0f} FPS")
    p.setPen(QColor("#e9e9f0"))
    p.setFont(small)
    y = box.top() + 40
    for ln in lines:
        p.drawText(QRectF(box.left(), y, box.width() - 14, 16), Qt.AlignRight | Qt.AlignVCenter, ln)
        y += 15


try:
    from PySide6.QtOpenGLWidgets import QOpenGLWidget
except Exception:  # pragma: no cover
    QOpenGLWidget = None


class RasterView(QWidget):
    """Fallback without OpenGL (also used by the automated tests)."""

    def __init__(self, engine: Engine, owner):
        super().__init__()
        self.engine, self.owner = engine, owner
        self.setMouseTracking(True)
        self.setMinimumSize(640, 360)
        self.timer = QTimer(self)
        self.timer.setTimerType(Qt.PreciseTimer)
        self.timer.timeout.connect(self.update)
        self.timer.start(4)

    def paintEvent(self, e):
        p = QPainter(self)
        paint_view(self, p, self.engine, self.owner.show_hud, self.owner.stats)
        p.end()

    def mouseMoveEvent(self, e):
        self.owner.poke()


if QOpenGLWidget is not None:
    class GLView(QOpenGLWidget):
        """Vsync-locked view: redraws exactly once per screen refresh (60/120/144/180/240 Hz)."""

        def __init__(self, engine: Engine, owner):
            super().__init__()
            self.engine, self.owner = engine, owner
            self.setMouseTracking(True)
            self.setMinimumSize(640, 360)
            self.frameSwapped.connect(self.update)

        def paintGL(self):
            p = QPainter(self)
            paint_view(self, p, self.engine, self.owner.show_hud, self.owner.stats)
            p.end()

        def mouseMoveEvent(self, e):
            self.owner.poke()


# ----------------------------------------------------------------------------------------------
class SettingsDialog(QDialog):
    def __init__(self, win: "MainWindow"):
        super().__init__(win)
        self.win = win
        e = win.engine
        self.setWindowTitle("Einstellungen")
        self.setMinimumWidth(460)
        form = QFormLayout(self)
        form.setHorizontalSpacing(18)
        form.setVerticalSpacing(10)

        def section(t):
            lb = QLabel(t)
            lb.setObjectName("section")
            form.addRow(lb)

        section("Ton")
        self.audio_combo = QComboBox()
        self.audio_combo.addItem("Kein Ton", None)
        for name, idx in input_devices():
            self.audio_combo.addItem(name, idx)
        i = self.audio_combo.findData(e.audio_device)
        self.audio_combo.setCurrentIndex(max(0, i))
        self.audio_combo.currentIndexChanged.connect(self._audio_dev)
        form.addRow("Audio-Quelle", self.audio_combo)
        self.vol = QSlider(Qt.Horizontal)
        self.vol.setRange(0, 100)
        self.vol.setValue(int(e.audio.volume * 100))
        self.vol.valueChanged.connect(lambda v: win.set_setting("volume", v / 100))
        form.addRow("Lautstärke", self.vol)
        self.sync = QCheckBox("Bild und Ton synchron (Ton-Puffer)")
        self.sync.setChecked(e.audio_sync)
        self.sync.toggled.connect(lambda v: win.set_setting("audio_sync", v))
        form.addRow("", self.sync)
        self.offset = QSlider(Qt.Horizontal)
        self.offset.setRange(-100, 200)
        self.offset.setSingleStep(5)
        self.offset.setValue(int(e.audio_offset_ms))
        self.offset_lbl = QLabel()
        self.offset.valueChanged.connect(self._offset)
        form.addRow("Feinabstimmung", self.offset)
        form.addRow("", self.offset_lbl)
        self._offset(self.offset.value())
        hint = QLabel("Test: Demo-Signal starten – weißes Quadrat und Piepton müssen gleichzeitig kommen.")
        hint.setObjectName("hint")
        hint.setWordWrap(True)
        form.addRow("", hint)

        section("Frame Generation")
        self.quality = QComboBox()
        self.quality.addItems(["Hoch", "Schnell"])
        self.quality.setCurrentText(e.interp.quality)
        self.quality.currentTextChanged.connect(lambda q: win.set_setting("quality", q))
        form.addRow("Qualität", self.quality)
        self.dedup = QCheckBox("Doppelte Frames entfernen (PS5 sendet 30 FPS in 60 Hz)")
        self.dedup.setChecked(e.store.dedup)
        self.dedup.toggled.connect(lambda v: win.set_setting("dedup", v))
        form.addRow("", self.dedup)
        self.blend = QCheckBox("Vergleich: nur überblenden (schlechter, zum Testen)")
        self.blend.setChecked(e.blend_only)
        self.blend.toggled.connect(lambda v: setattr(e, "blend_only", v))
        form.addRow("", self.blend)
        lb = QLabel(f"Berechnung: {e.interp.backend}")
        lb.setObjectName("hint")
        form.addRow("", lb)

        section("Anzeige")
        self.hud = QCheckBox("FPS-Anzeige")
        self.hud.setChecked(win.show_hud)
        self.hud.toggled.connect(lambda v: win.set_setting("hud", v))
        form.addRow("", self.hud)
        self.compat = QCheckBox("Kompatibilitätsmodus ohne OpenGL (nach Neustart)")
        self.compat.setChecked(win.settings.value("raster", False, type=bool))
        self.compat.toggled.connect(lambda v: win.settings.setValue("raster", v))
        form.addRow("", self.compat)

        section("Hilfe")
        row = QHBoxLayout()
        rep = QPushButton("Fehlerbericht erstellen")
        rep.clicked.connect(win.bug_report)
        web = QPushButton("Projektseite")
        web.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(REPO_URL)))
        row.addWidget(rep)
        row.addWidget(web)
        row.addStretch(1)
        form.addRow(row)
        ver = QLabel(f"FrameBoost {__version__} · OpenCV {cv2.__version__}")
        ver.setObjectName("hint")
        form.addRow(ver)

    def _audio_dev(self):
        self.win.set_setting("audio_device", self.audio_combo.currentData())

    def _offset(self, v):
        self.win.set_setting("audio_offset", float(v))
        self.offset_lbl.setText(f"Ton {'später' if v > 0 else 'früher' if v < 0 else 'automatisch'}"
                                f"{f' um {abs(v)} ms' if v else ''} · Puffer jetzt {self.win.stats.get('audio', 0):.0f} ms")
        self.offset_lbl.setObjectName("hint")


# ----------------------------------------------------------------------------------------------
class MainWindow(QMainWindow):
    def __init__(self, raster: bool = False):
        super().__init__()
        self.settings = QSettings("FrameBoost", "FrameBoost")
        self.engine = Engine()
        self.show_hud = self.settings.value("hud", True, type=bool)
        self.stats: dict = {}
        self._last_move = time.time()
        self._known_devices = None
        self.setWindowTitle("FrameBoost")
        self.resize(1280, 780)
        self.setMinimumSize(900, 560)
        self._apply_saved()

        central = QWidget()
        lay = QVBoxLayout(central)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self.topbar = self._build_topbar()
        lay.addWidget(self.topbar)
        use_raster = raster or self.settings.value("raster", False, type=bool) or QOpenGLWidget is None
        self.view = RasterView(self.engine, self) if use_raster else GLView(self.engine, self)
        lay.addWidget(self.view, 1)
        self.banner = QLabel()
        self.banner.setObjectName("banner")
        self.banner.setWordWrap(True)
        self.banner.hide()
        lay.addWidget(self.banner)
        self.setCentralWidget(central)

        for i, m in enumerate(MODES):
            QShortcut(QKeySequence(f"Ctrl+{[0, 1, 2, 3, 4, 6][i]}"), self, activated=lambda m=m: self.set_mode(m))
        QShortcut(QKeySequence("F11"), self, activated=self.toggle_fullscreen)
        QShortcut(QKeySequence("Escape"), self, activated=lambda: self.isFullScreen() and self.toggle_fullscreen())
        QShortcut(QKeySequence("Ctrl+I"), self, activated=lambda: self.set_setting("hud", not self.show_hud))
        QShortcut(QKeySequence("Ctrl+Shift+S"), self, activated=self.toggle_run)

        self.stat_timer = QTimer(self)
        self.stat_timer.timeout.connect(self._tick)
        self.stat_timer.start(500)
        self.refresh_devices(autostart=True)

    # -- settings ---------------------------------------------------------------------------------
    def _apply_saved(self):
        e, s = self.engine, self.settings
        e.mode = s.value("mode", "Auto")
        e.interp.set_quality(s.value("quality", "Hoch"))
        e.store.dedup = s.value("dedup", True, type=bool)
        e.audio_sync = s.value("audio_sync", True, type=bool)
        e.audio_offset_ms = float(s.value("audio_offset", 0.0))
        e.audio.volume = float(s.value("volume", 1.0))
        dev = s.value("audio_device", None)
        e.audio_device = int(dev) if dev not in (None, "", "None") else None

    def set_setting(self, key, value):
        e = self.engine
        self.settings.setValue(key, value)
        if key == "volume":
            e.audio.volume = value
        elif key == "audio_sync":
            e.audio_sync = value
            e.update_audio_delay()
        elif key == "audio_offset":
            e.audio_offset_ms = value
            e.update_audio_delay()
        elif key == "audio_device":
            e.audio_device = value
            if e.running and self.current_video()[1] is not None:
                self.start()
        elif key == "quality":
            e.interp.set_quality(value)
        elif key == "dedup":
            e.store.dedup = value
        elif key == "hud":
            self.show_hud = value

    # -- top bar --------------------------------------------------------------------------------
    def _build_topbar(self) -> QFrame:
        bar = QFrame()
        bar.setObjectName("topbar")
        h = QHBoxLayout(bar)
        h.setContentsMargins(14, 9, 14, 9)
        h.setSpacing(10)
        brand = QLabel(f"Frame<span style='color:{ACCENT}'>Boost</span>")
        brand.setObjectName("brand")
        brand.setTextFormat(Qt.RichText)
        h.addWidget(brand)
        self.source_combo = QComboBox()
        self.source_combo.setToolTip("Video-Quelle")
        self.source_combo.activated.connect(self._source_chosen)
        h.addWidget(self.source_combo)
        seg = QHBoxLayout()
        seg.setSpacing(0)
        self.mode_group = QButtonGroup(self)
        self.mode_group.setExclusive(True)
        for i, m in enumerate(MODES):
            b = QPushButton(m)
            b.setCheckable(True)
            b.setObjectName("segL" if i == 0 else "segR" if i == len(MODES) - 1 else "seg")
            b.setToolTip(MODE_HELP[m])
            b.setChecked(m == self.engine.mode)
            b.clicked.connect(lambda _=False, m=m: self.set_mode(m))
            self.mode_group.addButton(b)
            seg.addWidget(b)
        h.addLayout(seg)
        h.addStretch(1)
        self.settings_btn = QPushButton("Einstellungen")
        self.settings_btn.clicked.connect(lambda: SettingsDialog(self).exec())
        h.addWidget(self.settings_btn)
        self.full_btn = QPushButton("Vollbild")
        self.full_btn.setToolTip("Vollbild (F11)")
        self.full_btn.clicked.connect(self.toggle_fullscreen)
        h.addWidget(self.full_btn)
        self.run_btn = QPushButton("Start")
        self.run_btn.setObjectName("primary")
        self.run_btn.clicked.connect(self.toggle_run)
        h.addWidget(self.run_btn)
        return bar

    def set_mode(self, m):
        self.engine.mode = m
        self.settings.setValue("mode", m)
        for b in self.mode_group.buttons():
            b.setChecked(b.text() == m)
        self.engine.update_audio_delay()

    # -- sources --------------------------------------------------------------------------------
    def refresh_devices(self, autostart=False):
        devs = list_video_devices()
        self._known_devices = [d[0] for d in devs]
        cur = self.current_video()
        self.source_combo.blockSignals(True)
        self.source_combo.clear()
        for name, idx, card in devs:
            self.source_combo.addItem(("● " if card else "") + name, (name, idx))
        self.source_combo.addItem("Demo-Signal (ohne Capture Card)", ("demo", None))
        remembered = self.settings.value("video", "")
        pick = next((i for i, d in enumerate(devs) if d[0] == remembered), None)
        if pick is None:
            pick = next((i for i, d in enumerate(devs) if d[2]), None)
        if cur is not None and cur[1] is not None and cur[0] in self._known_devices:
            pick = self._known_devices.index(cur[0])
        self.source_combo.setCurrentIndex(pick if pick is not None else self.source_combo.count() - 1)
        self.source_combo.blockSignals(False)
        if autostart and pick is not None and devs[pick][2] and not self.engine.running:
            self.start()

    def current_video(self):
        return self.source_combo.currentData() if self.source_combo.count() else ("demo", None)

    def _source_chosen(self):
        name, idx = self.current_video()
        if idx is not None:
            self.settings.setValue("video", name)
            m = matching_input(name, input_devices())
            if m is not None:
                self.engine.audio_device = m
                self.settings.setValue("audio_device", m)
        if self.engine.running:
            self.start()

    def start_demo(self):
        self.source_combo.setCurrentIndex(self.source_combo.count() - 1)
        self.start()

    def start(self):
        ok = self.engine.start(self.current_video())
        self._update_run_btn()
        self._show_error(self.engine.error if not ok else "")

    def stop(self):
        self.engine.stop()
        self._update_run_btn()

    def toggle_run(self):
        self.stop() if self.engine.running else self.start()

    def _update_run_btn(self):
        run = self.engine.running
        self.run_btn.setText("Stop" if run else "Start")
        self.run_btn.setProperty("running", run)
        self.run_btn.style().unpolish(self.run_btn)
        self.run_btn.style().polish(self.run_btn)

    def _show_error(self, text):
        self.banner.setText(text)
        self.banner.setVisible(bool(text))

    # -- fullscreen / auto-hide -----------------------------------------------------------------
    def toggle_fullscreen(self):
        if self.isFullScreen():
            self.showNormal()
            self.topbar.show()
        else:
            self.showFullScreen()
        self.poke()

    def poke(self):
        self._last_move = time.time()
        if not self.topbar.isVisible():
            self.topbar.show()
            self.unsetCursor()

    # -- periodic -------------------------------------------------------------------------------
    def _tick(self):
        e = self.engine
        if e.running:
            game, signal, dupes = e.store.stats()
            st = e.interp.state
            self.stats = {"out": e.output_fps(), "game": game, "signal": signal, "dupes": dupes,
                          "hz": 1 / max(e.draw_period, 1e-3), "synth": e.synth_ms, "analysis": e.interp.analysis_ms,
                          "backend": e.interp.backend, "audio": e.audio.delay * 1000 if e.audio_sync else 0,
                          "format": e.source.format if e.source else ""}
            e.update_audio_delay()
            err = (e.source.error if e.source else "") or e.audio.error
            if not err and signal == 0 and self.current_video()[1] is not None:
                err = "Kein Signal – PS5 an? In der PS5: Einstellungen → System → HDMI → „HDCP aktivieren“ aus."
            self._show_error(err)
            if self.isFullScreen() and time.time() - self._last_move > 3 and self.topbar.isVisible():
                self.topbar.hide()
                self.setCursor(Qt.BlankCursor)
        else:
            # plug & play: look for new capture cards every few seconds
            self._idle = getattr(self, "_idle", 0) + 1
            if self._idle % 6 == 0:
                names = [d[0] for d in list_video_devices()]
                if names != self._known_devices:
                    self.refresh_devices(autostart=True)

    # -- bug report -----------------------------------------------------------------------------
    def bug_report(self):
        e = self.engine
        lines = [f"FrameBoost {__version__} – Fehlerbericht", "=" * 40,
                 f"System: {platform.platform()} · {platform.processor()}",
                 f"Python {platform.python_version()} · OpenCV {cv2.__version__} · Berechnung {e.interp.backend}",
                 f"Videogeräte: {[d[0] for d in list_video_devices()]}",
                 f"Audiogeräte: {[d[0] for d in input_devices()]}",
                 f"Einstellungen: Modus {e.mode}, Qualität {e.interp.quality}, Duplikate {e.store.dedup}, "
                 f"Ton-Puffer {e.audio_sync} ({e.audio_offset_ms:+.0f} ms)",
                 f"Messwerte: {self.stats}", "", "Letzter Absturz:", applog.take_previous_crash() or "(keiner)", "",
                 "Log:", applog.tail(200)]
        desk = os.path.join(os.path.expanduser("~"), "Desktop")
        path = os.path.join(desk if os.path.isdir(desk) else os.path.expanduser("~"), "FrameBoost-Fehlerbericht.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        QMessageBox.information(self, "Fehlerbericht",
                                f"Der Bericht wurde gespeichert:\n{path}\n\nAuf der Projektseite kannst du ein Issue "
                                "erstellen und die Datei anhängen.")
        QDesktopServices.openUrl(QUrl(REPO_URL + "/issues/new"))

    def closeEvent(self, ev):
        self.engine.stop()
        super().closeEvent(ev)


# ----------------------------------------------------------------------------------------------
class Autopilot:
    """--soak <seconds> <dir>: clicks through every feature on the demo signal, records memory/FPS."""

    def __init__(self, win: MainWindow, seconds: float, out_dir: str):
        self.win, self.seconds, self.dir = win, seconds, out_dir
        self.t0 = time.time()
        self.step = 0
        self.rows = ["sekunde,aktion,speicher_mb,ausgabe_fps,spiel_fps"]
        self.mem = []
        self.last = "Demo starten"
        w = win
        self.actions = [
            ("Modus Auto", lambda: w.set_mode("Auto")), ("Modus 2×", lambda: w.set_mode("2×")),
            ("Modus 3×", lambda: w.set_mode("3×")), ("Modus 4×", lambda: w.set_mode("4×")),
            ("Modus 6×", lambda: w.set_mode("6×")), ("Modus Aus", lambda: w.set_mode("Aus")),
            ("Modus Auto", lambda: w.set_mode("Auto")),
            ("Qualität Schnell", lambda: w.set_setting("quality", "Schnell")),
            ("Qualität Hoch", lambda: w.set_setting("quality", "Hoch")),
            ("Duplikate aus", lambda: w.set_setting("dedup", False)), ("Duplikate an", lambda: w.set_setting("dedup", True)),
            ("Ton-Puffer aus", lambda: w.set_setting("audio_sync", False)),
            ("Ton-Puffer an", lambda: w.set_setting("audio_sync", True)),
            ("Ton +150 ms", lambda: w.set_setting("audio_offset", 150.0)),
            ("Ton 0 ms", lambda: w.set_setting("audio_offset", 0.0)),
            ("FPS-Anzeige aus", lambda: w.set_setting("hud", False)), ("FPS-Anzeige an", lambda: w.set_setting("hud", True)),
            ("Stop", w.stop), ("Start", w.start), ("Stop+Start schnell", lambda: (w.stop(), w.start(), w.stop(), w.start())),
            ("Geräte suchen", lambda: w.refresh_devices(False)),
            ("Vollbild", w.toggle_fullscreen), ("Vollbild aus", w.toggle_fullscreen),
            ("Fenster klein", lambda: w.resize(900, 560)), ("Fenster groß", lambda: w.resize(1400, 850)),
        ]
        w.start_demo()
        self.timer = QTimer()
        self.timer.timeout.connect(self.tick)
        self.timer.start(2500)
        self.sampler = QTimer()
        self.sampler.timeout.connect(self.sample)
        self.sampler.start(5000)

    @staticmethod
    def memory_mb() -> float:
        try:
            import psutil
            return psutil.Process().memory_info().rss / 1048576
        except Exception:
            return 0.0

    def tick(self):
        name, fn = self.actions[self.step % len(self.actions)]
        self.step += 1
        self.last = name
        fn()
        if time.time() - self.t0 > self.seconds:
            self.finish()

    def sample(self):
        m = self.memory_mb()
        self.mem.append((time.time() - self.t0, m))
        s = self.win.stats
        self.rows.append(f"{time.time() - self.t0:.0f},{self.last},{m:.1f},{s.get('out', 0):.1f},{s.get('game', 0):.1f}")

    def finish(self):
        self.timer.stop()
        self.sampler.stop()
        warm = [m for t, m in self.mem if t > 30]
        growth = (np.mean(warm[-3:]) - np.mean(warm[:3])) / max((self.mem[-1][0] - 30) / 60, 1) if len(warm) > 6 else 0
        ok = growth < 5
        rep = (f"FrameBoost (Windows) Dauertest\nLaufzeit {time.time() - self.t0:.0f} s, Aktionen {self.step}\n"
               f"Abstürze: keine\nSpeicher: Start {warm[0] if warm else 0:.0f} MB, Ende {warm[-1] if warm else 0:.0f} MB, "
               f"Wachstum {growth:.1f} MB/min\nERGEBNIS: {'BESTANDEN' if ok else 'NICHT BESTANDEN'}\n")
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, "soak-report.txt"), "w", encoding="utf-8") as f:
            f.write(rep)
        with open(os.path.join(self.dir, "soak-log.csv"), "w", encoding="utf-8") as f:
            f.write("\n".join(self.rows))
        self.win.grab().save(os.path.join(self.dir, "soak_ende.png"))
        self.win.engine.stop()
        QApplication.exit(0 if ok else 2)


def run_app(args: list[str]) -> int:
    fmt = QSurfaceFormat()
    fmt.setSwapInterval(1)       # vsync: one image per screen refresh
    QSurfaceFormat.setDefaultFormat(fmt)
    app = QApplication(sys.argv[:1])
    app.setApplicationName("FrameBoost")
    app.setStyle("Fusion")
    app.setStyleSheet(STYLE)
    icon_path = os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "icon.ico")
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))
    raster = "--raster" in args or os.environ.get("FB_RASTER") == "1"
    win = MainWindow(raster=raster)
    win.show()

    crash = applog.take_previous_crash()
    if crash and "--soak" not in args and "--screenshot" not in args:
        if QMessageBox.question(win, "FrameBoost", "FrameBoost wurde beim letzten Mal unerwartet beendet.\n"
                                "Möchtest du einen Fehlerbericht erstellen?") == QMessageBox.Yes:
            with open(applog.CRASH_FILE, "a", encoding="utf-8") as f:
                f.write(crash)
            win.bug_report()

    if "--demo" in args:
        win.start_demo()
    if "--screenshot" in args:
        path = args[args.index("--screenshot") + 1]
        win.start_demo()
        QTimer.singleShot(7000, lambda: (win.grab().save(path), win.engine.stop(), app.exit(0)))
    if "--screenshot-idle" in args:
        path = args[args.index("--screenshot-idle") + 1]
        QTimer.singleShot(2500, lambda: (win.grab().save(path), app.exit(0)))
    if "--soak" in args:
        i = args.index("--soak")
        secs = float(args[i + 1]) if i + 1 < len(args) else 180
        out = args[i + 2] if i + 2 < len(args) else "soak-output"
        win._autopilot = Autopilot(win, secs, out)
    return app.exec()
