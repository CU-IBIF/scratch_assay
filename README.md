# Scratch Assay Analyzer for QuPath

This repository contains an installable **QuPath Groovy script** that ports the
core workflow from `Scratch_Assay_Analyzer.ijm` to QuPath. It segments the
low-texture gap in phase-contrast images, tracks it through a project time
series, creates wound annotations, and exports measurements and QC images.

## Requirements

- QuPath 0.5.x or 0.6.x
- A QuPath project containing one image per time point
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

Import one image for every time point. The script processes project entries in
natural filename order (`t2` precedes `t10`), so use consistent names. It treats
the entire project as one time series. Images can differ in dimensions, but a
single pixel calibration and a consistent field of view are strongly advised.

## Workflow

The QuPath script mirrors the validated parts of the ImageJ v5.5 workflow:

1. Read each image at a configurable downsample.
2. Convert RGB to luminance and compute a local variance (texture) image.
3. Create the initial wound mask either from the variance/Otsu workflow or from
   a saved QuPath pixel classifier.
4. Restrict analysis to a centered field of view and apply binary close/open.
5. Select the largest component on the first frame, then the nearest plausible
   component on subsequent frames.
6. Optionally refine the boundary in a narrow second-pass variance band.
7. Add the final wound as a QuPath annotation and save the image data.
8. Export temporal metrics, binary masks, QC overlays, and run settings.

The output is written below the project directory:

```text
Scratch_Assay_Results/
  Scratch_Assay_Texture_Tracking.csv
  Scratch_Assay_Settings.txt
  Masks/
  QC/
```

Areas and lengths are exported in both analysis pixels and calibrated units
when QuPath has a valid pixel size. Measurements account for the selected
downsample. Existing annotations are left untouched; generated annotations use
the class **Scratch wound** and are replaced on a subsequent run.

## Parameters

| Setting | Meaning |
|---|---|
| Starting mask | Use the original variance threshold or a saved pixel classifier |
| Saved pixel classifier | Project classifier evaluated for every time point |
| Classifier wound class | Exact classifier output class to treat as wound (case-insensitive) |
| Downsample | Scale used to read images; larger values save memory |
| Analysis field (%) | Centered width and height included in analysis |
| Variance radius | Neighborhood radius for the first texture map |
| Texture smoothing | Gaussian sigma applied to that map |
| Minimum wound area | Reject smaller components (full-resolution pixels²) |
| Close/open iterations | Radius-1 binary morphology passes |
| Maximum tracking shift | Largest accepted centroid motion (full-resolution pixels) |
| Second pass | Reclassify a band around the first boundary with a finer texture map |
| Frame interval | Elapsed hours between naturally ordered project entries |

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
Otsu steps; the analysis-field restriction, morphology, component tracking, and
optional second-pass refinement are then applied normally. Disable the second
pass if the classifier boundary should be used without variance-based
refinement. The saved classifier must be compatible with every image in the
time series (channels, resolution, and features).

## Validation notes

Segmentation is deterministic for a given QuPath image server and parameter
set. Thresholds can differ slightly from Fiji because this port operates in
floating-point and does not reproduce ImageJ's 8-bit variance saturation.
Always inspect the generated QC overlays before using measurements. Red is the
final wound boundary, yellow is the first-pass boundary, and cyan is the
analysis field.

For very large slides, start with a downsample between 2 and 8. The script
guards against analysis images larger than 100 million pixels.

## Development checks

Run the repository checks without launching QuPath:

```bash
python3 tests/test_script_contract.py
```

The contract test verifies required exports, natural sorting, annotation
provenance, and balanced delimiters. Functional image-server testing should be
performed inside the supported QuPath versions.
