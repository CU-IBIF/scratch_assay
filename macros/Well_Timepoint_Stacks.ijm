// Fiji/ImageJ macro: assemble one padded time-lapse TIFF stack / AVI per well.
// ROOT/TimePoint_n/Well*/Fused/*.tif[f]  |  Source images are never modified.
// Time points are found, ordered and selected as in BaSiC_Batch_Tile_Stitcher_v1.3:
// only TimePoint_n folders count, frames follow n (TimePoint_2 before TimePoint_10),
// and a typed list such as 1-3,5 means folder numbers, not positions in the list.
root = getDirectory("Select BaSiC_Stitch_Output (the parent of the TimePoint_n folders)");
out = getDirectory("Select output folder (ideally outside input)");
all = getFileList(root);
Array.sort(all);
tps = newArray(all.length); tpIdx = newArray(all.length); tpCount = 0;
for (i = 0; i < all.length; i++) {
    name = all[i];
    if (endsWith(name, "/") || endsWith(name, "\\")) name = substring(name, 0, lengthOf(name)-1);
    if (!File.isDirectory(root + name)) continue;
    n = timepointIndex(name);
    if (n >= 0) { tps[tpCount] = name; tpIdx[tpCount] = n; tpCount++; }
}
if (tpCount == 0) exit("No TimePoint_n folders found in:\n" + root);
sortTimepointsByNumber(tps, tpIdx, tpCount);
tps = Array.trim(tps, tpCount);
tpIdx = Array.trim(tpIdx, tpCount);
// Two folders with the same number (TimePoint_1, TimePoint_01) have no defined frame order.
for (i = 1; i < tpCount; i++)
    if (tpIdx[i] == tpIdx[i-1]) exit("Two folders share time point number " + tpIdx[i] + ":\n" + tps[i-1] + "\n" + tps[i]);
print("\\Clear");
print("Time point folders (numeric order):");
for (i = 0; i < tpCount; i++) print("  " + tps[i]);
Dialog.create("Well time-lapse export");
Dialog.addMessage("Found " + tpCount + " time point folder(s), in numeric order.\nUntick any you do not want in the movies.");
tpCols = 1;
if (tpCount > 12) tpCols = floor((tpCount + 11) / 12);
tpRows = floor((tpCount + tpCols - 1) / tpCols);
tpDefaults = newArray(tpCount);
for (i = 0; i < tpCount; i++) tpDefaults[i] = true;
Dialog.addCheckboxGroup(tpRows, tpCols, tps, tpDefaults);
Dialog.addString("Or list time point numbers, e.g. 1-3,5 (overrides the boxes):", "", 28);
Dialog.addNumber("Movie frames per second", 5);
Dialog.addChoice("Padding", newArray("Center", "Top-Left"), "Center");
Dialog.addChoice("AVI compression", newArray("PNG", "JPEG", "None"), "PNG");
Dialog.addCheckbox("Export multi-page TIFF", true);
Dialog.addCheckbox("Export AVI", true);
Dialog.show();
picked = newArray(tpCount);
for (i = 0; i < tpCount; i++) picked[i] = Dialog.getCheckbox();
rangeText = replace(Dialog.getString(), " ", "");
fps = Dialog.getNumber();
position = Dialog.getChoice();
compression = Dialog.getChoice();
writeTiff = Dialog.getCheckbox();
writeAvi = Dialog.getCheckbox();
if (lengthOf(rangeText) > 0) {
    err = applyTimepointRange(rangeText, tpIdx, tpCount, picked);
    if (err != "") exit(err);
}
if (fps <= 0) exit("Movie frame rate must be positive.");
if (!writeTiff && !writeAvi) exit("Select at least one output.");
selected = newArray(0);
for (i = 0; i < tpCount; i++)
    if (picked[i]) selected = Array.concat(selected, newArray(tps[i]));
