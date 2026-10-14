#!/usr/bin/env python3
"""Score Scratch_Assay_Measurements.csv against the synthetic ground truth.

Standard library only.

    python3 benchmark/score_against_truth.py \
        --truth benchmark/dataset/ground_truth.csv \
        --measured Scratch_Assay_Results/Scratch_Assay_Measurements.csv

Reports bias and error per series and overall, flags the mistakes that are easy
to make when setting the run up, and exits non-zero if a tolerance is exceeded
so it can gate a regression check.

Which columns to trust
----------------------
Width is the robust comparison. A wound spanning the whole frame has the same
width on every scan line whether or not the analysis field clips some of those
lines away, so Mean_Width_px is comparable even at the default 90% field.

Area and length are *not*: a 90% field removes 10% of the scan lines and so
10% of the area and length. Run the benchmark with **Analysis field = 100**, or
read the area and length columns as lower bounds. The report says so when it
sees that pattern rather than leaving you to work it out.
"""

import argparse
import csv
import math
import sys
from pathlib import Path


def key(name):
    """Match on the image name without extension, case-insensitively.

    QuPath may present an image as "a.png", "a" or with a stage label, so the
    join should not hinge on the exact spelling.
    """
    n = (name or '').strip().strip('"')
    return n.rsplit('.', 1)[0].lower() if '.' in n else n.lower()


def num(row, *names):
    for n in names:
        if n in row:
            v = (row[n] or '').strip().strip('"')
            if v in ('', 'NA', 'nan', 'NaN'):
                return None
            try:
                return float(v)
            except ValueError:
                return None
    return None


def text(row, *names):
    for n in names:
        if n in row:
            return (row[n] or '').strip().strip('"')
    return ''


def load(path):
    with open(path, newline='') as fh:
        return list(csv.DictReader(fh))


