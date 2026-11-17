/*
 * Phase-Contrast / Brightfield Batch Normalization (16-bit)
 * Fiji / ImageJ Macro Language (IJM)
 *
 * Each well is normalized to its own 0 h image.
 *
 * Wells: A01, A02, A03, B01, B02, B03
 *
 * Methods (chosen in the dialog):
 *
 *   Brightfield linear (mode exact)            [default]
 *     One straight line. The mode (background peak) lands exactly on the
 *     reference mode; the low-high percentile range is scaled to the
 *     reference range, so min/max match only approximately.
 *       scale = (High_ref - Low_ref) / (High_target - Low_target)
 *       I_normalized = Mode_ref + scale * (I_target - Mode_target)
 *
 *   Brightfield two-segment (min, mode, max exact)
 *     Two straight lines joined at the mode. Low, mode and high all land
 *     exactly on the reference values; the slope can change at the mode.
 *       below mode: slope = (Mode_ref - Low_ref) / (Mode_target - Low_target)
 *       above mode: slope = (High_ref - Mode_ref) / (High_target - Mode_target)
 *       I_normalized = Mode_ref + slope * (I_target - Mode_target)
 *
 *   Median offset (shift only)
 *     No scaling: I_normalized = I_target + (P50_ref - P50_target)
 *
 * Low and High are percentiles set in the dialog (default 0.1 and 99.9);
 * 0 and 100 give the true minimum and maximum. The mode is the most
 * frequent grey value.
 *
 * Output: 16-bit TIFF using the full 16-bit range (0-65535); there is no
 * 12-bit cap. Results are rounded; below 0 becomes 0 and above 65535
 * becomes 65535. Originals are never modified.
 *
 * Input: one folder of single-plane 16-bit TIFFs named
 * <timepoint>_..._<well>.tif, e.g. 0h_Exp_A01.tif, 24h_Exp_A01.tif. The
 * timepoint is the text before the first underscore and must end in "h";
 * the 0 h reference must start "0h_".
 * Images that are not 16-bit are skipped (SKIPPED_NOT_16BIT), as are stacks
 * (SKIPPED_STACK) and images whose mapping is undefined because a range is
 * zero (SKIPPED_ZERO_RANGE). A 0 h reference that is not a 16-bit single
 * plane stops the run.
 */

// --------------------------------------------
// 1. Select input and output folders
// --------------------------------------------

inputDir = getDirectory("Select folder containing 16-bit TIFF images");
if (inputDir == "")
    exit("No input folder selected.");

outputDir = inputDir + "normalized" + File.separator;
File.makeDirectory(outputDir);

// --------------------------------------------
// 2. Settings
// --------------------------------------------

METHOD_LINEAR = "Brightfield linear (mode exact)";
METHOD_TWO = "Brightfield two-segment (min, mode, max exact)";
METHOD_OFFSET = "Median offset (shift only)";

Dialog.create("Batch Normalization (16-bit)");

Dialog.addChoice("Normalization method",
    newArray(METHOD_LINEAR, METHOD_TWO, METHOD_OFFSET),
    METHOD_LINEAR);

Dialog.addNumber("Low percentile (min)", 0.1);
Dialog.addNumber("High percentile (max)", 99.9);
Dialog.addMessage("Brightfield methods only. 0 and 100 = true min/max.");

Dialog.addCheckbox("Copy 0 h reference images", true);

Dialog.show();

method = Dialog.getChoice();
lowPct = Dialog.getNumber();
highPct = Dialog.getNumber();
copyReferences = Dialog.getCheckbox();

if (isNaN(lowPct) || isNaN(highPct) ||
    lowPct < 0 || highPct > 100 || lowPct >= highPct)
    exit("Percentiles must satisfy 0 <= low < high <= 100 (got " +
        lowPct + " and " + highPct + ").");

// --------------------------------------------
// 3. Identify images and reference files
// --------------------------------------------

files = getFileList(inputDir);

wells = newArray(
    "A01", "A02", "A03",
    "B01", "B02", "B03"
);

refPaths = newArray(6);
refLow = newArray(6);
refMode = newArray(6);
refP50 = newArray(6);
refHigh = newArray(6);

// Find the 0 h reference for each well
for (w = 0; w < wells.length; w++) {

    refPaths[w] = "";

    for (i = 0; i < files.length; i++) {

        name = files[i];

        // ImageJ treats a user function's result in a comparison as a
        // number, so read the well into a variable before comparing it
        nameWell = getWell(name, wells);

        if (isTiff(name) &&
            startsWith(name, "0h_") &&
            nameWell == wells[w]) {

            refPaths[w] = inputDir + name;
            break;
        }
    }

    if (refPaths[w] == "")
        exit("Missing 0 h reference for " + wells[w]);
}

