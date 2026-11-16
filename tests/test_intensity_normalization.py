#!/usr/bin/env python3
"""Checks for 20261116_intensity_normalization.ijm. Standard library only.

- Static checks always run: balanced delimiters; every name a macro function
  reads is a parameter or assigned inside it (ImageJ macro functions cannot see
  top-level variables); the 12-bit clip uses Max... for the ceiling and Min...
  for the floor; percentile() is told the bit depth, since getRawStatistics
  bins 8/16-bit histograms one bin per grey value.

- An end-to-end check runs the whole macro through ImageJ's interpreter on
  synthetic 16-bit images, with the dialogs replaced by fixed answers. Each
  well's 0 h image is a ramp 1000..2000; its 24 h image is a ramp 500..1000.
  "Background + Contrast" must map 24 h back onto 1000..2000 (scale 2,
  offset 0); "Background Only" must shift it by +750 (median 1500 - 750).
  Point IJ_JAR at an ImageJ jar (or pass --ij-jar) to enable it. It needs a
  display, since Process > Math uses menu commands; headless, use xvfb-run.

    python3 tests/test_intensity_normalization.py
    IJ_JAR=/path/to/ij.jar xvfb-run -a python3 tests/test_intensity_normalization.py
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_basic_stitcher import (BUILTIN, KEYWORDS, find_functions,  # noqa: E402
                                 strip_comments_and_strings)

ROOT = Path(__file__).parents[1]
MACRO = ROOT / '20261116_intensity_normalization.ijm'
WELLS = ['A01', 'A02', 'A03', 'B01', 'B02', 'B03']


def static_checks(raw):
    code = strip_comments_and_strings(raw)
    lines = code.split('\n')
    for left, right, name in [('{', '}', 'braces'), ('(', ')', 'parens'),
                              ('[', ']', 'brackets')]:
        assert code.count(left) == code.count(right), 'unbalanced %s' % name

    declared = set()
    for line in lines:
        m = re.match(r'\s*var\s+(.*?);', line)
        if m:
            declared.update(p.split('=')[0].strip() for p in m.group(1).split(','))

    funcs = find_functions(lines)
    for want in ['percentile', 'isTiff', 'stripTiff', 'getWell', 'getTimepoint']:
        assert want in funcs, 'missing function %s' % want
    for name, (start, end, params) in funcs.items():
        body = '\n'.join(lines[start:end + 1])
        bound = set(params) | declared | set(funcs)
        for m in re.finditer(r'\b(\w+)\s*(?:\[[^\]]*\])?\s*=(?!=)', body):
            bound.add(m.group(1))
        for m in re.finditer(r'\bfor\s*\(\s*(\w+)\s*=', body):
            bound.add(m.group(1))
        unbound = sorted({
            m.group(1) for m in re.finditer(r'\b([A-Za-z_]\w*)\b', body)
            if body[m.end():m.end() + 1] != '('
            and body[max(0, m.start() - 1):m.start()] != '.'
            and m.group(1) not in bound | BUILTIN | KEYWORDS})
        assert not unbound, \
            'in %s(): %s is not a parameter, global, or local assignment' % (name, unbound)

    # Max... caps at 4095, Min... floors at 0. Swapped, every pixel ends up 0.
    clip = re.findall(r'run\("(Min|Max)\.\.\.", "value=(\d+)"\)', raw)
    assert clip == [('Max', '4095'), ('Min', '0')], clip

    calls = re.findall(r'\bpercentile\(([^)]*)\)', code)
    for args in calls:
        assert len(args.split(',')) == 5, 'percentile(%s) needs the bit depth' % args
    print('static checks passed')


SETUP = r'''
root = "%(root)s";
wells = newArray("A01", "A02", "A03", "B01", "B02", "B03");
for (w = 0; w < wells.length; w++) {
    newImage("r", "16-bit black", 101, 4, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 1000 + 10 * x);
    saveAs("Tiff", root + "0h_Exp_" + wells[w] + ".tif");
    close();
    newImage("t", "16-bit black", 101, 4, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 500 + 5 * x);
    saveAs("Tiff", root + "24h_Exp_" + wells[w] + ".tif");
    close();
}
print("SETUP DONE");
'''

STUBS = r'''
function stubDialog_create(t) {}
function stubDialog_addChoice(l, items, d) {}
function stubDialog_addCheckbox(l, d) {}
function stubDialog_show() {}
function stubDialog_getChoice() { return "%(method)s"; }
function stubDialog_getCheckbox() { return true; }
// exit("...") and showMessage would open a dialog and wait forever.
function stubExit(message) { print("EXIT " + message); exit(); }
function stubShowMessage(t, m) { print("DONE " + m); }
'''

CHECK = r'''
open("%(path)s");
s = "";
for (x = 0; x < getWidth(); x += 25) s = s + getPixel(x, 1) + ";";
print("PIXELS " + bitDepth() + " " + s);
'''


def run_ij(ij_jar, program, td, name):
    script = Path(td) / name
    script.write_text(program, encoding='utf-8')
    try:
        r = subprocess.run(['java', '-cp', ij_jar, 'ij.ImageJ', '-batch', str(script)],
                           capture_output=True, text=True,
                           timeout=int(os.environ.get('IJ_TIMEOUT', 120)))
    except subprocess.TimeoutExpired as e:
        return '%s\nTIMED OUT (macro error dialog?)' % (e.stdout or b'').decode(errors='replace')
    return r.stdout + r.stderr


def stubbed_macro(raw, root, method):
    body = re.sub(r'getDirectory\("[^"]*"\)', '"%s"' % root, raw, count=1)
    body = re.sub(r'\bDialog\.(\w+)\(', r'stubDialog_\1(', body)
    body = re.sub(r'\bexit\(', 'stubExit(', body)
    body = re.sub(r'\bshowMessage\(', 'stubShowMessage(', body)
    body = body.replace('print("\\\\Clear");', '')
    return STUBS % {'method': method} + body


def end_to_end(raw, ij_jar):
    # x = 0, 25, 50, 75, 100 -> reference 1000, 1250, 1500, 1750, 2000
    cases = [
        ('Background + Contrast', '16 1000;1250;1500;1750;2000;', 2.0, 0.0),
        ('Background Only', '16 1250;1375;1500;1625;1750;', 1.0, 750.0),
    ]
    for method, want, scale, offset in cases:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td, 'in').as_posix() + '/'
            os.makedirs(root)
            log = run_ij(ij_jar, SETUP % {'root': root}, td, 'setup.ijm')
            assert 'SETUP DONE' in log, log[-2000:]
            log = run_ij(ij_jar, stubbed_macro(raw, root, method), td, 'run.ijm')
            assert 'DONE Processed: 6' in log, '%s: %s' % (method, log[-2000:])
            out = root + 'normalized/'
            for well in WELLS:
                got = run_ij(ij_jar, CHECK % {'path': out + '24h_Exp_%s_normalized.tif' % well},
                             td, 'check.ijm')
                m = re.search(r'PIXELS (.*)', got)
                assert m and m.group(1).strip() == want, \
                    '%s %s: got %r want %r' % (method, well, m and m.group(1), want)
                assert os.path.isfile(out + '0h_Exp_%s_normalized.tif' % well)
            with open(out + 'normalization_log.csv', newline='') as f:
                rows = list(csv.DictReader(f))
            assert len(rows) == 6 and all(r['Status'] == 'OK' for r in rows), rows
            for r in rows:
                assert (float(r['Ref_P10']), float(r['Ref_P50']), float(r['Ref_P90'])) \
                    == (1100, 1500, 1900), r
                assert abs(float(r['Scale']) - scale) < 1e-9, r
                assert abs(float(r['Offset']) - offset) < 1e-6, r
            print('ok   %s -> %s' % (method, want))
    print('end-to-end checks passed (real ImageJ interpreter)')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--ij-jar', default=os.environ.get('IJ_JAR'))
    a = ap.parse_args()
    raw = MACRO.read_text(encoding='utf-8')
    print('macro: %s' % MACRO.name)
    static_checks(raw)
    if a.ij_jar and Path(a.ij_jar).is_file():
        end_to_end(raw, a.ij_jar)
    else:
        print('end-to-end checks SKIPPED: no ImageJ jar. Set IJ_JAR or pass --ij-jar.')
    print('intensity normalization checks passed')


if __name__ == '__main__':
    main()
