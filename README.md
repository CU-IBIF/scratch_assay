# Scratch Assay Analyzer for QuPath

This repository contains an installable **QuPath Groovy script** that ports the
core workflow from [`macros/Scratch_Assay_Analyzer.ijm`](macros/Scratch_Assay_Analyzer.ijm) to QuPath. It segments the
low-texture gap in phase-contrast images, creates wound annotations, and exports
measurements and QC images.

Every image is measured **independently**. The script does no frame tracking and
has no notion of elapsed time, so results are keyed by image name and can be
joined to whatever experimental design you keep elsewhere.

## Requirements

- QuPath 0.5.x or 0.6.x
- A QuPath project containing the images to measure
- Java 17 or newer (included with normal QuPath distributions)

No ImageJ or third-party QuPath extension is required for the analyzer.
[`macros/Scratch_Assay_Analyzer.ijm`](macros/Scratch_Assay_Analyzer.ijm) is retained as the reference implementation it was
ported from.

[`macros/BaSiC_Batch_Tile_Stitcher_v1.3.ijm`](macros/BaSiC_Batch_Tile_Stitcher_v1.3.ijm) is a separate Fiji preprocessing macro:
it flat-field corrects tiles with BaSiC and stitches them into one image per
well. Point it at a parent folder of `TimePoint_1 ... TimePoint_n` subfolders
and tick which to process, or at a single folder of tiles as before. Each time
point is corrected on its own tiles, so illumination drift between
acquisitions is not blurred into one shared shading profile.

## Fiji / ImageJ macros

The [`macros/` directory](macros/) contains four Fiji/ImageJ macros.
They complement the QuPath analyzer and support tile preprocessing, scratch
measurement, and time-lapse visualization:

| Macro | Purpose | Typical input → output |
| --- | --- | --- |
| [BaSiC tile stitcher v1.3](macros/BaSiC_Batch_Tile_Stitcher_v1.3.ijm) | **Recommended stitcher:** apply BaSiC flat-field correction separately at each selected timepoint, then stitch tiles into a fused image per well. | `TimePoint_n/` with `rootname_A01_s1.tif` tiles → `BaSiC_Stitch_Output/TimePoint_n/<well>/Corrected_Tiles/` and `Fused/` |
| [BaSiC tile stitcher v1.2](macros/BaSiC_Batch_Tile_Stitcher_v1.2.ijm) | Earlier iteration of the BaSiC + tile stitching workflow, retained for reproducibility / compatibility. Prefer v1.3 for timepoint-folder workflows. | TIFF tile files → corrected tiles and stitched output |
| [Scratch Assay Analyzer (ImageJ)](macros/Scratch_Assay_Analyzer.ijm) | Original Fiji scratch-assay analysis implementation, retained alongside the [QuPath port](qupath/ScratchAssayAnalyzer.groovy). | Phase-contrast scratch images → scratch/wound measurements; consult macro options for output details |
| [Well Timepoint Stacks](macros/Well_Timepoint_Stacks.ijm) | Collect one 2D TIFF from each selected `<TimePoint>/<well>/Fused/`, pad differing X/Y dimensions without rescaling, and export a TIFF stack and/or AVI per well. | Fused TIFF images across timepoints → `<well>_timelapse.tif` and `.avi` |

**Common workflow:** run the v1.3 BaSiC stitcher on raw tiles, then
run the Well Timepoint Stacks macro on the **`BaSiC_Stitch_Output/`**
directory (not the raw-tile folder). Open `.ijm` scripts in Fiji via
**Plugins → Macros → Run** or the Fiji script editor. The BaSiC stitcher
requires the BaSiC and Grid/Collection Stitching plugins.

The stack exporter reads one 2D TIFF per `Fused/` folder, skips missing or
ambiguous folders with a Log message, and can use centered or top-left padding.
Timepoint folders are found, ordered and selected as in the v1.3 stitcher:
only `TimePoint_n` folders are used, frames follow the number `n`
(`TimePoint_2` before `TimePoint_10`, no zero-padding needed), and a typed
selection such as `1-3,5` refers to those folder numbers. Padding accommodates
different canvas sizes; it does **not** register image drift or guarantee the
stitched images are aligned. TIFF preserves the source pixel type where supported; AVI is an export for visualization and may
use an appropriate codec/color conversion.

