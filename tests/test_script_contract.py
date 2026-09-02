#!/usr/bin/env python3
"""Lightweight checks that do not require a QuPath installation."""
from pathlib import Path
import re

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "qupath" / "ScratchAssayAnalyzer.groovy"
text = SCRIPT.read_text(encoding="utf-8")

assert "naturalCompare" in text
assert "Scratch_Assay_Texture_Tracking.csv" in text
assert "Scratch_Assay_Settings.txt" in text
assert "Scratch wound (generated)" in text
assert "entry.saveImageData(imageData)" in text
assert "RegionRequest.createInstance" in text
assert "100_000_000L" in text
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

# Protect the stable CSV contract relied on by downstream analysis.
header = re.search(r"List names=\[(.*?)\];def keys", text, re.S).group(1)
for required in ("Frame", "Time_h", "Wound_Area_px2", "Percent_Closure", "Tracking_Status"):
    assert f"'{required}'" in header

# A simple lexical delimiter check catches most truncated edits. Strip comments
# and quoted strings first so punctuation in documentation is ignored.
code = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", "", text, flags=re.S)
for left, right in [("(", ")"), ("[", "]"), ("{", "}")]:
    assert code.count(left) == code.count(right), (left, right)

print("ScratchAssayAnalyzer.groovy contract checks passed")
