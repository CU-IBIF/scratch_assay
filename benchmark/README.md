# Synthetic phase-contrast benchmark

A generated scratch assay time series with exact ground truth, for validating
`qupath/ScratchAssayAnalyzer.groovy` against known answers rather than against
eyeballing.

Everything here is standard-library Python, so it runs wherever QuPath does
without a `pip install`.

```bash
# 1. make the dataset (about 2-3 minutes for the defaults)
python3 benchmark/generate_synthetic.py --out benchmark/dataset

# 2. import benchmark/dataset/images into a QuPath project and run the
#    analyzer over it (see "Running the analyzer on it" below)

# 3. score the run
python3 benchmark/score_against_truth.py \
    --measured .../Scratch_Assay_Results/Scratch_Assay_Measurements.csv
```

The dataset is reproducible from its seed and is **not** tracked in git;
`benchmark/dataset/` is ignored.

## What the images model

Phase contrast does not image absorption, it images phase *gradients*. That is
the whole reason this assay is hard, so the generator models it rather than
drawing a dark band on a light background.

1. **Optical path map.** Bare substrate in the wound is flat, `phi = 0`. The
   cell sheet is a jittered grid of smooth lenses, one per cell, each with a
   denser nucleus, dense enough to be confluent but granular.

2. **Phase-contrast transfer.** `phi` is convolved with a difference-of-Gaussians
   point spread function whose weights make it integrate to roughly zero, and
   added to a uniform background. Both signature artifacts fall out of that:

   - **halo** - a bright rim just outside a phase object, so the wound edge glows;
   - **shade-off** - the interior of a large uniform object drifts back toward
     background, so neither the middle of the sheet nor the middle of a wide
     wound carries much signal.

   The consequence that matters: **the sheet and the wound differ in texture,
   not in brightness.** Mean intensity across a frame is nearly flat. That is
   the cue the analyzer thresholds, and the cue a plain intensity threshold
   misses entirely.

3. **Microscope reality.** Smooth uneven illumination (vignette plus a slow
   tilt), slight defocus, shot noise scaled by signal, Gaussian read noise,
   quantised to 8-bit.

The wound is defined *before* any optics are applied - a band between two
migrating fronts, minus any debris cells in it - so the truth is exact by
construction, not annotated. The halo then deliberately spills across that
boundary. Recovering the true edge in spite of the halo is the thing being
validated.

## Series

`python3 benchmark/generate_synthetic.py --list`

| Series | What it is for |
|---|---|
| `vertical_fast` | Closes fully within the time course |
| `vertical_slow` | Still open at the last time point |
| `vertical_static` | Negative control: no migration, so the width must not drift |
| `vertical_narrow` | Narrow wound, near the minimum-area cutoff |
| `horizontal_medium` | The same wound rotated; exercises the orientation setting |
| `vertical_debris` | Detached cells in the wound; exercises fill holes |
| `vertical_shading` | Strong uneven illumination; exercises robustness |

Nine time points each (0-24 h), 480x360 by default. `--width`, `--height`,
`--hours`, `--series` and `--seed` all override. Larger images are slower
roughly in proportion to pixel count.

## Ground truth

`ground_truth.csv`, one row per image, keyed by file name:

| Column | Meaning |
|---|---|
| `Image`, `Series`, `Time_h`, `Orientation` | Identity |
| `True_Gap_Area_px2` | Wound pixels |
| `True_Scratch_Length_px` | Extent along the scratch |
| `True_Mean_Width_px`, `True_Median_Width_px`, `True_Width_SD_px`, `True_Width_Samples` | Per-scan-line widths, measured exactly as the analyzer measures them |
| `True_Percent_Open` | Wound as a percentage of the **whole frame** |
| `Nominal_Gap_Width_px`, `Closure_Rate_px_per_h`, `Debris_Cells`, `Shading` | The parameters that produced the frame |

`True_*` statistics mirror `ScratchAssayAnalyzer.measurements` line for line, so
a disagreement is a real disagreement and not a definitional one.

## Running the analyzer on it

1. New QuPath project, **Add images** -> `benchmark/dataset/images`.
2. Run `qupath/ScratchAssayAnalyzer.groovy`.
3. In the dialog:
   - **Analysis field (%) = 100.** The default 90 clips 10% of the scan lines
     and therefore 10% of the area and length. Width is unaffected either way,
     but area and length are only comparable at 100.
   - Set the `horizontal_medium` rows to **Horizontal** (the **All horizontal**
     button, after ticking only those). Everything else is vertical.
   - Leave the rest at defaults for a baseline.

### Which columns to trust

**Width is the robust comparison.** A wound spanning the frame has the same
width on every scan line whether or not some of those lines are clipped away,
so `Mean_Width_px` is comparable regardless of the analysis field. Area and
length are proportional to the number of scan lines, so they are only
comparable at a 100% field. The scorer says so when it sees that pattern
instead of leaving you to work it out.

