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

## Workflow

For each image, independently:

1. Read the image at a configurable downsample.
2. Convert RGB to luminance and compute a local variance (texture) image.
3. Create the initial wound mask either from the variance/Otsu workflow or from
   a saved QuPath pixel classifier.
4. Restrict analysis to a centered field of view and apply binary close/open.
5. Select the largest remaining component.
6. Optionally refine the boundary in a narrow second-pass variance band.
7. Add the final wound as a QuPath annotation and save the image data.
8. Record the row, then release the image server before moving on.

The output is written below the project directory:

```text
Scratch_Assay_Results/
  Scratch_Assay_Measurements.csv
  Scratch_Assay_Settings.txt
  Masks/
  QC/
```

Areas and lengths are exported in both analysis pixels and calibrated units
when QuPath has a valid pixel size. Measurements account for the selected
downsample. Existing annotations are left untouched; generated annotations use
the class **Scratch wound** and are replaced on a subsequent run.

`Percent_Open` is the wound area as a percentage of the analysis field for that
same image, so it is comparable across images without a baseline frame.
`Detection_Status` is `FOUND` or `NOT_FOUND`; a `NOT_FOUND` row reports a zero
area and is worth inspecting in the QC overlay before use.

## Parameters

| Setting | Meaning |
|---|---|
| Starting mask | Use the original variance threshold or a saved pixel classifier |
| Saved pixel classifier | Project classifier evaluated for every image |
| Classifier wound class | Exact classifier output class to treat as wound (case-insensitive) |
| Downsample | Scale used to read images; larger values save memory |
| Analysis field (%) | Centered width and height included in analysis |
| Variance radius | Neighborhood radius for the first texture map |
| Texture smoothing | Gaussian sigma applied to that map |
| Minimum wound area | Reject a smaller wound (full-resolution pixels²) |
| Close/open iterations | Radius-1 binary morphology passes |
| Second pass | Reclassify a band around the first boundary with a finer texture map |
| Save masks | Write a binary mask PNG per image |
| Save QC overlays | Write a QC overlay PNG per image |

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
selection, and optional second-pass refinement are then applied normally.
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
