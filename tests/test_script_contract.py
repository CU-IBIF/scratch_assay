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

# Images are measured independently: no tracking, baseline or elapsed time.
for banned in ("selectComponent", "maxTrackShift", "frameInterval", "baselineArea",
               "Percent_Closure", "Tracking_Status", "Time_h"):
    assert banned not in text, f"time-course behaviour survived: {banned}"

# Protect the stable CSV contract relied on by downstream analysis.
header = re.search(r"List names=\[(.*?)\];def keys", text, re.S).group(1)
for required in ("Image", "Wound_Area_px2", "Percent_Open", "Detection_Status"):
    assert f"'{required}'" in header
# Image name is the key, so it must lead the row.
assert header.startswith("'Image'")

# A simple lexical delimiter check catches most truncated edits. Strip comments
# and quoted strings first so punctuation in documentation is ignored.
code = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", "", text, flags=re.S)
for left, right in [("(", ")"), ("[", "]"), ("{", "}")]:
    assert code.count(left) == code.count(right), (left, right)

print("ScratchAssayAnalyzer.groovy contract checks passed")