See [macros/README.md](macros/README.md) for input layout, detailed usage, and
limitations for each macro.

## Install

1. In QuPath, choose **Automate > Show script editor**.
2. Open `qupath/ScratchAssayAnalyzer.groovy`.
3. Press **Run**.

To keep it available in QuPath, copy the script into QuPath's user `scripts`
directory. You can find that directory under **Edit > Preferences > Extensions**.

## Preparing a project

Import the images you want to measure. Images can differ in dimensions and are
analysed one at a time, but a consistent pixel calibration and field of view
make results easier to compare. CSV rows are written in natural filename order
(`t2` precedes `t10`) purely so the output is readable and reproducible; no
measurement depends on where an image falls in that order.

You do not have to measure the whole project. The settings dialog opens with a
row per image: a tick to include it, and a dropdown for that image's scratch
orientation. Everything starts ticked and set to **Vertical**. The **All**,
**None**, **All vertical** and **All horizontal** buttons set every row at
once, so a project that is mostly one orientation takes two clicks. Selection
is by position in the list, so a project containing two entries with the same
image name still resolves to the one you ticked, each with its own
orientation.

## Workflow

For each image, independently:

1. Read the image at a configurable downsample.
2. Convert RGB to luminance and compute a local variance (texture) image, log
   transformed.
3. Create the initial wound mask either from the texture/Otsu workflow or from
   a saved QuPath pixel classifier.
4. Restrict analysis to a `Restrict` annotation if the image has one, or to a
   centered field of view otherwise, and apply binary close/open.
5. Select the largest remaining component.
6. Check it is actually a wound: the sheet around it must be enough more
   textured than the inside. Reject it if not.
7. Fill holes enclosed by that component.
8. Optionally refine the boundary in a narrow second-pass texture band, then
   fill holes again.
9. Add the final wound as a QuPath annotation and save the image data.
10. Record the row, then release the image server before moving on.

The output is written below the project directory:

```text
Scratch_Assay_Results/
  Scratch_Assay_Measurements.csv     one row per image
  Scratch_Assay_Settings.txt
  Masks/
    <image>_wound_mask.png
  QC/
    <image>_QC.png
    <image>_width_profile.csv        one row per measured line
```

Areas and lengths are exported in both analysis pixels and calibrated units
when QuPath has a valid pixel size. Measurements account for the selected
downsample. Existing annotations are left untouched; generated annotations use
the class **Scratch wound** and are replaced on a subsequent run.

`Percent_Open` is the wound area as a percentage of the analysis field for that
same image, so it is comparable across images without a baseline frame.
`Detection_Status` is `FOUND` or `NOT_FOUND`; a `NOT_FOUND` row reports a zero
area and is worth inspecting in the QC overlay before use.
`Sheet_Wound_Texture_Ratio` is how many times more textured the analysis field
is outside the wound than inside it - the number the wound-presence test acts
on. `Detection_Status` is `FOUND`, `NOT_FOUND`, or `REJECTED_LOW_CONTRAST` when
a candidate was found but was not smooth enough to be bare substrate.
`Holes_Filled_px2` reports how much of the wound area came from the fill-holes
step, which is a useful sanity check: a large value means a lot of the gap was
occupied by cells or debris. `Orientation` records what the image was measured
as, and `Scratch_Length_px` the wound's extent along the scratch, so the width
and length columns can always be told apart.

### Restricting analysis to part of the image

To measure only part of a scratch, draw a **rectangle** on the image in QuPath
and label it `Restrict` - either give the annotation that *name*, or that
*classification*; the script accepts either, ignoring case. Images without one
are analysed as before, so this is opt-in per image and needs no setting.

A `Restrict` annotation **replaces** the centred **Analysis field (%)** rather
than intersecting with it: it is an explicit instruction about where to look,
and intersecting would quietly trim what you drew. `Percent_Open` is then
relative to the restricted region, which is usually what you want - it is the
fraction of *the region you chose* that is still open.

Any ROI shape is accepted and its bounding box used, so a rectangle is simply
the case where the box is the shape. The box is rounded outwards to whole
analysis pixels, so nothing you drew is lost to the downsample. A `Restrict`
annotation that falls entirely outside the image is an error rather than a
silent whole-image run.