// --------------------------------------------
// 4. Measure reference images
// --------------------------------------------

setBatchMode(true);

for (w = 0; w < wells.length; w++) {

    open(refPaths[w]);

    // A saved ROI would limit measuring and the math steps to that region
    run("Select None");

    if (bitDepth() != 16)
        exit("0 h reference is " + bitDepth() +
            "-bit, expected 16-bit: " + refPaths[w]);

    if (nSlices > 1)
        exit("0 h reference is a stack, expected one plane: " + refPaths[w]);

    getRawStatistics(nPixels, mean, min, max, std, hist);

    refLow[w] = percentile16(hist, min, max, lowPct);
    refP50[w] = percentile16(hist, min, max, 50);
    refHigh[w] = percentile16(hist, min, max, highPct);
    refMode[w] = mode16(hist);

    close();
}

// --------------------------------------------
// 5. Create CSV report
// --------------------------------------------

// Center is the mode for the brightfield methods and the median (P50)
// for the median offset method. Low/High are the chosen percentiles.

logPath = outputDir + "normalization_log.csv";

header = "Filename,Well,Timepoint,Method,Low_Pct,High_Pct,";
header += "Ref_Low,Ref_Center,Ref_High,";
header += "Target_Low,Target_Center,Target_High,";
header += "Slope_Below,Slope_Above,Status\n";

File.saveString(header, logPath);

// --------------------------------------------
// 6. Process images
// --------------------------------------------

processed = 0;
skipped = 0;

for (i = 0; i < files.length; i++) {

    name = files[i];

    if (!isTiff(name))
        continue;

    if (indexOf(name, "_normalized") >= 0)
        continue;

    well = getWell(name, wells);
    timepoint = getTimepoint(name);

    // Skip unrecognized filenames
    if (well == "" || timepoint == "") {
        skipped++;
        continue;
    }

    // Identify well index
    w = -1;

    for (j = 0; j < wells.length; j++) {
        if (well == wells[j]) {
            w = j;
            break;
        }
    }

    if (w < 0) {
        skipped++;
        continue;
    }

    rowStart = name + "," + well + "," + timepoint + "," +
        method + "," + lowPct + "," + highPct + ",";

    // Handle 0 h reference images
    if (timepoint == "0h") {

        if (copyReferences) {

            open(inputDir + name);

            if (bitDepth() == 16 && nSlices == 1) {

                outputPath = outputDir +
                    stripTiff(name) + "_normalized.tif";

                saveAs("Tiff", outputPath);
            }

            close();
        }

        continue;
    }

    // Open target image
    open(inputDir + name);

    // A saved ROI would limit measuring and the math steps to that region
    run("Select None");

    // Only 16-bit single-plane images are processed
    status = "";

    if (bitDepth() != 16)
        status = "SKIPPED_NOT_16BIT";
    else if (nSlices > 1)
        status = "SKIPPED_STACK";

    if (status != "") {

        File.append(rowStart + ",,,,,,,," + status + "\n", logPath);

        close();
        skipped++;
        continue;
    }

    getRawStatistics(nPixels, mean, min, max, std, hist);

    tarLow = percentile16(hist, min, max, lowPct);
    tarHigh = percentile16(hist, min, max, highPct);

    // ----------------------------------------
    // 7. Calculate the mapping
    // ----------------------------------------

    if (method == METHOD_OFFSET) {
        refCenter = refP50[w];
        tarCenter = percentile16(hist, min, max, 50);
    } else {
        refCenter = refMode[w];
        tarCenter = mode16(hist);
    }

    slopeBelow = 1;
    slopeAbove = 1;
    status = "OK";

    if (method == METHOD_LINEAR) {

        if (tarHigh - tarLow <= 0)
            status = "SKIPPED_ZERO_RANGE";
        else
            slopeBelow = (refHigh[w] - refLow[w]) / (tarHigh - tarLow);

        slopeAbove = slopeBelow;

    } else if (method == METHOD_TWO) {

        if (tarCenter - tarLow <= 0 || tarHigh - tarCenter <= 0)
            status = "SKIPPED_ZERO_RANGE";
        else {
            slopeBelow = (refCenter - refLow[w]) / (tarCenter - tarLow);
            slopeAbove = (refHigh[w] - refCenter) / (tarHigh - tarCenter);
        }
    }

    row = rowStart + refLow[w] + "," + refCenter + "," + refHigh[w] + "," +
        tarLow + "," + tarCenter + "," + tarHigh + ",";

    if (status != "OK") {

        File.append(row + ",," + status + "\n", logPath);

        close();
        skipped++;
        continue;
    }

    // ----------------------------------------
    // 8. Apply normalization
    // ----------------------------------------

    if (method == METHOD_OFFSET) {

        // Shift only. 16-bit arithmetic keeps results within 0-65535.
        run("Add...", "value=" + (refCenter - tarCenter));

    } else {

        // Work in 32-bit so intermediate values are not rounded or clipped.
        targetId = getImageID();
        run("32-bit");

        if (method == METHOD_TWO) {

            // Split at the mode: below = min(I, mode), above = max(I, mode).
            // Process > Math > Max lowers pixels above the value; Min raises
            // pixels below it.
            run("Duplicate...", "title=bf_below");
            belowId = getImageID();
            run("Max...", "value=" + tarCenter);
            run("Subtract...", "value=" + tarCenter);
            run("Multiply...", "value=" + d2s(slopeBelow, 12));

            selectImage(targetId);
            run("Min...", "value=" + tarCenter);
            run("Subtract...", "value=" + tarCenter);
            run("Multiply...", "value=" + d2s(slopeAbove, 12));

            // (I - mode) * slope, using the slope for each side of the mode
            imageCalculator("Add", targetId, belowId);

            selectImage(belowId);
            close();
            selectImage(targetId);

        } else {

            run("Subtract...", "value=" + tarCenter);
            run("Multiply...", "value=" + d2s(slopeBelow, 12));
        }

        run("Add...", "value=" + refCenter);

        // Back to 16-bit without rescaling: values are rounded and kept
        // within 0-65535. The default is restored straight afterwards.
        setOption("ScaleConversions", false);
        run("16-bit");
        setOption("ScaleConversions", true);
    }

    // ----------------------------------------
    // 9. Save normalized image
    // ----------------------------------------

    outputPath = outputDir +
        stripTiff(name) + "_normalized.tif";

    saveAs("Tiff", outputPath);

    close();

    // ----------------------------------------
    // 10. Log normalization parameters
    // ----------------------------------------

    File.append(row + slopeBelow + "," + slopeAbove + ",OK\n", logPath);

    processed++;
}

