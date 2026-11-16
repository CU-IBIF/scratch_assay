/*
 * Phase-Contrast Batch Normalization
 * Fiji / ImageJ Macro Language (IJM)
 *
 * Each well is normalized to its own 0 h image.
 *
 * Wells: A01, A02, A03, B01, B02, B03
 *
 * Transformation:
 *   I_normalized = scale * I_target + offset
 *
 *   scale = (P90_ref - P10_ref) /
 *           (P90_target - P10_target)
 *
 *   offset = P50_ref - scale * P50_target
 *
 * Output: 16-bit TIFF with 12-bit range (0-4095)
 * Originals are never modified.
 *
 * Input: one folder of single-plane TIFFs named <timepoint>_..._<well>.tif,
 * e.g. 0h_Exp_A01.tif, 24h_Exp_A01.tif. The timepoint is the text before the
 * first underscore and must end in "h"; the 0 h reference must start "0h_".
 * Stacks are skipped (logged as SKIPPED_STACK).
 */

// --------------------------------------------
// 1. Select input and output folders
// --------------------------------------------

inputDir = getDirectory("Select folder containing TIFF images");
if (inputDir == "")
    exit("No input folder selected.");

outputDir = inputDir + "normalized" + File.separator;
File.makeDirectory(outputDir);

// --------------------------------------------
// 2. Settings
// --------------------------------------------

Dialog.create("Phase-Contrast Batch Normalization");

Dialog.addChoice("Normalization method",
    newArray("Background + Contrast", "Background Only"),
    "Background + Contrast");

Dialog.addCheckbox("Copy 0 h reference images", true);

Dialog.show();

method = Dialog.getChoice();
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
refP10 = newArray(6);
refP50 = newArray(6);
refP90 = newArray(6);

// Find the 0 h reference for each well
for (w = 0; w < wells.length; w++) {

    refPaths[w] = "";

    for (i = 0; i < files.length; i++) {

        name = files[i];

        if (isTiff(name) &&
            startsWith(name, "0h_") &&
            getWell(name, wells) == wells[w]) {

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

    if (nSlices > 1)
        exit("0 h reference is a stack, expected one plane: " + refPaths[w]);

    getRawStatistics(nPixels, mean, min, max, std, hist);

    depth = bitDepth();

    refP10[w] = percentile(hist, min, max, depth, 10);
    refP50[w] = percentile(hist, min, max, depth, 50);
    refP90[w] = percentile(hist, min, max, depth, 90);

    close();
}

// --------------------------------------------
// 5. Create CSV report
// --------------------------------------------

logPath = outputDir + "normalization_log.csv";

header = "Filename,Well,Timepoint,Method,";
header += "Ref_P10,Ref_P50,Ref_P90,";
header += "Target_P10,Target_P50,Target_P90,";
header += "Scale,Offset,Status\n";

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

            outputPath = outputDir +
                stripTiff(name) + "_normalized.tif";

            saveAs("Tiff", outputPath);
            close();
        }

        continue;
    }

    // Open target image
    open(inputDir + name);

    // Math commands without "stack" only change the current slice
    if (nSlices > 1) {
        File.append(name + "," + well + "," + timepoint + "," + method +
            ",,,,,,,,,SKIPPED_STACK\n", logPath);
        close();
        skipped++;
        continue;
    }

    getRawStatistics(nPixels, mean, min, max, std, hist);

    depth = bitDepth();

    tarP10 = percentile(hist, min, max, depth, 10);
    tarP50 = percentile(hist, min, max, depth, 50);
    tarP90 = percentile(hist, min, max, depth, 90);

    // ----------------------------------------
    // 7. Calculate linear transformation
    // ----------------------------------------

    scale = 1.0;

    if (method == "Background + Contrast") {

        refContrast = refP90[w] - refP10[w];
        tarContrast = tarP90 - tarP10;

        if (tarContrast <= 0) {

            row = name + "," + well + "," +
                timepoint + "," + method + ",";

            row += refP10[w] + "," +
                refP50[w] + "," + refP90[w] + ",";

            row += tarP10 + "," + tarP50 +
                "," + tarP90 + ",,,";

            row += "SKIPPED_ZERO_CONTRAST\n";

            File.append(row, logPath);

            close();
            skipped++;
            continue;
        }

        scale = refContrast / tarContrast;
    }

    offset = refP50[w] - scale * tarP50;

    // ----------------------------------------
    // 8. Apply normalization
    // ----------------------------------------

    run("32-bit");

    run("Multiply...", "value=" + d2s(scale, 12));
    run("Add...", "value=" + d2s(offset, 12));

    // Clip to 12-bit intensity range
    // Process > Math > Max lowers pixels above the value; Min raises
    // pixels below it.
    run("Max...", "value=4095");
    run("Min...", "value=0");

    // Convert to 16-bit without rescaling, then restore the default
    setOption("ScaleConversions", false);
    run("16-bit");
    setOption("ScaleConversions", true);

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

    row = name + "," + well + "," +
        timepoint + "," + method + ",";

    row += refP10[w] + "," +
        refP50[w] + "," + refP90[w] + ",";

    row += tarP10 + "," +
        tarP50 + "," + tarP90 + ",";

    row += scale + "," + offset + ",OK\n";

    File.append(row, logPath);

    processed++;
}

// --------------------------------------------
// 11. Finish
// --------------------------------------------

setBatchMode(false);

print("\\Clear");
print("PHASE-CONTRAST BATCH NORMALIZATION");
print("----------------------------------");
print("Input: " + inputDir);
print("Output: " + outputDir);
print("Method: " + method);
print("Processed: " + processed);
print("Skipped: " + skipped);
print("Log: " + logPath);

showMessage("Normalization Complete",
    "Processed: " + processed +
    "\nSkipped: " + skipped +
    "\nOutput: " + outputDir);

// --------------------------------------------
// Helper: Percentile from histogram
// --------------------------------------------

// getRawStatistics bins 8- and 16-bit histograms one bin per grey value
// starting at 0, so bin k is value k. Only 32-bit images get 256 bins spread
// over min..max.

function percentile(hist, min, max, depth, pct) {

    total = 0;

    for (k = 0; k < hist.length; k++)
        total += hist[k];

    if (total == 0)
        return min;

    threshold = total * pct / 100;
    cumulative = 0;

    for (k = 0; k < hist.length; k++) {

        cumulative += hist[k];

        if (cumulative >= threshold) {

            if (depth != 32)
                return k;

            return min + (max - min) *
                (k + 0.5) / hist.length;
        }
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