Several `Restrict` annotations on one image are unioned into a single analysis
field, and the image still produces one CSV row. Note that the script keeps a
single connected component, so if you draw regions on genuinely separate
wounds only the largest survives - use one region per image for that, or ask
for per-region rows.

`Restricted` in the summary CSV is `YES` or `NO`, and `Field_X_px`,
`Field_Y_px`, `Field_W_px`, `Field_H_px` give the bounding box of the field
that was used, so every row records where it was measured. The QC overlay
draws that field in cyan, as it always has.

Generated wound annotations are removed and rewritten on each run, but they
are matched by the **Scratch wound** classification, so your `Restrict`
rectangles are never touched.

### Scratch orientation

The dropdown describes **the scratch**, not the direction the width is
measured in:

- *Vertical scratch (width measured left-right)* - the gap runs top to bottom,
  so its width is the horizontal run in each row.
- *Horizontal scratch (width measured top-bottom)* - the gap runs left to
  right, so its width is the vertical run in each column.

`Scratch_Length_px` is reported next to the width columns, measured along the
opposite axis. For a real scratch the length should be much larger than the
width, and it should run the way the image looks. If `Scratch_Length_px` is the
small number and `Mean_Width_px` is close to the image dimension, the dropdown
is set the wrong way round for that image.

Nothing else in the pipeline depends on orientation. The variance and Gaussian
kernels are square, morphology uses square structuring elements, and component
labelling and hole filling are 4-connected, all of which are unchanged by a
quarter turn. Measuring the transposed axis is therefore exactly equivalent to
rotating the image and measuring rows, and it avoids allocating a second copy
of the image and rotating the mask back for the annotation and QC overlay.
Area, `Percent_Open`, the centroid and the QC images are all reported in the
original image frame either way.

### Width profiles

`Mean_Width_px` and friends summarise one measurement per scan line. The
per-image `QC/<image>_width_profile.csv` writes those measurements out
individually, so a reported width can be traced back to the pixels it came
from - and drawn over the image to show where it was taken.

| Column | Meaning |
|---|---|
| `Image`, `Orientation` | Repeated on every row so profiles concatenate cleanly |
| `Line_Index` | Position of the scan line, in scan order |
| `Start_X_px`, `Start_Y_px` | Where the line entered the wound, full resolution |
| `End_X_px`, `End_Y_px` | Where it left |
| `Width_px`, `Width_um` | The measured width; `Width_um` is `NA` when uncalibrated |
| `Start_X_analysis_px` … `Width_analysis_px` | The same in analysis pixels |

Full-resolution coordinates line up with the summary CSV and the QuPath
annotation; the analysis-pixel columns line up with the QC and mask PNGs, so
the lines can be drawn straight onto either. For a vertical scratch each row
is one image row and the start/end points differ only in x; for a horizontal
one it is the other way round.

At the default stride of 1 the mean of `Width_analysis_px` reproduces
`Mean_Width_px` exactly - the profile is the summary's own input, not a
recomputation. An image where no wound was found writes a header-only file.

A vertical scratch in a 2400-pixel-tall image gives 2400 rows. **Width profile
stride** writes every Nth line instead: a stride of 10 keeps a tenth of them.
`Line_Index` still records each line's true position, so a thinned profile
plots in the right place. The stride thins the file *only* - `Mean_Width_px`,
the median and the SD are always computed over every line, so changing it never
changes a measurement. At a stride above 1 the profile is a sample of the
summary rather than a reproduction of it.

Turn the file off entirely with **Save width profile CSVs**; it is independent
of the QC overlays, which are the memory-hungry output.

### Fill holes

Cells and debris that have settled in the gap are high-texture, so thresholding
leaves them as unconnected islands *inside* the wound. Because the script keeps
a single connected component, those islands survive as holes and the reported
area comes out too low. **Fill holes in wound** (on by default) closes any
background region that the wound fully encloses.

Background reachable from the edge of the image is never filled, so a wound
that runs off the side of the analysis field keeps its true shape and only
genuine interior holes are closed. Turn the option off if you want the raw
segmentation, and compare `Holes_Filled_px2` against `Wound_Area_px2` to see
what it changed.

