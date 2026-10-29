/*
======================================================================
 PHASE-CONTRAST SCRATCH ASSAY ANALYZER v5.5.0
 Two-pass variance/texture segmentation + temporal tracking
 + timestamped settings/provenance logger
 ImageJ / Fiji macro
======================================================================

PURPOSE
-------
Quantify phase-contrast scratch/wound-healing assays using local variance
(texture) rather than raw phase intensity.

PASS 1
------
1. Convert source image to 8-bit grayscale.
2. Optional rolling-ball background correction.
3. Calculate a local variance map.
4. Smooth/normalize the variance map.
5. Segment the LOW-variance wound region.
6. Select wound candidate by largest area or temporal tracking.
7. Rebuild into a guaranteed 8-bit 0/255 mask.
8. Apply rank-based morphology (Maximum/Minimum filters).
9. Retain the dominant wound component.

OPTIONAL PASS 2: BOUNDARY REFINEMENT
------------------------------------
1. Use the Pass-1 wound ROI as the prior boundary.
2. Erode and dilate the Pass-1 mask by a user-set number of pixels.
3. The difference between dilated and eroded masks defines a narrow
   boundary-search band around the Pass-1 ROI line.
4. Calculate a SECOND local variance map from the original phase image.
5. Determine the second-pass threshold using ONLY the boundary band.
6. Keep the eroded Pass-1 wound core and reclassify only pixels inside
   the boundary band as wound/non-wound based on the second variance map.
7. Apply optional rank-based refinement morphology.
8. Retain the component nearest the Pass-1 wound centroid.
9. If refinement fails, automatically fall back to the Pass-1 mask.

TEMPORAL OUTPUTS
----------------
- Wound area
- Percent open
- Percent closure relative to first valid frame
- Mean/median wound width
- Width SD and number of sampled lines
- Mean positions of both wound edges
- Inward edge velocities
- Width closure rate
- Area closure rate
- Centroid

QC OVERLAY
----------
Red    = FINAL wound boundary
Yellow = Pass-1 wound boundary (when Pass 2 is enabled)
Cyan   = analysis ROI

OUTPUTS
-------
Scratch_Assay_Results/
    Scratch_Assay_Texture_Tracking.csv
    Scratch_Assay_Settings_YYYYMMDD_HHMMSS.txt
    QC/
        *_QC.png
    Masks/
        *_wound_mask.tif                [optional]

CHANGES IN v5.5.0 (correctness / robustness)
--------------------------------------------
1. CSV rows evaluated to NaN and no data row could ever be written.
   The row expressions began with frameIndex, a number, so ImageJ
   evaluated the whole concatenation numerically - the first "," parsed
   as NaN and took the entire row with it. Both row builders now start
   with a string constant. Every row is additionally field-counted
   against the header before it is committed, which is what turned this
   from a silent "CSV verification failed" into a located fault.
2. Frame order: the file list was sorted with a plain alphabetical sort,
   so t10 sorted before t2 and the time series was silently scrambled.
   Replaced with a digit-aware (natural) sort; the resolved frame order is
   printed to the Log and recorded in the settings file.
3. Variance is computed in 8-bit, as in v5.4.5. ImageJ's rank filter
   clamps 8-bit variance output to 0-255, so high-texture regions
   saturate, but the threshold methods and the shipped parameter defaults
   are calibrated for that map and it is kept deliberately.
4. 8-bit conversion of 16/32-bit sources depended on whatever display
   range each file happened to carry. resetMinAndMax() is now applied
   first, making the conversion deterministic across frames.
5. Centroid_X_px / Centroid_Y_px reported the bounding-box centre, not the
   centroid. True area centroids are now measured and are also what
   temporal tracking matches on.
6. Width, edge, and centroid columns are written as NA when no wound was
   segmented, instead of 0, which previously entered mean-width and
   edge-position curves as real measurements.
7. Width/edge measurement scanned the whole analysis ROI pixel by pixel.
   It now scans only the wound bounding box and stops at the first and
   last wound pixel of each line - identical results, far fewer getPixel
   calls.
8. Analyze Particles is called with the "pixel" flag so the minimum-area
   filter cannot be reinterpreted through an image calibration.
9. All abort paths now leave batch mode and restore ImageJ settings.
10. Output directories are verified to exist before analysis starts.

IMPORTANT
---------
No Process > Binary > Fill Holes/Open/Close commands are used.
Morphology uses grayscale-safe Maximum/Minimum rank filters on explicit
8-bit 0/255 masks.

The selected input folder is treated as ONE time series. Supported image
files are sorted alphabetically and frame time is assigned from the user-
entered frame interval.
======================================================================
*/

requires("1.53");


// ====================================================================
// VERSION
// ====================================================================

var macroVersion = "5.5.0";


// ====================================================================
// USER-ADJUSTABLE DEFAULTS - PASS 1
// ====================================================================

var rollingBall = 50;            // px; 0 disables
var varianceRadius = 5;          // local variance radius, px
var textureSmoothSigma = 2;      // variance-map Gaussian smoothing, px
var minWoundArea = 5000;         // minimum wound candidate, px^2
var analysisPercent = 90;        // central width AND height retained
var thresholdMethod = "Otsu";    // Pass-1 variance threshold method
var morphCloseIterations = 2;    // Maximum -> Minimum, radius 1
var morphOpenIterations = 1;     // Minimum -> Maximum, radius 1


// ====================================================================
// USER-ADJUSTABLE DEFAULTS - OPTIONAL PASS 2
// ====================================================================

var useSecondPass = true;
var refineBandPx = 20;               // +/- boundary movement allowed, px
var refineVarianceRadius = 3;        // second local-variance radius, px
var refineSmoothSigma = 1;           // second variance-map smoothing, px
var refineThresholdMethod = "Otsu";  // threshold calculated in boundary band
var refineCloseIterations = 1;       // optional final refinement closing
var refineOpenIterations = 0;        // optional final refinement opening


// ====================================================================
// USER-ADJUSTABLE DEFAULTS - TIME SERIES / OUTPUT
// ====================================================================

var frameIntervalHours = 1;
var pixelSizeUm = 0;              // um/pixel; 0 = unknown
var maxTrackShiftPx = 250;
var saveMasks = true;


// ====================================================================
// GLOBAL STATE / MEASUREMENTS
// ====================================================================

var lastArea = 0;
var lastAnalysisArea = 0;
var lastPercentOpen = 0;
var lastCx = 0;
var lastCy = 0;
var lastBx = 0;
var lastBy = 0;
var lastBw = 0;
var lastBh = 0;
var lastTrackStatus = "";

var lastMeanWidth = 0;
var lastMedianWidth = 0;
var lastWidthSD = 0;
var lastWidthSamples = 0;
var lastEdge1 = 0;
var lastEdge2 = 0;

var lastFirstPassArea = 0;
var lastFirstTextureCut = -1;
var lastSecondTextureCut = -1;
var lastRefineStatus = "DISABLED";

// Analysis ROI
var roiX = 0;
var roiY = 0;
var roiW = 0;
var roiH = 0;

// Temporal tracking
var havePrevious = false;
var havePrevShape = false;
var prevCx = 0;
var prevCy = 0;
var prevArea = 0;
var prevMeanWidth = 0;
var prevEdge1 = 0;
var prevEdge2 = 0;
var prevTimeH = 0;

// First valid baseline and orientation
var firstArea = 0;
var woundOrientation = "";

// Resolved frame order, recorded in the settings/provenance file.
var frameOrderSummary = "";

// Number of image windows already open before this macro starts.
// Recorded for memory/provenance diagnostics; the macro does not close them.
var initialOpenImages = 0;


// ====================================================================
// MAIN
// ====================================================================

saveSettings();
setOption("Limit to threshold", false);

// Remove any named intermediates left by a previously aborted run.
// Existing user/source images with other titles are left untouched.
cleanupScratchIntermediates();
initialOpenImages = nImages;
if (initialOpenImages > 0)
    print("MEMORY NOTE | Existing non-macro image windows at start: " + initialOpenImages);

inputDir = getDirectory("Choose folder containing ONE scratch-assay time series");

outputDir = inputDir + "Scratch_Assay_Results" + File.separator;
qcDir = outputDir + "QC" + File.separator;
maskDir = outputDir + "Masks" + File.separator;

File.makeDirectory(outputDir);
File.makeDirectory(qcDir);

// A read-only or otherwise unwritable input folder makes File.makeDirectory
// fail silently. Detect that here rather than after the first frame.
if (File.exists(outputDir) == false || File.exists(qcDir) == false)
    abortMacro(
        "Output folders could not be created.\n\n" +
        outputDir + "\n\n" +
        "Check that the input folder is writable."
    );

list = getFileList(inputDir);

// Frame order defines the whole time series, so the file list is sorted
// with a digit-aware comparison. A plain Array.sort() is alphabetical and
// places "t10" before "t2", which silently reorders the series.
list = naturalSortFileList(list);

previewFile = "";
inputImageCount = 0;

for (i = 0; i < list.length; i++) {
    if (isImageFile(list[i])) {
        inputImageCount++;
        if (previewFile == "")
            previewFile = list[i];
    }
}

if (previewFile == "")
    abortMacro("No TIFF, PNG, JPG or JPEG images were found.");

print("FRAME ORDER | " + inputImageCount + " supported image(s), digit-aware sort:");
frameOrderSummary = "";
orderIndex = 0;
for (i = 0; i < list.length; i++) {
    if (isImageFile(list[i])) {
        print("  [" + orderIndex + "] " + list[i]);
        frameOrderSummary = frameOrderSummary + "  [" + orderIndex + "] " + list[i] + "\n";
        orderIndex++;
    }
}


