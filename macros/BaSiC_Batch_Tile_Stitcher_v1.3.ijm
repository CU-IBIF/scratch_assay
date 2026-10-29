/*
===============================================================================
 BaSiC Flat-Field Correction + Row-Major Tile Stitching
 Fiji / ImageJ Macro
 Version 1.3
===============================================================================

INPUT LAYOUT
------------
Point the macro at either:

 (a) a PARENT folder holding time point subfolders, in which case you pick
     which ones to process:

        Experiment/
            TimePoint_1/   rootname_A01_s1.tif ...
            TimePoint_2/   ...
            ...
            TimePoint_n/

     The folder name is matched case-insensitively, and the separator before
     the number is optional, so TimePoint_1, Timepoint_1, TIMEPOINT-1 and
     TimePoint1 are all recognised. Folders are processed in numeric order, so
     TimePoint_2 comes before TimePoint_10. Any other subfolder is ignored.

 (b) a single folder of tiles, exactly as in earlier versions. If no
     TimePoint folder is found the selected folder is processed on its own.

INPUT FILE NAMING
-----------------
    rootname_A01_s1.tif
    rootname_A01_s2.tif
    ...
    rootname_B03_s1.tif
    ...

The final "_s#" token is interpreted as the tile index.
Everything before "_s#" is treated as the well prefix.

Example:
    Experiment1_A01_s1.tif
        well prefix = Experiment1_A01
        tile index  = 1

GRID ORDER
----------
Tiles are assumed to have been acquired row-by-row:

    s1   s2   s3  ...
    sN   ...

left -> right, then move down one row and begin again at the left.

User enters:
    n = number of columns (X)
    m = number of rows (Y)

Expected tiles per well = n * m.

PROCESSING
----------
For each selected time point folder, and within it each detected well prefix:
    1. Verify exactly n*m tiles exist and s1...s(n*m) are complete.
    2. Open the tiles in numeric s-order.
    3. Convert the tiles to an ImageJ stack.
    4. Assign the original filenames as stack slice labels.
    5. Run BaSiC using the standard/default automatic settings:
         - Estimate shading profiles
         - Estimate flat-field only
         - Automatic regularization
         - Ignore temporal drift
         - Compute shading and correct images
    6. Save every corrected stack slice as a TIFF using its original
       slice label / filename convention, based on the attached export macro.
    7. Run Fiji Grid/Collection Stitching:
         - Grid: row-by-row
         - Right & Down
         - n columns x m rows
         - Linear Blending
         - optional compute overlap
         - memory-saving mode
    8. Save the fused image.

Each time point is flat-fielded on its own tiles. BaSiC is never asked to
estimate one shading profile across time points, since illumination can drift
between acquisitions and pooling them would blur that into the correction.

OUTPUT
------
One output folder is created beside the selected parent folder, with the time
point structure preserved so that wells of the same name never collide:

    BaSiC_Stitch_Output/
        TimePoint_1/
            rootname_A01/
                Corrected_Tiles/
                    rootname_A01_s1.tif
                    rootname_A01_s2.tif
                    ...
                Fused/
                    rootname_A01_BaSiC_Fused.tif
            rootname_A02/
                ...
        TimePoint_2/
            ...

For a single folder of tiles the TimePoint level is absent, which is the layout
earlier versions produced.

A single text processing log covering every selected time point is written to:
    BaSiC_Stitch_Output/BaSiC_Stitch_Log.txt

REQUIREMENTS
------------
- Fiji
- BaSiC plugin installed
- Fiji Stitching / Grid/Collection stitching plugin installed
- Input images must be individual 2D TIFF tiles of matching dimensions/type.
- Close all image windows before running this macro.

NOTES
-----
- The estimated overlap is required as a starting value by the Fiji stitcher.
  If "Compute overlap" is enabled, Fiji refines the tile alignment.
- The macro deliberately refuses incomplete wells rather than allowing missing
  tiles to shift the row-major tile order.
- A time point folder containing no matching tiles is logged and skipped rather
  than aborting the run, so one stray folder cannot lose a long batch.
===============================================================================
*/

