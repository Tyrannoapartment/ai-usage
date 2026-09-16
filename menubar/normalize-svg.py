#!/usr/bin/env python3
"""Flatten an SVG path to absolute M / L / C / Z only.

Arcs become cubic Beziers here so the Swift side needs no arc maths.
"""
import math, re, sys

TOKEN = re.compile(r'([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)')


def tokens(d):
    for m in TOKEN.finditer(d):
        yield m.group(1) if m.group(1) else float(m.group(2))


def arc_to_beziers(x0, y0, rx, ry, phi_deg, large, sweep, x, y):
    if rx == 0 or ry == 0 or (x0 == x and y0 == y):
        return [("L", x, y)]
    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x0 - x) / 2.0, (y0 - y) / 2.0
    x1 = cosp * dx2 + sinp * dy2
    y1 = -sinp * dx2 + cosp * dy2
    rx, ry = abs(rx), abs(ry)
    lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    sign = -1 if large == sweep else 1
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    co = sign * math.sqrt(max(0.0, num / den)) if den else 0.0
    cx1 = co * rx * y1 / ry
    cy1 = -co * ry * x1 / rx
    cx = cosp * cx1 - sinp * cy1 + (x0 + x) / 2.0
    cy = sinp * cx1 + cosp * cy1 + (y0 + y) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1.0, min(1.0, dot / n))) if n else 0.0
        return -a if ux * vy - uy * vx < 0 else a

    theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    out, segments = [], max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / segments
    t = 4 / 3 * math.tan(step / 4)
    for i in range(segments):
        a0 = theta + i * step
        a1 = a0 + step
        c0, s0 = math.cos(a0), math.sin(a0)
        c1, s1 = math.cos(a1), math.sin(a1)

        def point(ca, sa):
            return (cosp * rx * ca - sinp * ry * sa + cx,
                    sinp * rx * ca + cosp * ry * sa + cy)

        p1 = point(c0, s0)
        p2 = point(c1, s1)
        d1 = (cosp * rx * -s0 - sinp * ry * c0, sinp * rx * -s0 + cosp * ry * c0)
        d2 = (cosp * rx * -s1 - sinp * ry * c1, sinp * rx * -s1 + cosp * ry * c1)
        out.append(("C", p1[0] + t * d1[0], p1[1] + t * d1[1],
                    p2[0] - t * d2[0], p2[1] - t * d2[1], p2[0], p2[1]))
    return out


def normalize(d):
    ts = list(tokens(d))
    i = 0
    cmd = None
    cur = start = (0.0, 0.0)
    prev_c2 = None
    out = []

    def take(n):
        nonlocal i
        vals = ts[i:i + n]
        i += n
        return vals

    while i < len(ts):
        if isinstance(ts[i], str):
            cmd = ts[i]
            i += 1
            if cmd in "Zz":
                out.append(("Z",))
                cur = start
                prev_c2 = None
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            x, y = take(2)
            if rel: x, y = cur[0] + x, cur[1] + y
            out.append(("M", x, y)); cur = start = (x, y); prev_c2 = None
            cmd = "l" if rel else "L"
        elif c == "L":
            x, y = take(2)
            if rel: x, y = cur[0] + x, cur[1] + y
            out.append(("L", x, y)); cur = (x, y); prev_c2 = None
        elif c == "H":
            (x,) = take(1)
            if rel: x = cur[0] + x
            out.append(("L", x, cur[1])); cur = (x, cur[1]); prev_c2 = None
        elif c == "V":
            (y,) = take(1)
            if rel: y = cur[1] + y
            out.append(("L", cur[0], y)); cur = (cur[0], y); prev_c2 = None
        elif c == "C":
            x1, y1, x2, y2, x, y = take(6)
            if rel:
                x1, y1, x2, y2, x, y = (cur[0]+x1, cur[1]+y1, cur[0]+x2, cur[1]+y2, cur[0]+x, cur[1]+y)
            out.append(("C", x1, y1, x2, y2, x, y)); prev_c2 = (x2, y2); cur = (x, y)
        elif c == "S":
            x2, y2, x, y = take(4)
            if rel:
                x2, y2, x, y = cur[0]+x2, cur[1]+y2, cur[0]+x, cur[1]+y
            x1, y1 = (2*cur[0]-prev_c2[0], 2*cur[1]-prev_c2[1]) if prev_c2 else cur
            out.append(("C", x1, y1, x2, y2, x, y)); prev_c2 = (x2, y2); cur = (x, y)
        elif c == "A":
            rx, ry, rot, large, sweep, x, y = take(7)
            if rel: x, y = cur[0] + x, cur[1] + y
            for seg in arc_to_beziers(cur[0], cur[1], rx, ry, rot, int(large), int(sweep), x, y):
                out.append(seg)
            cur = (x, y); prev_c2 = None
        else:
            raise SystemExit("unsupported command: %s" % c)
    return out


def emit(segments):
    parts = []
    for seg in segments:
        parts.append(seg[0] + " ".join("%.3f" % v for v in seg[1:]))
    return " ".join(parts)


if __name__ == "__main__":
    svg = open(sys.argv[1]).read()
    d = re.search(r'\sd="([^"]+)"', svg).group(1)
    print(emit(normalize(d)))