// ====================================================================
// PREVIEW / PARAMETER TUNING
// ====================================================================

accepted = false;
previewWidth = 0;
previewHeight = 0;
previewOrientationAccepted = "Unknown";

while (accepted == false) {

    methods = newArray("Otsu", "Triangle", "Li", "Yen", "Default");

    Dialog.create("Scratch Assay - Two-Pass Variance Segmentation");

    Dialog.addMessage(
        "Preview image:\n" + previewFile +
        "\n\nPass 1 detects the LOW-VARIANCE wound region.\n" +
        "Optional Pass 2 re-evaluates variance only within a band\n" +
        "around the Pass-1 wound boundary."
    );

    Dialog.addMessage("PASS 1 - GLOBAL WOUND SEGMENTATION");
    Dialog.addNumber("Rolling-ball radius px (0 disables):", rollingBall);
    Dialog.addNumber("Pass-1 variance radius (px):", varianceRadius);
    Dialog.addNumber("Pass-1 variance smoothing sigma (px):", textureSmoothSigma);
    Dialog.addNumber("Minimum wound area (px^2):", minWoundArea);
    Dialog.addNumber("Central image width/height retained (%):", analysisPercent);
    Dialog.addChoice("Pass-1 threshold method:", methods, thresholdMethod);
    Dialog.addNumber("Pass-1 closing iterations:", morphCloseIterations);
    Dialog.addNumber("Pass-1 opening iterations:", morphOpenIterations);

    Dialog.addMessage("PASS 2 - OPTIONAL BOUNDARY REFINEMENT");
    Dialog.addCheckbox("Enable second-pass boundary refinement", useSecondPass);
    Dialog.addNumber("Boundary search band +/- (px):", refineBandPx);
    Dialog.addNumber("Pass-2 variance radius (px):", refineVarianceRadius);
    Dialog.addNumber("Pass-2 variance smoothing sigma (px):", refineSmoothSigma);
    Dialog.addChoice("Pass-2 threshold method:", methods, refineThresholdMethod);
    Dialog.addNumber("Pass-2 closing iterations:", refineCloseIterations);
    Dialog.addNumber("Pass-2 opening iterations:", refineOpenIterations);

    Dialog.addMessage("TIME SERIES / OUTPUT");
    Dialog.addNumber("Frame interval (hours):", frameIntervalHours);
    Dialog.addNumber("Pixel size (um/pixel; 0 = unknown):", pixelSizeUm);
    Dialog.addNumber("Maximum tracking centroid shift (px):", maxTrackShiftPx);
    Dialog.addCheckbox("Save final binary wound masks", saveMasks);

    Dialog.show();

    rollingBall = Dialog.getNumber();
    varianceRadius = Dialog.getNumber();
    textureSmoothSigma = Dialog.getNumber();
    minWoundArea = Dialog.getNumber();
    analysisPercent = Dialog.getNumber();
    thresholdMethod = Dialog.getChoice();
    morphCloseIterations = round(Dialog.getNumber());
    morphOpenIterations = round(Dialog.getNumber());

    useSecondPass = Dialog.getCheckbox();
    refineBandPx = round(Dialog.getNumber());
    refineVarianceRadius = Dialog.getNumber();
    refineSmoothSigma = Dialog.getNumber();
    refineThresholdMethod = Dialog.getChoice();
    refineCloseIterations = round(Dialog.getNumber());
    refineOpenIterations = round(Dialog.getNumber());

    frameIntervalHours = Dialog.getNumber();
    pixelSizeUm = Dialog.getNumber();
    maxTrackShiftPx = Dialog.getNumber();
    saveMasks = Dialog.getCheckbox();

    sanitizeParameters();

    open(inputDir + previewFile);
    previewSourceID = getImageID();

    getDimensions(pw, ph, pc, pz, pt);
    previewWidth = pw;
    previewHeight = ph;

    if (pc != 1 || pz != 1 || pt != 1) {
        setOption("Changes", false);
        close();
        abortMacro(
            "Preview image must be a single-plane 2D image.\n\n" +
            "Detected C=" + pc + " Z=" + pz + " T=" + pt
        );
    }

    run("Duplicate...", "title=Scratch_Texture_Preview_Work");
    buildWoundMask("Scratch_Preview_Mask", false, previewSourceID);
    previewMaskID = getImageID();

    previewOrientation = inferOrientation();
    previewOrientationAccepted = previewOrientation;
    measureWidthAndEdges(previewOrientation);

    // Build QC overlay ROIs: Pass-1 yellow, final red, analysis ROI cyan.
    roiManager("reset");
    firstRoiIndex = -1;
    finalRoiIndex = -1;

    if (useSecondPass && isOpen("Scratch_First_Pass_Mask")) {
        selectWindow("Scratch_First_Pass_Mask");
        setThreshold(255, 255);
        run("Create Selection");
        if (selectionType() != -1) {
            roiManager("add");
            firstRoiIndex = roiManager("count") - 1;
        }
        resetThreshold();
    }

    selectImage(previewMaskID);
    if (lastArea > 0) {
        setThreshold(255, 255);
        run("Create Selection");
        if (selectionType() != -1) {
            roiManager("add");
            finalRoiIndex = roiManager("count") - 1;
        }
        resetThreshold();
    }

    selectImage(previewSourceID);
    Overlay.clear;

    if (firstRoiIndex >= 0) {
        roiManager("select", firstRoiIndex);
        Overlay.addSelection("yellow", 2);
    }

    if (finalRoiIndex >= 0) {
        roiManager("select", finalRoiIndex);
        Overlay.addSelection("red", 2);
    }

    makeRectangle(roiX, roiY, roiW, roiH);
    Overlay.addSelection("cyan", 2);
    run("Select None");
    Overlay.show;

    previewMessage =
        "PREVIEW RESULTS\n\n" +
        "Red = FINAL wound boundary\n" +
        "Cyan = analysis ROI\n";

    if (useSecondPass)
        previewMessage += "Yellow = Pass-1 boundary\n";

    previewMessage +=
        "\nOrientation: " + previewOrientation +
        "\nPass-1 area: " + lastFirstPassArea + " px^2" +
        "\nFinal area: " + lastArea + " px^2" +
        "\nRefinement: " + lastRefineStatus +
        "\nPercent open: " + d2s(lastPercentOpen, 2) + "%" +
        "\nMean width: " + d2s(lastMeanWidth, 2) + " px" +
        "\nMedian width: " + d2s(lastMedianWidth, 2) + " px" +
        "\n\nDoes the FINAL red outline identify the wound correctly?";

    accepted = getBoolean(
        previewMessage,
        "Use settings",
        "Adjust again"
    );

    selectImage(previewSourceID);
    setOption("Changes", false);
    close();

    if (isOpen(previewMaskID)) {
        selectImage(previewMaskID);
        setOption("Changes", false);
        close();
    }

    cleanupScratchIntermediates();

    roiManager("reset");
}

if (saveMasks)
    File.makeDirectory(maskDir);


// ====================================================================
// OUTPUT FILES + SETTINGS/PROVENANCE
// ====================================================================

csvFile = outputDir + "Scratch_Assay_Texture_Tracking.csv";

settingsPath = saveAnalysisSettings(
    inputDir,
    outputDir,
    qcDir,
    maskDir,
    csvFile,
    previewFile,
    previewWidth,
    previewHeight,
    previewOrientationAccepted,
    inputImageCount
);


// ====================================================================
// RESULTS CSV
// ====================================================================

header =
    "Frame," +
    "Time_h," +
    "Image," +
    "Track_Status," +
    "Orientation," +
    "Segmentation_Mode," +
    "Refinement_Status," +
    "FirstPass_Area_px2," +
    "Wound_Area_px2," +
    "Analysis_Area_px2," +
    "Percent_Open," +
    "Percent_Closure_T0," +
    "Mean_Width_px," +
    "Median_Width_px," +
    "Width_SD_px," +
    "Width_Samples," +
    "Edge1_Mean_px," +
    "Edge2_Mean_px," +
    "Edge1_Inward_Velocity_px_per_h," +
    "Edge2_Inward_Velocity_px_per_h," +
    "Mean_Edge_Velocity_px_per_h," +
    "Width_Closure_Rate_px_per_h," +
    "Area_Closure_Rate_px2_per_h," +
    "Centroid_X_px," +
    "Centroid_Y_px," +
    "Wound_Area_um2," +
    "Mean_Width_um," +
    "Median_Width_um," +
    "Mean_Edge_Velocity_um_per_h," +
    "Pass1_Texture_Cut_0_255," +
    "Pass2_Texture_Cut_0_255," +
    "Pass1_Variance_Radius_px," +
    "Pass1_Smooth_Sigma_px," +
    "Pass1_Threshold_Method," +
    "Pass1_Close_Iterations," +
    "Pass1_Open_Iterations," +
    "Second_Pass_Enabled," +
    "Refinement_Band_px," +
    "Pass2_Variance_Radius_px," +
    "Pass2_Smooth_Sigma_px," +
    "Pass2_Threshold_Method," +
    "Pass2_Close_Iterations," +
    "Pass2_Open_Iterations," +
    "Analysis_Percent";

// Build the CSV in memory and save the complete text after every
// completed frame. This intentionally avoids File.append(), which has
// proven unreliable on the current Windows/Fiji setup.
csvText = header + "\n";
File.saveString(csvText, csvFile);
csvRowsWritten = 0;

// Every row is counted against this before it is committed, so a row that
// does not line up with the header can never reach disk.
csvExpectedFields = countCsvFields(header);