## Parameters

| Setting | Meaning |
|---|---|
| Images to measure | Tick the images to process; all are ticked by default |
| Scratch orientation | Per image: is the scratch vertical or horizontal? |
| Starting mask | Use the original variance threshold or a saved pixel classifier |
| Saved pixel classifier | Project classifier evaluated for every image |
| Classifier wound class | Exact classifier output class to treat as wound (case-insensitive) |
| Downsample | Scale used to read images; larger values save memory |
| Analysis field (%) | Centered width and height included in analysis, when the image has no `Restrict` annotation |
| Variance radius | Neighborhood radius for the first texture map |
| Texture smoothing | Gaussian sigma applied to that map |
| Minimum wound area | Reject a smaller wound (full-resolution pixels²) |
| Close/open iterations | Radius-1 binary morphology passes |
| Fill holes in wound | Close background regions fully enclosed by the wound |
| Second pass | Reclassify a band around the first boundary with a finer texture map |
| Minimum sheet/wound texture ratio | Reject a wound unless the sheet around it is this many times more textured; 0 disables the check |
| Save masks | Write a binary mask PNG per image |
| Save QC overlays | Write a QC overlay PNG per image |
| Save width profile CSVs | Write the measured lines to `QC/<image>_width_profile.csv` |
| Save per-step debug images | Write every intermediate image to `Debug/`, for working out why a hard image failed |
| Width profile stride | Write every Nth line to that file; does not affect any measurement |

### Using a trained QuPath pixel classifier

Train and save a **pixel classifier** in the same QuPath project before running
the script. In the settings dialog:

1. Change **Starting mask** to **Pixel classifier**.
2. Select the saved classifier (or type its resource name).
3. Enter the classifier output class that denotes open wound, for example
   `Wound`. Matching is case-insensitive.

The classifier is evaluated independently for every project image. Its class
labels are read from the classification server metadata, so the script does not
assume a numeric label. The selected class replaces the first-pass variance and
Otsu steps; the analysis-field restriction, morphology, largest-component
selection, hole filling, and optional second-pass refinement are then applied
normally.
Disable the second pass if the classifier boundary should be used without
variance-based refinement. The saved classifier must be compatible with every
image in the project (channels, resolution, and features).

In this mode the variance map is built **only if something still reads it**:

| Still needed by | Setting |
|---|---|
| the wound presence test | **Minimum texture ratio** above 0 |
| the second pass | **Second pass refinement** ticked |
| the `03_texture` dump | **Save debug images** ticked |

With all three off the classifier's own output is the only input, and the
variance pipeline is skipped outright - about three quarters of the per-image
compute, so the classifier path runs appreciably faster than the variance one
rather than slower. Turning the presence test off does mean a classifier that
finds a wound on a closed sheet is believed; keep a non-zero ratio unless you
have checked the classifier's behaviour on confluent images.

## Memory

Memory scales with the *analysis* pixel count, which the downsample controls.
Before reading an image the script estimates what it will need and refuses the
image with an actionable message rather than failing with an
`OutOfMemoryError` partway through a project.

If you hit that message, in rough order of effect:

- raise the **Downsample** (each doubling cuts memory about fourfold);
- turn off **Save QC overlays**, then the **second pass**;
- reduce the **Analysis field (%)**;
- give QuPath more memory under **Edit > Preferences > Memory**.

## Runtime

Per image, the work scales with the *analysis* pixel count, like memory, so the
downsample is the main control. On the 480x360 synthetic benchmark the whole
63-image dataset segments in **18 s** (about 0.25 s an image, warm), measured
through `benchmark/run_reference_pipeline.py`.

That is **8.1x** faster than the previous version - 2 min 25 s for the same 63
images - and the two runs agree byte for byte on every row, so the speedup cost
nothing in accuracy.

The reason is mundane. Groovy dispatches dynamically by default, and in a loop
over every pixel that cost is paid 170,000 times a frame, which swamped the
arithmetic. Annotating the numeric helpers `@CompileStatic` removes it; the
compiler emits the same operations either way, which is why the output is
identical. Two things had to move for that to work:

