#!/usr/bin/env python3
"""Checks for BaSiC_Batch_Tile_Stitcher. Standard library only.

Two layers:

- Static checks always run: balanced delimiters, and every name used inside a
  macro function is a parameter, a declared global, or assigned locally. That
  second one matters because ImageJ macro functions cannot see their caller's
  variables, so a refactor that moves code into a function can silently break
  scoping with no syntax error.

- Behavioural checks run the real helper functions through ImageJ's own macro
  interpreter, which is the only thing that actually settles how parseInt,
  split, substring and Array.trim behave. Point IJ_JAR at an ImageJ jar (or
  pass --ij-jar) to enable them; without it they are skipped and said to be.

    python3 tests/test_basic_stitcher.py
    IJ_JAR=/path/to/ij.jar python3 tests/test_basic_stitcher.py
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).parents[1]


def newest_macro():
    """The highest-numbered BaSiC_Batch_Tile_Stitcher_vX.Y.ijm in the repo.

    The macro is versioned in its filename, so older copies stay around; the
    checks should always describe the current one.
    """
    def version(path):
        m = re.search(r'_v(\d+)\.(\d+)', path.name)
        return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    found = sorted(ROOT.glob('BaSiC_Batch_Tile_Stitcher_v*.ijm'), key=version)
    assert found, 'no BaSiC_Batch_Tile_Stitcher_v*.ijm found'
    return found[-1]


MACRO = newest_macro()

# Functions the behavioural tests exercise, lifted from the macro verbatim.
TESTED = ['timepointIndex', 'sortTimepointsByNumber', 'applyTimepointRange']

BUILTIN = set('''
print exit getDirectory getFileList getDimensions getImageID getInfo getTitle
nImages nSlices nResults bitDepth isOpen selectImage selectWindow setSlice close
open run saveAs showMessage showStatus showProgress setOption roiManager
toLowerCase toUpperCase substring lengthOf indexOf lastIndexOf startsWith
endsWith replace split parseInt parseFloat isNaN round floor abs minOf maxOf
sqrt pow exp log d2s toString matches trim newArray requires eval wait
File Dialog Array String Property IJ Table Roi List Math Stack Overlay
PI true false NaN getWidth getHeight
'''.split())

KEYWORDS = {'function', 'if', 'else', 'for', 'while', 'return', 'continue',
            'break', 'var', 'macro'}


def strip_comments_and_strings(text):
    """Blank out comments and string bodies, preserving line structure."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append('""')
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def find_functions(lines):
    """Map function name -> (first line, last line, params), 0-based."""
    funcs = {}
    for i, line in enumerate(lines):
        m = re.match(r'\s*function\s+(\w+)\s*\(([^)]*)\)', line)
        if not m:
            continue
        depth, end = 0, None
        for j in range(i, len(lines)):
            depth += lines[j].count('{') - lines[j].count('}')
            if depth == 0 and '{' in ''.join(lines[i:j + 1]):
                end = j
                break
        funcs[m.group(1)] = (i, end if end is not None else len(lines) - 1,
                             [p.strip() for p in m.group(2).split(',') if p.strip()])
    return funcs


