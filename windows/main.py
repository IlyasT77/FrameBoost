"""FrameBoost for Windows - entry point."""
import sys


def main() -> int:
    args = sys.argv[1:]
    if "--selftest" in args:
        from frameboost_win.selftest import run
        i = args.index("--selftest")
        return 0 if run(args[i + 1] if i + 1 < len(args) else "selftest-output") else 1
    from frameboost_win import applog
    applog.setup()
    from frameboost_win.ui import run_app
    return run_app(args)


if __name__ == "__main__":
    sys.exit(main())
