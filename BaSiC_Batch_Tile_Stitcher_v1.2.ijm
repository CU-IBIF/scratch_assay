/*
===============================================================================
 BaSiC Flat-Field Correction + Row-Major Tile Stitching
 Fiji / ImageJ Macro
 Version 1.2
===============================================================================

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
For each detected well prefix:
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

OUTPUT
------
An output folder is created beside the source data:

    BaSiC_Stitch_Output/
        rootname_A01/
            Corrected_Tiles/
                rootname_A01_s1.tif
                rootname_A01_s2.tif
                ...
            Fused/
                rootname_A01_BaSiC_Fused.tif
        rootname_A02/
            ...

A text processing log is also written to:
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
// Select input folder
// -----------------------------------------------------------------------------

inputDir = getDirectory("Choose folder containing tiled TIFF images");

fileList = getFileList(inputDir);
fileList = Array.sort(fileList);

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

Dialog.show();

gridX = round(Dialog.getNumber());
gridY = round(Dialog.getNumber());
tileOverlap = Dialog.getNumber();
computeOverlap = Dialog.getCheckbox();
subpixelAccuracy = Dialog.getCheckbox();

if (gridX < 1)
    exit("Grid columns n must be >= 1.");

if (gridY < 1)
    exit("Grid rows m must be >= 1.");

if (tileOverlap < 0 || tileOverlap >= 100)
    exit("Estimated tile overlap must be >= 0 and < 100 percent.");

tilesPerWell = gridX * gridY;

if (tilesPerWell < 2)
    exit("BaSiC requires a collection of images.\nPlease use a grid containing at least two tiles.");

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

if (prefixCount == 0)
    exit(
        "No TIFF files matching the expected naming pattern were found.\n\n" +
        "Expected format:\nrootname_A01_s1.tif"
    );

// -----------------------------------------------------------------------------
// Create output root and log
// -----------------------------------------------------------------------------

outputRoot = inputDir + "BaSiC_Stitch_Output" + File.separator;
File.makeDirectory(outputRoot);

logFile = outputRoot + "BaSiC_Stitch_Log.txt";

logText =
    "BaSiC FLAT-FIELD + STITCHING LOG\n" +
    "================================\n" +
    "Input directory: " + inputDir + "\n" +
    "Output directory: " + outputRoot + "\n" +
    "Grid columns (X): " + gridX + "\n" +
    "Grid rows (Y): " + gridY + "\n" +
    "Tiles expected per well: " + tilesPerWell + "\n" +
    "Estimated overlap (%): " + tileOverlap + "\n" +
    "Compute overlap: " + computeOverlap + "\n" +
    "Subpixel accuracy: " + subpixelAccuracy + "\n" +
    "BaSiC settings: automatic/default flat-field estimation; dark-field ignored; temporal drift ignored\n" +
    "Detected well prefixes: " + prefixCount + "\n\n";

File.saveString(logText, logFile);

print("Detected " + prefixCount + " well prefix(es).");
print("Expected " + tilesPerWell + " tiles per well.");
print("Output: " + outputRoot);

// -----------------------------------------------------------------------------
// Process each well
// -----------------------------------------------------------------------------

processedWells = 0;
skippedWells = 0;

for (p = 0; p < prefixCount; p++) {

    prefix = prefixes[p];

    print("");
    print("------------------------------------------------------------");
    print("Processing well prefix: " + prefix);
    print("------------------------------------------------------------");

    // -------------------------------------------------------------------------
    // Gather tiles s1...sN by numeric tile index.
    // -------------------------------------------------------------------------

    tileFiles = newArray(tilesPerWell);
    tileFound = newArray(tilesPerWell);
    duplicateTile = false;

    for (t = 0; t < tilesPerWell; t++) {
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

                    if (tileNum <= tilesPerWell) {

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

    for (t = 0; t < tilesPerWell; t++) {
        if (tileFound[t] == 0)
            complete = false;
    }

    if (matchedCount != tilesPerWell)
        complete = false;

    if (duplicateTile)
        complete = false;

    // -------------------------------------------------------------------------
    // Skip incomplete or ambiguous wells.
    // -------------------------------------------------------------------------

    if (!complete) {

        msg =
            "SKIPPED: " + prefix +
            " | found=" + matchedCount +
            " | expected=" + tilesPerWell;

        if (duplicateTile)
            msg = msg + " | duplicate tile index detected";

        print(msg);
        File.append(msg + "\n", logFile);

        for (t = 0; t < tilesPerWell; t++) {
            if (tileFound[t] == 0) {
                missingMsg = "  Missing tile: " + prefix + "_s" + (t + 1);
                print(missingMsg);
                File.append(missingMsg + "\n", logFile);
            }
        }

        skippedWells++;
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

        wellDir = outputRoot + safePrefix + File.separator;
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

        for (t = 0; t < tilesPerWell; t++) {

            open(inputDir + tileFiles[t]);

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
                "SKIPPED: " + prefix +
                " | source tiles do not have matching 2D dimensions/type\n",
                logFile
            );

            closeAllImagesWithoutSaving();
            skippedWells++;
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
            for (s = 1; s <= tilesPerWell; s++) {
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

            if (correctedSlices != tilesPerWell) {

                closeAllImagesWithoutSaving();

                exit(
                    "BaSiC corrected stack slice count does not match the expected tile count.\n\n" +
                    "Well: " + prefix + "\n" +
                    "Expected: " + tilesPerWell + "\n" +
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
                "BaSiC corrected: " + prefix +
                " | tiles=" + correctedSlices + "\n",
                logFile
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
                "grid_size_x=" + gridX + " " +
                "grid_size_y=" + gridY + " " +
                "tile_overlap=" + tileOverlap + " " +
                "first_file_index_i=1 " +
                "directory=[" + correctedDir + "] " +
                "file_names=[" + stitchPattern + "] " +
                "output_textfile_name=TileConfiguration.txt " +
                "fusion_method=[Linear Blending] " +
                "regression_threshold=0.30 " +
                "max/avg_displacement_threshold=2.50 " +
                "absolute_displacement_threshold=3.50 ";

            if (computeOverlap)
                stitchOptions = stitchOptions + "compute_overlap ";

            if (subpixelAccuracy)
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
                "FUSED: " + prefix +
                " | " + gridX + "x" + gridY +
                " | output=" + fusedPath + " | VERIFIED\n",
                logFile
            );

            print("Saved fused image:");
            print(fusedPath);

            closeAllImagesWithoutSaving();

            processedWells++;
        }
    }
}

// -----------------------------------------------------------------------------
// Completion
// -----------------------------------------------------------------------------

summary =
    "\nPROCESSING COMPLETE\n" +
    "Processed wells: " + processedWells + "\n" +
    "Skipped wells: " + skippedWells + "\n" +
    "Output: " + outputRoot + "\n";

print(summary);
File.append(summary, logFile);

showMessage(
    "BaSiC + Stitching Complete",
    "Processing complete.\n\n" +
    "Processed wells: " + processedWells + "\n" +
    "Skipped wells: " + skippedWells + "\n\n" +
    "Output folder:\n" + outputRoot
);


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
