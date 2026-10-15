#!/usr/bin/env python3
"""Checks for the synthetic benchmark. Standard library only, no QuPath.

Generates a tiny dataset, verifies the images and ground truth are sound, and
round-trips the scorer against truth-as-measurement so that a perfect run
scores as perfect and a biased one does not.
"""
import csv
import io
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).parents[1]
GEN = ROOT / 'benchmark' / 'generate_synthetic.py'
SCORE = ROOT / 'benchmark' / 'score_against_truth.py'


def read_png_gray8(path):
    """Minimal reader for the 8-bit grayscale PNGs the generator writes."""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG: %s' % path
    i, idat, w, h, bit, colour = 8, b'', 0, 0, None, None
    while i < len(data):
        n = struct.unpack('>I', data[i:i + 4])[0]
        tag, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        stored = struct.unpack('>I', data[i + 8 + n:i + 12 + n])[0]
        assert zlib.crc32(tag + body) & 0xffffffff == stored, 'bad CRC in %s' % path
        if tag == b'IHDR':
            w, h, bit, colour = struct.unpack('>IIBB', body[:10])
        elif tag == b'IDAT':
            idat += body
        i += 12 + n
    assert (bit, colour) == (8, 0), 'expected 8-bit grayscale, got %s' % ((bit, colour),)
    raw = zlib.decompress(idat)
    assert len(raw) == h * (w + 1), 'truncated image data in %s' % path
    px = bytearray()
    for y in range(h):
        off = y * (w + 1)
        assert raw[off] == 0, 'unexpected scanline filter in %s' % path
        px.extend(raw[off + 1:off + 1 + w])
    return w, h, px


