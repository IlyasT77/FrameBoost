#!/usr/bin/env python3
"""Frame pacing simulation: replays the timing logic of Renderer.swift (output clock, refresh slots,
rounding centred between refreshes, pair switch gate) and FrameStore (arrival smoothing) with a
synthetic capture card signal, for different screens and modes. Keep in sync with Renderer.swift.

Measures per screen refresh: is the image new, and did the shown moment advance by exactly the elapsed time?
Exit code 1 if a normal case (no game stutter) is below 99 %."""
import bisect
import math
import random
import sys


def simulate(hz, steps, seconds=40, game_fps=30, usb_jitter=0.0015, draw_jitter=0.0004, skip_p=0.002,
             seed=1, proc=0.002, stutter=0.0):
    rnd = random.Random(seed)
    dp = 1 / hz
    interval = 1 / game_fps
    per = 60 // game_fps
    # real frames: every game frame inside a 60 Hz signal; the first copy arrives at k/60 (+USB jitter, processing)
    frames, smoothed, shift = [], 0.0, 0.0
    for k in range(int(seconds * game_fps)):
        if rnd.random() < stutter:
            shift += 1 / 60  # the game needed one signal period longer for this frame
        t = k * per / 60 + shift + 0.5 + rnd.gauss(0, usb_jitter) + proc
        pred = smoothed + interval
        smoothed = t if (smoothed == 0 or abs(t - pred) > interval * 0.4) else pred + (t - pred) * 0.15
        frames.append((k + 1, t, smoothed))
    arrivals = [f[1] for f in frames]
    draws, t = [], 0.5
    while t < seconds + 0.5:
        t += dp
        if rnd.random() < skip_p:
            continue  # the system skipped a refresh call
        draws.append(t + rnd.gauss(0, draw_jitter))

    S = dict(last_seq=0, ta=0.0, tb=0.0, out=0.0, pend=None, need_new=True, grid=0.5, gv=(0.0, 0.0),
             anchor=0.0, slot=0, last=0.0, n=0, valid=False)
    margin = max(1.2 * dp, 0.012)

    def gstep():
        return None if steps is None else interval / steps

    def position(clock):
        span = max(S["tb"] - S["ta"], 0.004)
        g = gstep()
        if g is None:
            p = (clock - S["ta"]) / span
            return p, p > 1 + 1e-9
        k = math.floor((clock - S["ta"]) / g - S["grid"] + 0.5)
        return k * g / span, k > span / g + 0.5

    def analyse(f, shared):
        seq, _, sm = f
        S["last_seq"] = seq
        S["n"] += 1
        gap = sm - S["tb"]
        a = S["tb"] if (S["tb"] > 0 and 0.004 < gap < 0.1) else sm - interval
        if shared or S["n"] < 2:
            S["ta"], S["tb"], S["pend"] = a, sm, None
        else:
            S["pend"] = (a, sm)
            S["need_new"] = False

    def waiting(now):
        i = bisect.bisect_right(arrivals, now) - 1
        return frames[i] if i >= 0 and frames[i][0] > S["last_seq"] else None

    log = []
    for i, now in enumerate(draws):
        if i > 0:  # frames arriving between two refreshes (ingestNow)
            j = bisect.bisect_right(arrivals, draws[i - 1])
            while j < len(frames) and frames[j][1] < now:
                if S["need_new"] and frames[j][0] > S["last_seq"]:
                    analyse(frames[j], False)
                j += 1
        prev, S["last"] = S["last"], now
        if S["pend"]:
            S["ta"], S["tb"] = S["pend"]
            S["pend"] = None
        if S["n"] < 2:
            f = waiting(now)
            if f:
                analyse(f, True)
            S["need_new"] = True
            continue
        target = now - interval - margin
        st = 1
        if S["anchor"] == 0 or prev == 0:
            S["anchor"], S["slot"] = now, 0
        else:
            rel = (now - S["anchor"]) / dp
            idx = math.floor(rel + 0.5)
            S["anchor"] += (rel - idx) * dp * 0.05
            st = max(idx - S["slot"], 0)
            S["slot"] = max(idx, S["slot"])
        if S["out"] == 0 or prev == 0:
            S["out"] = target
        elif st > 0:
            S["out"] += st * dp
            err = target - S["out"]
            S["out"] = target if abs(err) > 2.5 * dp else S["out"] + err * 0.03
        g = gstep()
        if g is not None and st > 0:
            x = (S["out"] - S["ta"]) / g
            fr = x - math.floor(x)
            S["gv"] = (S["gv"][0] * 0.97 + math.cos(2 * math.pi * fr) * 0.03, S["gv"][1] * 0.97 + math.sin(2 * math.pi * fr) * 0.03)
            if math.hypot(*S["gv"]) > 0.5:
                o = math.atan2(S["gv"][1], S["gv"][0]) / (2 * math.pi)
                c = o + round(S["grid"] - o) if S["valid"] else o
                c = c - 1 if c >= 1 else (c + 1 if c < -0.5 else c)
                S["grid"], S["valid"] = c, True
            else:
                S["grid"], S["valid"] = 0.5, False
        p, beyond = position(S["out"])
        if beyond:
            f = waiting(now)
            if f:
                analyse(f, True)
                p, beyond = position(S["out"])
        tt = min(max(p, 0), 1)
        log.append((now, S["ta"] + tt * (S["tb"] - S["ta"]), S["slot"]))
        S["need_new"] = position(S["out"] + dp)[1]
        f = waiting(now)
        if S["need_new"] and f:
            analyse(f, False)

    n = new = ok = 0
    lat = []
    for i in range(1, len(log)):
        s = log[i][2] - log[i - 1][2]
        if s <= 0:
            continue
        n += 1
        adv = log[i][1] - log[i - 1][1]
        new += adv > 0.0005
        ok += abs(adv - s * dp) <= min(0.0025, dp * 0.45)
        lat.append(log[i][0] - log[i][1])
    lat.sort()
    return 100 * new / n, 100 * ok / n, 1000 * lat[len(lat) // 2]


def main():
    cases = [(60, 2, "60 Hz, 2× (30 → 60)"), (120, 4, "120 Hz, 4× (30 → 120)"), (180, 6, "180 Hz, 6× (30 → 180)"),
             (60, None, "60 Hz, Auto"), (144, None, "144 Hz, Auto"), (180, None, "180 Hz, Auto")]
    print("FrameBoost Takt-Simulation (Logik wie Renderer.swift, je 3 × 40 s)")
    print("Spalten: neue Bilder pro Refresh · zeitlich exakt · Verzögerung Bildmoment → Refresh (Median)\n")
    worst = 100.0
    for title, kw in [("Normal (USB-Jitter 1,5 ms)", {}), ("Unruhige Capture Card (USB-Jitter 4 ms)", {"usb_jitter": 0.004}),
                      ("Spiel ruckelt (5 % der Bilder 1 Signalbild zu spät)", {"stutter": 0.05})]:
        print(title)
        for hz, steps, label in cases:
            r = [simulate(hz, steps, seed=s, **kw) for s in range(3)]
            nw, ok, lat = (sum(x[i] for x in r) / 3 for i in range(3))
            if not kw.get("stutter"):
                worst = min(worst, nw, ok)
            print(f"  {label:24s} {nw:6.2f} % neu · {ok:6.2f} % exakt · {lat:3.0f} ms")
        print()
    verdict = worst >= 99
    print("ERGEBNIS: " + ("BESTANDEN" if verdict else "NICHT BESTANDEN") + f" (schlechtester Normalfall {worst:.2f} %)")
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
