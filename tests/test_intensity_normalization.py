#!/usr/bin/env python3
"""Checks for 20261116_intensity_normalization.ijm. Standard library only.

- Static checks always run: balanced delimiters; every name a macro function
  reads is a parameter or assigned inside it (ImageJ macro functions cannot see
  top-level variables); no scaling step remains (no Multiply, no 32-bit or
  8-bit conversion, no ScaleConversions); the macro checks for 16-bit input
  and clears any saved selection after opening; nothing clips to a 12-bit
  (4095) maximum, since some data use the full 16-bit range.

- An end-to-end check runs the whole macro through ImageJ's interpreter on
  synthetic images, with the dialog replaced by fixed answers. Each well's
  0 h image is a 16-bit ramp 40000..50000 (median 45000); its 24 h image is
  a ramp 20000..25000 (median 22500), so it must be shifted by +22500 to
  42500..47500 with the slope unchanged. Values far above 4095 must survive.
  An extra 8-bit image must be skipped.
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
    for want in ['median16', 'isTiff', 'stripTiff', 'getWell', 'getTimepoint']:
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

    # Offset only: nothing may rescale intensities or change the pixel type.
    for banned in ['Multiply...', 'Divide...', '"32-bit"', '"8-bit"', 'ScaleConversions']:
        assert banned not in raw, '%s found: scaling steps were removed' % banned
    assert re.search(r'run\("Add\.\.\.", "value=" \+ offset\)', raw), 'offset step missing'
    assert raw.count('bitDepth() != 16') >= 2, 'reference and target must be checked for 16-bit'
    # ImageJ assumes a user-defined function returns a number when its call is
    # an operand of == or != ("Number or numeric function expected"), so a
    # string result must be stored in a variable before it is compared.
    for fn in funcs:
        for m in re.finditer(r'\b%s\s*\([^()]*\)\s*[=!]=|[=!]=\s*%s\s*\(' % (fn, fn), code):
            line = code.count('\n', 0, m.start()) + 1
            raise AssertionError('line %d: %s() result compared directly; assign it first'
                                 % (line, fn))

    # A TIFF's saved ROI is restored on open and would confine measuring and Add/Max.
    assert raw.count('run("Select None");') >= 2, 'selections must be cleared after open'

    # No 12-bit cap: some data are full 16-bit, and 16-bit Add already keeps
    # results within 0..65535.
    # Search with comments removed but strings kept: the clip value is a string.
    no_comments = re.sub(r'//[^\n]*', '', re.sub(r'/\*.*?\*/', '', raw, flags=re.S))
    assert not re.search(r'run\("(Min|Max)\.\.\."', no_comments), 'Min/Max clip found'
    assert '4095' not in no_comments, '12-bit (4095) assumption found'
    print('static checks passed')


SETUP = r'''
root = "%(root)s";
wells = newArray("A01", "A02", "A03", "B01", "B02", "B03");
for (w = 0; w < wells.length; w++) {
    newImage("r", "16-bit black", 101, 4, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 40000 + 100 * x);
    saveAs("Tiff", root + "0h_Exp_" + wells[w] + ".tif");
    close();
    newImage("t", "16-bit black", 101, 4, 1);
    for (y = 0; y < 4; y++) for (x = 0; x < 101; x++) setPixel(x, y, 20000 + 50 * x);
    saveAs("Tiff", root + "24h_Exp_" + wells[w] + ".tif");
    close();
}
newImage("e", "8-bit black", 101, 4, 1);
saveAs("Tiff", root + "48h_Exp_A01.tif");
close();
print("SETUP DONE");
'''

STUBS = r'''
function stubDialog_create(t) {}
function stubDialog_addMessage(m) {}
function stubDialog_addCheckbox(l, d) {}
function stubDialog_show() {}
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


def stubbed_macro(raw, root):
    body = re.sub(r'getDirectory\("[^"]*"\)', '"%s"' % root, raw, count=1)
    body = re.sub(r'\bDialog\.(\w+)\(', r'stubDialog_\1(', body)
    body = re.sub(r'\bexit\(', 'stubExit(', body)
    body = re.sub(r'\bshowMessage\(', 'stubShowMessage(', body)
    body = body.replace('print("\\\\Clear");', '')
    return STUBS + body


def end_to_end(raw, ij_jar):
    # x = 0, 25, 50, 75, 100 -> 24 h 20000..25000 shifted by +22500
    want = '16 42500;43750;45000;46250;47500;'
    with tempfile.TemporaryDirectory() as td:
        root = Path(td, 'in').as_posix() + '/'
        os.makedirs(root)
        log = run_ij(ij_jar, SETUP % {'root': root}, td, 'setup.ijm')
        assert 'SETUP DONE' in log, log[-2000:]
        log = run_ij(ij_jar, stubbed_macro(raw, root), td, 'run.ijm')
        assert 'DONE Processed: 6\nSkipped: 1' in log, log[-2000:]
        out = root + 'normalized/'
        for well in WELLS:
            got = run_ij(ij_jar, CHECK % {'path': out + '24h_Exp_%s_normalized.tif' % well},
                         td, 'check.ijm')
            m = re.search(r'PIXELS (.*)', got)
            assert m and m.group(1).strip() == want, \
                '%s: got %r want %r' % (well, m and m.group(1), want)
            assert os.path.isfile(out + '0h_Exp_%s_normalized.tif' % well)
        assert not os.path.exists(out + '48h_Exp_A01_normalized.tif'), '8-bit image was written'
        with open(out + 'normalization_log.csv', newline='') as f:
            rows = {r['Filename']: r for r in csv.DictReader(f)}
        assert rows['48h_Exp_A01.tif']['Status'] == 'SKIPPED_NOT_16BIT', rows
        ok = [r for r in rows.values() if r['Status'] == 'OK']
        assert len(ok) == 6, rows
        for r in ok:
            assert (float(r['Ref_P50']), float(r['Target_P50']), float(r['Offset'])) \
                == (45000, 22500, 22500), r
        print('ok   offset only -> %s, 8-bit skipped' % want)
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
