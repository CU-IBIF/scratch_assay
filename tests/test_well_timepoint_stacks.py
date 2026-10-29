#!/usr/bin/env python3
"""Checks for Well_Timepoint_Stacks. Standard library only.

- Static checks always run: the time point helpers must be byte-identical to
  the stitcher's copies (whose behaviour test_basic_stitcher.py covers), and the
  dialog must be read back in the order it was built.

- An end-to-end check runs the whole macro through ImageJ's interpreter on a
  synthetic BaSiC_Stitch_Output tree, with the dialogs replaced by fixed
  answers. Each fused image's pixel value is its time point number, so the
  exported stack shows exactly which folders became which frames. Point IJ_JAR
  at an ImageJ jar (or pass --ij-jar) to enable it. It needs a display, since
  the macro uses menu commands; on a headless machine wrap it in xvfb-run.

    python3 tests/test_well_timepoint_stacks.py
    IJ_JAR=/path/to/ij.jar xvfb-run -a python3 tests/test_well_timepoint_stacks.py
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_basic_stitcher import (MACRO as STITCHER, TESTED as SHARED,  # noqa: E402
                                 extract, find_functions,
                                 strip_comments_and_strings)

ROOT = Path(__file__).parents[1]
MACRO = ROOT / 'macros' / 'Well_Timepoint_Stacks.ijm'


def static_checks(raw):
    code = strip_comments_and_strings(raw)
    for left, right, name in [('{', '}', 'braces'), ('(', ')', 'parens'),
                              ('[', ']', 'brackets')]:
        assert code.count(left) == code.count(right), 'unbalanced %s' % name

    funcs = find_functions(code.split('\n'))
    for name in SHARED:
        assert name in funcs, 'missing function %s' % name
    stitcher = STITCHER.read_text(encoding='utf-8')
    for name in SHARED:
        assert extract(raw, [name]) == extract(stitcher, [name]), \
            '%s() differs from the copy in %s' % (name, STITCHER.name)
    # The old position-based parser must not come back.
    assert 'chosen' not in funcs, 'position-based chosen() is back'

    # Checkboxes: one group, then two plain boxes, read back in that order.
    adds = re.findall(r'Dialog\.add(CheckboxGroup|Checkbox|Number|String|Choice)', code)
    gets = re.findall(r'Dialog\.get(Checkbox|Number|String|Choice)', code)
    assert adds.count('CheckboxGroup') == 1, adds
    assert adds.count('Checkbox') == 2 and gets.count('Checkbox') == 3, (adds, gets)
    for kind in ('Number', 'String', 'Choice'):
        assert adds.count(kind) == gets.count(kind), (kind, adds, gets)
    group = code.index('Dialog.addCheckboxGroup')
    assert group < code.index('Dialog.addCheckbox('), 'group must precede plain boxes'
    print('static checks passed (%s shared with %s)' % (', '.join(SHARED), STITCHER.name))


SETUP = r'''
root = "%(root)s";
// Pixel value = time point number. TimePoint_2 is larger, so padding is used.
names = newArray("TimePoint_1", "TimePoint_2", "TimePoint_10", "Notes");
values = newArray(1, 2, 10, 99);
for (i = 0; i < names.length; i++) {
    dir = root + names[i] + "/Exp_A01/Fused/";
    File.makeDirectory(root + names[i]);
    File.makeDirectory(root + names[i] + "/Exp_A01");
    File.makeDirectory(dir);
    w = 32; h = 32;
    if (values[i] == 2) { w = 40; h = 36; }
    newImage("f", "16-bit black", w, h, 1);
    run("Set...", "value=" + values[i]);
    saveAs("Tiff", dir + "Exp_A01_BaSiC_Fused.tif");
    close();
}
File.saveString("log", root + "BaSiC_Stitch_Log.txt");
print("SETUP DONE");
'''

STUBS = r'''
var stubBoxes = newArray(%(boxes)s);
var stubBoxAt = 0;
var stubChoices = newArray("Center", "PNG");
var stubChoiceAt = 0;
function stubDialog_create(t) {}
function stubDialog_addMessage(m) {}
function stubDialog_addCheckboxGroup(r, c, l, d) {}
function stubDialog_addString(l, d, w) {}
function stubDialog_addNumber(l, d) {}
function stubDialog_addChoice(l, items, d) {}
function stubDialog_addCheckbox(l, d) {}
function stubDialog_show() {}
function stubDialog_getCheckbox() { v = stubBoxes[stubBoxAt]; stubBoxAt++; return v; }
function stubDialog_getString() { return "%(range)s"; }
function stubDialog_getNumber() { return 5; }
function stubDialog_getChoice() { v = stubChoices[stubChoiceAt]; stubChoiceAt++; return v; }
// exit("...") would open a message box and wait forever; print it and stop instead.
function stubExit(message) { print("EXIT " + message); exit(); }
'''

CHECK = r'''
open("%(out)sExp_A01_timelapse.tif");
s = "";
for (i = 1; i <= nSlices; i++) {
    setSlice(i);
    s = s + getInfo("slice.label") + "=" + getPixel(floor(getWidth()/2), floor(getHeight()/2)) + ";";
}
print("FRAMES " + nSlices + " " + getWidth() + "x" + getHeight() + " " + s);
'''


def run_ij(ij_jar, program, td, name):
    script = Path(td) / name
    script.write_text(program, encoding='utf-8')
    # Not headless: run("Copy"), run("Paste") and friends need ImageJ's menus,
    # which need a display. On a machine without one, use xvfb-run. A macro
    # error opens a modal dialog, which shows up here as a timeout.
    try:
        r = subprocess.run(['java', '-cp', ij_jar, 'ij.ImageJ', '-batch', str(script)],
                           capture_output=True, text=True,
                           timeout=int(os.environ.get('IJ_TIMEOUT', 120)))
    except subprocess.TimeoutExpired as e:
        return '%s\nTIMED OUT (macro error dialog?)' % (e.stdout or b'').decode(errors='replace')
    return r.stdout + r.stderr


def stubbed_macro(raw, root, out, boxes, rng):
    dirs = iter([root, out])
    body = re.sub(r'getDirectory\("[^"]*"\)', lambda m: '"%s"' % next(dirs), raw, count=2)
    body = re.sub(r'\bDialog\.(\w+)\(', r'stubDialog_\1(', body)
    body = re.sub(r'\bexit\(', 'stubExit(', body)
    # Clearing the Log opens its window, which keeps the JVM alive afterwards.
    body = body.replace('print("\\\\Clear");', '')
    return STUBS % {'boxes': ', '.join(boxes), 'range': rng} + body


def end_to_end(raw, ij_jar):
    # Folder order after the numeric sort is TimePoint_1, _2, _10 (Notes ignored).
    cases = [
        ('all boxes', ['true'] * 3, '', '3 40x36 TimePoint_1=1;TimePoint_2=2;TimePoint_10=10;'),
        ('untick middle', ['true', 'false', 'true'], '', '2 32x32 TimePoint_1=1;TimePoint_10=10;'),
        # Typed numbers are folder numbers: "10" is the third folder, not a 10th.
        ('typed 10', ['true'] * 3, '10', '1 32x32 TimePoint_10=10;'),
        ('typed 2-10 overrides boxes', ['false'] * 3, '2-10', '2 40x36 TimePoint_2=2;TimePoint_10=10;'),
    ]
    for label, boxes, rng, want in cases:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td, 'BaSiC_Stitch_Output').as_posix() + '/'
            out = Path(td, 'Movie_Output').as_posix() + '/'
            os.makedirs(root)
            os.makedirs(out)
            log = run_ij(ij_jar, SETUP % {'root': root}, td, 'setup.ijm')
            assert 'SETUP DONE' in log, log[-2000:]
            log = run_ij(ij_jar, stubbed_macro(raw, root, out, boxes + ['true', 'false'], rng),
                         td, 'run.ijm')
            got = run_ij(ij_jar, CHECK % {'out': out}, td, 'check.ijm')
            m = re.search(r'FRAMES (.*)', got)
            assert m and m.group(1).strip() == want, \
                '%s: got %r want %r\n%s' % (label, m and m.group(1), want, log[-2000:])
            print('ok   %s -> %s' % (label, want))

    refusals = [
        # Two folders with the same number must stop the run rather than guess an order.
        ('duplicate number', ['TimePoint_1', 'TimePoint_01'], '', 'Two folders share time point number 1'),
        # A typed number with no folder is an error, not an empty selection.
        ('absent number', ['TimePoint_1', 'TimePoint_2'], '3', 'No time point folder matches "3"'),
        ('no time point folders', ['Notes', 'Plate_1'], '', 'No TimePoint_n folders found'),
    ]
    for label, folders, rng, want in refusals:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td, 'in').as_posix() + '/'
            out = Path(td, 'out').as_posix() + '/'
            for f in folders:
                os.makedirs(root + f + '/Exp_A01/Fused')
            os.makedirs(out)
            boxes = ['true'] * len(folders) + ['true', 'false']
            log = run_ij(ij_jar, stubbed_macro(raw, root, out, boxes, rng), td, 'refuse.ijm')
            assert 'EXIT ' + want in log, '%s: %s' % (label, log[-2000:])
            assert not os.listdir(out), '%s: output was written' % label
            print('ok   %s refused' % label)
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
    print('Well_Timepoint_Stacks checks passed')


if __name__ == '__main__':
    main()