requires("1.53");

// -----------------------------------------------------------------------------
// Require an empty ImageJ workspace.
// This guarantees "Images to Stack" contains only the current well.
// -----------------------------------------------------------------------------

if (nImages > 0)
    exit("Please close all image windows before running this macro.\n\n" +
         "This macro uses Images to Stack and requires an empty ImageJ workspace.");

// -----------------------------------------------------------------------------
// Globals.
//
// Settings, the log path and the running totals are shared with
// processFolder() below. ImageJ macro functions cannot see their caller's
// variables, so anything the per-folder work needs is declared here. The "g"
// prefix keeps these from being shadowed by a same-named local inside a
// function, which would silently write to the global instead.
// -----------------------------------------------------------------------------

var gGridX, gGridY, gTileOverlap, gComputeOverlap, gSubpixelAccuracy;
var gTilesPerWell;
var gLogFile;
var gProcessedWells = 0;
var gSkippedWells = 0;
var gFoldersWithNoTiles = 0;

// -----------------------------------------------------------------------------
// Select the parent folder and find any time point subfolders
// -----------------------------------------------------------------------------

parentDir = getDirectory("Choose a parent folder of TimePoint_n folders, or a single folder of tiles");

entries = getFileList(parentDir);
entries = Array.sort(entries);

tpNames = newArray(entries.length);
tpIndex = newArray(entries.length);
tpCount = 0;

for (i = 0; i < entries.length; i++) {

    name = entries[i];

    // getFileList() marks directories with a trailing separator.
    if (endsWith(name, "/") || endsWith(name, "\\"))
        name = substring(name, 0, lengthOf(name) - 1);

    if (!File.isDirectory(parentDir + name))
        continue;

    idx = timepointIndex(name);

    if (idx >= 0) {
        tpNames[tpCount] = name;
        tpIndex[tpCount] = idx;
        tpCount++;
    }
}

sortTimepointsByNumber(tpNames, tpIndex, tpCount);

tpNames = Array.trim(tpNames, tpCount);
tpIndex = Array.trim(tpIndex, tpCount);

// -----------------------------------------------------------------------------
// User settings
// -----------------------------------------------------------------------------

Dialog.create("BaSiC + Tile Stitching");

Dialog.addMessage(
    "Tile order is assumed to be row-major:\n" +
    "left to right, then down one row, then left to right again.\n\n" +
    "n = columns (X)\n" +
    "m = rows (Y)"
);

Dialog.addNumber("Grid columns n (X):", 3);
Dialog.addNumber("Grid rows m (Y):", 3);
Dialog.addNumber("Estimated tile overlap (%):", 10);
Dialog.addCheckbox("Compute overlap during stitching", true);
Dialog.addCheckbox("Use subpixel accuracy", true);

if (tpCount > 0) {

    Dialog.addMessage(
        "Found " + tpCount + " time point folder(s).\n" +
        "Untick any you do not want to process."
    );

    // One column reads naturally; past a dozen, wrap into more columns so the
    // dialog cannot grow taller than the screen.
    tpCols = 1;
    if (tpCount > 12)
        tpCols = floor((tpCount + 11) / 12);
    tpRows = floor((tpCount + tpCols - 1) / tpCols);

    tpDefaults = newArray(tpCount);
    for (i = 0; i < tpCount; i++)
        tpDefaults[i] = true;

    Dialog.addCheckboxGroup(tpRows, tpCols, tpNames, tpDefaults);

    Dialog.addString(
        "Or list time point numbers, e.g. 1-3,5 (overrides the boxes):", "", 28);
}

Dialog.show();

gGridX = round(Dialog.getNumber());
gGridY = round(Dialog.getNumber());
gTileOverlap = Dialog.getNumber();
gComputeOverlap = Dialog.getCheckbox();
gSubpixelAccuracy = Dialog.getCheckbox();