// Verify that the header actually reached disk before analysis starts.
if (File.exists(csvFile) == false)
    abortMacro("CSV initialization failed: output file was not created.\n\n" + csvFile);

csvInitialBytes = File.length(csvFile);
csvLastVerifiedBytes = csvInitialBytes;
if (csvInitialBytes <= 0)
    abortMacro("CSV initialization failed: output file is empty.\n\n" + csvFile);

csvVerifyText = File.openAsString(csvFile);
if (indexOf(csvVerifyText, "Frame,Time_h,Image") < 0)
    abortMacro("CSV initialization failed: header could not be read back.\n\n" + csvFile);

print("CSV initialized and verified:");
print(csvFile);
print("CSV columns: " + csvExpectedFields);
print("Initial CSV size: " + csvInitialBytes + " bytes");
print("Settings/provenance:");
print(settingsPath);


// ====================================================================
// BATCH TIME-SERIES PROCESSING
// ====================================================================

setBatchMode(true);

havePrevious = false;
havePrevShape = false;
woundOrientation = "";
firstArea = 0;
processed = 0;
skipped = 0;
frameIndex = 0;

for (i = 0; i < list.length; i++) {

    filename = list[i];

    if (isImageFile(filename)) {

        showStatus("Two-pass texture scratch assay: " + filename);
        showProgress(i, list.length);

        open(inputDir + filename);
        sourceID = getImageID();

        getDimensions(w, h, c, z, t);
        timeH = frameIndex * frameIntervalHours;

        print(
            "INPUT | " + filename +
            " | Width=" + w + " Height=" + h +
            " C=" + c + " Z=" + z + " T=" + t
        );

        if (c == 1 && z == 1 && t == 1) {

            run("Duplicate...", "title=Scratch_Texture_Work");
            buildWoundMask("Scratch_Wound_Mask", havePrevious, sourceID);
            maskID = getImageID();

            if ((woundOrientation == "" || woundOrientation == "Unknown") && lastArea > 0)
                woundOrientation = inferOrientation();

            measureWidthAndEdges(woundOrientation);

            if (firstArea <= 0 && lastArea > 0)
                firstArea = lastArea;

            if (firstArea > 0)
                closureT0 = 100 * (1 - lastArea / firstArea);
            else
                closureT0 = 0;

            // Width, edge and centroid values are undefined when nothing was
            // segmented. Writing 0 for them lets a failed frame enter mean
            // width / edge-position curves as if it were a real measurement,
            // so those columns are written as NA instead.
            haveShape = false;
            if (lastArea > 0 && lastWidthSamples > 0)
                haveShape = true;

            meanWidthText = "NA";
            medianWidthText = "NA";
            widthSDText = "NA";
            edge1Text = "NA";
            edge2Text = "NA";
            centroidXText = "NA";
            centroidYText = "NA";

            if (haveShape) {
                meanWidthText = d2s(lastMeanWidth, 6);
                medianWidthText = d2s(lastMedianWidth, 6);
                widthSDText = d2s(lastWidthSD, 6);
                edge1Text = d2s(lastEdge1, 6);
                edge2Text = d2s(lastEdge2, 6);
            }

            if (lastArea > 0) {
                centroidXText = d2s(lastCx, 3);
                centroidYText = d2s(lastCy, 3);
            }

            edge1Vel = "NA";
            edge2Vel = "NA";
            meanEdgeVel = "NA";
            widthRate = "NA";
            areaRate = "NA";
            meanEdgeVelUm = "NA";

            if (havePrevious && lastArea > 0 && prevArea > 0) {

                dt = timeH - prevTimeH;
                if (dt <= 0)
                    dt = frameIntervalHours;

                // Area rate needs two areas only.
                ar = (prevArea - lastArea) / dt;
                areaRate = d2s(ar, 6);

                // Edge and width rates need two measured wound shapes.
                // Deriving them from a frame whose widths were never
                // measured would report an edge velocity out of nothing.
                if (haveShape && havePrevShape) {
                    e1v = (lastEdge1 - prevEdge1) / dt;
                    e2v = (prevEdge2 - lastEdge2) / dt;
                    mev = (e1v + e2v) / 2;
                    wr = (prevMeanWidth - lastMeanWidth) / dt;

                    edge1Vel = d2s(e1v, 6);
                    edge2Vel = d2s(e2v, 6);
                    meanEdgeVel = d2s(mev, 6);
                    widthRate = d2s(wr, 6);

                    if (pixelSizeUm > 0)
                        meanEdgeVelUm = d2s(mev * pixelSizeUm, 6);
                }
            }

            woundAreaUm2 = "NA";
            meanWidthUm = "NA";
            medianWidthUm = "NA";

            if (pixelSizeUm > 0) {
                woundAreaUm2 = d2s(lastArea * pixelSizeUm * pixelSizeUm, 6);
                if (haveShape) {
                    meanWidthUm = d2s(lastMeanWidth * pixelSizeUm, 6);
                    medianWidthUm = d2s(lastMedianWidth * pixelSizeUm, 6);
                }
            }

            if (useSecondPass)
                segmentationMode = "TwoPass";
            else
                segmentationMode = "SinglePass";

            if (lastFirstTextureCut >= 0)
                firstCutText = d2s(lastFirstTextureCut, 3);
            else
                firstCutText = "NA";

            if (lastSecondTextureCut >= 0)
                secondCutText = d2s(lastSecondTextureCut, 3);
            else
                secondCutText = "NA";

            // Precompute all CSV text fields using only built-in string
            // operations. This avoids ImageJ interpreter ambiguity with
            // user-defined functions that return strings inside a long
            // concatenation expression.
            qFilename = "\"" + replace(filename, "\"", "\"\"") + "\"";
            qTrackStatus = "\"" + replace(lastTrackStatus, "\"", "\"\"") + "\"";
            qOrientation = "\"" + replace(woundOrientation, "\"", "\"\"") + "\"";
            qSegmentationMode = "\"" + replace(segmentationMode, "\"", "\"\"") + "\"";
            qRefineStatus = "\"" + replace(lastRefineStatus, "\"", "\"\"") + "\"";
            qThresholdMethod = "\"" + replace(thresholdMethod, "\"", "\"\"") + "\"";
            qRefineThresholdMethod = "\"" + replace(refineThresholdMethod, "\"", "\"\"") + "\"";

            secondPassText = "No";
            if (useSecondPass)
                secondPassText = "Yes";

            // The leading "" is load-bearing, not cosmetic.
            //
            // ImageJ decides whether an assignment is a string expression or
            // a numeric one from how the right-hand side STARTS. Beginning
            // with frameIndex - a number - makes the interpreter evaluate the
            // whole concatenation numerically: the very first "," is parsed
            // as a number, yields NaN, and the entire row collapses to NaN.
            // Starting with a string constant forces string concatenation.
            //
            // This is the same interpreter rule the note further down records
            // for user-defined string-returning functions; it applies to any
            // concatenation that begins with a numeric value.
            row = "" +
                frameIndex + "," +
                d2s(timeH, 6) + "," +
                qFilename + "," +
                qTrackStatus + "," +
                qOrientation + "," +
                qSegmentationMode + "," +
                qRefineStatus + "," +
                lastFirstPassArea + "," +
                lastArea + "," +
                lastAnalysisArea + "," +
                d2s(lastPercentOpen, 6) + "," +
                d2s(closureT0, 6) + "," +
                meanWidthText + "," +
                medianWidthText + "," +
                widthSDText + "," +
                lastWidthSamples + "," +
                edge1Text + "," +
                edge2Text + "," +
                edge1Vel + "," +
                edge2Vel + "," +
                meanEdgeVel + "," +
                widthRate + "," +
                areaRate + "," +
                centroidXText + "," +
                centroidYText + "," +
                woundAreaUm2 + "," +
                meanWidthUm + "," +
                medianWidthUm + "," +
                meanEdgeVelUm + "," +
                firstCutText + "," +
                secondCutText + "," +
                varianceRadius + "," +
                textureSmoothSigma + "," +
                qThresholdMethod + "," +
                morphCloseIterations + "," +
                morphOpenIterations + "," +
                secondPassText + "," +
                refineBandPx + "," +
                refineVarianceRadius + "," +
                refineSmoothSigma + "," +
                qRefineThresholdMethod + "," +
                refineCloseIterations + "," +
                refineOpenIterations + "," +
                analysisPercent;

            // Commit this frame's FINAL measurements immediately by
            // rewriting the complete CSV, then read it back to verify that
            // the current image row is physically present on disk.
            rowFields = countCsvFields(row);
            if (rowFields != csvExpectedFields)
                abortMacro(
                    "Internal CSV error: row for frame " + frameIndex + " has " +
                    rowFields + " fields but the header has " + csvExpectedFields + ".\n\n" +
                    "Image: " + filename
                );

            csvText = csvText + row + "\n";
            csvRowsWritten++;
            File.saveString(csvText, csvFile);

            if (File.exists(csvFile) == false)
                abortMacro("CSV write failed: file disappeared after frame " + frameIndex + ".\n\n" + csvFile);

            csvVerifyText = File.openAsString(csvFile);
            csvCurrentBytes = File.length(csvFile);

            if (csvCurrentBytes <= csvLastVerifiedBytes || indexOf(csvVerifyText, qFilename) < 0)
                abortMacro(
                    "CSV verification failed after frame " + frameIndex + ".\n\n" +
                    "The measurements were calculated, but the row could not be confirmed on disk.\n\n" +
                    "CSV: " + csvFile + "\n" +
                    "Bytes: " + csvCurrentBytes + "\n" +
                    "Image: " + filename + "\n\n" +
                    "Make sure the CSV is not open in Excel or another program during analysis."
                );

            csvLastVerifiedBytes = csvCurrentBytes;

            print(
                "CSV VERIFIED | Frame=" + frameIndex +
                " | Image=" + filename +
                " | Rows=" + csvRowsWritten +
                " | Bytes=" + csvCurrentBytes +
                " | Track=" + lastTrackStatus +
                " | Refine=" + lastRefineStatus +
                " | Pass1Area=" + lastFirstPassArea +
                " | FinalArea=" + lastArea
            );

            base = stripExtension(filename);

            if (saveMasks) {
                selectImage(maskID);
                saveAs("tiff", maskDir + base + "_wound_mask.tif");
            }

            // --------------------------------------------------------
            // QC OVERLAY
            // --------------------------------------------------------

            roiManager("reset");
            firstRoiIndex = -1;
            finalRoiIndex = -1;

            if (useSecondPass && isOpen("Scratch_First_Pass_Mask")) {
                selectWindow("Scratch_First_Pass_Mask");
                setThreshold(255, 255);
                run("Create Selection");
                if (selectionType() != -1) {
                    roiManager("add");
                    firstRoiIndex = roiManager("count") - 1;
                }
                resetThreshold();
            }

            selectImage(maskID);
            if (lastArea > 0) {
                setThreshold(255, 255);
                run("Create Selection");
                if (selectionType() != -1) {
                    roiManager("add");
                    finalRoiIndex = roiManager("count") - 1;
                }
                resetThreshold();
            }

            selectImage(sourceID);
            Overlay.clear;

            if (firstRoiIndex >= 0) {
                roiManager("select", firstRoiIndex);
                Overlay.addSelection("yellow", 2);
            }

            if (finalRoiIndex >= 0) {
                roiManager("select", finalRoiIndex);
                Overlay.addSelection("red", 2);
            }

            makeRectangle(roiX, roiY, roiW, roiH);
            Overlay.addSelection("cyan", 2);
            run("Select None");
            Overlay.show;

            // 16- and 32-bit sources carry an arbitrary display range, and
            // Flatten renders through it, so a QC PNG can come out black.
            // Stretching the display range fixes that; no pixel data is
            // altered, and the Pass-2 duplicate of this image was taken long
            // before this point. 8-bit and RGB are left alone.
            if (bitDepth() == 16 || bitDepth() == 32)
                run("Enhance Contrast", "saturated=0.35");

            run("Flatten");
            qcID = getImageID();

            if (qcID != sourceID) {
                saveAs("png", qcDir + base + "_QC.png");
                setOption("Changes", false);
                close();
            } else {
                print("QC WARNING | Flatten produced no overlay image for " + filename);
            }

            // --------------------------------------------------------
            // TEMPORAL STATE
            // --------------------------------------------------------

            if (lastArea > 0) {
                prevCx = lastCx;
                prevCy = lastCy;
                prevArea = lastArea;
                prevMeanWidth = lastMeanWidth;
                prevEdge1 = lastEdge1;
                prevEdge2 = lastEdge2;
                prevTimeH = timeH;
                havePrevious = true;
                havePrevShape = haveShape;
            }

            selectImage(maskID);
            setOption("Changes", false);
            close();

            cleanupScratchIntermediates();

            processed++;

        } else {

            // Preserve chronology and record unsupported images.
            if (useSecondPass)
                segmentationMode = "TwoPass";
            else
                segmentationMode = "SinglePass";

            skippedStatus = "SKIPPED_DIMENSIONS_C" + c + "_Z" + z + "_T" + t;
            qFilename = "\"" + replace(filename, "\"", "\"\"") + "\"";
            qSkippedStatus = "\"" + replace(skippedStatus, "\"", "\"\"") + "\"";
            qUnknown = "\"Unknown\"";
            qSegmentationMode = "\"" + replace(segmentationMode, "\"", "\"\"") + "\"";
            qSkipped = "\"SKIPPED\"";
            qThresholdMethod = "\"" + replace(thresholdMethod, "\"", "\"\"") + "\"";
            qRefineThresholdMethod = "\"" + replace(refineThresholdMethod, "\"", "\"\"") + "\"";

            secondPassText = "No";
            if (useSecondPass)
                secondPassText = "Yes";

            // The leading "" is load-bearing, not cosmetic.
            //
            // ImageJ decides whether an assignment is a string expression or
            // a numeric one from how the right-hand side STARTS. Beginning
            // with frameIndex - a number - makes the interpreter evaluate the
            // whole concatenation numerically: the very first "," is parsed
            // as a number, yields NaN, and the entire row collapses to NaN.
            // Starting with a string constant forces string concatenation.
            //
            // This is the same interpreter rule the note further down records
            // for user-defined string-returning functions; it applies to any
            // concatenation that begins with a numeric value.
            skippedRow = "" +
                frameIndex + "," +
                d2s(timeH, 6) + "," +
                qFilename + "," +
                qSkippedStatus + "," +
                qUnknown + "," +
                qSegmentationMode + "," +
                qSkipped + "," +
                "0,0,0,0,NA,NA,NA,NA,0,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA," +
                varianceRadius + "," +
                textureSmoothSigma + "," +
                qThresholdMethod + "," +
                morphCloseIterations + "," +
                morphOpenIterations + "," +
                secondPassText + "," +
                refineBandPx + "," +
                refineVarianceRadius + "," +
                refineSmoothSigma + "," +
                qRefineThresholdMethod + "," +
                refineCloseIterations + "," +
                refineOpenIterations + "," +
                analysisPercent;

            skippedRowFields = countCsvFields(skippedRow);
            if (skippedRowFields != csvExpectedFields)
                abortMacro(
                    "Internal CSV error: skipped-image row has " + skippedRowFields +
                    " fields but the header has " + csvExpectedFields + ".\n\n" +
                    "Image: " + filename
                );

            csvText = csvText + skippedRow + "\n";
            csvRowsWritten++;
            File.saveString(csvText, csvFile);

            csvVerifyText = File.openAsString(csvFile);
            csvCurrentBytes = File.length(csvFile);
            if (csvCurrentBytes <= csvLastVerifiedBytes || indexOf(csvVerifyText, qFilename) < 0)
                abortMacro(
                    "CSV verification failed while recording skipped image.\n\n" +
                    "CSV: " + csvFile + "\n" +
                    "Image: " + filename
                );

            csvLastVerifiedBytes = csvCurrentBytes;
            skipped++;
        }

        frameIndex++;

        if (isOpen(sourceID)) {
            selectImage(sourceID);
            setOption("Changes", false);
            close();
        }

        roiManager("reset");
    }
}