## Headless shortcut

To score the segmentation without launching QuPath:

```bash
python3 benchmark/run_reference_pipeline.py --dataset benchmark/dataset
python3 benchmark/score_against_truth.py --measured benchmark/dataset/reference_measurements.csv
```

This lifts the Groovy helper functions out of `ScratchAssayAnalyzer.groovy` at
run time and executes them verbatim, so the **algorithm** is the real one and
cannot drift from it. The **orchestration** is mirrored rather than shared,
because `analyseImage` is welded to QuPath's project and server objects: the
sequence tracks that method step for step, but a change to its order of
operations needs mirroring here too. A real QuPath run stays the authoritative
check; this is the fast one. Needs `groovy` on `PATH`, or `--groovy-jar`.

## Measured result: the analyzer over-segments this dataset

Scored over the default 63-image dataset with `run_reference_pipeline.py`,
mean width against truth, nearly closed frames held out:

| Settings | Width bias | Mean abs. error |
|---|---|---|
| Defaults (second pass on, band 20) | +421% | 421% |
| Second pass off | +395% | 395% |

Measured widths come back around 470 px on a 480 px-wide frame: the analyzer is
selecting a component that spans almost the whole field. The second pass adds
roughly 30 px on top of that, so it is a real but secondary effect.

**The data is not the problem.** On a benchmark frame, an oracle threshold -
the single best cut on the same texture map - misclassifies only **3.7%** of
the frame. The images are highly separable; it is the choice of threshold that
fails.

### Cause: `otsu` is thresholding the wrong quantity

`otsu` is given the raw local variance map. The wound forms a tight class near
zero, but the sheet's class is broad and heavy-tailed, which breaks Otsu's
assumption of two compact classes and puts the cut far too high. On one frame:

| What `otsu` is given | Cut | % of frame misclassified |
|---|---|---|
| Linear variance (what the script does) | 132 | **33.8%** |
| Standard deviation (sqrt) | 9.05 | 9.2% |
| `log(1 + variance)` | about 60 | **4.1%** |
| Oracle best cut | about 50 | 3.7% |

Thresholding `log(1 + variance)` is near-optimal, which is unsurprising: the
local variance of a textured field is roughly chi-square distributed and its
log is roughly Gaussian, which is the shape Otsu expects.

Two consequences worth knowing:

- The error depends on **how much of the field the wound occupies**, because
  that sets the class balance Otsu sees. A wound filling 60% of a small frame
  measures far better than the same wound filling 30% of a larger one. So
  measurements are sensitive to field of view and magnification.
- It is **not** an artifact of this appearance model's granularity. An earlier
  version of the generator with much smoother cells failed the same way
  (+90 px on the static control at the same frame size); dense cytoplasmic
  granularity, which is what real phase contrast shows, makes it worse by
  broadening the sheet's variance distribution further.

Reproduce, including the proposed fix:

```bash
python3 benchmark/run_reference_pipeline.py --out /tmp/default.csv
python3 benchmark/run_reference_pipeline.py --no-second-pass --out /tmp/sp_off.csv
python3 benchmark/run_reference_pipeline.py --experimental-log-variance \
        --no-second-pass --out /tmp/log.csv
for f in default sp_off log; do
  python3 benchmark/score_against_truth.py --measured /tmp/$f.csv | tail -3
done
```

`--experimental-log-variance` is **not** what `ScratchAssayAnalyzer.groovy`
does. It exists so the proposal can be measured before anyone changes the
script, since changing it moves every number the script has ever produced.

### Also: a closed wound still reports one

`vertical_fast` and `vertical_narrow` close to a few pixels by the last time
points, and the analyzer reports a full-frame wound for those frames rather
than nothing. Otsu always returns a cut, even on a unimodal texture map, so
there is no "is there a wound at all?" test. The scorer lists these separately
rather than letting a percentage error on a six-pixel wound dominate the
summary.

## Limits of this benchmark

- It validates **segmentation and measurement** against a known wound. It does
  not validate QuPath I/O, the dialog, annotation writing, or the pixel
  classifier path.
- The cell appearance model is a plausible caricature, not a physical optics
  simulation. It reproduces halo, shade-off and texture contrast; it does not
  model objective NA, condenser annulus geometry or true partial coherence. An
  analyzer that passes here can still be surprised by real imagery.
- Agreement is only meaningful against *this* appearance model. Treat the
  numbers as a regression baseline and a relative comparison between settings,
  not an absolute accuracy claim about your microscope.
- Human-annotated ground truth on real images remains the stronger validation.
  This is the cheap, exactly-known complement to it, not a replacement.
