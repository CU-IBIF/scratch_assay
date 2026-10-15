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
assert "selection << [index:i, orientation:isHorizontal(r.orient.value)" in text
assert "Images to measure" in text
assert "Vertical scratch (width measured left-right)" in text
assert "Horizontal scratch (width measured top-bottom)" in text
# One place decides what counts as horizontal.
assert text.count("boolean isHorizontal(Object label)") == 1
assert "boolean vertical = !isHorizontal(orientation)" in text
# Length along the scratch and width across it are reported separately.
assert "double lengthScale = vertical ? dsY : dsX" in text

# Every width in the summary is traceable to the scan line that produced it.
assert "writeWidthProfile" in text
assert "_width_profile.csv" in text
assert "lines<<[first,y,last,y]" in text and "lines<<[x,first,x,last]" in text
# The profile lives in QC, so that folder must exist whenever either is written.
assert "if (cfg.saveQC || cfg.saveProfiles) Files.createDirectories(qcDir)" in text
# Stride thins the profile file only: the summary is always over every line.
assert "profileStride" in text
assert "if (i % stride != 0) return" in text
assert "positiveInt(f.profileStride.text" in text

# A "Restrict" annotation confines the analysis field; without one the whole
# centred field is used. Matching is on classification or name, either case.
assert "List restrictRects(imageData, String image, int w, int h, double dsX, double dsY)" in text
assert "'restrict'.equalsIgnoreCase(cls?.trim()) || 'restrict'.equalsIgnoreCase(name?.trim())" in text
# A Restrict that misses the image must fail loudly, never fall back to all of it.
assert "outside the image" in text
# Percent_Open must not double count overlapping rectangles.
assert "long fieldArea = field.count(true)" in text
# The QC overlay draws the field that was actually used.
assert "BufferedImage qcImage(BufferedImage source,boolean[] p1,boolean[] fin,List rects)" in text

# Otsu assumes two compact classes, which raw local variance is not: the
# threshold must be chosen on the log of the variance map.
assert "float[] textureMap(float[] gray,int w,int h,int radius,double sigma)" in text
assert "Math.log1p" in text
# Exactly one place builds the texture map, so both passes get the transform.
assert text.count("gaussian(localVariance(") == 1
assert text.count("textureMap(gray, w, h") == 2
# Thresholds are exported in variance units even though chosen on the log.
assert "threshold1:Math.expm1(cut1), threshold2:Math.expm1(cut2)" in text

# Otsu always returns a cut, so a closed sheet needs an explicit presence test
# or it reports a wound that is not there.
assert "double textureRatio(float[] texture,boolean[] mask,boolean[] field)" in text
assert "REJECTED_LOW_CONTRAST" in text
assert "minTextureRatio" in text
# A mask covering the whole field yields no outside, which must reject.
assert "if(nIn==0||nOut==0) return Double.NaN" in text
# NaN must fail the comparison rather than pass it, hence the negated form.
assert "!(ratio >= (cfg.minTextureRatio as double))" in text

# Every pipeline step can be dumped for inspection, and the dump must be
# purely additive: guarded by the flag, never changing what is measured.
assert "void debugMask(Map cfg,Path dir,String stem,String step,boolean[] m,int w,int h)" in text
assert "String debugMap(" in text and "void debugImage(" in text
assert text.count("if (!cfg.saveDebug) return") == 3
assert "_debug.txt" in text
# A texture map has no natural display range, so the scaling has to be recorded.
assert "grey 0..255 spans log-variance" in text
# A flat or empty map must not divide by zero when being scaled.
assert "if(!Double.isFinite(mn)||!(mx>mn)){ mn=0d; mx=1d }" in text
# The presence test clears the mask, so it needs its own step: without one the
# dump makes the next step look like the culprit.
assert "08_presence_test" in text
assert "CLEARED HERE" in text

# fillHoles must stay monotone: it may only add pixels. That invariant is what
# makes "the wound was lost at fill holes" impossible, so pin it rather than
# trusting a reading of the code.
_fh = text[text.index("long fillHoles("):]
_fh = _fh[:_fh.index("\n}")]
_writes = re.findall(r"mask\[[^\]]*\]\s*=\s*(\w+)", _fh)
assert _writes == ["true"], f"fillHoles writes {_writes}; it must only set true"

# What the component choice threw away is the point of the dump with debris.
assert "07_discarded" in text
assert "boolean[] morphMask = cfg.saveDebug ? pass1 : null" in text
# Debug images cost memory too, so the budget has to know about them.
assert "(cfg.saveDebug ? px * 6L : 0L)" in text

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
                 "Percent_Open", "Restricted", "Field_X_px", "Scratch_Length_px",
                 "Sheet_Wound_Texture_Ratio", "Detection_Status"):
    assert f"'{required}'" in header
# Image name is the key, so it must lead the row.
assert header.startswith("'Image'")

# A simple lexical delimiter check catches most truncated edits. Strip comments
# and quoted strings first so punctuation in documentation is ignored.
code = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", "", text, flags=re.S)
for left, right in [("(", ")"), ("[", "]"), ("{", "}")]:
    assert code.count(left) == code.count(right), (left, right)

print("ScratchAssayAnalyzer.groovy contract checks passed")