expectedCsvRows = processed + skipped;
csvBytes = File.length(csvFile);

if (csvRowsWritten != expectedCsvRows) {
    print(
        "WARNING: CSV row audit mismatch. Written=" + csvRowsWritten +
        " Expected=" + expectedCsvRows
    );
} else {
    print(
        "CSV ROW AUDIT OK | Data rows=" + csvRowsWritten +
        " | Expected=" + expectedCsvRows
    );
}

setBatchMode(false);
showProgress(1);
restoreSettings();

print("");
print("====================================================");
print("TWO-PASS TEXTURE SCRATCH ASSAY ANALYSIS COMPLETE");
print("====================================================");
print("Macro version: " + macroVersion);
print("Supported images detected: " + inputImageCount);
print("Processed: " + processed);
print("Skipped: " + skipped);
print("CSV data rows written: " + csvRowsWritten);
print("CSV file size: " + csvBytes + " bytes");
print("Results: " + csvFile);
print("Settings: " + settingsPath);
print("QC folder: " + qcDir);
if (saveMasks)
    print("Mask folder: " + maskDir);
print("");

showMessage(
    "Scratch Assay Complete",
    "Analysis complete.\n\n" +
    "Macro version: " + macroVersion + "\n" +
    "Processed: " + processed + "\n" +
    "Skipped: " + skipped + "\n" +
    "CSV data rows written: " + csvRowsWritten + "\n\n" +
    "Results:\n" + csvFile + "\n\n" +
    "Settings / provenance:\n" + settingsPath + "\n\n" +
    "QC overlays:\n" + qcDir
);


// ====================================================================
// FUNCTION: buildWoundMask
// Current image is an analysis duplicate of the raw phase image.
// Leaves the FINAL 8-bit 0/255 wound mask active.
// If Pass 2 is enabled, Scratch_First_Pass_Mask is intentionally left
// open for QC comparison and is closed by the caller.
// ====================================================================