// Read the time point boxes in the order they were added, then the override.
selected = newArray(maxOf(tpCount, 1));

if (tpCount > 0) {

    for (i = 0; i < tpCount; i++)
        selected[i] = Dialog.getCheckbox();

    rangeText = Dialog.getString();
    rangeText = replace(rangeText, " ", "");

    if (lengthOf(rangeText) > 0) {
        err = applyTimepointRange(rangeText, tpIndex, tpCount, selected);
        if (err != "")
            exit(err);
    }
}

if (gGridX < 1)
    exit("Grid columns n must be >= 1.");

if (gGridY < 1)
    exit("Grid rows m must be >= 1.");

if (gTileOverlap < 0 || gTileOverlap >= 100)
    exit("Estimated tile overlap must be >= 0 and < 100 percent.");

gTilesPerWell = gGridX * gGridY;

if (gTilesPerWell < 2)
    exit("BaSiC requires a collection of images.\nPlease use a grid containing at least two tiles.");

// Build the list of folders to process, in numeric time point order.
selectedCount = 0;
for (i = 0; i < tpCount; i++) {
    if (selected[i])
        selectedCount++;
}

if (tpCount > 0 && selectedCount == 0)
    exit("No time points were selected.");

// -----------------------------------------------------------------------------
// Create output root and log
// -----------------------------------------------------------------------------

outputRoot = parentDir + "BaSiC_Stitch_Output" + File.separator;
File.makeDirectory(outputRoot);

gLogFile = outputRoot + "BaSiC_Stitch_Log.txt";

if (tpCount > 0) {
    tpSummary = "Time point folders found: " + tpCount + "\n" +
                "Time point folders selected: " + selectedCount + "\n";
    for (i = 0; i < tpCount; i++) {
        if (selected[i])
            tpSummary = tpSummary + "  " + tpNames[i] + "\n";
    }
} else {
    tpSummary = "Time point folders found: none, processing the selected folder itself\n";
}

logText =
    "BaSiC FLAT-FIELD + STITCHING LOG\n" +
    "================================\n" +
    "Parent directory: " + parentDir + "\n" +
    "Output directory: " + outputRoot + "\n" +
    tpSummary +
    "Grid columns (X): " + gGridX + "\n" +
    "Grid rows (Y): " + gGridY + "\n" +
    "Tiles expected per well: " + gTilesPerWell + "\n" +
    "Estimated overlap (%): " + gTileOverlap + "\n" +
    "Compute overlap: " + gComputeOverlap + "\n" +
    "Subpixel accuracy: " + gSubpixelAccuracy + "\n" +
    "BaSiC settings: automatic/default flat-field estimation; dark-field ignored; temporal drift ignored\n" +
    "Each time point is corrected on its own tiles.\n\n";

File.saveString(logText, gLogFile);

print("Expected " + gTilesPerWell + " tiles per well.");
print("Output: " + outputRoot);

// -----------------------------------------------------------------------------
// Process the selected folders
// -----------------------------------------------------------------------------

foldersProcessed = 0;

if (tpCount == 0) {

    processFolder(parentDir, outputRoot, "");
    foldersProcessed = 1;

} else {

    print("Processing " + selectedCount + " of " + tpCount + " time point folder(s).");

    for (i = 0; i < tpCount; i++) {

        if (!selected[i])
            continue;

        tpSrc = parentDir + tpNames[i] + File.separator;
        tpOut = outputRoot + tpNames[i] + File.separator;

        File.makeDirectory(tpOut);

        print("");
        print("============================================================");
        print("Time point folder: " + tpNames[i]);
        print("============================================================");

        File.append("\n--- " + tpNames[i] + " ---\n", gLogFile);

        processFolder(tpSrc, tpOut, tpNames[i]);
        foldersProcessed++;
    }
}

// -----------------------------------------------------------------------------
// Completion
// -----------------------------------------------------------------------------

