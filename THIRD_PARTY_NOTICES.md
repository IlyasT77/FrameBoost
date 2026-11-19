# Third-party software

FrameBoost itself is MIT licensed (see `LICENSE`).

**macOS app:** uses only Apple system frameworks (Metal, AVFoundation, SwiftUI, AppKit, Core Audio).

**Windows app (FrameBoost.exe)** bundles the following libraries, each under its own license:

| Library | License | Source |
|---|---|---|
| Python | PSF License | https://www.python.org |
| Qt 6 / PySide6 | LGPL-3.0 | https://www.qt.io · https://wiki.qt.io/Qt_for_Python — loaded as separate DLLs; you can replace them with your own build |
| OpenCV | Apache-2.0 | https://opencv.org |
| NumPy | BSD-3-Clause (includes OpenBLAS, BSD-3-Clause) | https://numpy.org |
| python-sounddevice | MIT | https://github.com/spatialaudio/python-sounddevice |
| PortAudio | MIT | https://www.portaudio.com |
| pygrabber | MIT | https://github.com/bunkahle/pygrabber |
| psutil | BSD-3-Clause | https://github.com/giampaolo/psutil |
| PyInstaller bootloader | GPL-2.0 with bootloader exception (allows any license for the bundled app) | https://pyinstaller.org |

The automated tests download *Big Buck Bunny* (© Blender Foundation, CC BY 3.0, https://peach.blender.org) as a test video.
It is not part of the app.
