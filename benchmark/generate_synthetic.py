#!/usr/bin/env python3
"""Generate a synthetic phase-contrast scratch assay time series with ground truth.

Standard library only, so this runs anywhere QuPath does without a pip install.

The imaging model
-----------------
Phase contrast does not image absorption, it images *phase gradients*, which is
why it looks the way it does. The model here follows the usual linear
approximation:

1. Build an optical path (phase) map, `phi`. Bare substrate in the wound is
   flat, phi = 0. The cell sheet is a sum of smooth lenses, one per cell, each
   with a denser nucleus, laid on a jittered grid so the sheet is confluent but
   granular.

2. Convolve phi with a phase-contrast point spread function and add it to a
   uniform background. The PSF is a difference of Gaussians whose weights make
   it integrate to roughly zero, which reproduces both signature artifacts for
   free:

   - *halo*: a bright rim just outside a phase object, so the wound edge glows;
   - *shade-off*: the interior of a large uniform object drifts back to
     background, so neither the middle of the sheet nor the middle of a wide
     wound carries much signal.

   The consequence that matters for this assay is that the sheet and the wound
   are told apart by *texture*, not by brightness. That is exactly the cue the
   analyzer thresholds, and exactly the cue a naive intensity threshold misses.

3. Add microscope reality: smooth uneven illumination, slight defocus, shot
   noise scaled by signal, and camera read noise. Quantise to 8-bit.

Ground truth
------------
The wound is defined before any optics are applied: a band between two
migrating fronts, minus any debris cells sitting in it. So the truth is exact
by construction rather than annotated, and the halo deliberately spills across
that boundary - recovering the true edge despite the halo is the thing being
validated.

Usage
-----
    python3 benchmark/generate_synthetic.py --out benchmark/dataset
    python3 benchmark/generate_synthetic.py --list
    python3 benchmark/generate_synthetic.py --series vertical_fast --width 320 --height 240
"""

import argparse
import csv
import math
import random
import struct
import sys
import zlib
from pathlib import Path

# --------------------------------------------------------------------------- #
# 8-bit grayscale PNG, written by hand so Pillow is not needed
# --------------------------------------------------------------------------- #