summary =
    "\nPROCESSING COMPLETE\n" +
    "Folders processed: " + foldersProcessed + "\n" +
    "Processed wells: " + gProcessedWells + "\n" +
    "Skipped wells: " + gSkippedWells + "\n" +
    "Folders with no matching tiles: " + gFoldersWithNoTiles + "\n" +
    "Output: " + outputRoot + "\n";

print(summary);
File.append(summary, gLogFile);

if (gProcessedWells == 0) {

    showMessage(
        "BaSiC + Stitching: nothing processed",
        "No wells were processed.\n\n" +
        "Folders examined: " + foldersProcessed + "\n" +
        "Folders with no matching tiles: " + gFoldersWithNoTiles + "\n" +
        "Skipped wells: " + gSkippedWells + "\n\n" +
        "Tiles must be named like rootname_A01_s1.tif, and each well must have " +
        "exactly " + gTilesPerWell + " tiles for the grid you entered.\n\n" +
        "See the log:\n" + gLogFile
    );

} else {

    showMessage(
        "BaSiC + Stitching Complete",
        "Processing complete.\n\n" +
        "Folders processed: " + foldersProcessed + "\n" +
        "Processed wells: " + gProcessedWells + "\n" +
        "Skipped wells: " + gSkippedWells + "\n\n" +
        "Output folder:\n" + outputRoot
    );
}


// =============================================================================
// Per-folder processing
// =============================================================================

/*
 * BaSiC-correct and stitch every complete well in one folder.
 *
 *   srcDir  folder holding the rootname_A01_s1.tif tiles
 *   outRoot where this folder's per-well output goes
 *   label   time point name for the log, or "" for a single folder run
 *
 * Reads the shared settings from the globals above and adds to the running
 * totals. A folder with no matching tiles is logged and skipped rather than
 * ending the run, so one stray folder cannot lose a long batch.
 */
