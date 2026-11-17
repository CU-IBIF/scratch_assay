#!/usr/bin/env python3
"""Checks for 20261116_intensity_normalization.ijm. Standard library only.

- Static checks always run: balanced delimiters; every name a macro function
  reads is a parameter or assigned inside it (ImageJ macro functions cannot see
  top-level variables); no user function result is compared directly with ==;
  the three methods are offered with "Brightfield linear (mode exact)" as the
  default; the dialog is read back in the order it was built; 16-bit input is
  required and saved selections are cleared; the ScaleConversions option is
  restored; Min/Max only split at the mode and nothing clips to a 12-bit (4095)
  maximum, since some data use the full 16-bit range.

- An end-to-end check runs the whole macro through ImageJ's interpreter on
  synthetic images, with the dialog replaced by fixed answers. Each image is a
  ramp (rows 0-3) plus a constant background block (rows 4-5) that sets the
  mode, placed off-centre in the 24 h image so the methods give different
  results:
      0 h : ramp 40000..50000, background 45000 -> low 40000, mode 45000, high 50000
      24 h: ramp 20000..25000, background 21250 -> low 20000, mode 21250, high 25000
  Expected outputs at x = 0, 25, 50, 75, 100 of the 24 h ramp:
      linear (mode exact): slope 2           -> 42500 45000 47500 50000 52500
      two-segment:         slopes 4 and 4/3  -> 40000 45000 46667 48333 50000
      median offset:       +23750            -> 43750 45000 46250 47500 48750
  Values far above 4095 must survive, an extra 8-bit image must be skipped, and
  percentiles in the wrong order must stop the run before anything is written.
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
    for want in ['percentile16', 'mode16', 'isTiff', 'stripTiff', 'getWell', 'getTimepoint']:
        assert want in funcs, 'missing function %s' % want
    for name, (start, end, params) in funcs.items():
        body = '\n'.join(lines[start:end + 1])
        bound = set(params) | declared | set(funcs)
        for m in re.finditer(r'\b(\w+)\s*(?:\[[^\]]*\])?\s*=(?!=)', body):
            bound.add(m.group(1))
        for m in re.finditer(r'\bfor\s*\(\s*(\w+)\s*=', body):
            bound.add(m.group(1))
        # getRawStatistics assigns through its arguments
        for m in re.finditer(r'\bgetRawStatistics\s*\(([^)]*)\)', body):
            bound.update(a.strip() for a in m.group(1).split(','))
        unbound = sorted({
            m.group(1) for m in re.finditer(r'\b([A-Za-z_]\w*)\b', body)
            if body[m.end():m.end() + 1] != '('
            and body[max(0, m.start() - 1):m.start()] != '.'
            and m.group(1) not in bound | BUILTIN | KEYWORDS})
        assert not unbound, \
            'in %s(): %s is not a parameter, global, or local assignment' % (name, unbound)

    # Three methods, brightfield linear (mode exact) first and the default.
    methods = re.findall(r'^(METHOD_\w+) = "([^"]*)";', raw, re.M)
    assert [m[1] for m in methods] == [
        'Brightfield linear (mode exact)',
        'Brightfield two-segment (min, mode, max exact)',
        'Median offset (shift only)'], methods
    assert re.search(r'newArray\(METHOD_LINEAR, METHOD_TWO, METHOD_OFFSET\),\s*METHOD_LINEAR\)',
                     raw), 'method choice must default to METHOD_LINEAR'
    assert re.search(r'addNumber\("Low percentile \(min\)", 0\.1\)', raw), 'low default'
    assert re.search(r'addNumber\("High percentile \(max\)", 99\.9\)', raw), 'high default'

    # Dialog fields must be read back in the order they were added.
    adds = re.findall(r'Dialog\.add(Choice|Number|Checkbox|String)', raw)
    gets = re.findall(r'Dialog\.get(Choice|Number|Checkbox|String)', raw)
    assert adds == gets == ['Choice', 'Number', 'Number', 'Checkbox'], (adds, gets)

    assert re.search(r'run\("Add\.\.\.", "value=" \+ \(refCenter - tarCenter\)\)', raw), \
        'median offset step missing'
    assert raw.count('bitDepth() != 16') >= 2, 'reference and target must be checked for 16-bit'
    assert '"8-bit"' not in raw, 'images must not be converted to 8-bit'
    # The conversion option is global to Fiji: every change must be undone.
    assert raw.count('setOption("ScaleConversions", false);') == \
        raw.count('setOption("ScaleConversions", true);') == 1, 'ScaleConversions not restored'
    # ImageJ assumes a user-defined function returns a number when its call is
    # an operand of == or != ("Number or numeric function expected"), so a
    # string result must be stored in a variable before it is compared.
    for fn in funcs:
        for m in re.finditer(r'\b%s\s*\([^()]*\)\s*[=!]=|[=!]=\s*%s\s*\(' % (fn, fn), code):
            line = code.count('\n', 0, m.start()) + 1
            raise AssertionError('line %d: %s() result compared directly; assign it first'
                                 % (line, fn))

    # A TIFF's saved ROI is restored on open and would confine measuring and the math.
    assert raw.count('run("Select None");') >= 2, 'selections must be cleared after open'

    # No 12-bit cap: some data are full 16-bit. Min/Max may only split the
    # image at its mode (two-segment method), never clip to a fixed value.
    # Search with comments removed but strings kept: the clip value is a string.
    no_comments = re.sub(r'//[^\n]*', '', re.sub(r'/\*.*?\*/', '', raw, flags=re.S))
    minmax = re.findall(r'run\("(Min|Max)\.\.\.", ([^)]*)\)', no_comments)
    assert minmax == [('Max', '"value=" + tarCenter'), ('Min', '"value=" + tarCenter')], minmax
    assert '4095' not in no_comments, '12-bit (4095) assumption found'
    print('static checks passed')


SETUP = r'''
root = "%(root)s";
wells = newArray("A01", "A02", "A03", "B01", "B02", "B03");
// Rows 0-3: ramp. Rows 4-5: constant background, which becomes the mode.
for (w = 0; w < wells.length; w++) {
    newImage("r", "16-bit black", 101, 6, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 40000 + 100 * x);
    for (y = 4; y < 6; y++) for (x = 0; x < 101; x++) setPixel(x, y, 45000);
    saveAs("Tiff", root + "0h_Exp_" + wells[w] + ".tif");
    close();
    newImage("t", "16-bit black", 101, 6, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 20000 + 50 * x);
    for (y = 4; y < 6; y++) for (x = 0; x < 101; x++) setPixel(x, y, 21250);
    saveAs("Tiff", root + "24h_Exp_" + wells[w] + ".tif");
    close();
}
newImage("e", "8-bit black", 101, 6, 1);
saveAs("Tiff", root + "48h_Exp_A01.tif");
close();
print("SETUP DONE");
'''

STUBS = r'''
var stubNumbers = newArray(%(numbers)s);
var stubNumberAt = 0;
function stubDialog_create(t) {}
function stubDialog_addChoice(l, items, d) {}
function stubDialog_addNumber(l, d) {}
function stubDialog_addMessage(m) {}
function stubDialog_addCheckbox(l, d) {}
function stubDialog_show() {}
function stubDialog_getChoice() { return "%(method)s"; }
function stubDialog_getNumber() { v = stubNumbers[stubNumberAt]; stubNumberAt++; return v; }
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


def stubbed_macro(raw, root, method, numbers):
    body = re.sub(r'getDirectory\("[^"]*"\)', '"%s"' % root, raw, count=1)
    body = re.sub(r'\bDialog\.(\w+)\(', r'stubDialog_\1(', body)
    body = re.sub(r'\bexit\(', 'stubExit(', body)
    body = re.sub(r'\bshowMessage\(', 'stubShowMessage(', body)
    body = body.replace('print("\\\\Clear");', '')
    return STUBS % {'method': method, 'numbers': ', '.join(map(str, numbers))} + body


CASES = [
    # method, percentiles, pixels at x = 0, 25, 50, 75, 100, slopes, centers
    ('Brightfield linear (mode exact)', (0.1, 99.9),
     '16 42500;45000;47500;50000;52500;', (2, 2), (45000, 21250)),
    ('Brightfield two-segment (min, mode, max exact)', (0.1, 99.9),
     '16 40000;45000;46667;48333;50000;', (4, 4 / 3), (45000, 21250)),
    ('Median offset (shift only)', (0.1, 99.9),
     '16 43750;45000;46250;47500;48750;', (1, 1), (45000, 21250)),
    # 0 and 100 are the true extremes; here they equal the 0.1/99.9 values.
    ('Brightfield linear (mode exact)', (0, 100),
     '16 42500;45000;47500;50000;52500;', (2, 2), (45000, 21250)),
]


def end_to_end(raw, ij_jar):
    for method, numbers, want, slopes, centers in CASES:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td, 'in').as_posix() + '/'
            os.makedirs(root)
            log = run_ij(ij_jar, SETUP % {'root': root}, td, 'setup.ijm')
            assert 'SETUP DONE' in log, log[-2000:]
            log = run_ij(ij_jar, stubbed_macro(raw, root, method, numbers), td, 'run.ijm')
            assert 'DONE Processed: 6\nSkipped: 1' in log, '%s: %s' % (method, log[-2000:])
            out = root + 'normalized/'
            for well in WELLS:
                got = run_ij(ij_jar, CHECK % {'path': out + '24h_Exp_%s_normalized.tif' % well},
                             td, 'check.ijm')
                m = re.search(r'PIXELS (.*)', got)
                assert m and m.group(1).strip() == want, \
                    '%s %s: got %r want %r' % (method, well, m and m.group(1), want)
                assert os.path.isfile(out + '0h_Exp_%s_normalized.tif' % well)
            assert not os.path.exists(out + '48h_Exp_A01_normalized.tif'), '8-bit image written'
            with open(out + 'normalization_log.csv', newline='') as f:
                rows = {r['Filename']: r for r in csv.DictReader(f)}
            assert rows['48h_Exp_A01.tif']['Status'] == 'SKIPPED_NOT_16BIT', rows
            ok = [r for r in rows.values() if r['Status'] == 'OK']
            assert len(ok) == 6, rows
            for r in ok:
                assert r['Method'] == method, r
                got = tuple(float(r[k]) for k in ('Ref_Low', 'Ref_Center', 'Ref_High',
                                                   'Target_Low', 'Target_Center', 'Target_High'))
                assert got == (40000, centers[0], 50000, 20000, centers[1], 25000), r
                assert abs(float(r['Slope_Below']) - slopes[0]) < 1e-3, r
                assert abs(float(r['Slope_Above']) - slopes[1]) < 1e-3, r
            print('ok   %s %s -> %s' % (method, numbers, want))

    # Percentiles in the wrong order stop the run before any image or log is written.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td, 'in').as_posix() + '/'
        os.makedirs(root)
        run_ij(ij_jar, SETUP % {'root': root}, td, 'setup.ijm')
        log = run_ij(ij_jar, stubbed_macro(raw, root, CASES[0][0], (50, 10)), td, 'bad.ijm')
        assert 'EXIT Percentiles must satisfy' in log, log[-2000:]
        assert not os.listdir(root + 'normalized'), 'output written despite bad percentiles'
        print('ok   bad percentiles refused')
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