// --------------------------------------------
// 11. Finish
// --------------------------------------------

setBatchMode(false);

print("\\Clear");
print("BATCH NORMALIZATION (16-bit)");
print("----------------------------");
print("Input: " + inputDir);
print("Output: " + outputDir);
print("Method: " + method);
print("Percentiles: " + lowPct + " / " + highPct);
print("Processed: " + processed);
print("Skipped: " + skipped);
print("Log: " + logPath);

showMessage("Normalization Complete",
    "Processed: " + processed +
    "\nSkipped: " + skipped +
    "\nOutput: " + outputDir);

// --------------------------------------------
// Helper: Percentile of a 16-bit histogram
// --------------------------------------------

// getRawStatistics gives 16-bit images one histogram bin per grey value
// starting at 0, so bin k is value k. 0 and 100 return the true min/max.

function percentile16(hist, min, max, pct) {

    if (pct <= 0)
        return min;

    if (pct >= 100)
        return max;

    total = 0;

    for (k = 0; k < hist.length; k++)
        total += hist[k];

    if (total == 0)
        return min;

    threshold = total * pct / 100;
    cumulative = 0;

    for (k = 0; k < hist.length; k++) {

        cumulative += hist[k];

        if (cumulative >= threshold)
            return k;
    }

    return max;
}

// --------------------------------------------
// Helper: Mode (most frequent grey value) of a 16-bit histogram
// --------------------------------------------

// Ties go to the lowest grey value.

function mode16(hist) {

    best = 0;

    for (k = 1; k < hist.length; k++) {
        if (hist[k] > hist[best])
            best = k;
    }

    return best;
}

// --------------------------------------------
// Helper: Recognize TIFF files
// --------------------------------------------

function isTiff(name) {

    lower = toLowerCase(name);

    return endsWith(lower, ".tif") ||
           endsWith(lower, ".tiff");
}

// --------------------------------------------
// Helper: Remove TIFF extension
// --------------------------------------------

function stripTiff(name) {

    dot = lastIndexOf(name, ".");

    if (dot < 0)
        return name;

    return substring(name, 0, dot);
}

// --------------------------------------------
// Helper: Extract well identifier
// --------------------------------------------

function getWell(name, wells) {

    base = stripTiff(name);

    for (q = 0; q < wells.length; q++) {

        suffix = "_" + wells[q];

        if (endsWith(base, suffix))
            return wells[q];
    }

    return "";
}

// --------------------------------------------
// Helper: Extract timepoint
// --------------------------------------------

function getTimepoint(name) {

    underscore = indexOf(name, "_");

    if (underscore < 0)
        return "";

    tp = substring(name, 0, underscore);

    if (endsWith(tp, "h"))
        return tp;

    return "";
}