function processFolder(srcDir, outRoot, label) {

    // Prefix log and print lines with the time point, so a well name that
    // recurs at every time point is still identifiable.
    tag = "";
    if (label != "")
        tag = label + " / ";

    fileList = getFileList(srcDir);
    fileList = Array.sort(fileList);

    // -----------------------------------------------------------------------------
    // Discover unique well prefixes.
    // Array is allocated to the maximum possible number of source files.
    // -----------------------------------------------------------------------------

    prefixes = newArray(fileList.length);
    prefixCount = 0;
    validNamedTiles = 0;

    for (i = 0; i < fileList.length; i++) {

        name = fileList[i];

        if (isTiffFile(name)) {

            stem = removeExtension(name);
            lowerStem = toLowerCase(stem);

            sPos = lastIndexOf(lowerStem, "_s");

            if (sPos > 0) {

                tileText = substring(stem, sPos + 2);
                tileNum = parseInt(tileText);

                if (!isNaN(tileNum) && tileNum >= 1) {

                    prefix = substring(stem, 0, sPos);
                    validNamedTiles++;

                    alreadyListed = false;

                    for (p = 0; p < prefixCount; p++) {
                        if (prefixes[p] == prefix)
                            alreadyListed = true;
                    }

                    if (!alreadyListed) {
                        prefixes[prefixCount] = prefix;
                        prefixCount++;
                    }
                }
            }
        }
    }

    if (prefixCount == 0) {

        msg = "SKIPPED FOLDER: " + label +
              " | no TIFFs matching rootname_A01_s1.tif";

        print(msg);
        File.append(msg + "\n", gLogFile);
        gFoldersWithNoTiles++;

        return;
    }

    print("Detected " + prefixCount + " well prefix(es) in " + label + ".");
    File.append("Well prefixes detected: " + prefixCount + "\n", gLogFile);

    for (p = 0; p < prefixCount; p++) {

        prefix = prefixes[p];

        print("");
        print("------------------------------------------------------------");
        print("Processing well prefix: " + tag + prefix);
        print("------------------------------------------------------------");

        // -------------------------------------------------------------------------
        // Gather tiles s1...sN by numeric tile index.
        // -------------------------------------------------------------------------

        tileFiles = newArray(gTilesPerWell);
        tileFound = newArray(gTilesPerWell);
        duplicateTile = false;

        for (t = 0; t < gTilesPerWell; t++) {
            tileFiles[t] = "";
            tileFound[t] = 0;
        }

        matchedCount = 0;

        for (i = 0; i < fileList.length; i++) {

            name = fileList[i];

            if (isTiffFile(name)) {

                stem = removeExtension(name);
                lowerStem = toLowerCase(stem);
                sPos = lastIndexOf(lowerStem, "_s");

                if (sPos > 0) {

                    thisPrefix = substring(stem, 0, sPos);
                    tileText = substring(stem, sPos + 2);
                    tileNum = parseInt(tileText);

                    if (thisPrefix == prefix && !isNaN(tileNum) && tileNum >= 1) {

                        matchedCount++;

                        if (tileNum <= gTilesPerWell) {

                            arrayIndex = tileNum - 1;

                            if (tileFound[arrayIndex] == 1) {
                                duplicateTile = true;
                            } else {
                                tileFiles[arrayIndex] = name;
                                tileFound[arrayIndex] = 1;
                            }
                        }
                    }
                }
            }
        }

        complete = true;

        for (t = 0; t < gTilesPerWell; t++) {
            if (tileFound[t] == 0)
                complete = false;
        }

        if (matchedCount != gTilesPerWell)
            complete = false;

        if (duplicateTile)
            complete = false;

        // -------------------------------------------------------------------------
        // Skip incomplete or ambiguous wells.
        // -------------------------------------------------------------------------

        if (!complete) {

            msg =
                "SKIPPED: " + tag + prefix +
                " | found=" + matchedCount +
                " | expected=" + gTilesPerWell;

            if (duplicateTile)
                msg = msg + " | duplicate tile index detected";

            print(msg);
            File.append(msg + "\n", gLogFile);

            for (t = 0; t < gTilesPerWell; t++) {
                if (tileFound[t] == 0) {
                    missingMsg = "  Missing tile: " + prefix + "_s" + (t + 1);
                    print(missingMsg);
                    File.append(missingMsg + "\n", gLogFile);
                }
            }

            gSkippedWells++;
        }

        else {

            // ---------------------------------------------------------------------
            // Create per-well output structure.
            // ---------------------------------------------------------------------

            // Sanitize the well prefix ONCE, then use the resulting plain string.
            // Avoid placing a user-defined string-return function directly inside
            // concatenation expressions; some ImageJ macro interpreter builds
            // can report "Numeric return value expected" in that situation.
            safePrefix = prefix;
            safePrefix = replace(safePrefix, "\\", "_");
            safePrefix = replace(safePrefix, "/", "_");
            safePrefix = replace(safePrefix, ":", "_");
            safePrefix = replace(safePrefix, "*", "_");
            safePrefix = replace(safePrefix, "?", "_");
            safePrefix = replace(safePrefix, "\"", "_");
            safePrefix = replace(safePrefix, "<", "_");
            safePrefix = replace(safePrefix, ">", "_");
            safePrefix = replace(safePrefix, "|", "_");

            wellDir = outRoot + safePrefix + File.separator;
            correctedDir = wellDir + "Corrected_Tiles" + File.separator;
            fusedDir = wellDir + "Fused" + File.separator;

            File.makeDirectory(wellDir);
            File.makeDirectory(correctedDir);
            File.makeDirectory(fusedDir);

            // ---------------------------------------------------------------------
            // Open source tiles in explicit numeric s-order.
            // Verify all images are single-plane and dimensions/type match.
            // ---------------------------------------------------------------------

            dimensionsOK = true;
            refW = -1;
            refH = -1;
            refBitDepth = -1;

            for (t = 0; t < gTilesPerWell; t++) {

                open(srcDir + tileFiles[t]);

                getDimensions(w, h, c, z, frames);
                bd = bitDepth();

                if (c != 1 || z != 1 || frames != 1) {
                    dimensionsOK = false;
                    print("Invalid dimensionality: " + tileFiles[t] +
                          " | C=" + c + " Z=" + z + " T=" + frames);
                }

                if (t == 0) {
                    refW = w;
                    refH = h;
                    refBitDepth = bd;
                } else {
                    if (w != refW || h != refH || bd != refBitDepth) {
                        dimensionsOK = false;
                        print("Dimension/type mismatch: " + tileFiles[t]);
                    }
                }
            }

            if (!dimensionsOK) {

                File.append(
                    "SKIPPED: " + tag + prefix +
                    " | source tiles do not have matching 2D dimensions/type\n",
                    gLogFile
                );

                closeAllImagesWithoutSaving();
                gSkippedWells++;
            }

            else {

                // -----------------------------------------------------------------
                // Convert opened tiles to one stack.
                // Source files were opened in s1...sN order.
                // -----------------------------------------------------------------

                run("Images to Stack", "name=BaSiC_Input title=[] use");

                inputStackID = getImageID();

                // Explicitly set source filenames as slice labels so the BaSiC
                // corrected stack can be exported exactly using those labels.
                for (s = 1; s <= gTilesPerWell; s++) {
                    selectImage(inputStackID);
                    setSlice(s);
                    Property.setSliceLabel(tileFiles[s - 1], s);
                }

                // -----------------------------------------------------------------
                // Run BaSiC with the standard automatic/default correction profile.
                //
                // Recorder-compatible parameters based on the BaSiC Fiji plugin:
                //   Estimate shading profiles
                //   Estimate flat-field only
                //   Automatic regularization
                //   Ignore temporal drift
                //   Compute shading and correct images
                // -----------------------------------------------------------------

                selectImage(inputStackID);

                run(
                    "BaSiC ",
                    "processing_stack=BaSiC_Input " +
                    "flat-field=None " +
                    "dark-field=None " +
                    "shading_estimation=[Estimate shading profiles] " +
                    "shading_model=[Estimate flat-field only (ignore dark-field)] " +
                    "setting_regularisationparametes=Automatic " +
                    "temporal_drift=Ignore " +
                    "correction_options=[Compute shading and correct images] " +
                    "lambda_flat=0.50 lambda_dark=0.50"
                );

                correctedTitle = "Corrected:BaSiC_Input";

                if (!isOpen(correctedTitle)) {

                    closeAllImagesWithoutSaving();

                    exit(
                        "BaSiC completed but the expected corrected stack was not found:\n" +
                        correctedTitle + "\n\n" +
                        "This can occur if your installed BaSiC version uses a different " +
                        "output title or command parameters.\n\n" +
                        "Use Plugins > Macros > Record, run BaSiC once manually, and compare " +
                        "the recorded BaSiC command with the command in this macro."
                    );
                }

                selectWindow(correctedTitle);
                correctedID = getImageID();

                correctedSlices = nSlices;

                if (correctedSlices != gTilesPerWell) {

                    closeAllImagesWithoutSaving();

                    exit(
                        "BaSiC corrected stack slice count does not match the expected tile count.\n\n" +
                        "Well: " + tag + prefix + "\n" +
                        "Expected: " + gTilesPerWell + "\n" +
                        "Corrected stack: " + correctedSlices
                    );
                }

                // Re-assert the original source filenames as corrected-stack labels.
                // This makes downstream export deterministic even if a BaSiC build
                // changes, shortens, or drops the input slice labels.
                for (s = 1; s <= correctedSlices; s++) {
                    selectImage(correctedID);
                    Property.setSliceLabel(tileFiles[s - 1], s);
                }

                // -----------------------------------------------------------------
                // Save corrected stack slices.
                // This follows the behavior of the user's attached export macro:
                //   - use slice label as filename
                //   - remove original extension
                //   - sanitize Windows-invalid characters
                //   - save each current slice as an individual TIFF
                // -----------------------------------------------------------------

                for (s = 1; s <= correctedSlices; s++) {

                    selectImage(correctedID);
                    setSlice(s);

                    label = getInfo("slice.label");

                    // BaSiC should preserve labels, but use the original source
                    // filename as a deterministic fallback.
                    if (label == "")
                        label = tileFiles[s - 1];

                    label = removeExtension(label);
                    label = replace(label, "\\", "_");
                    label = replace(label, "/", "_");
                    label = replace(label, ":", "_");
                    label = replace(label, "*", "_");
                    label = replace(label, "?", "_");
                    label = replace(label, "\"", "_");
                    label = replace(label, "<", "_");
                    label = replace(label, ">", "_");
                    label = replace(label, "|", "_");

                    run("Duplicate...", "title=[" + label + "]");
                    saveAs("Tiff", correctedDir + label + ".tif");
                    close();
                }

                File.append(
                    "BaSiC corrected: " + tag + prefix +
                    " | tiles=" + correctedSlices + "\n",
                    gLogFile
                );

                // Free BaSiC/source images before stitching.
                closeAllImagesWithoutSaving();

                // -----------------------------------------------------------------
                // Fiji Grid/Collection Stitching
                //
                // Row-major layout:
                //   Grid: row-by-row
                //   Right & Down
                //
                // Corrected filenames are:
                //   prefix_s1.tif ... prefix_sN.tif
                // -----------------------------------------------------------------

                stitchPattern = prefix + "_s{i}.tif";

                stitchOptions =
                    "type=[Grid: row-by-row] " +
                    "order=[Right & Down                ] " +
                    "grid_size_x=" + gGridX + " " +
                    "grid_size_y=" + gGridY + " " +
                    "tile_overlap=" + gTileOverlap + " " +
                    "first_file_index_i=1 " +
                    "directory=[" + correctedDir + "] " +
                    "file_names=[" + stitchPattern + "] " +
                    "output_textfile_name=TileConfiguration.txt " +
                    "fusion_method=[Linear Blending] " +
                    "regression_threshold=0.30 " +
                    "max/avg_displacement_threshold=2.50 " +
                    "absolute_displacement_threshold=3.50 ";

                if (gComputeOverlap)
                    stitchOptions = stitchOptions + "compute_overlap ";

                if (gSubpixelAccuracy)
                    stitchOptions = stitchOptions + "subpixel_accuracy ";

                stitchOptions =
                    stitchOptions +
                    "computation_parameters=[Save memory (but be slower)] " +
                    "image_output=[Fuse and display]";

                run("Grid/Collection stitching", stitchOptions);

                // The fused image is the active image when the stitcher finishes.
                // safePrefix was precomputed above. Keeping the function call out
                // of this concatenation avoids the ImageJ parser error seen in
                // v1.1 ("Numeric return value expected").
                fusedName = safePrefix + "_BaSiC_Fused.tif";
                fusedPath = fusedDir + fusedName;

                saveAs("Tiff", fusedPath);

                // Verify that the fused image was actually written before
                // continuing to the next well.
                if (!File.exists(fusedPath)) {
                    exit(
                        "The fused image was created in Fiji but could not be verified on disk.\n\n" +
                        "Expected file:\n" + fusedPath
                    );
                }

                File.append(
                    "FUSED: " + tag + prefix +
                    " | " + gGridX + "x" + gGridY +
                    " | output=" + fusedPath + " | VERIFIED\n",
                    gLogFile
                );

                print("Saved fused image:");
                print(fusedPath);

                closeAllImagesWithoutSaving();

                gProcessedWells++;
            }
        }
    }
}


