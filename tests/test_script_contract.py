#!/usr/bin/env python3
"""Lightweight checks that do not require a QuPath installation."""
from pathlib import Path
import re

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "qupath" / "ScratchAssayAnalyzer.groovy"
text = SCRIPT.read_text(encoding="utf-8")

assert "naturalCompare" in text
assert "Scratch_Assay_Measurements.csv" in text
assert "Scratch_Assay_Settings.txt" in text
assert "Scratch wound (generated)" in text
assert "entry.saveImageData(imageData)" in text
assert "RegionRequest.createInstance" in text
assert "PixelClassifierTools.createPixelClassificationServer" in text
assert "qupath.opencv.ml.pixel.PixelClassifierTools" in text
assert "getClassificationLabels" in text
assert "classifierMask(project, imageData" in text
assert "Starting mask" in text

# Regressions that only surface at runtime inside QuPath.
# "import java.awt.*" shadows java.util.List, so every `List x = []` blows up.
assert "import java.awt.*" not in text
# Groovy `/` on two ints yields BigDecimal, so int division needs an explicit cast.
assert "q/w==p/w" not in text
# ResourceManager.Manager exposes get(String), not getResource(String).
assert "getResource(" not in text
# Date.format(String) comes from groovy-dateutil, which QuPath does not bundle.
assert "new Date().format" not in text
# QuPath runs scripts off the FX thread; the settings dialog must marshal onto it.
assert "Platform.runLater" in text

# Memory hygiene. Each readImageData() owns a server and tile cache, and an
# image too large for the heap must be refused up front rather than blowing up
# partway through the project.
assert "checkMemoryBudget" in text
assert "getServer().close()" in text
# Only the winning component is ever materialised as a full-size mask.
assert "largestComponent" in text

# Debris inside the gap punches holes in the wound; closing them is what makes
# the reported area the true open area.
assert "fillHoles" in text
# The image picker resolves by position, so duplicate image names stay distinct,
# and each ticked image carries its own scratch orientation.
assert "selection << [index:i, orientation:r.orient.value]" in text
assert "Images to measure" in text
assert "'Vertical', 'Horizontal'" in text

# Width is measured across the scratch. Measuring the transposed axis is what
# makes a horizontal scratch correct; it must not be reduced to one axis again.
assert "Map measurements(boolean[] m,int w,int h,boolean vertical)" in text
assert "double widthScale = vertical ? dsX : dsY" in text
assert "measurements(finalMask, w, h, vertical)" in text

# The analysis grid must come from the image the server actually returned.
# Servers round region dimensions their own way at a downsample, and a computed
# estimate that is one pixel larger indexes past the end of the pixel arrays.
assert "int w = source.getWidth(), h = source.getHeight()" in text
assert "double dsX = server.getWidth() / (double)w" in text
assert "double dsY = server.getHeight() / (double)h" in text
assert text.count("cannot cover") == 2, "boxSum and gaussian should both guard the grid"

# Images are measured independently: no tracking, baseline or elapsed time.
for banned in ("selectComponent", "maxTrackShift", "frameInterval", "baselineArea",
               "Percent_Closure", "Tracking_Status", "Time_h"):
    assert banned not in text, f"time-course behaviour survived: {banned}"

# Protect the stable CSV contract relied on by downstream analysis.
header = re.search(r"List names=\[(.*?)\];def keys", text, re.S).group(1)
for required in ("Image", "Orientation", "Wound_Area_px2", "Holes_Filled_px2",
                 "Percent_Open", "Detection_Status"):
    assert f"'{required}'" in header
# Image name is the key, so it must lead the row.
assert header.startswith("'Image'")

# A simple lexical delimiter check catches most truncated edits. Strip comments
# and quoted strings first so punctuation in documentation is ignored.
code = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", "", text, flags=re.S)
for left, right in [("(", ")"), ("[", "]"), ("{", "}")]:
    assert code.count(left) == code.count(right), (left, right)

print("ScratchAssayAnalyzer.groovy contract checks passed")