if (selected.length == 0) exit("No time points were selected.");
print("Frames, in order: " + String.join(selected, ", "));
wells = newArray(0);
for (t = 0; t < selected.length; t++) {
    entries = getFileList(root + selected[t] + "/");
    for (j = 0; j < entries.length; j++) {
        if (endsWith(entries[j], "/") && File.isDirectory(root + selected[t] + "/" + entries[j] + "Fused/")) {
            well = substring(entries[j], 0, lengthOf(entries[j])-1);
            present = false;
            for (k = 0; k < wells.length; k++) if (wells[k] == well) present = true;
            if (!present) wells = Array.concat(wells, newArray(well));
        }
    }
}
Array.sort(wells);
if (wells.length == 0) exit("No well/Fused folders found.");
File.makeDirectory(out);
setBatchMode(true);
for (wi = 0; wi < wells.length; wi++) {
    well = wells[wi];
    paths = newArray(0); labels = newArray(0);
    maxW = 0; maxH = 0; depth = -1;
    // First pass: verify TIFF inputs and calculate the common padded canvas.
    for (t = 0; t < selected.length; t++) {
        file = findTiff(root + selected[t] + "/" + well + "/Fused/");
        if (file == "") {
            print("SKIP missing or ambiguous TIFF: " + well + " / " + selected[t]);
            continue;
        }
        open(file);
        id = getImageID();
        getDimensions(w, h, c, z, frames);
        bits = bitDepth();
        if (c != 1 || z != 1 || frames != 1) {
            print("SKIP non-2D image: " + file);
            selectImage(id); close();
            continue;
        }
        if (depth == -1) depth = bits;
        if (depth != bits) {
            print("SKIP incompatible bit depth: " + file);
            selectImage(id); close();
            continue;
        }
        if (w > maxW) maxW = w;
        if (h > maxH) maxH = h;
        paths = Array.concat(paths, newArray(file));
        labels = Array.concat(labels, newArray(selected[t]));
        selectImage(id); close();
    }
    if (paths.length == 0) {
        print("No usable frames: " + well);
        continue;
    }
    kind = "16-bit black";
    if (depth == 8) kind = "8-bit black";
    if (depth == 24) kind = "RGB black";
    if (depth == 32) kind = "32-bit black";
    newImage("Timelapse_" + well, kind, maxW, maxH, paths.length);
    stack = getImageID();
    // Second pass: copy the native pixels without rescaling or interpolation.
    for (p = 0; p < paths.length; p++) {
        open(paths[p]);
        src = getImageID();
        w = getWidth(); h = getHeight();
        run("Select All"); run("Copy");
        selectImage(stack);
        setSlice(p+1);
        x = 0; y = 0;
        if (position == "Center") {
            x = floor((maxW-w)/2);
            y = floor((maxH-h)/2);
        }
        makeRectangle(x, y, w, h);
        run("Paste");
        run("Select None");
        setMetadata("Label", labels[p]);
        selectImage(src); close();
    }
    selectImage(stack);
    Stack.setFrameRate(fps);
    if (paths.length > 1) Stack.setDimensions(1, 1, paths.length);
    base = out + safe(well) + "_timelapse";
    if (writeTiff) saveAs("Tiff", base + ".tif");
    if (writeAvi) run("AVI... ", "compression=" + compression + " frame=" + fps + " save=[" + base + ".avi]");
    print("EXPORTED " + well + ": " + paths.length + " frames; " + maxW + "x" + maxH + "; " + depth + "-bit");
    selectImage(stack); close();
}
setBatchMode(false);
print("Finished: " + out);
function findTiff(dir) {
    if (!File.isDirectory(dir)) return "";
    entries = getFileList(dir);
    count = 0; match = "";
    for (n = 0; n < entries.length; n++) {
        low = toLowerCase(entries[n]);
        if (!endsWith(entries[n], "/") && (endsWith(low, ".tif") || endsWith(low, ".tiff"))) {
            count++; match = dir + entries[n];
        }
    }
    if (count == 1) return match;
    return "";
}
function safe(name) {
    name = replace(name, " ", "_");
    name = replace(name, "/", "_");
    return replace(name, "\\", "_");
}
// The three functions below are copied verbatim from BaSiC_Batch_Tile_Stitcher_v1.3.ijm
// so both macros read time point folders identically; tests check they stay in sync.
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