- `measurements` cannot be compiled statically as written, because it builds
  Groovy lists and indexes with `size()/2`, which is a `BigDecimal`. Its two
  whole-image scans are now `maskExtent` and `scanRuns`, which can be. Measured
  on one frame: **234 ms -> 13 ms** warm.
- the three per-pixel mask writes that lived inline in `analyseImage` are now
  `maskBelow`, `addBelow` and `andMask`.

`tests/test_script_contract.py` counts the annotations and checks that those
helpers are the ones doing the per-pixel work, because dropping an annotation
breaks nothing visible - it just makes the script many times slower.

Warm, on one 480x360 frame, the variance pipeline is **49 ms** against **16 ms**
for everything downstream of it, which is why skipping it matters so much on the
classifier path. The first image of a run is several times slower than the rest
regardless: the JVM is still compiling.

If a run is slower than this, in rough order of effect:

- raise the **Downsample**; cost falls with the square;
- under a pixel classifier, drop the presence test and second pass so the
  variance map is skipped entirely (see above);
- turn off **Save debug images**, which writes a PNG per pipeline step;
- turn off **Save QC overlays** and **Save width profiles**.

## Synthetic benchmark

`benchmark/` generates a phase-contrast scratch assay time series with **exact
ground truth** and scores a run against it, so the analyzer can be checked
against known answers rather than by eye:

```bash
python3 benchmark/generate_synthetic.py --out benchmark/dataset
# import benchmark/dataset/images into a QuPath project, run the analyzer
python3 benchmark/score_against_truth.py \
    --measured .../Scratch_Assay_Results/Scratch_Assay_Measurements.csv
```

The images model phase contrast properly - halo, shade-off, and a cell sheet
told apart from bare substrate by *texture* rather than brightness - so they
exercise the same cue the analyzer thresholds. Seven series cover fast and slow
closure, a no-migration control, a narrow wound, a rotated wound, debris in the
gap, and heavy uneven illumination. See `benchmark/README.md` for the imaging
model, the ground-truth columns, and the settings to use.

It has already earned its keep: see **Known limitations** below.

## Segmentation notes

Measured against the synthetic benchmark, where the true wound is known exactly:

### Thresholding

The segmentation thresholds the **logarithm** of the local variance, not the
variance itself. Otsu assumes two compact classes; raw variance gives it a
tight class near zero for the wound and a broad, heavy-tailed one for the cell
sheet, which drags the threshold far above the valley and swallows much of the
sheet. The variance of a textured field is roughly chi-square distributed, so
its log is roughly Gaussian, which is the shape Otsu expects. On the synthetic
benchmark this is the difference between measuring a wound almost the width of
the frame and measuring it to within a few percent.

`Pass1_Threshold` and `Pass2_Threshold` are still reported in variance units,
so they mean what they always meant, even though the cut is now chosen on the
log.

### Wound presence

Otsu returns a threshold whatever it is given, including a closed sheet whose
texture map has only one mode, so on its own it will always find a "wound".
Each candidate therefore has to earn the name: the analysis field outside it
must be at least **Minimum sheet/wound texture ratio** times more textured than
the inside. Bare substrate runs several times smoother than a cell sheet; a
slightly duller patch of sheet does not. A candidate that fails is reported as
`REJECTED_LOW_CONTRAST` with zero area, and the measured ratio is exported on
every row so the threshold can be tuned to your imagery.

A mask covering the entire analysis field leaves no outside to compare against,
and is rejected for the same reason.

### Working out why an image failed

Turn on **Save per-step debug images** and every stage writes a numbered PNG to
`Scratch_Assay_Results/Debug/`, plus `<image>_debug.txt` recording the
thresholds, pixel counts and decisions:

| File | What it shows |
|---|---|
| `01_source` | the image as read, at the analysis downsample |
| `02_field` | the analysis field, from the percentage or a `Restrict` annotation |
| `03_texture` | the log-variance map the threshold is chosen on |
| `04_initial_mask` | the thresholded mask, or the classifier's output |
| `05_morphology` | after close/open |
| `06_largest_component` | the component that was kept |
| `07_discarded` | **everything the component choice threw away** |
| `08_presence_test` | the candidate after the wound-presence test, blank if it was rejected |
| `09_holes_filled` | after fill holes |
| `10_refine_band`, `11_refine_texture`, `12_refined` | the second pass |
| `13_final` | the mask that was measured |

