# Fiji / ImageJ macros

This folder contains the ImageJ macro-language (`.ijm`) tools in this repository.
Run them using **Fiji → Plugins → Macros → Run** or open them in the script editor.
They are independent scripts, not one automatically executed pipeline.

## Which macro should I use?

| Macro | Role | Notes |
| --- | --- | --- |
| [`BaSiC_Batch_Tile_Stitcher_v1.3.ijm`](BaSiC_Batch_Tile_Stitcher_v1.3.ijm) | Flat-field correction and stitched mosaics | **Preferred** BaSiC stitcher; detects and selects multiple timepoint directories. |
| [`BaSiC_Batch_Tile_Stitcher_v1.2.ijm`](BaSiC_Batch_Tile_Stitcher_v1.2.ijm) | Earlier BaSiC correction/stitching version | Retained for reproducibility. Review its header before using it on new datasets. |
| [`Scratch_Assay_Analyzer.ijm`](Scratch_Assay_Analyzer.ijm) | Phase-contrast scratch/wound analysis in ImageJ | Original ImageJ implementation; the separate [QuPath version](../qupath/ScratchAssayAnalyzer.groovy) has its own documented workflow in the [root README](../README.md). |
| [`Well_Timepoint_Stacks.ijm`](Well_Timepoint_Stacks.ijm) | Per-well time-lapse stacks and movies | Assembles selected timepoints from fused TIFFs; pads variable X/Y canvas sizes. |

## Suggested workflow: TIFF tiles to well movies

### 1. Correct and stitch tiles

Use the v1.3 stitcher when raw tile filenames follow a pattern like
`Experiment_A01_s1.tif`, `Experiment_A01_s2.tif`, etc. (tile numbers
are row-major: left-to-right, then next row). Example raw layout:

```text
Experiment/
  TimePoint_001/
    Experiment_A01_s1.tif
    Experiment_A01_s2.tif
    ...
    Experiment_B01_s1.tif
  TimePoint_002/
    ...
```

The v1.3 macro accepts either the parent directory with `TimePoint_n`
subdirectories or one folder of tiles. Choose the grid columns and rows,
starting overlap, and which timepoints to process. It rejects wells with
missing or duplicated tile indices. It uses BaSiC for correction and Fiji's
Grid/Collection Stitching for mosaics. **Install the BaSiC and Stitching plugins
and close all open images before running the stitcher.**

The documented v1.3 output layout is:

```text
BaSiC_Stitch_Output/
  BaSiC_Stitch_Log.txt
  TimePoint_001/
    Experiment_A01/
      Corrected_Tiles/
        Experiment_A01_s1.tif
        ...
      Fused/
        Experiment_A01_BaSiC_Fused.tif
  TimePoint_002/
    Experiment_A01/
      Fused/
        Experiment_A01_BaSiC_Fused.tif
      ...
```

The macro processes each selected timepoint independently, estimating BaSiC
shading from that timepoint's tiles rather than pooling the time series.
Review the log and fused images for missing tiles, seam artifacts, or alignment
issues before continuing.

### 2. Assemble each well into a time-lapse

Run [`Well_Timepoint_Stacks.ijm`](Well_Timepoint_Stacks.ijm). Select
`BaSiC_Stitch_Output/` as the parent folder and choose a separate output
directory. It expects the `TimePoint/<well>/Fused/` hierarchy above
with **exactly one TIFF per Fused folder**.

The macro prints numbered timepoint folders to the Fiji Log. Select `all`,
a range like `1-20`, or a list like `1,3-5,8`. These are **list positions**
rather than numerical timepoint IDs. Configure frame rate, centered or top-left
padding, AVI compression, and which outputs to write.

For each well, it reads image dimensions in a first pass, then copies the
original pixels into a common canvas based on the **maximum width and height
for that well**. Differences in stitching canvas size therefore do not force
interpolation or resampling. Expected outputs:

```text
Movie_Output/
  Experiment_A01_timelapse.tif
  Experiment_A01_timelapse.avi
  Experiment_B01_timelapse.tif
  Experiment_B01_timelapse.avi
```

**Limitations and checks:**

- Folder ordering is alphabetical. Name timepoints `TimePoint_001`,
  `TimePoint_002`, etc. to avoid `TimePoint_10` preceding `TimePoint_2`.
- Missing `Fused/` TIFFs, ambiguous multiple TIFFs, non-2D images, or
  inconsistent bit depths are skipped and recorded in the Log. Consequently
  stacks can contain different numbers of frames across wells.
- Centering assumes any size difference is distributed symmetrically;
  padding does **not** correct drift, spatial translation, or differences
  in mosaic origins. Check alignment when interpreting cell migration.
- Movie frame rate controls playback, not measured elapsed time between
  acquisitions. TIFF stacks retain slices for analysis; AVI is intended for
  visualization.
- The tool loads images and constructs a stack per well in memory. For very
  large stitched TIFFs, adjust Fiji's memory allocation or process fewer
  timepoints.

### 3. Analyze scratch closure

Use [`Scratch_Assay_Analyzer.ijm`](Scratch_Assay_Analyzer.ijm) for
the original ImageJ scratch assay analysis approach, or the
[`qupath/ScratchAssayAnalyzer.groovy`](../qupath/ScratchAssayAnalyzer.groovy)
port for its documented QuPath project, QC overlay, wound mask, and CSV workflow.
The QuPath script analyzes images independently (it does **not** perform
automatic temporal tracking). See the [root README](../README.md) and
[benchmark guide](../benchmark/README.md) for QuPath analysis and validation
details.

## Choosing versions and troubleshooting

Use the **v1.3 stitcher** for new timepoint-aware BaSiC preprocessing.
The v1.2 script is retained so older analyses can be reproduced. Before batch
processing a large experiment, validate one representative well and a few
timepoints; verify field-of-view orientation, correct fused images, frame order,
padding, and that output filenames match the intended wells.

All these scripts are research tools: inspect outputs and maintain original
raw TIFFs as the source of record.
