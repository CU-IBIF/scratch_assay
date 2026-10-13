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

## Known result: the second pass biases outward on phase contrast

Measured over the default dataset, mean width against truth:

| Setting | Width bias | Mean abs. error |
|---|---|---|
| Second pass **off** | about +3% | a few percent |
| Second pass **on**, band 20 (default) | about +35% | about 35% |
| Second pass on, band 10 | about +17% | |
| Second pass on, band 5 | about +10% | |

The cause is structural, not a coding error. The second pass re-thresholds a
band straddling the first boundary using a *finer* variance map. The
phase-contrast halo is a **smooth** bright rim, so it has low local variance
and reads as wound. The wider the refinement band, the more halo gets absorbed,
and the bias scales with the band.

So for phase contrast: **leave the second pass off, or use a band no wider than
the halo** (roughly `sigma_outer` in the model, a handful of pixels). The second
pass was ported from the ImageJ workflow, where it was tuned for different
imagery; this is the benchmark earning its keep by pinning that down with a
number.

Reproduce both sides with:

```bash
python3 benchmark/run_reference_pipeline.py --out /tmp/sp_on.csv
python3 benchmark/run_reference_pipeline.py --no-second-pass --out /tmp/sp_off.csv
python3 benchmark/score_against_truth.py --measured /tmp/sp_off.csv
```

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