function buildWoundMask(maskTitle, useTracking, originalSourceID) {

    lastArea = 0;
    lastFirstPassArea = 0;
    lastFirstTextureCut = -1;
    lastSecondTextureCut = -1;

    if (useSecondPass)
        lastRefineStatus = "PENDING";
    else
        lastRefineStatus = "DISABLED";

    getDimensions(imgW, imgH, imgC, imgZ, imgT);

    frac = analysisPercent / 100;
    roiW = round(imgW * frac);
    roiH = round(imgH * frac);
    if (roiW < 1) roiW = 1;
    if (roiH < 1) roiH = 1;

    roiX = floor((imgW - roiW) / 2);
    roiY = floor((imgH - roiH) / 2);
    lastAnalysisArea = roiW * roiH;

    sourceWorkID = getImageID();

    // Pass 1 is performed on the working duplicate. The original source
    // stays untouched and is used later to create the Pass-2 variance map.
    // This avoids keeping an additional full-size phase duplicate in memory
    // during Pass 1. ImageJ image IDs may be negative, so validity is always
    // checked with isOpen(id), never by testing id < 0.

    setVoxelSize(1, 1, 1, "pixel");

    // resetMinAndMax() before the 8-bit conversion. Without it, a 16- or
    // 32-bit source is scaled through whatever display range that
    // particular file happened to carry, which makes the conversion - and
    // therefore the variance map - differ between frames of one series.
    if (bitDepth() != 24)
        resetMinAndMax();
    run("8-bit");

    if (rollingBall > 0)
        run("Subtract Background...", "rolling=" + rollingBall);

    // Variance is computed in 8-bit. ImageJ's rank filter clamps 8-bit
    // variance output to 0-255, so high-texture regions saturate; the
    // threshold methods and the shipped parameter defaults are calibrated
    // for that clamped 0-255 map.
    run("Variance...", "radius=" + varianceRadius);

    if (textureSmoothSigma > 0)
        run("Gaussian Blur...", "sigma=" + textureSmoothSigma);

    run("Enhance Contrast", "saturated=0.35 normalize");
    run("8-bit");

    // Pass-1 threshold is calculated only in the central analysis ROI.
    makeRectangle(roiX, roiY, roiW, roiH);
    setAutoThreshold(thresholdMethod);
    getThreshold(autoLow, autoHigh);

    if (autoLow <= 1)
        textureCut = autoHigh;
    else
        textureCut = autoLow;

    if (textureCut < 0) textureCut = 0;
    if (textureCut > 255) textureCut = 255;

    lastFirstTextureCut = textureCut;
    setThreshold(0, textureCut);

    roiManager("reset");
    run("Analyze Particles...", "size=" + minWoundArea + "-Infinity pixel add include");
    nCand = roiManager("count");

    best = -1;
    bestD2 = 1e30;
    largest = -1;
    largestArea = -1;

    for (j = 0; j < nCand; j++) {
        roiManager("select", j);
        getStatistics(a);
        if (a > largestArea) {
            largestArea = a;
            largest = j;
        }
    }

    if (nCand == 0) {
        lastTrackStatus = "NO_CANDIDATE";
    } else if (useTracking == false || havePrevious == false) {
        best = largest;
        lastTrackStatus = "INITIAL_LARGEST";
    } else {

        // Candidate centroids are measured on a duplicate of the source,
        // which inherits its calibration - including a coordinate origin if
        // the file carried one. prevCx/prevCy come from a newImage() mask,
        // whose origin is always 0. Measure the offset once and take it back
        // out so both sides of the comparison are in raw pixel coordinates.
        makeRectangle(0, 0, imgW, imgH);
        originShiftX = imgW / 2 - getValue("X");
        originShiftY = imgH / 2 - getValue("Y");

        for (j = 0; j < nCand; j++) {
            roiManager("select", j);
            // Area centroid, not bounding-box centre: a bounding box is
            // pulled around by a single stray pixel, and the tracked value
            // has to match the centroid recorded for the previous frame.
            ccx = getValue("X") + originShiftX;
            ccy = getValue("Y") + originShiftY;
            dx = ccx - prevCx;
            dy = ccy - prevCy;
            d2 = dx * dx + dy * dy;

            if (d2 < bestD2) {
                bestD2 = d2;
                best = j;
            }
        }

        if (maxTrackShiftPx > 0 && bestD2 > maxTrackShiftPx * maxTrackShiftPx) {
            best = largest;
            lastTrackStatus = "TRACK_FALLBACK_LARGEST";
        } else {
            lastTrackStatus = "TRACK_NEAREST";
        }
    }

    // Build explicit Pass-1 binary morphology mask.
    newImage("Scratch_Binary_Morph_Work", "8-bit black", imgW, imgH, 1);
    setVoxelSize(1, 1, 1, "pixel");
    setForegroundColor(255, 255, 255);

    if (best >= 0) {
        roiManager("select", best);
        run("Fill");
    }

    run("Select None");
    changeValues(1, 254, 0);
    setBackgroundColor(0, 0, 0);
    makeRectangle(roiX, roiY, roiW, roiH);
    run("Clear Outside");
    run("Select None");

    applyRankMorphology(morphCloseIterations, morphOpenIterations);

    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    // Keep dominant post-morphology Pass-1 component.
    setThreshold(255, 255);
    roiManager("reset");
    run("Analyze Particles...", "size=" + minWoundArea + "-Infinity pixel add include");
    nFinal = roiManager("count");

    finalBest = -1;
    finalBestArea = -1;

    for (j = 0; j < nFinal; j++) {
        roiManager("select", j);
        getStatistics(a2);
        if (a2 > finalBestArea) {
            finalBestArea = a2;
            finalBest = j;
        }
    }

    newImage("Scratch_First_Pass_Mask", "8-bit black", imgW, imgH, 1);
    firstMaskID = getImageID();
    setVoxelSize(1, 1, 1, "pixel");
    setForegroundColor(255, 255, 255);

    firstBx = 0;
    firstBy = 0;
    firstBw = 0;
    firstBh = 0;
    firstCx = 0;
    firstCy = 0;

    if (finalBest >= 0) {
        roiManager("select", finalBest);
        getSelectionBounds(firstBx, firstBy, firstBw, firstBh);
        firstCx = getValue("X");
        firstCy = getValue("Y");
        run("Fill");
    }

    run("Select None");
    changeValues(1, 254, 0);
    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    getHistogram(fpVals, fpCounts, 256);
    lastFirstPassArea = fpCounts[255];

    // Close first-pass working images, preserve Pass-1 final mask.
    closeIfOpen("Scratch_Binary_Morph_Work");
    closeIfOpen("Scratch_Texture_Work");
    closeIfOpen("Scratch_Texture_Preview_Work");

    // If second pass is off, Pass-1 becomes the final mask.
    if (useSecondPass == false) {
        selectImage(firstMaskID);
        rename(maskTitle);

        lastArea = lastFirstPassArea;
        lastBx = firstBx;
        lastBy = firstBy;
        lastBw = firstBw;
        lastBh = firstBh;
        lastCx = firstCx;
        lastCy = firstCy;
        lastRefineStatus = "DISABLED";

        if (lastAnalysisArea > 0)
            lastPercentOpen = 100 * lastArea / lastAnalysisArea;
        else
            lastPercentOpen = 0;

        resetThreshold();
        return;
    }

    // If Pass 1 found no wound, there is no boundary to refine.
    if (lastFirstPassArea <= 0) {
        selectImage(firstMaskID);
        run("Duplicate...", "title=" + maskTitle);

        lastArea = lastFirstPassArea;
        lastBx = firstBx;
        lastBy = firstBy;
        lastBw = firstBw;
        lastBh = firstBh;
        lastCx = firstCx;
        lastCy = firstCy;
        lastRefineStatus = "NO_FIRST_PASS_WOUND";

        if (lastAnalysisArea > 0)
            lastPercentOpen = 100 * lastArea / lastAnalysisArea;
        else
            lastPercentOpen = 0;

        selectWindow(maskTitle);
        resetThreshold();
        return;
    }

    // ImageJ image IDs are often negative. A negative ID is NOT an error.
    // Validate the source with isOpen(id), then create the Pass-2 source
    // only now, after Pass-1 working images have already been closed.
    if (isOpen(originalSourceID) == false) {
        fallbackToFirstPass(
            firstMaskID,
            maskTitle,
            firstBx,
            firstBy,
            firstBw,
            firstBh,
            firstCx,
            firstCy,
            "REFINE_FALLBACK_SOURCE_UNAVAILABLE"
        );
        selectWindow(maskTitle);
        resetThreshold();
        return;
    }

    selectImage(originalSourceID);
    run("Duplicate...", "title=Scratch_Refine_Source");
    refineSourceID = getImageID();

    refineBoundaryFromVariance(
        firstMaskID,
        refineSourceID,
        maskTitle,
        imgW,
        imgH,
        firstBx,
        firstBy,
        firstBw,
        firstBh,
        firstCx,
        firstCy
    );

    resetThreshold();
}


// ====================================================================
// FUNCTION: refineBoundaryFromVariance
// Re-estimates the wound boundary ONLY within +/- refineBandPx of the
// Pass-1 ROI. The Pass-1 eroded core is always retained.
// ====================================================================

