#!/usr/bin/env python3
"""Run the analyzer's segmentation over the synthetic dataset, without QuPath.

    python3 benchmark/run_reference_pipeline.py --dataset benchmark/dataset
    python3 benchmark/run_reference_pipeline.py --no-second-pass --out ref_nosp.csv

Writes a CSV in the same shape as Scratch_Assay_Measurements.csv, so
score_against_truth.py scores it exactly as it scores a real QuPath run. That
makes the benchmark usable as a regression check without launching the GUI.

How much of the real thing this is
----------------------------------
The *algorithm* is the real one: the Groovy helper functions are lifted out of
qupath/ScratchAssayAnalyzer.groovy at run time and executed verbatim, so there
is one copy of the maths and this cannot drift from it.

The *orchestration* is mirrored, not shared, because analyseImage is welded to
QuPath's project and server objects. The sequence below tracks analyseImage
step for step, but a change to that method's order of operations would need
mirroring here. A real QuPath run remains the authoritative check; this is the
fast one.

Requires Groovy: `groovy` on PATH, or point --groovy-jar at a groovy jar and
Java will be used directly.
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# The pure-computation helpers this harness borrows. Anything touching QuPath
# types (replaceGeneratedAnnotation, classifierMask, the dialog) is excluded.
HELPERS = [
    'isHorizontal', 'luminance', 'boxSum', 'localVariance', 'gaussian', 'otsu',
    'morphology', 'dilate', 'erode', 'flood', 'largestComponent', 'fillHoles',
    'measurements', 'maskExtent', 'scanRuns', 'textureMap', 'textureRatio',
    'maskBelow', 'addBelow', 'andMask',
]

DEF_RE = re.compile(
    r'^(?:[A-Za-z_][\w.\[\]<>]*(?:\[\])?\s+)?(?P<name>[A-Za-z_]\w*)\s*\(')


def extract_helpers(groovy_source, names):
    """Pull named top-level function definitions out of the Groovy script.

    Walks from each definition's opening brace to its matching close, ignoring
    braces inside strings, comments and GStrings, so a function body with a
    regex or a quoted brace in it still ends where it really ends.
    """
    text = groovy_source.read_text(encoding='utf-8')
    lines = text.split('\n')
    found, missing = {}, []
    for want in names:
        start = None
        for i, line in enumerate(lines):
            m = DEF_RE.match(line)
            if m and m.group('name') == want:
                start = i
                break
        if start is None:
            missing.append(want)
            continue
        # Carry any annotations immediately above the signature: @CompileStatic
        # is what makes these run at a sane speed, and dropping it would mean
        # the harness is not running the same code the analyzer does.
        head = start
        while head > 0 and lines[head - 1].strip().startswith('@'):
            head -= 1
        # Then the doc comment above that, for readability.
        if head > 0 and lines[head - 1].strip().startswith('*/'):
            j = head - 1
            while j > 0 and not lines[j].strip().startswith('/**'):
                j -= 1
            head = j
        depth, end, started = 0, None, False
        for i in range(start, len(lines)):
            net, opens = _scan_braces(lines[i])
            depth += net
            if opens:
                started = True
            # A one-line body opens and closes on the same line, so the test
            # has to be "an opening brace was seen", not "depth went positive".
            if started and depth <= 0:
                end = i
                break
        if end is None:
            missing.append(want)
            continue
        found[want] = (head, end)
    if missing:
        raise SystemExit('could not extract from %s: %s'
                         % (groovy_source, ', '.join(missing)))
    seen, blocks = set(), []
    for n in names:
        span = found[n]
        if span in seen:
            continue
        seen.add(span)
        blocks.append('\n'.join(lines[span[0]:span[1] + 1]))
    return '\n\n'.join(blocks)


def _scan_braces(line):
    """(net depth change, number of opening braces) outside strings/comments."""
    depth, opens, i, n = 0, 0, 0, len(line)
    while i < n:
        c = line[i]
        if c == '/' and i + 1 < n and line[i + 1] == '/':
            break
        if c in '\'"':
            quote, i = c, i + 1
            while i < n:
                if line[i] == '\\':
                    i += 2
                    continue
                if line[i] == quote:
                    break
                i += 1
        elif c == '/' and i + 1 < n and line[i + 1] == '*':
            i += 2
            while i + 1 < n and not (line[i] == '*' and line[i + 1] == '/'):
                i += 1
            i += 1
        elif c == '{':
            depth += 1
            opens += 1
        elif c == '}':
            depth -= 1
        i += 1
    return depth, opens


HARNESS = r'''
import groovy.transform.CompileStatic

import javax.imageio.ImageIO
import java.awt.image.BufferedImage
import java.nio.file.*
import java.nio.charset.StandardCharsets
import java.text.DecimalFormat

// Mirrors ScratchAssayAnalyzer.analyseImage step for step. The helpers it
// calls are the script's own, appended below.
def analyse = { BufferedImage src, boolean vertical, Map cfg ->
    int w = src.width, h = src.height
    float[] gray = luminance(src)
    int mx = Math.round(w*(100d-cfg.analysisPercent)/200d) as int
    int my = Math.round(h*(100d-cfg.analysisPercent)/200d) as int
    boolean[] field = new boolean[w*h]
    for (int y=my; y<h-my; y++) Arrays.fill(field, y*w+mx, y*w+(w-mx), true)
    long fieldArea = field.count(true)

    float[] texLog = textureMap(gray,w,h,cfg.varianceRadius as int,cfg.smoothSigma as double)
    // legacyLinear undoes the log transform to reproduce the pre-fix behaviour
    // for comparison. The presence test always uses the log map, whose mean
    // difference is a log ratio.
    float[] texThr = texLog
    if (cfg.legacyLinear) {
        texThr = new float[texLog.length]
        for (int i=0;i<texThr.length;i++) texThr[i] = (float)Math.expm1(texLog[i])
    }
    double cut1 = otsu(texThr, field)
    boolean[] pass1 = new boolean[w*h]
    maskBelow(texThr, field, cut1, pass1)
    pass1 = morphology(pass1,w,h,cfg.closeIterations as int,cfg.openIterations as int)

    def selected = largestComponent(pass1,w,h,cfg.minArea as int)
    boolean[] firstMask = selected == null ? new boolean[w*h] : selected.mask
    double ratio = Double.NaN
    String detection = 'FOUND'
    if (selected == null) {
        detection = 'NOT_FOUND'
    } else if ((cfg.minTextureRatio as double) > 0d) {
        ratio = textureRatio(texLog, firstMask, field)
        if (!(ratio >= (cfg.minTextureRatio as double))) {
            selected = null
            firstMask = new boolean[w*h]
            detection = 'REJECTED_LOW_CONTRAST'
        }
    }
    long holes = (selected != null && cfg.fillHoles) ? fillHoles(firstMask,w,h) : 0L
    boolean[] finalMask = firstMask
    double cut2 = Double.NaN
    String refineStatus = cfg.secondPass ? 'NO_COMPONENT' : 'DISABLED'

    if (selected != null && cfg.secondPass) {
        int band = Math.max(1, cfg.refineBand as int)
        boolean[] inner = erode(firstMask,w,h,band), outer = dilate(firstMask,w,h,band)
        boolean[] bandMask = new boolean[w*h]
        for (int i=0;i<bandMask.length;i++) bandMask[i] = outer[i] && !inner[i] && field[i]
        float[] tex2 = textureMap(gray,w,h,cfg.refineVarianceRadius as int,cfg.refineSmoothSigma as double)
        if (cfg.legacyLinear) for (int i=0;i<tex2.length;i++) tex2[i] = (float)Math.expm1(tex2[i])
        cut2 = otsu(tex2, bandMask)
        boolean[] refined = inner
        addBelow(tex2, bandMask, cut2, refined)
        refined = morphology(refined,w,h,cfg.refineCloseIterations as int,cfg.refineOpenIterations as int)
        def best = largestComponent(refined,w,h,1)
        if (best != null) {
            finalMask = best.mask
            if (cfg.fillHoles) holes = fillHoles(finalMask,w,h)
            refineStatus = 'APPLIED'
        } else refineStatus = 'FALLBACK'
    }

    def m = measurements(finalMask,w,h,vertical)
    [area:m.area, length:m.length, meanWidth:m.meanWidth, medianWidth:m.medianWidth,
     widthSD:m.widthSD, samples:m.samples, cx:m.cx, cy:m.cy, holes:holes,
     percentOpen:100d*m.area/Math.max(1L,fieldArea),
     cut1:Math.expm1(cut1), cut2:Math.expm1(cut2), ratio:ratio,
     detection:detection, refinement:refineStatus]
}

// Settings arrive as key=value pairs rather than JSON: groovy-json is a
// separate module and QuPath does not bundle it either.
Map cfg = [:]
args[2].split(';').each { pair ->
    if (!pair) return
    def kv = pair.split('=', 2)
    String v = kv[1]
    cfg[kv[0]] = (v == 'true' || v == 'false') ? Boolean.parseBoolean(v)
               : (v.contains('.') ? Double.parseDouble(v) : Integer.parseInt(v))
}
Path root = Paths.get(args[0])
def d = new DecimalFormat('0.######')
def q = { String s -> '"' + s.replace('"','""') + '"' }
def nf = { v -> (v instanceof Number && Double.isFinite(v as double)) ? d.format(v) : 'NA' }

def lines = root.resolve('ground_truth.csv').toFile().readLines()
def hdr = lines[0].split(',') as List
List out = ['Image,Orientation,Wound_Area_px2,Holes_Filled_px2,Percent_Open,Restricted,' +
            'Scratch_Length_px,Mean_Width_px,Median_Width_px,Width_SD_px,Width_Samples,' +
            'Centroid_X_px,Centroid_Y_px,Pass1_Threshold,Pass2_Threshold,' +
            'Sheet_Wound_Texture_Ratio,Detection_Status,Refinement_Status']
int done = 0
lines[1..-1].collect{ it.split(',') }.sort{ it[hdr.indexOf('Image')] }.each { f ->
    String name = f[hdr.indexOf('Image')]
    String orientation = f[hdr.indexOf('Orientation')]
    BufferedImage im = ImageIO.read(root.resolve('images').resolve(name).toFile())
    if (im == null) { System.err.println("cannot read ${name}"); return }
    def r = analyse(im, !isHorizontal(orientation), cfg)
    out << [q(name), q(orientation), r.area as String, nf(r.holes), nf(r.percentOpen), q('NO'),
            nf(r.length), nf(r.meanWidth), nf(r.medianWidth), nf(r.widthSD), r.samples as String,
            nf(r.cx), nf(r.cy), nf(r.cut1), nf(r.cut2), nf(r.ratio),
            q(r.detection), q(r.refinement)].join(',')
    done++
    if (done % 10 == 0) System.err.println("  ${done} images")
}
Files.write(Paths.get(args[1]), out, StandardCharsets.UTF_8)
println "wrote ${args[1]} (${out.size()-1} rows)"
'''


def find_groovy(explicit_jar):
    jar = explicit_jar or os.environ.get('GROOVY_JAR')
    if jar:
        if not Path(jar).is_file():
            raise SystemExit('no such groovy jar: %s' % jar)
        java = shutil.which('java')
        if not java:
            raise SystemExit('a groovy jar was given but java is not on PATH')
        return [java, '-cp', jar, 'groovy.ui.GroovyMain']
    exe = shutil.which('groovy')
    if exe:
        return [exe]
    raise SystemExit(
        'Groovy not found. Install it (https://groovy.apache.org/download.html) '
        'so `groovy` is on PATH, or pass --groovy-jar /path/to/groovy-4.x.jar.\n'
        'This script only provides the headless shortcut; running the real '
        'QuPath script over benchmark/dataset/images needs neither.')


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--dataset', default='benchmark/dataset')
    p.add_argument('--script', default='qupath/ScratchAssayAnalyzer.groovy')
    p.add_argument('--out', default=None,
                   help='default: <dataset>/reference_measurements.csv')
    p.add_argument('--groovy-jar', default=None)
    # Defaults match the analyzer's dialog, except the analysis field, which is
    # 100 here so area and length are on the same basis as the ground truth.
    p.add_argument('--analysis-percent', type=float, default=100.0)
    p.add_argument('--downsample-note', default='1 (images are read at full size)')
    p.add_argument('--variance-radius', type=int, default=5)
    p.add_argument('--smooth-sigma', type=float, default=2.0)
    p.add_argument('--min-area', type=int, default=5000)
    p.add_argument('--close-iterations', type=int, default=2)
    p.add_argument('--open-iterations', type=int, default=1)
    p.add_argument('--no-fill-holes', action='store_true')
    p.add_argument('--no-second-pass', action='store_true')
    p.add_argument('--refine-band', type=int, default=20)
    p.add_argument('--refine-variance-radius', type=int, default=3)
    p.add_argument('--refine-smooth-sigma', type=float, default=1.0)
    p.add_argument('--refine-close-iterations', type=int, default=1)
    p.add_argument('--refine-open-iterations', type=int, default=0)
    p.add_argument('--min-texture-ratio', type=float, default=2.5,
                   help='reject a proposed wound unless the field outside it is '
                        'this many times more textured (default 2.5, as in the '
                        'analyzer). 0 disables the presence test.')
    p.add_argument('--legacy-linear-variance', action='store_true',
                   help='threshold raw variance instead of log(1+variance), '
                        'reproducing the behaviour from before that fix. For '
                        'measuring what the change bought, not for real use.')
    a = p.parse_args(argv)

    dataset = Path(a.dataset)
    if not (dataset / 'ground_truth.csv').is_file():
        raise SystemExit('no ground_truth.csv under %s - run '
                         'benchmark/generate_synthetic.py first' % dataset)
    out = Path(a.out) if a.out else dataset / 'reference_measurements.csv'
    runner = find_groovy(a.groovy_jar)

    cfg = {
        'analysisPercent': a.analysis_percent,
        'varianceRadius': a.variance_radius, 'smoothSigma': a.smooth_sigma,
        'minArea': a.min_area,
        'closeIterations': a.close_iterations, 'openIterations': a.open_iterations,
        'fillHoles': not a.no_fill_holes, 'secondPass': not a.no_second_pass,
        'refineBand': a.refine_band,
        'refineVarianceRadius': a.refine_variance_radius,
        'refineSmoothSigma': a.refine_smooth_sigma,
        'refineCloseIterations': a.refine_close_iterations,
        'refineOpenIterations': a.refine_open_iterations,
        'minTextureRatio': a.min_texture_ratio,
        'legacyLinear': a.legacy_linear_variance,
    }
    program = HARNESS + '\n\n' + extract_helpers(Path(a.script), HELPERS) + '\n'
    with tempfile.TemporaryDirectory() as td:
        script = Path(td) / 'reference.groovy'
        script.write_text(program, encoding='utf-8')
        encoded = ';'.join(
            '%s=%s' % (k, 'true' if v is True else 'false' if v is False else v)
            for k, v in sorted(cfg.items()))
        cmd = runner + [str(script), str(dataset), str(out), encoded]
        print('settings: %s' % encoded.replace(';', '  '))
        r = subprocess.run(cmd)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
