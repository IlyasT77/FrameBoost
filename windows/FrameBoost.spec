# PyInstaller build for FrameBoost.exe - only what the app really needs.
# Saves ~40 % compared with the default: no FFmpeg (videos are decoded by Windows' Media Foundation,
# capture cards via DirectShow), no software OpenGL driver (real GPU or compatibility mode), no Qt
# networking/QML/Quick/PDF/SVG, no Qt translations.
from PyInstaller.utils.hooks import collect_data_files

a = Analysis(
    ["main.py"],
    datas=[("icon.ico", ".")] + collect_data_files("sounddevice"),
    hiddenimports=["pygrabber.dshow_graph"],
    excludes=["tkinter", "matplotlib", "PySide6.QtNetwork", "PySide6.QtQml", "PySide6.QtQuick",
              "PySide6.QtPdf", "PySide6.QtSvg", "PySide6.QtDBus"],
)

DROP = ("opencv_videoio_ffmpeg", "opengl32sw", "qt6network", "qt6qml", "qt6quick", "qt6pdf", "qt6svg",
        "qt6virtualkeyboard", "qsvg", "qpdf", "qtvirtualkeyboard", "qnetworklistmanager", "qtuiotouchplugin")
a.binaries = [b for b in a.binaries if not any(x in b[0].lower().replace("\\", "/").split("/")[-1] for x in DROP)]
a.datas = [d for d in a.datas if "translations" not in d[0].replace("\\", "/").lower()]

pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, a.binaries, a.datas, [], name="FrameBoost", icon="icon.ico",
          console=False, upx=False, strip=False)
