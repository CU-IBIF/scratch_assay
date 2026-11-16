/*
 * Phase-Contrast Batch Normalization (16-bit, background offset only)
 * Fiji / ImageJ Macro Language (IJM)
 *
 * Each well is normalized to its own 0 h image by shifting its median
 * intensity to the median of that 0 h image. Pixel values are never
 * multiplied or rescaled, and images stay 16-bit throughout.
 *
 * Wells: A01, A02, A03, B01, B02, B03
 *
 * Transformation:
 *   I_normalized = I_target + offset
 *   offset       = P50_ref - P50_target
 *
 * Output: 16-bit TIFF clipped to the 12-bit range (0-4095)
 * Originals are never modified.
 *
 * Input: one folder of single-plane 16-bit TIFFs named
 * <timepoint>_..._<well>.tif, e.g. 0h_Exp_A01.tif, 24h_Exp_A01.tif. The
 * timepoint is the text before the first underscore and must end in "h";
 * the 0 h reference must start "0h_".
 * Images that are not 16-bit are skipped (SKIPPED_NOT_16BIT), as are stacks
 * (SKIPPED_STACK). A 0 h reference that is not a 16-bit single plane stops
 * the run.
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

Dialog.create("Phase-Contrast Batch Normalization");

Dialog.addMessage("16-bit images only. Background offset, no scaling.");

Dialog.addCheckbox("Copy 0 h reference images", true);

Dialog.show();

copyReferences = Dialog.getCheckbox();

// --------------------------------------------
// 3. Identify images and reference files
// --------------------------------------------

files = getFileList(inputDir);

wells = newArray(
    "A01", "A02", "A03",
    "B01", "B02", "B03"
);

refPaths = newArray(6);
refP50 = newArray(6);

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

    // A saved ROI would limit measuring and Add/Max to that region
    run("Select None");

    if (bitDepth() != 16)
        exit("0 h reference is " + bitDepth() +
            "-bit, expected 16-bit: " + refPaths[w]);

    if (nSlices > 1)
        exit("0 h reference is a stack, expected one plane: " + refPaths[w]);

    refP50[w] = median16();

    close();
}

// --------------------------------------------
// 5. Create CSV report
// --------------------------------------------

logPath = outputDir + "normalization_log.csv";

header = "Filename,Well,Timepoint,Ref_P50,Target_P50,Offset,Status\n";

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

    // A saved ROI would limit measuring and Add/Max to that region
    run("Select None");

    // Only 16-bit single-plane images are processed
    status = "";

    if (bitDepth() != 16)
        status = "SKIPPED_NOT_16BIT";
    else if (nSlices > 1)
        status = "SKIPPED_STACK";

    if (status != "") {

        File.append(name + "," + well + "," + timepoint + "," +
            refP50[w] + ",,," + status + "\n", logPath);

        close();
        skipped++;
        continue;
    }

    tarP50 = median16();

    // ----------------------------------------
    // 7. Calculate background offset
    // ----------------------------------------

    offset = refP50[w] - tarP50;

    // ----------------------------------------
    // 8. Apply normalization
    // ----------------------------------------

    // 16-bit arithmetic: results below 0 are set to 0
    run("Add...", "value=" + offset);

    // Clip to 12-bit intensity range
    // (Process > Math > Max lowers pixels above the value)
    run("Max...", "value=4095");

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

    File.append(name + "," + well + "," + timepoint + "," +
        refP50[w] + "," + tarP50 + "," + offset + ",OK\n", logPath);

    processed++;
}

// --------------------------------------------
// 11. Finish
// --------------------------------------------

setBatchMode(false);

print("\\Clear");
print("PHASE-CONTRAST BATCH NORMALIZATION (16-bit, offset only)");
print("--------------------------------------------------------");
print("Input: " + inputDir);
print("Output: " + outputDir);
print("Processed: " + processed);
print("Skipped: " + skipped);
print("Log: " + logPath);

showMessage("Normalization Complete",
    "Processed: " + processed +
    "\nSkipped: " + skipped +
    "\nOutput: " + outputDir);

// --------------------------------------------
// Helper: Median (P50) of the open 16-bit image
// --------------------------------------------

// getRawStatistics gives 16-bit images one histogram bin per grey value
// starting at 0, so bin k is value k and the median is a whole number.

function median16() {

    getRawStatistics(nPixels, mean, min, max, std, hist);

    total = 0;

    for (k = 0; k < hist.length; k++)
        total += hist[k];

    if (total == 0)
        return min;

    threshold = total * 50 / 100;
    cumulative = 0;

    for (k = 0; k < hist.length; k++) {

        cumulative += hist[k];

        if (cumulative >= threshold)
            return k;
    }

    return max;
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
