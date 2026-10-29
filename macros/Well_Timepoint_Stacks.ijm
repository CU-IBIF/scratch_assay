// Fiji/ImageJ macro: assemble one padded time-lapse TIFF stack / AVI per well.
// ROOT/TimePoint*/Well*/Fused/*.tif[f]  |  Source images are never modified.
root = getDirectory("Select parent folder containing timepoint folders");
out = getDirectory("Select output folder (ideally outside input)");
all = getFileList(root);
Array.sort(all);
tps = newArray(0);
for (i = 0; i < all.length; i++)
    if (endsWith(all[i], "/")) tps = Array.concat(tps, newArray(all[i]));
if (tps.length == 0) exit("No timepoint folders found.");
print("\\Clear");
print("Timepoints (sorted alphabetically; use zero-padded folder names):");
for (i = 0; i < tps.length; i++) print("" + (i+1) + ": " + tps[i]);
Dialog.create("Well time-lapse export");
Dialog.addMessage("Choose timepoints by the numbered Log listing: all, 1-20 or 1,3-5,8");
Dialog.addString("Timepoints", "all", 32);
Dialog.addNumber("Movie frames per second", 5);
Dialog.addChoice("Padding", newArray("Center", "Top-Left"), "Center");
Dialog.addChoice("AVI compression", newArray("PNG", "JPEG", "None"), "PNG");
Dialog.addCheckbox("Export multi-page TIFF", true);
Dialog.addCheckbox("Export AVI", true);
Dialog.show();
selection = replace(Dialog.getString(), " ", "");
fps = Dialog.getNumber();
position = Dialog.getChoice();
compression = Dialog.getChoice();
writeTiff = Dialog.getCheckbox();
writeAvi = Dialog.getCheckbox();
if (fps <= 0) exit("Movie frame rate must be positive.");
if (!writeTiff && !writeAvi) exit("Select at least one output.");
selected = newArray(0);
for (i = 0; i < tps.length; i++)
    if (chosen(i+1, selection)) selected = Array.concat(selected, newArray(tps[i]));
if (selected.length == 0) exit("No timepoints selected.");
wells = newArray(0);
for (t = 0; t < selected.length; t++) {
    entries = getFileList(root + selected[t]);
    for (j = 0; j < entries.length; j++) {
        if (endsWith(entries[j], "/") && File.isDirectory(root + selected[t] + entries[j] + "Fused/")) {
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
        file = findTiff(root + selected[t] + well + "/Fused/");
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
        labels = Array.concat(labels, newArray(substring(selected[t], 0, lengthOf(selected[t])-1)));
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
        selectAll(); run("Copy");
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
    Stack.setDimensions(1, 1, paths.length);
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
function chosen(index, spec) {
    if (toLowerCase(spec) == "all") return true;
    tokens = split(spec, ",");
    for (n = 0; n < tokens.length; n++) {
        dash = indexOf(tokens[n], "-");
        if (dash < 0) {
            if (tokens[n] != "" && parseInt(tokens[n]) == index) return true;
        } else {
            a = parseInt(substring(tokens[n], 0, dash));
            b = parseInt(substring(tokens[n], dash+1));
            if (index >= a && index <= b) return true;
        }
    }
    return false;
}
function safe(name) {
    name = replace(name, " ", "_");
    name = replace(name, "/", "_");
    return replace(name, "\\", "_");
}
