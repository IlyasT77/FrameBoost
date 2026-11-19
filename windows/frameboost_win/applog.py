"""Log file + crash capture (%LOCALAPPDATA%/FrameBoost/frameboost.log) for bug reports."""
from __future__ import annotations

import faulthandler
import logging
import os
import platform
import sys
import threading
import traceback
from logging.handlers import RotatingFileHandler

from . import __version__

LOG_DIR = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~/.local/share"), "FrameBoost")
LOG_FILE = os.path.join(LOG_DIR, "frameboost.log")
CRASH_FILE = os.path.join(LOG_DIR, "last-crash.txt")
log = logging.getLogger("frameboost")
_fault_fp = None


def setup():
    global _fault_fp
    os.makedirs(LOG_DIR, exist_ok=True)
    h = RotatingFileHandler(LOG_FILE, maxBytes=1_000_000, backupCount=1, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s  %(message)s"))
    log.addHandler(h)
    log.setLevel(logging.INFO)
    # hard crashes (access violations inside native libraries) -> crash file
    _fault_fp = open(CRASH_FILE, "a", encoding="utf-8")
    faulthandler.enable(_fault_fp)

    def hook(tp, val, tb):
        text = "".join(traceback.format_exception(tp, val, tb))
        log.error("Absturz:\n%s", text)
        with open(CRASH_FILE, "a", encoding="utf-8") as f:
            f.write("Absturz (Python):\n" + text)
        sys.__excepthook__(tp, val, tb)

    sys.excepthook = hook
    threading.excepthook = lambda a: hook(a.exc_type, a.exc_value, a.exc_traceback)
    log.info("FrameBoost %s gestartet · %s · Python %s", __version__, platform.platform(), platform.python_version())


def take_previous_crash() -> str | None:
    try:
        if _fault_fp is not None:
            _fault_fp.flush()
        with open(CRASH_FILE, encoding="utf-8") as f:
            s = f.read().strip()
        if not s:
            return None
        # keep the handle open for faulthandler; just empty the file
        if _fault_fp is not None:
            _fault_fp.seek(0)
            _fault_fp.truncate()
        return s
    except OSError:
        return None


def tail(lines: int = 200) -> str:
    try:
        with open(LOG_FILE, encoding="utf-8") as f:
            return "".join(f.readlines()[-lines:])
    except OSError:
        return "(kein Log)"
