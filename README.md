# Scratch Assay Analyzer for QuPath

This repository contains an installable **QuPath Groovy script** that ports the
core workflow from `Scratch_Assay_Analyzer.ijm` to QuPath. It segments the
low-texture gap in phase-contrast images, creates wound annotations, and exports
measurements and QC images.

Every image is measured **independently**. The script does no frame tracking and
has no notion of elapsed time, so results are keyed by image name and can be
joined to whatever experimental design you keep elsewhere.

## Requirements

- QuPath 0.5.x or 0.6.x
- A QuPath project containing the images to measure
- Java 17 or newer (included with normal QuPath distributions)

No ImageJ or third-party QuPath extension is required. The original ImageJ
macros are retained as reference implementations.

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
2. Convert RGB to luminance and compute a local variance (texture) image.
3. Create the initial wound mask either from the variance/Otsu workflow or from
   a saved QuPath pixel classifier.
4. Restrict analysis to a centered field of view and apply binary close/open.
5. Select the largest remaining component.
6. Fill holes enclosed by that component.
7. Optionally refine the boundary in a narrow second-pass variance band, then
   fill holes again.
8. Add the final wound as a QuPath annotation and save the image data.
9. Record the row, then release the image server before moving on.

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
`Holes_Filled_px2` reports how much of the wound area came from the fill-holes
step, which is a useful sanity check: a large value means a lot of the gap was
occupied by cells or debris. `Orientation` records what the image was measured
as, and `Scratch_Length_px` the wound's extent along the scratch, so the width
and length columns can always be told apart.

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
| Analysis field (%) | Centered width and height included in analysis |
| Variance radius | Neighborhood radius for the first texture map |
| Texture smoothing | Gaussian sigma applied to that map |
| Minimum wound area | Reject a smaller wound (full-resolution pixels²) |
| Close/open iterations | Radius-1 binary morphology passes |
| Fill holes in wound | Close background regions fully enclosed by the wound |
| Second pass | Reclassify a band around the first boundary with a finer texture map |
| Save masks | Write a binary mask PNG per image |
| Save QC overlays | Write a QC overlay PNG per image |
| Save width profile CSVs | Write the measured lines to `QC/<image>_width_profile.csv` |
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
```

The contract test verifies required exports, the CSV contract, memory hygiene,
annotation provenance, that time-course behaviour stays removed, and balanced
delimiters. Functional image-server testing should be performed inside the
supported QuPath versions.