class Acc:
    """Signed bias, absolute error and the worst case, in one pass."""

    def __init__(self, label, unit=''):
        self.label, self.unit = label, unit
        self.d, self.rel = [], []
        self.worst = None

    def add(self, image, truth, measured):
        if truth is None or measured is None:
            return
        d = measured - truth
        self.d.append(d)
        if abs(truth) > 1e-9:
            self.rel.append(100.0 * d / truth)
        if self.worst is None or abs(d) > abs(self.worst[1]):
            self.worst = (image, d, truth, measured)

    @property
    def n(self):
        return len(self.d)

    def line(self):
        if not self.d:
            return '%-18s no comparable rows' % self.label
        bias = sum(self.d) / self.n
        mae = sum(abs(v) for v in self.d) / self.n
        relbias = (sum(self.rel) / len(self.rel)) if self.rel else float('nan')
        relmae = (sum(abs(v) for v in self.rel) / len(self.rel)) if self.rel else float('nan')
        return ('%-18s n=%-4d bias=%+9.2f%-4s (%+6.1f%%)  MAE=%8.2f%-4s (%5.1f%%)'
                % (self.label, self.n, bias, self.unit, relbias, mae, self.unit, relmae))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--truth', default='benchmark/dataset/ground_truth.csv')
    p.add_argument('--measured', required=True)
    p.add_argument('--max-width-error-pct', type=float, default=10.0,
                   help='fail if mean |width error| exceeds this (default 10)')
    p.add_argument('--max-width-bias-pct', type=float, default=10.0,
                   help='fail if the signed width bias exceeds this (default 10)')
    p.add_argument('--per-image', action='store_true', help='list every row')
    p.add_argument('--min-true-width', type=float, default=20.0,
                   help='exclude wounds narrower than this from the aggregate '
                        'percentages and report them separately (default 20px). '
                        'A percentage error on a nearly closed wound says more '
                        'about the denominator than about the measurement.')
    a = p.parse_args(argv)

    truth_rows = load(a.truth)
    measured_rows = load(a.measured)
    truth = {key(r.get('Image')): r for r in truth_rows}
    measured = {key(r.get('Image')): r for r in measured_rows}

    print('truth    %s  (%d rows)' % (a.truth, len(truth_rows)))
    print('measured %s  (%d rows)' % (a.measured, len(measured_rows)))

    missing = sorted(set(truth) - set(measured))
    extra = sorted(set(measured) - set(truth))
    if missing:
        print('\n%d ground-truth image(s) absent from the measurements, e.g. %s'
              % (len(missing), ', '.join(missing[:5])))
    if extra:
        print('%d measured image(s) not in the ground truth, e.g. %s'
              % (len(extra), ', '.join(extra[:5])))

    shared = [k for k in truth if k in measured]
    if not shared:
        print('\nNothing to compare: no image names matched. The ground truth '
              'uses names like "vertical_fast_t00h"; check the project imported '
              'benchmark/dataset/images.')
        return 2

    overall = {'width': Acc('Mean width', 'px'), 'median': Acc('Median width', 'px'),
               'area': Acc('Wound area', 'px2'), 'length': Acc('Scratch length', 'px')}
    by_series = {}
    notes, rows, nearly_closed, length_ratios = [], [], [], []

    for k in sorted(shared):
        t, m = truth[k], measured[k]
        series = t.get('Series', '?')
        acc = by_series.setdefault(series, {
            'width': Acc('Mean width', 'px'), 'area': Acc('Wound area', 'px2')})

        tw = num(t, 'True_Mean_Width_px')
        mw = num(m, 'Mean_Width_px')
        tmed, mmed = num(t, 'True_Median_Width_px'), num(m, 'Median_Width_px')
        ta, ma = num(t, 'True_Gap_Area_px2'), num(m, 'Wound_Area_px2')
        tl, ml = num(t, 'True_Scratch_Length_px'), num(m, 'Scratch_Length_px')

        # A wound a few pixels wide makes every percentage meaningless, so hold
        # those rows out of the aggregate and judge them on detection instead.
        if tw is not None and tw < a.min_true_width:
            nearly_closed.append((k, series, tw, mw, text(m, 'Detection_Status')))
        else:
            for store in (overall, acc):
                if 'width' in store:
                    store['width'].add(k, tw, mw)
                if 'area' in store:
                    store['area'].add(k, ta, ma)
            overall['median'].add(k, tmed, mmed)
            overall['length'].add(k, tl, ml)

        # Setup mistakes worth naming rather than letting them look like error.
        t_or, m_or = t.get('Orientation', ''), text(m, 'Orientation')
        if m_or and t_or and m_or.lower() != t_or.lower():
            notes.append('%s: measured as %s but the wound is %s - the width and '
                         'length columns are swapped for this image'
                         % (k, m_or, t_or))
        if text(m, 'Restricted').upper() == 'YES':
            notes.append('%s: measured with a Restrict region, so area and '
                         'Percent_Open are not on the same basis as the truth' % k)
        if tl and ml and ml < 0.97 * tl:
            # A uniform shortfall across the set means the analysis field is
            # clipping scan lines; a one-off means the detected wound simply
            # did not reach the edges. Guessing between them per row produces
            # false alarms, so record the ratio and judge it in aggregate.
            length_ratios.append((k, ml / tl))
        det = text(m, 'Detection_Status').upper()
        if det == 'NOT_FOUND' and ta and ta > 0:
            notes.append('%s: nothing detected, but the wound is %.0f px2' % (k, ta))
        if det == 'FOUND' and ta is not None and ta == 0:
            notes.append('%s: a wound was reported where the truth is fully '
                         'closed (false positive)' % k)

        rows.append((k, series, tw, mw, ta, ma))

    if a.per_image:
        print('\n%-28s %-18s %9s %9s %7s %11s %11s %7s'
              % ('image', 'series', 'true W', 'meas W', 'err%', 'true area', 'meas area', 'err%'))
        for (k, series, tw, mw, ta, ma) in rows:
            we = 100 * (mw - tw) / tw if (tw and mw is not None and tw > 0) else float('nan')
            ae = 100 * (ma - ta) / ta if (ta and ma is not None and ta > 0) else float('nan')
            print('%-28s %-18s %9s %9s %7s %11s %11s %7s'
                  % (k, series,
                     '%.1f' % tw if tw is not None else 'NA',
                     '%.1f' % mw if mw is not None else 'NA',
                     '%.1f' % we if we == we else 'NA',
                     '%.0f' % ta if ta is not None else 'NA',
                     '%.0f' % ma if ma is not None else 'NA',
                     '%.1f' % ae if ae == ae else 'NA'))

    print('\nPer series (mean width):')
    for series in sorted(by_series):
        print('  %-20s %s' % (series, by_series[series]['width'].line()))

    print('\nOverall:')
    for name in ('width', 'median', 'area', 'length'):
        print('  ' + overall[name].line())
    for name in ('width', 'area'):
        wst = overall[name].worst
        if wst:
            print('  worst %-14s %s  true=%.1f measured=%.1f (%+.1f)'
                  % (name, wst[0], wst[2], wst[3], wst[1]))

    if length_ratios:
        ratios = sorted(r for _k, r in length_ratios)
        med = ratios[len(ratios) // 2]
        worst_image, worst_ratio = min(length_ratios, key=lambda kr: kr[1])
        print('\n%d of %d image(s) have a scratch shorter than the truth '
              '(median %.0f%% of it).'
              % (len(length_ratios), len(shared), 100 * med))
        if ratios[-1] - ratios[0] < 0.06:
            print('  The shortfall is uniform, which is what a clipping '
                  'analysis field looks like. Re-run with Analysis field = 100 '
                  'before trusting the area or length columns.')
        else:
            print('  The shortfall varies between images, so this is the '
                  'detected wound not reaching the frame edges rather than a '
                  'field setting. Worst: %s at %.0f%%.'
                  % (worst_image, 100 * worst_ratio))

    if nearly_closed:
        print('\nNearly closed (true width < %gpx), held out of the aggregate:'
              % a.min_true_width)
        for (k, series, tw, mw, det) in nearly_closed:
            print('  %-28s true %5.1fpx  measured %s  %s'
                  % (k, tw, ('%.1fpx' % mw) if mw is not None else 'NA', det))
        print('  A much larger measured width here means a spurious wound was '
              'found in a closed sheet.')

    if notes:
        print('\nNotes (%d):' % len(notes))
        for n in notes[:40]:
            print('  - ' + n)
        if len(notes) > 40:
            print('  ... and %d more' % (len(notes) - 40))

    acc_w = overall['width']
    if not acc_w.n:
        print('\nFAIL: no width comparisons were possible.')
        return 2
    bias = sum(acc_w.rel) / len(acc_w.rel) if acc_w.rel else 0.0
    mae = sum(abs(v) for v in acc_w.rel) / len(acc_w.rel) if acc_w.rel else 0.0
    ok = abs(bias) <= a.max_width_bias_pct and mae <= a.max_width_error_pct
    print('\n%s  width bias %+.1f%% (limit +-%.1f%%), mean |error| %.1f%% (limit %.1f%%)'
          % ('PASS:' if ok else 'FAIL:', bias, a.max_width_bias_pct,
             mae, a.max_width_error_pct))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