**Read the steps from the last good one forward, and mind which steps can
subtract.** `09_holes_filled` only ever adds pixels, so a wound cannot be lost
there; if it looks empty, the mask was already empty when it arrived. The two
steps that can clear a wound are `06_largest_component`, which keeps only one
component, and `08_presence_test`, which rejects a candidate that is not smooth
enough against its surroundings. When the presence test is what cleared it the
report says so outright, along with the ratio and the setting to change.

With a lot of debris, `07_discarded` is usually the one that answers it. Debris
scattered through the gap breaks the wound into pieces, and only the largest
survives; if `07_discarded` holds most of the wound, the fix is a larger
**Close iterations** to bridge the debris before the component is chosen, not a
different threshold. The report's pixel counts show which step lost the area,
and the texture ratio shows whether the presence test rejected it.

Each `03_texture` and `10_refine_texture` note in the report gives the
log-variance range that grey 0..255 spans, so the picture can be related back
to the threshold.

The dump is off by default, costs roughly a dozen PNGs per image, and changes
nothing about what is measured.

### Remaining limitations

Measured against the synthetic benchmark, where the true wound is known exactly.
At default settings four of its seven series are measured to within 2.3%,
including one with heavy uneven illumination and one with debris in the gap.
What is left:

- **There is a resolution floor of roughly three cell diameters.** The variance
  radius has to span a cell to describe the sheet's texture, which means it
  cannot resolve a gap much narrower than its own support. Below that the
  wound's interior reads as contaminated sheet, the texture ratio collapses,
  and the presence test rejects the frame. Shrinking the radius does not help -
  it destroys the sheet contrast instead. A real scratch starts 15-25 cell
  diameters wide, so this is reached only near full closure.
- **The second pass and the halo bias in opposite directions.** A texture
  threshold sits slightly inside the true edge, because the halo is a steep
  gradient and the boundary pixels read as sheet; the second pass pulls outward,
  because the halo itself is smooth and reads as wound. On the benchmark these
  roughly cancel at the default **Refinement band** of 20, which is why the
  defaults beat turning the second pass off. That cancellation depends on the
  halo width and so on your optics - re-run the benchmark if you change them,
  rather than assuming it still holds.
- **Area and length depend on the analysis field, width does not.** A 90% field
  removes 10% of the scan lines and so 10% of the area and length. Use a 100%
  field, or a `Restrict` region, when those columns matter.

## Validation notes

Segmentation is deterministic for a given QuPath image server and parameter
set. Thresholds can differ slightly from Fiji because this port operates in
floating-point and does not reproduce ImageJ's 8-bit variance saturation.
Always inspect the generated QC overlays before using measurements. Red is the
final wound boundary, yellow is the first-pass boundary, and cyan is the
analysis field.

## Development checks

Run the repository checks without launching QuPath:

```bash
python3 tests/test_script_contract.py
python3 tests/test_benchmark.py
python3 tests/test_basic_stitcher.py
python3 tests/test_well_timepoint_stacks.py
```

`test_basic_stitcher.py` also runs the stitcher macro's helper functions
through ImageJ's own interpreter when one is available, which is the only way
to settle how the macro language really behaves:

```bash
IJ_JAR=/path/to/Fiji.app/jars/ij-1.54j.jar python3 tests/test_basic_stitcher.py
```

`test_well_timepoint_stacks.py` checks that the stack macro shares the
stitcher's time point functions unchanged. With `IJ_JAR` set it also runs the
whole macro on a synthetic `BaSiC_Stitch_Output` tree and checks which folders
became which frames. That run uses ImageJ menu commands and so needs a
display; on a headless machine wrap it in `xvfb-run -a`:

```bash
IJ_JAR=/path/to/ij.jar xvfb-run -a python3 tests/test_well_timepoint_stacks.py
```

The contract test verifies required exports, the CSV contract, memory hygiene,
annotation provenance, that time-course behaviour stays removed, and balanced
delimiters. Functional image-server testing should be performed inside the
supported QuPath versions.