def write_png_gray8(path, pixels, width, height):
    """Write a width*height bytes-like as an 8-bit grayscale PNG."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # no per-scanline filter
        raw.extend(pixels[y * width:(y + 1) * width])

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    Path(path).write_bytes(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
        + chunk(b'IEND', b''))


# --------------------------------------------------------------------------- #
# Fast blurs. Three box blurs approximate a Gaussian closely enough for
# synthetic data and, unlike a real kernel, cost O(1) per pixel.
# --------------------------------------------------------------------------- #


def box_blur(src, w, h, r):
    """Mean over a (2r+1) square, edges clamped, via running sums."""
    if r <= 0:
        return list(src)
    tmp = [0.0] * (w * h)
    for y in range(h):
        row = y * w
        acc = 0.0
        for x in range(min(w, r + 1)):
            acc += src[row + x]
        for x in range(w):
            lo, hi = max(0, x - r), min(w - 1, x + r)
            tmp[row + x] = acc / (hi - lo + 1)
            add, drop = x + r + 1, x - r
            if add < w:
                acc += src[row + add]
            if drop >= 0:
                acc -= src[row + drop]
    out = [0.0] * (w * h)
    for x in range(w):
        acc = 0.0
        for y in range(min(h, r + 1)):
            acc += tmp[y * w + x]
        for y in range(h):
            lo, hi = max(0, y - r), min(h - 1, y + r)
            out[y * w + x] = acc / (hi - lo + 1)
            add, drop = y + r + 1, y - r
            if add < h:
                acc += tmp[add * w + x]
            if drop >= 0:
                acc -= tmp[drop * w + x]
    return out


def gaussian_blur(src, w, h, sigma):
    """Approximate a Gaussian of this sigma with three box blurs.

    Three boxes of half-width r have total variance 3*((2r+1)^2-1)/12, so
    matching sigma^2 gives 2r+1 = sqrt(1 + 4*sigma^2).
    """
    if sigma <= 0:
        return list(src)
    r = max(1, int(round((math.sqrt(1.0 + 4.0 * sigma * sigma) - 1.0) / 2.0)))
    out = src
    for _ in range(3):
        out = box_blur(out, w, h, r)
    return out


# --------------------------------------------------------------------------- #
# The wound: two fronts closing over time, each with growing roughness
# --------------------------------------------------------------------------- #


class Front:
    """A migrating wound edge: a mean position plus a smooth random ripple.

    The ripple is a short Fourier sum with fixed random phases, so it is smooth,
    reproducible from the seed, and grows with time as individual cells start to
    lead. Being a function of position only, every frame of a series shares the
    same shape and simply advances - which is what a real front looks like.
    """

    def __init__(self, rng, n_modes=5):
        self.modes = [(rng.uniform(0.6, 3.0), rng.uniform(0, 2 * math.pi),
                       rng.uniform(0.4, 1.0)) for _ in range(n_modes)]
        norm = sum(m[2] for m in self.modes) or 1.0
        self.modes = [(f, p, a / norm) for f, p, a in self.modes]

    def offset(self, t, span, amplitude):
        """Ripple at normalised position t in [0,1) along the front."""
        return amplitude * sum(
            a * math.sin(2 * math.pi * f * t + p) for f, p, a in self.modes)


class Series:
    """One synthetic experiment: a scratch imaged repeatedly as it closes."""

    def __init__(self, name, *, gap0, closure_rate, horizontal=False,
                 debris=0, shading=0.08, roughness0=3.0, roughness_growth=0.45,
                 note=''):
        self.name = name
        self.gap0 = gap0                      # initial wound width, px
        self.closure_rate = closure_rate      # px/hour, summed over both fronts
        self.horizontal = horizontal
        self.debris = debris                  # detached cells left in the wound
        self.shading = shading                # illumination non-uniformity, 0..1
        self.roughness0 = roughness0
        self.roughness_growth = roughness_growth
        self.note = note

    def gap_width(self, hours):
        return max(0.0, self.gap0 - self.closure_rate * hours)


def default_series():
    return [
        Series('vertical_fast', gap0=150, closure_rate=6.0,
               note='closes fully within the time course'),
        Series('vertical_slow', gap0=150, closure_rate=2.0,
               note='still open at the last time point'),
        Series('vertical_static', gap0=150, closure_rate=0.0,
               roughness_growth=0.0,
               note='negative control: no migration, width must not drift'),
        Series('vertical_narrow', gap0=45, closure_rate=1.5,
               note='narrow wound, near the minimum area cutoff'),
        Series('horizontal_medium', gap0=150, closure_rate=4.0, horizontal=True,
               note='same wound rotated, exercises the orientation setting'),
        Series('vertical_debris', gap0=170, closure_rate=3.0, debris=14,
               note='detached cells in the wound, exercises fill holes'),
        Series('vertical_shading', gap0=150, closure_rate=4.0, shading=0.35,
               note='strong uneven illumination, exercises robustness'),
    ]


# --------------------------------------------------------------------------- #
# Frame synthesis
# --------------------------------------------------------------------------- #


def wound_mask(series, hours, w, h, front_a, front_b, rng_debris):
    """Ground-truth wound occupancy, decided before any optics.

    Returns (mask, debris_cells). Built for a vertical scratch; a horizontal
    series transposes afterwards, so both orientations are the same wound.
    """
    gap = series.gap_width(hours)
    centre = w / 2.0
    amp = series.roughness0 + series.roughness_growth * hours
    mask = bytearray(w * h)
    left_edge, right_edge = [], []
    for y in range(h):
        t = y / float(h)
        lo = centre - gap / 2.0 + front_a.offset(t, h, amp)
        hi = centre + gap / 2.0 + front_b.offset(t, h, amp)
        left_edge.append(lo)
        right_edge.append(hi)
        x0, x1 = max(0, int(math.ceil(lo))), min(w, int(math.floor(hi)) + 1)
        for x in range(x0, x1):
            mask[y * w + x] = 1

    # Detached cells sitting in the wound: real debris, and the reason the
    # analyzer needs a fill-holes step. They are not wound.
    debris = []
    for _ in range(series.debris):
        y = rng_debris.randrange(h)
        if right_edge[y] - left_edge[y] < 24:
            continue
        x = rng_debris.uniform(left_edge[y] + 8, right_edge[y] - 8)
        rx = rng_debris.uniform(4.0, 8.0)
        ry = rng_debris.uniform(4.0, 8.0)
        debris.append((x, float(y), rx, ry, rng_debris.uniform(0.7, 1.1)))
    for (cx, cy, rx, ry, _amp) in debris:
        for yy in range(max(0, int(cy - ry)), min(h, int(cy + ry) + 1)):
            for xx in range(max(0, int(cx - rx)), min(w, int(cx + rx) + 1)):
                dx, dy = (xx - cx) / rx, (yy - cy) / ry
                if dx * dx + dy * dy <= 1.0:
                    mask[yy * w + xx] = 0
    return mask, debris


def phase_map(w, h, mask, debris, rng, cell_pitch=13.0,
              granule_density=0.075, granule_amp=0.55):
    """Optical path introduced by the cells.

    Three scales, because phase contrast shows all three:

    - *cells*: a jittered grid of smooth lenses, overlapping enough to be
      confluent;
    - *nuclei*: a denser core per cell;
    - *granules*: dense sub-pixel-to-few-pixel organelles and vesicles
      throughout the cytoplasm.

    The granules matter more than they look. Without them the sheet is smooth
    between nuclei, so its local variance dips in patches and a texture
    threshold picks those patches up as wound. A real confluent monolayer in
    phase contrast is granular *everywhere*, which is what makes the sheet
    uniformly high-texture and the bare substrate the only smooth thing in
    frame.

    Everything is clipped to the cell-occupied region, so phi is exactly zero
    in the wound and the optical edge coincides with the ground-truth edge.
    What then blurs across that boundary is the halo, which is the point.
    """
    phi = [0.0] * (w * h)
    margin = int(cell_pitch * 2)
    ny = int(h / cell_pitch) + 4
    nx = int(w / cell_pitch) + 4
    for gy in range(-2, ny):
        for gx in range(-2, nx):
            cx = gx * cell_pitch + rng.uniform(-0.45, 0.45) * cell_pitch
            cy = gy * cell_pitch + rng.uniform(-0.45, 0.45) * cell_pitch
            if cx < -margin or cx > w + margin or cy < -margin or cy > h + margin:
                continue
            rx = cell_pitch * rng.uniform(0.85, 1.15)
            ry = cell_pitch * rng.uniform(0.85, 1.15)
            amp = rng.uniform(0.75, 1.25)
            _add_cell(phi, w, h, cx, cy, rx, ry, amp)
    # Debris in the wound is cells too, so it carries phase and shows up.
    for (cx, cy, rx, ry, amp) in debris:
        _add_cell(phi, w, h, cx, cy, rx * 1.4, ry * 1.4, amp)
    # Subcellular granularity, scattered independently of the cell grid.
    for _ in range(int(granule_density * w * h)):
        gx, gy = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.uniform(0.8, 2.4)
        _add_blob(phi, w, h, gx, gy, r, r, granule_amp * rng.uniform(0.5, 1.5))
    # Clip to occupancy: zero phase over bare substrate.
    for i in range(w * h):
        if mask[i]:
            phi[i] = 0.0
    return phi


def _add_cell(phi, w, h, cx, cy, rx, ry, amp):
    """One cell: a smooth paraboloid lens with a denser nucleus."""
    _add_blob(phi, w, h, cx, cy, rx, ry, amp)
    _add_blob(phi, w, h, cx, cy, rx * 0.38, ry * 0.38, amp * 1.9)


def _add_blob(phi, w, h, cx, cy, rx, ry, amp):
    """Add a paraboloid of this amplitude and radii. Compact support."""
    if rx <= 0 or ry <= 0:
        return
    for yy in range(max(0, int(cy - ry)), min(h, int(cy + ry) + 1)):
        dy = (yy - cy) / ry
        row = yy * w
        for xx in range(max(0, int(cx - rx)), min(w, int(cx + rx) + 1)):
            dx = (xx - cx) / rx
            v = 1.0 - (dx * dx + dy * dy)
            if v > 0.0:
                phi[row + xx] += amp * v


def render(series, phi, w, h, rng, *, sigma_inner=1.6, sigma_outer=5.0,
           dc_balance=0.98, gain=46.0, background=128.0, defocus=0.8,
           shot=0.45, read_noise=2.2):
    """Phase-contrast transfer, illumination, defocus and noise, to 8-bit.

    The difference of Gaussians is the phase-contrast PSF. `dc_balance` just
    short of 1 leaves a trace of low-frequency signal, which is what keeps a
    real phase-contrast sheet from being exactly background grey.
    """
    inner = gaussian_blur(phi, w, h, sigma_inner)
    outer = gaussian_blur(phi, w, h, sigma_outer)
    img = [background + gain * (inner[i] - dc_balance * outer[i])
           for i in range(w * h)]

    if defocus > 0:
        img = gaussian_blur(img, w, h, defocus)

    # Smooth illumination: a vignette plus one slow random tilt, the kind of
    # thing flat-fielding exists to remove.
    if series.shading > 0:
        ax, ay = rng.uniform(-1, 1), rng.uniform(-1, 1)
        for y in range(h):
            fy = (y / (h - 1.0)) * 2 - 1 if h > 1 else 0.0
            row = y * w
            for x in range(w):
                fx = (x / (w - 1.0)) * 2 - 1 if w > 1 else 0.0
                vignette = 1.0 - 0.55 * (fx * fx + fy * fy) / 2.0
                tilt = 1.0 + 0.5 * (ax * fx + ay * fy)
                img[row + x] *= 1.0 + series.shading * (vignette * tilt - 1.0)

    out = bytearray(w * h)
    for i in range(w * h):
        v = img[i]
        # Shot noise grows with signal; read noise does not.
        sigma = shot * math.sqrt(max(v, 1.0)) + read_noise
        v += rng.gauss(0.0, sigma)
        out[i] = 0 if v < 0 else (255 if v > 255 else int(v + 0.5))
    return out


def transpose(buf, w, h):
    out = bytearray(len(buf))
    for y in range(h):
        for x in range(w):
            out[x * h + y] = buf[y * w + x]
    return out


# --------------------------------------------------------------------------- #
# Ground truth, measured the same way the analyzer measures
# --------------------------------------------------------------------------- #


def truth_stats(mask, w, h, vertical):
    """Area, extent and per-scan-line widths of the true wound.

    Deliberately mirrors ScratchAssayAnalyzer.measurements: width is the run
    across the scratch on each scan line, length is the extent along it.
    """
    area = 0
    min_x, max_x, min_y, max_y = w, -1, h, -1
    for y in range(h):
        row = y * w
        for x in range(w):
            if mask[row + x]:
                area += 1
                min_x, max_x = min(min_x, x), max(max_x, x)
                min_y, max_y = min(min_y, y), max(max_y, y)
    if area == 0:
        return dict(area=0, length=0, widths=[])
    widths = []
    if vertical:
        for y in range(h):
            row = y * w
            first = last = -1
            for x in range(w):
                if mask[row + x]:
                    if first < 0:
                        first = x
                    last = x
            if first >= 0:
                widths.append(last - first + 1)
    else:
        for x in range(w):
            first = last = -1
            for y in range(h):
                if mask[y * w + x]:
                    if first < 0:
                        first = y
                    last = y
            if first >= 0:
                widths.append(last - first + 1)
    length = (max_y - min_y + 1) if vertical else (max_x - min_x + 1)
    return dict(area=area, length=length, widths=widths)


def summarise(widths):
    if not widths:
        return (float('nan'),) * 3 + (0,)
    s = sorted(widths)
    n = len(s)
    mean = sum(s) / float(n)
    median = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0
    sd = math.sqrt(sum((v - mean) ** 2 for v in s) / n)
    return mean, median, sd, n


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #

TRUTH_COLUMNS = [
    'Image', 'Series', 'Time_h', 'Orientation',
    'True_Gap_Area_px2', 'True_Percent_Open',
    'True_Scratch_Length_px', 'True_Mean_Width_px', 'True_Median_Width_px',
    'True_Width_SD_px', 'True_Width_Samples',
    'Nominal_Gap_Width_px', 'Closure_Rate_px_per_h', 'Debris_Cells',
    'Shading', 'Image_Width_px', 'Image_Height_px', 'Note',
]


def generate(out_dir, series_list, width, height, hours, seed, quiet=False):
    out_dir = Path(out_dir)
    images_dir = out_dir / 'images'
    images_dir.mkdir(parents=True, exist_ok=True)
    # The truth mask is worth having on disk: it can be overlaid on the image,
    # compared against Masks/ from a run, or used to diagnose a disagreement.
    masks_dir = out_dir / 'truth_masks'
    masks_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for s in series_list:
        # One RNG per series, derived from the master seed, so adding or
        # reordering series never changes another series' pixels.
        base = zlib.crc32(s.name.encode()) ^ seed
        front_a = Front(random.Random(base ^ 0xA1))
        front_b = Front(random.Random(base ^ 0xB2))
        for hrs in hours:
            # Image geometry is pre-transpose; a horizontal series swaps it.
            gw, gh = (height, width) if s.horizontal else (width, height)
            mask, debris = wound_mask(s, hrs, gw, gh, front_a, front_b,
                                      random.Random(base ^ int(hrs * 1000) ^ 0xD3))
            rng = random.Random(base ^ int(hrs * 1000))
            phi = phase_map(gw, gh, mask, debris, rng)
            pixels = render(s, phi, gw, gh, rng)

            if s.horizontal:
                pixels = transpose(pixels, gw, gh)
                mask = transpose(mask, gw, gh)
                iw, ih = gh, gw
            else:
                iw, ih = gw, gh

            vertical = not s.horizontal
            name = '%s_t%02dh.png' % (s.name, int(round(hrs)))
            write_png_gray8(images_dir / name, pixels, iw, ih)
            write_png_gray8(masks_dir / name.replace('.png', '_truth_mask.png'),
                            bytes(255 if v else 0 for v in mask), iw, ih)

            st = truth_stats(mask, iw, ih, vertical)
            mean, median, sd, n = summarise(st['widths'])
            rows.append({
                'Image': name,
                'Series': s.name,
                'Time_h': '%g' % hrs,
                'Orientation': 'Vertical' if vertical else 'Horizontal',
                'True_Gap_Area_px2': st['area'],
                'True_Percent_Open': '%.6g' % (100.0 * st['area'] / (iw * ih)),
                'True_Scratch_Length_px': st['length'],
                'True_Mean_Width_px': 'NA' if n == 0 else '%.6g' % mean,
                'True_Median_Width_px': 'NA' if n == 0 else '%.6g' % median,
                'True_Width_SD_px': 'NA' if n == 0 else '%.6g' % sd,
                'True_Width_Samples': n,
                'Nominal_Gap_Width_px': '%.6g' % s.gap_width(hrs),
                'Closure_Rate_px_per_h': '%g' % s.closure_rate,
                'Debris_Cells': len(debris),
                'Shading': '%g' % s.shading,
                'Image_Width_px': iw,
                'Image_Height_px': ih,
                'Note': s.note,
            })
            if not quiet:
                print('  %-28s area=%-8d mean width=%s'
                      % (name, st['area'],
                         'NA' if n == 0 else '%.1f' % mean))

    truth = out_dir / 'ground_truth.csv'
    with open(truth, 'w', newline='') as fh:
        wr = csv.DictWriter(fh, fieldnames=TRUTH_COLUMNS)
        wr.writeheader()
        wr.writerows(rows)

    (out_dir / 'MANIFEST.txt').write_text(
        'Synthetic phase-contrast scratch assay\n'
        'seed=%d\nimage=%dx%d\nhours=%s\nseries=%s\nimages=%d\n'
        'generator=benchmark/generate_synthetic.py\n'
        % (seed, width, height, ','.join('%g' % x for x in hours),
           ','.join(s.name for s in series_list), len(rows)))
    return truth, len(rows)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--out', default='benchmark/dataset')
    p.add_argument('--width', type=int, default=480)
    p.add_argument('--height', type=int, default=360)
    p.add_argument('--hours', default='0,3,6,9,12,15,18,21,24')
    p.add_argument('--series', action='append',
                   help='only this series; repeatable')
    p.add_argument('--seed', type=int, default=20260101)
    p.add_argument('--list', action='store_true', help='list series and exit')
    p.add_argument('--quiet', action='store_true')
    a = p.parse_args(argv)

    all_series = default_series()
    if a.list:
        for s in all_series:
            print('%-20s gap0=%-5g closure=%-5g %s%s'
                  % (s.name, s.gap0, s.closure_rate,
                     'horizontal ' if s.horizontal else '', s.note))
        return 0

    chosen = all_series
    if a.series:
        wanted = set(a.series)
        chosen = [s for s in all_series if s.name in wanted]
        missing = wanted - {s.name for s in chosen}
        if missing:
            p.error('unknown series: %s' % ', '.join(sorted(missing)))

    hours = [float(x) for x in a.hours.split(',') if x.strip()]
    if not a.quiet:
        print('Generating %d series x %d time points at %dx%d (seed %d)'
              % (len(chosen), len(hours), a.width, a.height, a.seed))
    truth, n = generate(a.out, chosen, a.width, a.height, hours, a.seed,
                        quiet=a.quiet)
    if not a.quiet:
        print('%d images under %s/images' % (n, a.out))
        print('ground truth: %s' % truth)
    return 0


if __name__ == '__main__':
    sys.exit(main())
