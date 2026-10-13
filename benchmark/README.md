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

## Measured result

Scored over the default 63-image dataset with `run_reference_pipeline.py`,
mean width against truth, nearly closed frames held out:

| Analyzer | Settings | Width bias | Mean abs. error |
|---|---|---|---|
| Before the fixes | defaults | +421% | 421% |
| Before the fixes | second pass off | +395% | 395% |
| **Current** | **defaults** | **+6.8%** | **7.9%** |
| Current | second pass off | -6.5% | 13.6% |

Per series at current defaults:

| Series | Width bias | Mean abs. error |
|---|---|---|
| `vertical_slow` | -0.2% | **1.5%** |
| `vertical_static` | +1.6% | **1.7%** |
| `horizontal_medium` | -0.2% | **1.8%** |
| `vertical_shading` | -0.3% | **2.3%** |
| `vertical_debris` | +5.7% | 5.7% |
| `vertical_fast` | +22.4% | 22.7% (late frames are narrow) |
| `vertical_narrow` | +76.9% | 76.9% (only 2 frames survive, see below) |

Four series - including one with heavy uneven illumination and one with debris
in the gap - are measured to within **2.3%**. That is the benchmark's main
result: on wounds the method can resolve, it is accurate.

### Leave the second pass on, now

This reverses the earlier advice in this file. Before the log-variance fix the
second pass was clearly harmful; now the defaults beat second-pass-off (7.9%
against 13.6%).

Be clear about why, though, because it is **two biases cancelling, not two
improvements**:

- a texture threshold sits slightly *inside* the true edge, because the halo is
  a steep intensity gradient and the boundary pixels therefore have high local
  variance and read as sheet. Alone this is about -11 px, roughly 5-6 px per
  edge.
- the second pass pulls the boundary *outward*, because the halo itself is a
  smooth bright rim and reads as low-texture. At band 20 this is about +15 px.

Net, on this dataset, roughly +4 px. The cancellation is not a law of nature:
it depends on the halo width, which depends on the optics. If you change
objective or camera, re-run the benchmark rather than assuming the default band
still happens to cancel. Report the numbers from whichever setting you
validated.

### The resolution floor: narrow wounds are refused, not guessed

The wound-presence test rejects 9 of 63 frames. The rejections are not
arbitrary - the texture ratio tracks wound width closely:

| True width | Texture ratio | Outcome |
|---|---|---|
| 45.0, 40.7, 40.3 px | 2.83, 2.66, 2.66 | kept |
| 36.2 px | 2.46 | rejected |
| 31.7, 27.2 px | 2.24, 1.83 | rejected |
| 22.8, 22.1, 18.3 px | 1.70, 1.90, 1.65 | rejected |
| 13.9, 10.3, 6.6 px | 1.65, 1.75, 1.56 | rejected |

There is **no clean gap** between a genuinely closed wound (6.6 px, ratio 1.56)
and a real but narrow one (22.8 px, ratio 1.70), so the test is not really a
wound-existence test. It is a *can this be measured* test, and it fails for the
same underlying reason in both cases: with a variance radius of 5 the texture
map's support is about +-7 px, so a gap narrower than roughly 40 px has no
pixel whose neighbourhood is purely wound, and its interior reads as
contaminated sheet.

**Shrinking the texture scale does not help.** Re-running `vertical_narrow`
with variance radius 2 and smoothing 1 rejects *every* frame, at a flat ratio
near 2.0: a small neighbourhood cannot characterise the sheet's texture either,
so the contrast collapses from the other side. The radius has to span a cell to
describe the sheet, and that sets a floor on the wound it can resolve - roughly
**three cell diameters**.

In practice that floor lands where it matters least. A real scratch starts
15-25 cell diameters wide, so the floor is only reached near full closure,
which is where you would want to report "closed" anyway. `vertical_narrow`
starts at 45 px, about 3.5 cell diameters - deliberately below what any real
assay would use, because its job is to find the floor. It did.

The useful behaviour is that the analyzer **refuses** rather than reporting a
confident wrong number, and exports `Sheet_Wound_Texture_Ratio` so you can see
how close to the floor each image sits.

### Tuning the presence test

The default minimum ratio of 2.5 sits exactly at the knee for *this* dataset
(kept frames are at 2.66 and above, rejected ones at 2.46 and below). That
calibration is against a synthetic appearance model, so check it against your
own imagery: run with `--min-texture-ratio 0` to disable the test, look at the
exported ratios for images you trust, and set the threshold below them.

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