function refineBoundaryFromVariance(
    firstMaskID,
    refineSourceID,
    maskTitle,
    imgW,
    imgH,
    firstBx,
    firstBy,
    firstBw,
    firstBh,
    firstCx,
    firstCy
) {

    bandRadius = round(refineBandPx);
    if (bandRadius < 1)
        bandRadius = 1;

    // Dilated outer limit.
    selectImage(firstMaskID);
    run("Duplicate...", "title=Scratch_Refine_Dilated");
    dilatedID = getImageID();
    run("Maximum...", "radius=" + bandRadius);
    changeValues(1, 254, 0);

    // Eroded guaranteed wound core.
    selectImage(firstMaskID);
    run("Duplicate...", "title=Scratch_Refine_Core");
    coreID = getImageID();
    run("Minimum...", "radius=" + bandRadius);
    changeValues(1, 254, 0);

    // Boundary band = dilated mask - eroded core.
    imageCalculator("subtract create", dilatedID, coreID);
    bandID = getImageID();
    rename("Scratch_Refine_Band");
    changeValues(1, 254, 0);

    // Dilated mask is no longer needed once the band exists.
    if (isOpen(dilatedID)) {
        selectImage(dilatedID);
        setOption("Changes", false);
        close();
    }
    selectImage(bandID);

    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    getHistogram(bVals, bCounts, 256);
    bandArea = bCounts[255];

    if (bandArea <= 0) {
        fallbackToFirstPass(
            firstMaskID,
            maskTitle,
            firstBx,
            firstBy,
            firstBw,
            firstBh,
            firstCx,
            firstCy,
            "REFINE_FALLBACK_EMPTY_BAND"
        );
        closeRefineIntermediates();
        selectWindow(maskTitle);
        return;
    }

    // Convert boundary band to a transferable ROI for threshold estimation.
    setThreshold(255, 255);
    run("Create Selection");

    if (selectionType() == -1) {
        fallbackToFirstPass(
            firstMaskID,
            maskTitle,
            firstBx,
            firstBy,
            firstBw,
            firstBh,
            firstCx,
            firstCy,
            "REFINE_FALLBACK_NO_BAND_ROI"
        );
        closeRefineIntermediates();
        selectWindow(maskTitle);
        return;
    }

    roiManager("reset");
    roiManager("add");
    resetThreshold();

    // Second local-variance map from the original phase image.
    selectImage(refineSourceID);
    setVoxelSize(1, 1, 1, "pixel");

    if (bitDepth() != 24)
        resetMinAndMax();
    run("8-bit");

    if (rollingBall > 0)
        run("Subtract Background...", "rolling=" + rollingBall);

    // 8-bit variance, as in Pass 1.
    run("Variance...", "radius=" + refineVarianceRadius);

    if (refineSmoothSigma > 0)
        run("Gaussian Blur...", "sigma=" + refineSmoothSigma);

    run("Enhance Contrast", "saturated=0.35 normalize");
    run("8-bit");
    refineVarID = getImageID();

    // Calculate threshold ONLY from the Pass-1 boundary band.
    roiManager("select", 0);
    setAutoThreshold(refineThresholdMethod);
    getThreshold(refLow, refHigh);

    if (refLow <= 1)
        refineCut = refHigh;
    else
        refineCut = refLow;

    if (refineCut < 0) refineCut = 0;
    if (refineCut > 255) refineCut = 255;
    lastSecondTextureCut = refineCut;

    // Build a binary mask of all LOW-variance pixels in the second map.
    run("Select None");
    setThreshold(0, refineCut);
    run("Create Selection");

    roiManager("reset");
    if (selectionType() != -1)
        roiManager("add");

    newImage("Scratch_Refine_LowVar", "8-bit black", imgW, imgH, 1);
    lowVarID = getImageID();
    setForegroundColor(255, 255, 255);

    if (roiManager("count") > 0) {
        roiManager("select", 0);
        run("Fill");
    }

    run("Select None");
    changeValues(1, 254, 0);

    // The second variance image is no longer needed after LowVar is built.
    if (isOpen(refineVarID)) {
        selectImage(refineVarID);
        setOption("Changes", false);
        close();
    }

    // Restrict second-pass classification to the boundary band.
    imageCalculator("and create", lowVarID, bandID);
    bandLowID = getImageID();
    rename("Scratch_Refine_BandLowVar");
    changeValues(1, 254, 0);

    // LowVar and the boundary band are no longer needed after their AND.
    if (isOpen(lowVarID)) {
        selectImage(lowVarID);
        setOption("Changes", false);
        close();
    }
    if (isOpen(bandID)) {
        selectImage(bandID);
        setOption("Changes", false);
        close();
    }

    // Refined wound = guaranteed eroded core OR low-variance pixels in band.
    imageCalculator("or create", coreID, bandLowID);
    refinedWorkID = getImageID();
    rename("Scratch_Refined_Work");
    changeValues(1, 254, 0);

    // Core and band-low masks have been merged into Refined_Work.
    if (isOpen(coreID)) {
        selectImage(coreID);
        setOption("Changes", false);
        close();
    }
    if (isOpen(bandLowID)) {
        selectImage(bandLowID);
        setOption("Changes", false);
        close();
    }
    selectImage(refinedWorkID);
    // imageCalculator results inherit calibration from the first operand;
    // set it explicitly so Analyze Particles sizes and getValue("X"/"Y")
    // are unambiguously in pixels.
    setVoxelSize(1, 1, 1, "pixel");

    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    applyRankMorphology(refineCloseIterations, refineOpenIterations);

    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    // Keep the refined component nearest the Pass-1 wound centroid.
    setThreshold(255, 255);
    roiManager("reset");
    run("Analyze Particles...", "size=" + minWoundArea + "-Infinity pixel add include");
    nRef = roiManager("count");

    refBest = -1;
    refBestD2 = 1e30;

    for (j = 0; j < nRef; j++) {
        roiManager("select", j);
        rcX = getValue("X");
        rcY = getValue("Y");
        rdx = rcX - firstCx;
        rdy = rcY - firstCy;
        rd2 = rdx * rdx + rdy * rdy;

        if (rd2 < refBestD2) {
            refBestD2 = rd2;
            refBest = j;
        }
    }

    if (refBest < 0) {
        fallbackToFirstPass(
            firstMaskID,
            maskTitle,
            firstBx,
            firstBy,
            firstBw,
            firstBh,
            firstCx,
            firstCy,
            "REFINE_FALLBACK_NO_FINAL_COMPONENT"
        );
        closeRefineIntermediates();
        selectWindow(maskTitle);
        return;
    }

    newImage(maskTitle, "8-bit black", imgW, imgH, 1);
    finalMaskID = getImageID();
    setVoxelSize(1, 1, 1, "pixel");
    setForegroundColor(255, 255, 255);

    roiManager("select", refBest);
    getSelectionBounds(lastBx, lastBy, lastBw, lastBh);
    lastCx = getValue("X");
    lastCy = getValue("Y");
    run("Fill");
    run("Select None");
    changeValues(1, 254, 0);

    makeRectangle(roiX, roiY, roiW, roiH);
    setBackgroundColor(0, 0, 0);
    run("Clear Outside");
    run("Select None");

    getHistogram(fVals, fCounts, 256);
    lastArea = fCounts[255];

    if (lastAnalysisArea > 0)
        lastPercentOpen = 100 * lastArea / lastAnalysisArea;
    else
        lastPercentOpen = 0;

    lastRefineStatus = "REFINED_BOUNDARY_BAND";

    closeRefineIntermediates();
    selectImage(finalMaskID);
}


// ====================================================================
// FUNCTION: fallbackToFirstPass
// ====================================================================

function fallbackToFirstPass(
    firstMaskID,
    maskTitle,
    firstBx,
    firstBy,
    firstBw,
    firstBh,
    firstCx,
    firstCy,
    statusText
) {

    selectImage(firstMaskID);
    run("Duplicate...", "title=" + maskTitle);

    lastArea = lastFirstPassArea;
    lastBx = firstBx;
    lastBy = firstBy;
    lastBw = firstBw;
    lastBh = firstBh;
    lastCx = firstCx;
    lastCy = firstCy;
    lastRefineStatus = statusText;

    if (lastAnalysisArea > 0)
        lastPercentOpen = 100 * lastArea / lastAnalysisArea;
    else
        lastPercentOpen = 0;
}


// ====================================================================
// FUNCTION: closeRefineIntermediates
// Preserve Scratch_First_Pass_Mask and the final wound mask.
// ====================================================================

function closeRefineIntermediates() {
    closeIfOpen("Scratch_Refine_Dilated");
    closeIfOpen("Scratch_Refine_Core");
    closeIfOpen("Scratch_Refine_Band");
    closeIfOpen("Scratch_Refine_LowVar");
    closeIfOpen("Scratch_Refine_BandLowVar");
    closeIfOpen("Scratch_Refined_Work");
    closeIfOpen("Scratch_Refine_Source");
}


// ====================================================================
// FUNCTION: applyRankMorphology
// Grayscale-safe binary-equivalent morphology on explicit 0/255 masks.
// closing = Maximum -> Minimum
// opening = Minimum -> Maximum
// ====================================================================

function applyRankMorphology(closeIterations, openIterations) {

    if (bitDepth() != 8)
        abortMacro("Internal morphology error: expected 8-bit image.");

    changeValues(1, 254, 0);

    for (m = 0; m < closeIterations; m++) {
        run("Maximum...", "radius=1");
        run("Minimum...", "radius=1");
    }

    for (m = 0; m < openIterations; m++) {
        run("Minimum...", "radius=1");
        run("Maximum...", "radius=1");
    }

    changeValues(1, 254, 0);
}


// ====================================================================
// FUNCTION: inferOrientation
// ====================================================================

function inferOrientation() {
    if (lastArea <= 0)
        return "Unknown";

    if (lastBh >= lastBw)
        return "Vertical";
    else
        return "Horizontal";
}


// ====================================================================
// FUNCTION: measureWidthAndEdges
// Vertical wound: row-wise left/right edges.
// Horizontal wound: column-wise top/bottom edges.
// ====================================================================