// =============================================================================
// Helper functions
// =============================================================================

function isTiffFile(name) {

    lower = toLowerCase(name);

    return endsWith(lower, ".tif") ||
           endsWith(lower, ".tiff");
}


function removeExtension(name) {

    lower = toLowerCase(name);

    if (endsWith(lower, ".tiff"))
        return substring(name, 0, lengthOf(name) - 5);

    if (endsWith(lower, ".tif"))
        return substring(name, 0, lengthOf(name) - 4);

    if (endsWith(lower, ".png"))
        return substring(name, 0, lengthOf(name) - 4);

    if (endsWith(lower, ".jpg"))
        return substring(name, 0, lengthOf(name) - 4);

    if (endsWith(lower, ".jpeg"))
        return substring(name, 0, lengthOf(name) - 5);

    return name;
}



function closeAllImagesWithoutSaving() {

    while (nImages > 0) {
        setOption("Changes", false);
        close();
    }
}

/*
 * Sort parallel name/number arrays into ascending numeric order, in place, so
 * TimePoint_2 precedes TimePoint_10 instead of following it.
 *
 * Insertion sort: n is the number of time points, and being obviously correct
 * matters more here than being fast. Arrays are passed by reference, so the
 * caller sees the reordering.
 */
function sortTimepointsByNumber(names, idx, count) {

    for (a = 1; a < count; a++) {

        keyName = names[a];
        keyIdx = idx[a];
        b = a - 1;

        // The bounds test is a separate statement on purpose: the ImageJ macro
        // language does not short-circuit &&, so "b >= 0 && idx[b] > keyIdx"
        // still evaluates idx[-1] and aborts the macro.
        while (b >= 0) {

            if (idx[b] <= keyIdx)
                break;

            names[b + 1] = names[b];
            idx[b + 1] = idx[b];
            b--;
        }

        names[b + 1] = keyName;
        idx[b + 1] = keyIdx;
    }
}