def run(args):
    r = subprocess.run([sys.executable] + args, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / 'ds'
        code, log = run([str(GEN), '--out', str(out), '--quiet',
                         # Wide enough that a 150px gap leaves sheet on both
                         # sides; a frame narrower than the wound has no sheet
                         # to measure against.
                         '--width', '260', '--height', '180',
                         '--hours', '0,12',
                         '--series', 'vertical_static',
                         '--series', 'horizontal_medium'])
        assert code == 0, 'generator failed:\n' + log

        rows = list(csv.DictReader(open(out / 'ground_truth.csv')))
        assert len(rows) == 4, 'expected 4 rows, got %d' % len(rows)

        for r in rows:
            img = out / 'images' / r['Image']
            w, h, px = read_png_gray8(img)
            assert (w, h) == (int(r['Image_Width_px']), int(r['Image_Height_px'])), \
                'ground truth disagrees with the image size for %s' % r['Image']
            # Phase contrast carries its signal in texture, not brightness, so
            # the frame must not be a dark band on a light field.
            assert 40 < sum(px) / len(px) < 215, 'implausible mean for %s' % r['Image']
            assert max(px) - min(px) > 40, 'no contrast in %s' % r['Image']
            clipped = sum(1 for v in px if v in (0, 255)) / len(px)
            assert clipped < 0.02, 'over 2%% of %s is clipped' % r['Image']

            mw, mh, mpx = read_png_gray8(
                out / 'truth_masks' / r['Image'].replace('.png', '_truth_mask.png'))
            assert (mw, mh) == (w, h), 'mask size differs from image for %s' % r['Image']
            assert set(mpx) <= {0, 255}, 'truth mask is not binary for %s' % r['Image']
            assert sum(1 for v in mpx if v) == int(r['True_Gap_Area_px2']), \
                'truth mask area disagrees with the CSV for %s' % r['Image']

            # Width is measured across the scratch, so it must not be the long
            # axis: a sanity check that the orientation is recorded correctly.
            width = float(r['True_Mean_Width_px'])
            length = float(r['True_Scratch_Length_px'])
            assert width < length, 'width >= length for %s' % r['Image']
            assert length == (h if r['Orientation'] == 'Vertical' else w), \
                'the scratch does not span the frame for %s' % r['Image']
            # The realised width should track the nominal closure model.
            nominal = float(r['Nominal_Gap_Width_px'])
            assert abs(width - nominal) < 0.25 * nominal + 6, \
                'realised width %.1f is far from nominal %.1f for %s' % (
                    width, nominal, r['Image'])

        # The static series must not drift: same wound at both time points.
        static = sorted([r for r in rows if r['Series'] == 'vertical_static'],
                        key=lambda r: float(r['Time_h']))
        a, b = (float(r['True_Mean_Width_px']) for r in static)
        assert abs(a - b) < 1.0, 'static control drifted: %.2f -> %.2f' % (a, b)

        # Scorer round trip: truth presented as a perfect measurement.
        perfect = Path(td) / 'perfect.csv'
        biased = Path(td) / 'biased.csv'
        cols = ['Image', 'Orientation', 'Wound_Area_px2', 'Percent_Open',
                'Scratch_Length_px', 'Mean_Width_px', 'Median_Width_px',
                'Width_Samples', 'Detection_Status']
        for path, factor in ((perfect, 1.0), (biased, 1.4)):
            with open(path, 'w', newline='') as fh:
                wr = csv.DictWriter(fh, fieldnames=cols)
                wr.writeheader()
                for r in rows:
                    wr.writerow({
                        'Image': r['Image'], 'Orientation': r['Orientation'],
                        'Wound_Area_px2': float(r['True_Gap_Area_px2']) * factor,
                        'Percent_Open': r['True_Percent_Open'],
                        'Scratch_Length_px': r['True_Scratch_Length_px'],
                        'Mean_Width_px': float(r['True_Mean_Width_px']) * factor,
                        'Median_Width_px': float(r['True_Median_Width_px']) * factor,
                        'Width_Samples': r['True_Width_Samples'],
                        'Detection_Status': 'FOUND'})

        code, log = run([str(SCORE), '--truth', str(out / 'ground_truth.csv'),
                         '--measured', str(perfect)])
        assert code == 0, 'a perfect measurement should pass:\n' + log
        assert 'PASS' in log, log

        code, log = run([str(SCORE), '--truth', str(out / 'ground_truth.csv'),
                         '--measured', str(biased)])
        assert code == 1, 'a 40%% bias should fail, got exit %d:\n%s' % (code, log)
        assert 'FAIL' in log and '+40.0%' in log, log

        # An orientation mix-up has to be named, not silently scored as error.
        swapped = Path(td) / 'swapped.csv'
        text = perfect.read_text().replace('Vertical', 'Horizontal')
        swapped.write_text(text)
        code, log = run([str(SCORE), '--truth', str(out / 'ground_truth.csv'),
                         '--measured', str(swapped)])
        assert 'width and length columns are swapped' in log, log

        # An empty intersection must be reported, not scored as success.
        nomatch = Path(td) / 'nomatch.csv'
        nomatch.write_text('Image,Mean_Width_px\n"other.png",10\n')
        code, log = run([str(SCORE), '--truth', str(out / 'ground_truth.csv'),
                         '--measured', str(nomatch)])
        assert code == 2 and 'no image names matched' in log, log

    check_helper_extraction()
    print('benchmark checks passed')


def check_helper_extraction():
    """The reference runner lifts the real helpers out of the Groovy source.

    If that extraction silently drops or duplicates a function the harness
    would not compile, or worse would compile against the wrong code, so pin
    its behaviour here where it runs without Groovy installed.
    """
    sys.path.insert(0, str(ROOT / 'benchmark'))
    import run_reference_pipeline as rrp

    script = ROOT / 'qupath' / 'ScratchAssayAnalyzer.groovy'
    block = rrp.extract_helpers(script, rrp.HELPERS)

    for name in rrp.HELPERS:
        starts = [ln for ln in block.split('\n')
                  if rrp.DEF_RE.match(ln) and rrp.DEF_RE.match(ln).group('name') == name]
        assert len(starts) == 1, \
            'expected exactly one definition of %s, got %d' % (name, len(starts))

    # @CompileStatic must come along, or the harness runs code that is an order
    # of magnitude slower than the analyzer's and is not the same compilation.
    assert block.count('@CompileStatic') >= 10, \
        'extraction dropped @CompileStatic annotations'

    # Nothing that touches QuPath may come along for the ride.
    for forbidden in ('replaceGeneratedAnnotation', 'PathClassFactory', 'ROIs.',
                      'PathObjects', 'RegionRequest', 'Dialogs'):
        assert forbidden not in block, 'extraction pulled in %s' % forbidden

    # Balanced delimiters, ignoring comments and strings, means each function
    # ended where it really ended.
    depth = 0
    for line in block.split('\n'):
        net, _opens = rrp._scan_braces(line)
        depth += net
    assert depth == 0, 'extracted block has unbalanced braces (%d)' % depth

    # A name that is not there must fail loudly rather than yield a short block.
    try:
        rrp.extract_helpers(script, ['noSuchHelper'])
    except SystemExit as e:
        assert 'noSuchHelper' in str(e), e
    else:
        raise AssertionError('extracting a missing helper should fail')


if __name__ == '__main__':
    main()