function measureWidthAndEdges(orientation) {

    lastMeanWidth = 0;
    lastMedianWidth = 0;
    lastWidthSD = 0;
    lastWidthSamples = 0;
    lastEdge1 = 0;
    lastEdge2 = 0;

    if (lastArea <= 0)
        return;

    // The mask holds a single component whose bounding box is
    // lastBx/lastBy/lastBw/lastBh, and Clear Outside has already restricted
    // it to the analysis ROI. Every wound pixel therefore lies inside that
    // box, so scanning the full ROI only spends getPixel calls that cannot
    // match. Restricting the scan to the box, and stopping at the first and
    // last wound pixel of each line, gives identical edges for a fraction of
    // the calls - the difference is minutes per frame on large images.
    scanX0 = roiX;
    scanY0 = roiY;
    scanX1 = roiX + roiW - 1;
    scanY1 = roiY + roiH - 1;

    if (lastBw > 0 && lastBh > 0) {
        scanX0 = maxOf(scanX0, lastBx);
        scanY0 = maxOf(scanY0, lastBy);
        scanX1 = minOf(scanX1, lastBx + lastBw - 1);
        scanY1 = minOf(scanY1, lastBy + lastBh - 1);
    }

    if (scanX1 < scanX0 || scanY1 < scanY0)
        return;

    if (orientation == "Vertical")
        maxN = scanY1 - scanY0 + 1;
    else if (orientation == "Horizontal")
        maxN = scanX1 - scanX0 + 1;
    else
        return;

    widths = newArray(maxN);
    edge1s = newArray(maxN);
    edge2s = newArray(maxN);
    n = 0;

    if (orientation == "Vertical") {

        for (yy = scanY0; yy <= scanY1; yy++) {
            first = -1;

            for (xx = scanX0; xx <= scanX1; xx++) {
                if (getPixel(xx, yy) == 255) {
                    first = xx;
                    break;
                }
            }

            if (first >= 0) {
                last = first;

                for (xx = scanX1; xx > first; xx--) {
                    if (getPixel(xx, yy) == 255) {
                        last = xx;
                        break;
                    }
                }

                widths[n] = last - first + 1;
                edge1s[n] = first;
                edge2s[n] = last;
                n++;
            }
        }

    } else {

        for (xx = scanX0; xx <= scanX1; xx++) {
            first = -1;

            for (yy = scanY0; yy <= scanY1; yy++) {
                if (getPixel(xx, yy) == 255) {
                    first = yy;
                    break;
                }
            }

            if (first >= 0) {
                last = first;

                for (yy = scanY1; yy > first; yy--) {
                    if (getPixel(xx, yy) == 255) {
                        last = yy;
                        break;
                    }
                }

                widths[n] = last - first + 1;
                edge1s[n] = first;
                edge2s[n] = last;
                n++;
            }
        }
    }

    if (n == 0)
        return;

    widths = Array.trim(widths, n);
    edge1s = Array.trim(edge1s, n);
    edge2s = Array.trim(edge2s, n);

    Array.getStatistics(widths, wMin, wMax, wMean, wSD);
    Array.getStatistics(edge1s, e1Min, e1Max, e1Mean, e1SD);
    Array.getStatistics(edge2s, e2Min, e2Max, e2Mean, e2SD);

    Array.sort(widths);

    if (n % 2 == 1)
        wMedian = widths[floor(n / 2)];
    else
        wMedian = (widths[n / 2 - 1] + widths[n / 2]) / 2;

    lastMeanWidth = wMean;
    lastMedianWidth = wMedian;
    lastWidthSD = wSD;
    lastWidthSamples = n;
    lastEdge1 = e1Mean;
    lastEdge2 = e2Mean;
}


// ====================================================================
// FUNCTION: saveAnalysisSettings
// Preserves the timestamped metadata/settings format introduced in v5.3.
// ====================================================================

function saveAnalysisSettings(
    inDir,
    outDir,
    qcOutputDir,
    maskOutputDir,
    csvOutputFile,
    previewName,
    imgWidth,
    imgHeight,
    previewOrientation,
    nInputImages
) {

    getDateAndTime(year, month, dayOfWeek, dayOfMonth, hour, minute, second, msec);
    month = month + 1;

    // Build timestamp components explicitly as strings. Avoid calling a
    // user-defined string-returning helper inside an expression that begins
    // with a numeric value; some ImageJ macro interpreter versions then
    // report "Numeric return value expected".
    yearString = d2s(year, 0);
    monthString = d2s(month, 0);
    dayString = d2s(dayOfMonth, 0);
    hourString = d2s(hour, 0);
    minuteString = d2s(minute, 0);
    secondString = d2s(second, 0);

    if (month < 10) monthString = "0" + monthString;
    if (dayOfMonth < 10) dayString = "0" + dayString;
    if (hour < 10) hourString = "0" + hourString;
    if (minute < 10) minuteString = "0" + minuteString;
    if (second < 10) secondString = "0" + secondString;

    dateString = yearString + "-" + monthString + "-" + dayString;
    timeString = hourString + ":" + minuteString + ":" + secondString;
    fileStamp = yearString + monthString + dayString + "_" + hourString + minuteString + secondString;

    settingsFile = outDir + "Scratch_Assay_Settings_" + fileStamp + ".txt";

    settings = "";
    settings += "SCRATCH ASSAY ANALYSIS SETTINGS / PROVENANCE\n";
    settings += "============================================================\n\n";
    settings += "Macro: Phase-Contrast Scratch Assay Analyzer\n";
    settings += "Macro version: " + macroVersion + "\n";
    settings += "Image-ID validation: isOpen(id); negative ImageJ IDs accepted\n";
    settings += "CSV text handling: built-in string operations only in row assembly\n";
    settings += "Pass-2 memory mode: deferred source duplicate + progressive intermediate cleanup\n";
    settings += "Input frame ordering: digit-aware (natural) filename sort\n";
    settings += "Variance computation depth: 8-bit (rank-filter output clamped to 0-255)\n";
    settings += "8-bit conversion of source: resetMinAndMax() first, so it does not depend on stored display ranges\n";
    settings += "Centroid definition: area centroid of the final wound mask\n";
    settings += "Analysis date: " + dateString + "\n";
    settings += "Analysis time: " + timeString + "\n";
    settings += "ImageJ version: " + getVersion() + "\n";
    settings += "Image windows already open at macro start: " + initialOpenImages + "\n";
    if (initialOpenImages >= 8)
        settings += "Memory advisory: many pre-existing image windows were open; closing unused images before batch processing is recommended for very large source images.\n";
    settings += "\n";

    settings += "INPUT / OUTPUT\n";
    settings += "------------------------------------------------------------\n";
    settings += "Input directory: " + inDir + "\n";
    settings += "Supported input images detected: " + nInputImages + "\n";
    settings += "Preview / first sorted image: " + previewName + "\n";
    settings += "Preview width (px): " + imgWidth + "\n";
    settings += "Preview height (px): " + imgHeight + "\n";
    settings += "Preview accepted orientation: " + previewOrientation + "\n";
    settings += "Resolved frame order:\n" + frameOrderSummary;
    settings += "Output directory: " + outDir + "\n";
    settings += "Quantitative CSV: " + csvOutputFile + "\n";
    settings += "QC directory: " + qcOutputDir + "\n";
    settings += "Mask directory: " + maskOutputDir + "\n";
    saveMasksText = "No";
    if (saveMasks)
        saveMasksText = "Yes";
    settings += "Save final wound masks: " + saveMasksText + "\n\n";

    settings += "PASS 1 - GLOBAL VARIANCE SEGMENTATION\n";
    settings += "------------------------------------------------------------\n";
    settings += "Background correction: Rolling Ball\n";
    settings += "Rolling-ball radius (px): " + rollingBall + "\n";

    // Precompute display text explicitly for interpreter compatibility.
    // v5.4.4 avoids user-defined string-return helpers in metadata/CSV code.
    rollingBallEnabledText = "No";
    if (rollingBall > 0)
        rollingBallEnabledText = "Yes";

    settings += "Rolling-ball enabled: " + rollingBallEnabledText + "\n";
    settings += "Primary feature: Local Variance\n";
    settings += "Variance radius (px): " + varianceRadius + "\n";
    settings += "Variance smoothing sigma (px): " + textureSmoothSigma + "\n";
    settings += "Variance normalization: Enhance Contrast, saturated=0.35, normalize\n";
    settings += "Threshold method: " + thresholdMethod + "\n";
    settings += "Threshold calculation ROI: central analysis ROI\n";
    settings += "Central width/height retained (%): " + analysisPercent + "\n";
    settings += "Minimum wound candidate area (px^2): " + minWoundArea + "\n";
    settings += "Pass-1 closing iterations: " + morphCloseIterations + "\n";
    settings += "Pass-1 opening iterations: " + morphOpenIterations + "\n\n";

    settings += "PASS 2 - BOUNDARY-FOCUSED VARIANCE REFINEMENT\n";
    settings += "------------------------------------------------------------\n";
    secondPassText = "No";
    if (useSecondPass)
        secondPassText = "Yes";
    settings += "Second pass enabled: " + secondPassText + "\n";
    settings += "Boundary prior: Pass-1 wound ROI line\n";
    settings += "Boundary search band +/- (px): " + refineBandPx + "\n";
    settings += "Boundary band construction: dilated Pass-1 mask minus eroded Pass-1 mask\n";
    settings += "Guaranteed wound core: Pass-1 mask eroded by boundary band radius\n";
    settings += "Second-pass feature: Local Variance from original phase image\n";
    settings += "Second-pass variance radius (px): " + refineVarianceRadius + "\n";
    settings += "Second-pass variance smoothing sigma (px): " + refineSmoothSigma + "\n";
    settings += "Second-pass threshold method: " + refineThresholdMethod + "\n";
    settings += "Second-pass threshold histogram region: Pass-1 boundary band ONLY\n";
    settings += "Second-pass classification region: Pass-1 boundary band ONLY\n";
    settings += "Maximum edge displacement from Pass-1 boundary (px): " + refineBandPx + "\n";
    settings += "Pass-2 closing iterations: " + refineCloseIterations + "\n";
    settings += "Pass-2 opening iterations: " + refineOpenIterations + "\n";
    settings += "Refinement failure behavior: fall back to Pass-1 wound mask\n\n";

    settings += "MORPHOLOGY IMPLEMENTATION\n";
    settings += "------------------------------------------------------------\n";
    settings += "Process > Binary > Fill Holes used: No\n";
    settings += "Process > Binary > Open used: No\n";
    settings += "Process > Binary > Close used: No\n";
    settings += "Closing implementation: Maximum -> Minimum, radius=1\n";
    settings += "Opening implementation: Minimum -> Maximum, radius=1\n";
    settings += "Morphology masks: explicit 8-bit 0/255 images\n\n";

    settings += "TEMPORAL TRACKING / CALIBRATION\n";
    settings += "------------------------------------------------------------\n";
    settings += "Input order: digit-aware (natural) filename sort\n";
    settings += "Frame interval (hours): " + frameIntervalHours + "\n";
    settings += "Pixel size (um/pixel): " + pixelSizeUm + "\n";
    settings += "Maximum tracking centroid shift (px): " + maxTrackShiftPx + "\n";
    settings += "Initial wound candidate: largest eligible component\n";
    settings += "Later wound candidate: eligible component whose area centroid is nearest the previous frame's wound centroid\n";
    settings += "Tracking fallback: largest eligible component\n";
    settings += "Closure baseline: first successfully segmented wound\n\n";

    settings += "QUALITY CONTROL / OUTPUT\n";
    settings += "------------------------------------------------------------\n";
    settings += "QC overlay saved for every successfully analyzed image: Yes\n";
    settings += "Final wound boundary: Red\n";
    settings += "Pass-1 boundary when Pass 2 enabled: Yellow\n";
    settings += "Analysis ROI: Cyan\n";
    settings += "QC format: PNG\n";
    settings += "Final binary wound mask format: TIFF when enabled\n";
    settings += "CSV records per-frame Pass-1 and Pass-2 automatic texture cuts: Yes\n";
    settings += "CSV write mode: full File.saveString rewrite after each frame, with immediate read-back verification\n";
    settings += "CSV row audit at batch completion: Yes\nCSV per-frame disk verification: Yes (File.openAsString + filename check)\n";
    settings += "CSV per-row field-count check against header: Yes\n";
    settings += "Undefined measurements (no wound segmented): written as NA, not 0\n\n";

    settings += "ANALYSIS PIPELINE\n";
    settings += "------------------------------------------------------------\n";
    settings += "1. Sort supported images alphanumerically.\n";
    settings += "2. Pass 1: background correction -> variance -> smoothing -> normalization.\n";
    settings += "3. Pass 1: calculate low-variance threshold in central analysis ROI.\n";
    settings += "4. Select wound by size / temporal tracking.\n";
    settings += "5. Rebuild explicit binary Pass-1 mask and apply rank morphology.\n";
    settings += "6. Retain dominant Pass-1 wound component.\n";
    settings += "7. Optional Pass 2: construct +/- boundary band around Pass-1 ROI.\n";
    settings += "8. Optional Pass 2: calculate second local-variance map from original image.\n";
    settings += "9. Optional Pass 2: threshold using only boundary-band pixels.\n";
    settings += "10. Optional Pass 2: retain eroded wound core and reclassify boundary band.\n";
    settings += "11. Optional Pass 2: apply refinement morphology and retain nearest component.\n";
    settings += "12. Measure area, width, edges, closure, centroid and kinetics.\n";
    settings += "13. Write CSV row and save QC overlay / optional mask.\n\n";

    settings += "REPRODUCIBILITY / RIGOR\n";
    settings += "------------------------------------------------------------\n";
    settings += "This settings file was generated automatically after the preview\n";
    settings += "parameters were accepted and before batch analysis began.\n\n";
    settings += "Retain together: raw images, exact macro, this settings file,\n";
    settings += "quantitative CSV, QC overlays and binary masks when enabled.\n";
    settings += "============================================================\n";

    File.saveString(settings, settingsFile);
    print("Analysis settings saved: " + settingsFile);

    return settingsFile;
}