/*
 * Apply a time point list such as "1-3,5,8" to the selection array, in place.
 *
 * The numbers refer to the numbers in the folder names, not to positions in
 * the list, so "5" means TimePoint_5 wherever it sits. Returns "" on success
 * or a message to show the user, rather than exiting, so the parsing can be
 * exercised by the tests.
 */
function applyTimepointRange(rangeText, idx, count, selected) {

    for (i = 0; i < count; i++)
        selected[i] = false;

    tokens = split(rangeText, ",");

    for (k = 0; k < tokens.length; k++) {

        tok = tokens[k];

        if (lengthOf(tok) == 0)
            continue;

        dash = indexOf(tok, "-");

        if (dash > 0 && dash < lengthOf(tok) - 1) {
            lo = parseInt(substring(tok, 0, dash));
            hi = parseInt(substring(tok, dash + 1));
        } else {
            lo = parseInt(tok);
            hi = lo;
        }

        if (isNaN(lo) || isNaN(hi))
            return "Could not read \"" + tok + "\" in the time point list.\n\n" +
                   "Use numbers and ranges, for example: 1-3,5,8";

        if (lo > hi) {
            swap = lo;
            lo = hi;
            hi = swap;
        }

        matched = false;

        for (i = 0; i < count; i++) {
            if (idx[i] >= lo && idx[i] <= hi) {
                selected[i] = true;
                matched = true;
            }
        }

        if (!matched)
            return "No time point folder matches \"" + tok + "\".\n\n" +
                   "The numbers refer to the folder names, not their position " +
                   "in the list.";
    }

    return "";
}


/*
 * The trailing number of a TimePoint folder name, or -1 if the name is not one.
 *
 * Matching is case-insensitive and the separator before the number is
 * optional, so TimePoint_1, Timepoint_1, TIMEPOINT-1 and TimePoint1 all read
 * as 1. Every remaining character has to be a digit, so TimePoint_1_old is
 * not silently treated as time point 1.
 */
function timepointIndex(name) {

    lower = toLowerCase(name);

    if (!startsWith(lower, "timepoint"))
        return -1;

    rest = substring(name, 9);

    while (lengthOf(rest) > 0 &&
           (startsWith(rest, "_") || startsWith(rest, "-") || startsWith(rest, " ")))
        rest = substring(rest, 1);

    if (lengthOf(rest) == 0)
        return -1;

    digits = "0123456789";

    for (c = 0; c < lengthOf(rest); c++) {
        if (indexOf(digits, substring(rest, c, c + 1)) < 0)
            return -1;
    }

    return parseInt(rest);
}