def static_checks(raw):
    code = strip_comments_and_strings(raw)
    lines = code.split('\n')

    for left, right, name in [('{', '}', 'braces'), ('(', ')', 'parens'),
                              ('[', ']', 'brackets')]:
        assert code.count(left) == code.count(right), \
            'unbalanced %s: %d vs %d' % (name, code.count(left), code.count(right))

    declared = set()
    for line in lines:
        m = re.match(r'\s*var\s+(.*?);', line)
        if m:
            for part in m.group(1).split(','):
                declared.add(part.split('=')[0].strip())
    assert declared, 'expected var globals shared with processFolder()'

    funcs = find_functions(lines)
    for want in TESTED + ['processFolder', 'isTiffFile', 'removeExtension',
                          'closeAllImagesWithoutSaving']:
        assert want in funcs, 'missing function %s' % want

    for name, (start, end, params) in funcs.items():
        body = '\n'.join(lines[start:end + 1])
        bound = set(params) | declared | set(funcs)
        for m in re.finditer(r'\b(\w+)\s*(?:\[[^\]]*\])?\s*=(?!=)', body):
            bound.add(m.group(1))
        for m in re.finditer(r'\bfor\s*\(\s*(\w+)\s*=', body):
            bound.add(m.group(1))
        # getDimensions assigns through its arguments
        for m in re.finditer(r'\bgetDimensions\s*\(([^)]*)\)', body):
            bound.update(a.strip() for a in m.group(1).split(','))
        unbound = []
        for m in re.finditer(r'\b([A-Za-z_]\w*)\b', body):
            tok = m.group(1)
            if body[m.end():m.end() + 1] == '(' and tok not in params:
                continue                                   # a call
            if body[max(0, m.start() - 1):m.start()] == '.':
                continue                                   # a property read
            if tok in bound or tok in BUILTIN or tok in KEYWORDS:
                continue
            unbound.append(tok)
        assert not unbound, \
            'in %s(): %s is not a parameter, global, or local assignment' % (
                name, sorted(set(unbound)))

    # The caller must still be in charge of aborting: the range parser returns a
    # message so the tests can drive it, which only works if nothing inside it
    # exits.
    rng = funcs['applyTimepointRange']
    body = '\n'.join(lines[rng[0]:rng[1] + 1])
    assert 'exit' not in body, 'applyTimepointRange must return a message, not exit'

    # Reading the dialog must match the order the fields were added.
    adds = re.findall(r'Dialog\.add(CheckboxGroup|Checkbox|Number|String)', code)
    gets = re.findall(r'Dialog\.get(Checkbox|Number|String)', code)
    assert adds.count('Number') == gets.count('Number'), (adds, gets)
    assert adds.count('CheckboxGroup') == 1, adds
    # Two plain checkboxes, plus one read inside the loop over the group.
    assert adds.count('Checkbox') == 2 and gets.count('Checkbox') == 3, (adds, gets)
    assert adds.count('String') == gets.count('String') == 1, (adds, gets)
    print('static checks passed (%d functions, %d globals)' % (len(funcs), len(declared)))


def extract(raw, names):
    """Pull named functions out of the macro so the tests run the real code."""
    code_lines = strip_comments_and_strings(raw).split('\n')
    raw_lines = raw.split('\n')
    funcs = find_functions(code_lines)
    out = []
    for n in names:
        start, end, _params = funcs[n]
        out.append('\n'.join(raw_lines[start:end + 1]))
    return '\n\n'.join(out)


HARNESS = r'''
// A var global, so check() updates the caller's counter rather than a local.
var failures = 0;

function check(label, got, want) {
    if ("" + got == "" + want) {
        print("ok   " + label + "  -> " + got);
    } else {
        print("FAIL " + label + "  got [" + got + "] want [" + want + "]");
        failures = failures + 1;
    }
}

// ---- timepointIndex ------------------------------------------------------
check("TimePoint_1",   timepointIndex("TimePoint_1"), 1);
check("Timepoint_7",   timepointIndex("Timepoint_7"), 7);
check("TIMEPOINT-12",  timepointIndex("TIMEPOINT-12"), 12);
check("TimePoint13",   timepointIndex("TimePoint13"), 13);
check("TimePoint 4",   timepointIndex("TimePoint 4"), 4);
check("TimePoint_0",   timepointIndex("TimePoint_0"), 0);
check("TimePoint_010", timepointIndex("TimePoint_010"), 10);
// Not time points: no number, trailing text, a different name entirely.
check("TimePoint_",        timepointIndex("TimePoint_"), -1);
check("TimePoint",         timepointIndex("TimePoint"), -1);
check("TimePoint_1_old",   timepointIndex("TimePoint_1_old"), -1);
check("TimePoint_two",     timepointIndex("TimePoint_two"), -1);
check("BaSiC_Stitch_Output", timepointIndex("BaSiC_Stitch_Output"), -1);
check("Plate_1",           timepointIndex("Plate_1"), -1);
check("empty",             timepointIndex(""), -1);

// ---- sortTimepointsByNumber ---------------------------------------------
// The case the whole function exists for: 10 must not sort before 2.
names = newArray("TimePoint_10", "TimePoint_2", "TimePoint_1", "TimePoint_21");
idx = newArray(10, 2, 1, 21);
sortTimepointsByNumber(names, idx, 4);
check("sorted names", String.join(names, ","),
      "TimePoint_1,TimePoint_2,TimePoint_10,TimePoint_21");
check("sorted idx", String.join(idx, ","), "1,2,10,21");

// Already ordered, reversed, and single element.
n2 = newArray("a", "b"); i2 = newArray(1, 2);
sortTimepointsByNumber(n2, i2, 2);
check("already sorted", String.join(i2, ","), "1,2");
n3 = newArray("a", "b", "c"); i3 = newArray(9, 5, 1);
sortTimepointsByNumber(n3, i3, 3);
check("reversed", String.join(i3, ","), "1,5,9");
n4 = newArray("only"); i4 = newArray(1); i4[0] = 3;
sortTimepointsByNumber(n4, i4, 1);
check("single", String.join(i4, ","), "3");

// ---- applyTimepointRange ------------------------------------------------
// Folder numbers are 1,2,5,10 - deliberately not 1..n, so that a number in the
// range refers to the folder name and not to a position in the list.
tpIdx = newArray(1, 2, 5, 10);

sel = newArray(4);
err = applyTimepointRange("5", tpIdx, 4, sel);
check("single err", err, "");
check("single pick", String.join(sel, ","), "0,0,1,0");

sel = newArray(4);
applyTimepointRange("1-2", tpIdx, 4, sel);
check("range pick", String.join(sel, ","), "1,1,0,0");

sel = newArray(4);
applyTimepointRange("1,10", tpIdx, 4, sel);
check("list pick", String.join(sel, ","), "1,0,0,1");

sel = newArray(4);
applyTimepointRange("1-10", tpIdx, 4, sel);
check("wide range", String.join(sel, ","), "1,1,1,1");

// A reversed range is accepted rather than silently selecting nothing.
sel = newArray(4);
applyTimepointRange("10-1", tpIdx, 4, sel);
check("reversed range", String.join(sel, ","), "1,1,1,1");

// Overlapping tokens must not cancel each other out.
sel = newArray(4);
applyTimepointRange("1-5,2", tpIdx, 4, sel);
check("overlapping", String.join(sel, ","), "1,1,1,0");

// A previous selection is cleared before the list is applied.
sel = newArray(4);
sel[0] = true; sel[1] = true; sel[2] = true; sel[3] = true;
applyTimepointRange("5", tpIdx, 4, sel);
check("clears previous", String.join(sel, ","), "0,0,1,0");

// Errors come back as messages, so the caller decides what to do.
sel = newArray(4);
err = applyTimepointRange("abc", tpIdx, 4, sel);
reported = 0; if (lengthOf(err) > 0) reported = 1;
check("bad token reports", reported, 1);
err = applyTimepointRange("3", tpIdx, 4, sel);
reported = 0; if (lengthOf(err) > 0) reported = 1;
check("absent folder reports", reported, 1);
err = applyTimepointRange("1-", tpIdx, 4, sel);
reported = 0; if (lengthOf(err) > 0) reported = 1;
check("trailing dash reports", reported, 1);
err = applyTimepointRange("4-9", tpIdx, 4, sel);
check("range hitting only 5", err, "");
check("range hitting only 5 pick", String.join(sel, ","), "0,0,1,0");

if (failures == 0)
    print("ALL MACRO CHECKS PASSED");
else
    print("MACRO CHECK FAILURES: " + failures);
'''