// ====================================================================
// FUNCTION: sanitizeParameters
// ====================================================================

function sanitizeParameters() {
    if (rollingBall < 0) rollingBall = 0;
    if (varianceRadius < 1) varianceRadius = 1;
    if (textureSmoothSigma < 0) textureSmoothSigma = 0;
    if (minWoundArea < 1) minWoundArea = 1;
    if (analysisPercent < 10) analysisPercent = 10;
    if (analysisPercent > 100) analysisPercent = 100;
    if (morphCloseIterations < 0) morphCloseIterations = 0;
    if (morphOpenIterations < 0) morphOpenIterations = 0;

    if (refineBandPx < 1) refineBandPx = 1;
    if (refineVarianceRadius < 1) refineVarianceRadius = 1;
    if (refineSmoothSigma < 0) refineSmoothSigma = 0;
    if (refineCloseIterations < 0) refineCloseIterations = 0;
    if (refineOpenIterations < 0) refineOpenIterations = 0;

    if (frameIntervalHours <= 0) frameIntervalHours = 1;
    if (pixelSizeUm < 0) pixelSizeUm = 0;
    if (maxTrackShiftPx < 0) maxTrackShiftPx = 0;
}


// ====================================================================
// STRING RETURN HELPER NOTE
// ====================================================================
// CSV and metadata concatenations use only built-in string operations.
// Text fields are precomputed with replace() and plain assignments, which
// avoids the "Numeric return value expected" interpreter error that a
// user-defined string-returning function can trigger inside a long
// concatenation beginning with a numeric value.


// ====================================================================
// FUNCTION: cleanupScratchIntermediates
// Closes only windows created by this macro. Useful after a failed run
// and between large frames. It does NOT close arbitrary user images.
// ====================================================================

function cleanupScratchIntermediates() {
    closeIfOpen("Scratch_Preview_Mask");
    closeIfOpen("Scratch_Wound_Mask");
    closeIfOpen("Scratch_First_Pass_Mask");
    closeIfOpen("Scratch_Refine_Source");
    closeIfOpen("Scratch_Refine_Dilated");
    closeIfOpen("Scratch_Refine_Core");
    closeIfOpen("Scratch_Refine_Band");
    closeIfOpen("Scratch_Refine_LowVar");
    closeIfOpen("Scratch_Refine_BandLowVar");
    closeIfOpen("Scratch_Refined_Work");
    closeIfOpen("Scratch_Binary_Morph_Work");
    closeIfOpen("Scratch_Texture_Work");
    closeIfOpen("Scratch_Texture_Preview_Work");
}


// ====================================================================
// FUNCTION: abortMacro
// Single exit path. Leaves batch mode (so any hidden window becomes
// visible again) and restores the ImageJ settings saved at start-up
// before terminating.
// ====================================================================

function abortMacro(message) {
    setBatchMode(false);
    restoreSettings();
    exit(message);
}


// ====================================================================
// FUNCTION: countCsvFields
// Number of comma-separated fields in one CSV line, honouring quoted
// fields so that a filename containing a comma is not miscounted.
// Escaped quotes ("") toggle the quote state twice and so cancel out.
// ====================================================================

function countCsvFields(line) {
    fields = 1;
    inQuote = false;
    len = lengthOf(line);

    for (c = 0; c < len; c++) {
        ch = substring(line, c, c + 1);

        if (ch == "\"")
            inQuote = !inQuote;
        else if (ch == "," && inQuote == false)
            fields++;
    }

    return fields;
}


// ====================================================================
// FUNCTION: naturalSortFileList
// Digit-aware ("natural") filename sort.
//
// Array.sort() is purely alphabetical, so "t10" sorts before "t2" and a
// time series is silently reordered - every velocity and closure rate
// downstream is then computed from the wrong frame pairs.
//
// Each run of digits is zero-padded to a fixed width to build a sort key,
// the original name is appended after a tab, and the combined strings are
// sorted with the built-in string sort. Padding makes the digit runs
// compare numerically; the appended name keeps the entries unique.
// ====================================================================

function naturalSortFileList(names) {

    if (names.length < 2)
        return names;

    digitChars = "0123456789";
    padWidth = 12;
    combined = newArray(names.length);

    for (i = 0; i < names.length; i++) {

        raw = names[i];
        lower = toLowerCase(raw);
        len = lengthOf(lower);
        key = "";
        c = 0;

        while (c < len) {

            ch = substring(lower, c, c + 1);

            if (indexOf(digitChars, ch) >= 0) {

                // Consume the whole digit run. The bounds test is written
                // as separate statements rather than relying on && to
                // short-circuit before substring() reads past the end.
                e = c;
                scanning = true;

                while (scanning) {
                    if (e >= len)
                        scanning = false;
                    else if (indexOf(digitChars, substring(lower, e, e + 1)) < 0)
                        scanning = false;
                    else
                        e++;
                }

                digitRun = substring(lower, c, e);

                while (lengthOf(digitRun) < padWidth)
                    digitRun = "0" + digitRun;

                key = key + digitRun;
                c = e;

            } else {

                key = key + ch;
                c++;
            }
        }

        combined[i] = key + "\t" + raw;
    }

    Array.sort(combined);

    sortedNames = newArray(names.length);

    for (i = 0; i < combined.length; i++) {
        tabAt = indexOf(combined[i], "\t");
        sortedNames[i] = substring(combined[i], tabAt + 1);
    }

    return sortedNames;
}


// ====================================================================
// FUNCTION: closeIfOpen
// ====================================================================

function closeIfOpen(title) {
    if (isOpen(title)) {
        selectWindow(title);
        setOption("Changes", false);
        close();
    }
}


// ====================================================================
// FUNCTION: image file filter
// ====================================================================

function isImageFile(name) {
    lower = toLowerCase(name);
    if (
        endsWith(lower, ".tif") ||
        endsWith(lower, ".tiff") ||
        endsWith(lower, ".png") ||
        endsWith(lower, ".jpg") ||
        endsWith(lower, ".jpeg")
    )
        return true;
    return false;
}


// ====================================================================
// FUNCTION: strip extension
// ====================================================================

function stripExtension(name) {
    dot = lastIndexOf(name, ".");
    if (dot > 0)
        return substring(name, 0, dot);
    return name;
}