def behavioural_checks(raw, ij_jar):
    program = HARNESS + '\n\n' + extract(raw, TESTED) + '\n'
    with tempfile.TemporaryDirectory() as td:
        script = Path(td) / 'check.ijm'
        script.write_text(program, encoding='utf-8')
        r = subprocess.run(
            ['java', '-Djava.awt.headless=true', '-cp', ij_jar, 'ij.ImageJ',
             '--headless', '-batch', str(script)],
            capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    tail = [l for l in out.split('\n')
            if l.startswith(('ok ', 'FAIL', 'ALL MACRO', 'MACRO CHECK'))]
    for line in tail:
        if line.startswith(('FAIL', 'MACRO CHECK')):
            print(line)
    if 'ALL MACRO CHECKS PASSED' not in out:
        # ImageJ reports a macro error by opening a dialog, so a runtime error
        # in a headless run surfaces as java.awt.HeadlessException. The stack
        # trace names the construct that failed (doWhile, getExpression, ...),
        # which is usually enough to locate it.
        if 'HeadlessException' in out:
            print('the macro aborted; ImageJ shows macro errors in a dialog, '
                  'so the real error appears only as HeadlessException. The '
                  'frames below name the failing construct.')
        print(out[-3000:])
        raise SystemExit('behavioural checks did not pass')
    print('behavioural checks passed (%d assertions, real ImageJ interpreter)'
          % sum(1 for l in tail if l.startswith('ok ')))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--ij-jar', default=os.environ.get('IJ_JAR'))
    a = ap.parse_args()

    raw = MACRO.read_text(encoding='utf-8')
    print('macro: %s' % MACRO.name)
    static_checks(raw)

    if a.ij_jar and Path(a.ij_jar).is_file():
        behavioural_checks(raw, a.ij_jar)
    else:
        print('behavioural checks SKIPPED: no ImageJ jar. Set IJ_JAR or pass '
              '--ij-jar to run the helper functions through the real macro '
              'interpreter.')
    print('BaSiC stitcher checks passed')


if __name__ == '__main__':
    main()
