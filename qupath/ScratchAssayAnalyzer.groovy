/**
 * Scratch Assay Analyzer for QuPath, version 2.0.0.
 *
 * Every project image is measured independently: there is no time series, no
 * frame-to-frame tracking and no baseline frame. Results are keyed by image
 * name, so the CSV can be joined to whatever experimental design you keep
 * elsewhere.
 *
 * Run from QuPath's script editor with a project open. The implementation is
 * deliberately dependency-free: image processing uses Java arrays so that the
 * script works in standard QuPath installations.
 */

import javafx.application.Platform
import javafx.beans.value.ChangeListener
import javafx.geometry.Insets
import javafx.scene.control.*
import javafx.event.EventHandler
import javafx.scene.layout.GridPane
import javafx.scene.layout.HBox
import javafx.scene.layout.VBox
import javafx.stage.Modality
import qupath.lib.gui.dialogs.Dialogs
import qupath.lib.objects.PathObjects
import qupath.lib.objects.classes.PathClassFactory
import qupath.lib.regions.ImagePlane
import qupath.lib.regions.RegionRequest
import qupath.lib.roi.ROIs
import qupath.opencv.ml.pixel.PixelClassifierTools

import javax.imageio.ImageIO
import java.awt.Graphics2D
import java.awt.geom.Area
import java.awt.geom.Rectangle2D
import java.awt.image.BufferedImage
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.text.DecimalFormat
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import groovy.transform.CompileStatic

import java.util.concurrent.Callable
import java.util.concurrent.FutureTask

final String VERSION = '2.0.0'
def project = getProject()
if (project == null) {
    Dialogs.showErrorMessage('Scratch Assay Analyzer', 'Open a QuPath project before running this script.')
    return
}

List entries = new ArrayList(project.getImageList())
if (entries.isEmpty()) {
    Dialogs.showErrorMessage('Scratch Assay Analyzer', 'The current project contains no images.')
    return
}
// Ordering is presentation only - it makes the CSV readable and the run
// reproducible. No measurement depends on the position of an image. It is
// settled before the dialog so that the picker and this list stay aligned.
entries.sort { a, b -> naturalCompare(a.getImageName(), b.getImageName()) }

Map cfg = showSettings(project, entries)
if (cfg == null) return

// The picker returns positions rather than names, so a project holding two
// entries with the same image name still resolves to the one that was ticked.
// Each job carries its own scratch orientation.
List jobs = (cfg.remove('selection') as List).collect {
    [entry: entries[it.index as int], orientation: it.orientation as String]
}
if (jobs.isEmpty()) {
    Dialogs.showErrorMessage('Scratch Assay Analyzer', 'No images were selected.')
    return
}

Path output = Path.of(project.getPath().getParent().toString(), 'Scratch_Assay_Results')
Path qcDir = output.resolve('QC')
Path maskDir = output.resolve('Masks')
Path debugDir = output.resolve('Debug')
Files.createDirectories(output)
if (cfg.saveQC || cfg.saveProfiles) Files.createDirectories(qcDir)
if (cfg.saveMasks) Files.createDirectories(maskDir)
if (cfg.saveDebug) Files.createDirectories(debugDir)

List rows = []
jobs.eachWithIndex { job, i ->
    // Each image is analysed in its own method call so that every large array
    // it allocates becomes unreachable as soon as the call returns.
    rows << analyseImage(project, job.entry, job.orientation as String, cfg, maskDir, qcDir, debugDir)
    println "Scratch assay ${i+1}/${jobs.size()}: ${job.entry.getImageName()} " +
            "[${rows[-1].orientation}] (${rows[-1].areaPx} px2)"
}

writeCsv(output.resolve('Scratch_Assay_Measurements.csv'), rows)
writeSettings(output.resolve('Scratch_Assay_Settings.txt'), VERSION, cfg,
    jobs.collect { "${it.entry.getImageName()}\t${it.orientation}" })
Dialogs.showInfoNotification('Scratch Assay Analyzer', "Measured ${jobs.size()} image(s). Results: ${output}")

/**
 * Measure a single image. Nothing carries over between images: the returned
 * map is the complete result for this entry.
 */
Map analyseImage(project, entry, String orientation, Map cfg, Path maskDir, Path qcDir, Path debugDir) {
    boolean vertical = !isHorizontal(orientation)
    def imageData = entry.readImageData()
    try {
        def server = imageData.getServer()
        double ds = cfg.downsample as double
        checkMemoryBudget(entry.getImageName(),
            Math.max(1, (int)Math.ceil(server.getWidth() / ds)),
            Math.max(1, (int)Math.ceil(server.getHeight() / ds)), cfg)

        def request = RegionRequest.createInstance(server.getPath(), ds, 0, 0, server.getWidth(), server.getHeight())
        BufferedImage source = server.readRegion(request)
        // Servers round region dimensions their own way at a downsample, so the
        // image that comes back can differ from a computed estimate by a pixel.
        // Take the analysis grid and the true scale from the returned image;
        // assuming otherwise indexes past the end of the pixel arrays.
        int w = source.getWidth(), h = source.getHeight()
        double dsX = server.getWidth() / (double)w
        double dsY = server.getHeight() / (double)h
        // The variance map is the most expensive step in the pipeline, so build
        // it, and the luminance it needs, only when something consumes them.
        // Under the pixel classifier the first-pass threshold does not, which
        // leaves the presence test and the debug dump as the only consumers.
        boolean needTexture = (cfg.inputMode != 'Pixel classifier') ||
                              (cfg.minTextureRatio as double) > 0d || cfg.saveDebug
        boolean needGray = needTexture || cfg.secondPass
        float[] gray = needGray ? luminance(source) : null

        // A "Restrict" annotation, when the image carries one, replaces the
        // centred analysis field outright: it is an explicit instruction about
        // where to look, so intersecting it with a percentage would quietly
        // trim what was actually drawn.
        List fieldRects = restrictRects(imageData, entry.getImageName(), w, h, dsX, dsY)
        boolean restricted = !fieldRects.isEmpty()
        if (!restricted) {
            int marginX = Math.round(w * (100d - cfg.analysisPercent) / 200d) as int
            int marginY = Math.round(h * (100d - cfg.analysisPercent) / 200d) as int
            fieldRects = [[marginX, marginY, w-marginX, h-marginY]]
        }
        boolean[] field = new boolean[w * h]
        fieldRects.each { r ->
            for (int y = r[1] as int; y < (r[3] as int); y++)
                Arrays.fill(field, y*w + (r[0] as int), y*w + (r[2] as int), true)
        }
        // Counted rather than multiplied out, so overlapping rectangles are not
        // double counted in Percent_Open.
        long fieldArea = field.count(true)

        // When debugging, every step writes a PNG and a line in a report, so a
        // run that loses the wound can be traced to the step that lost it.
        String stem = safeStem(entry.getImageName())
        List dbg = []
        if (cfg.saveDebug) {
            dbg << 'image: ' + entry.getImageName()
            dbg << 'orientation: ' + (vertical ? 'Vertical' : 'Horizontal')
            dbg << 'analysis grid: ' + w + ' x ' + h +
                   '  (full-res scale dsX=' + dsX + ', dsY=' + dsY + ')'
            dbg << 'starting mask: ' + cfg.inputMode
            dbg << 'analysis field: ' + fieldArea + ' px' +
                   (restricted ? ' (Restrict annotation)' : ' (centred ' + cfg.analysisPercent + '%)')
        }
        debugImage(cfg, debugDir, stem, '01_source', source)
        debugMask(cfg, debugDir, stem, '02_field', field, w, h)

        // Three things read this: the variance threshold, the wound-presence
        // test below (which guards the classifier path too) and the 03_texture
        // dump. Under a classifier with none of them active it is pure waste,
        // which is what needTexture is for. deadParams greys out the two
        // parameters below in exactly that case.
        float[] texture1 = needTexture
            ? textureMap(gray, w, h, cfg.varianceRadius as int, cfg.smoothSigma as double) : null
        if (cfg.saveDebug && texture1 != null)
            dbg << debugMap(cfg, debugDir, stem, '03_texture', texture1, w, h, field)
        boolean[] pass1
        double cut1 = Double.NaN
        if (cfg.inputMode == 'Pixel classifier') {
            pass1 = classifierMask(project, imageData, cfg.classifierName as String,
                cfg.woundClass as String, w, h, ds)
            andMask(pass1, field)
        } else {
            cut1 = otsu(texture1, field)
            pass1 = new boolean[w*h]
            maskBelow(texture1, field, cut1, pass1)
        }
        debugMask(cfg, debugDir, stem, '04_initial_mask', pass1, w, h)
        if (cfg.saveDebug) {
            dbg << 'pass 1 threshold: ' + (Double.isFinite(cut1)
                   ? ('variance ' + Math.expm1(cut1) + ', log ' + cut1)
                   : 'n/a (classifier)')
            dbg << '04_initial_mask: ' + pass1.count(true) + ' px'
        }
        pass1 = morphology(pass1, w, h, cfg.closeIterations as int, cfg.openIterations as int)
        debugMask(cfg, debugDir, stem, '05_morphology', pass1, w, h)
        if (cfg.saveDebug)
            dbg << '05_morphology (close ' + cfg.closeIterations + ', open ' +
                   cfg.openIterations + '): ' + pass1.count(true) + ' px'

        int minAreaPx = (cfg.minArea / (dsX*dsY)) as int
        Map selected = largestComponent(pass1, w, h, minAreaPx)
        // Held only for the debug image of what was discarded, so that debris
        // breaking the wound into pieces is visible rather than inferred.
        boolean[] morphMask = cfg.saveDebug ? pass1 : null
        pass1 = null
        boolean[] firstMask = selected == null ? new boolean[w*h] : selected.mask
        debugMask(cfg, debugDir, stem, '06_largest_component', firstMask, w, h)
        if (cfg.saveDebug) {
            dbg << 'minimum area: ' + minAreaPx + ' analysis px (' + cfg.minArea + ' full-res px2)'
            dbg << '06_largest_component: ' + (selected == null
                   ? 'none passed the minimum area' : selected.area + ' px')
            boolean[] dropped = new boolean[w*h]
            for (int i=0; i<dropped.length; i++) dropped[i] = morphMask[i] && !firstMask[i]
            debugMask(cfg, debugDir, stem, '07_discarded', dropped, w, h)
            dbg << '07_discarded (everything the component choice dropped): ' +
                   dropped.count(true) + ' px'
            dropped = null
            morphMask = null
        }

        // Otsu always returns a threshold, even on a closed sheet whose texture
        // map has only one mode, so without this a fully healed wound still
        // reports one. A real wound is bare substrate and so far smoother than
        // the sheet around it; a slightly duller patch of sheet is not.
        // A minimum of 0 switches the test off, in which case the ratio is not
        // worth the variance map it would need. Skipping the comparison rather
        // than comparing against 0 also keeps a NaN from rejecting everything.
        double ratio = Double.NaN
        String detection = 'FOUND'
        if (selected == null) {
            detection = 'NOT_FOUND'
        } else if ((cfg.minTextureRatio as double) > 0d) {
            ratio = textureRatio(texture1, firstMask, field)
            if (!(ratio >= (cfg.minTextureRatio as double))) {
                selected = null
                firstMask = new boolean[w*h]
                detection = 'REJECTED_LOW_CONTRAST'
            }
        }
        debugMask(cfg, debugDir, stem, '08_presence_test', firstMask, w, h)
        if (cfg.saveDebug) {
            dbg << 'sheet/wound texture ratio: ' + ratio +
                   ' (minimum ' + cfg.minTextureRatio + ')'
            dbg << 'detection: ' + detection
            if (detection == 'REJECTED_LOW_CONTRAST')
                dbg << '08_presence_test: the candidate was CLEARED HERE - it was ' +
                       'not smooth enough against its surroundings. Everything after ' +
                       'this step is empty as a consequence, not as a further failure. ' +
                       'Lower "Minimum sheet/wound texture ratio" (0 disables the test) ' +
                       'to keep a wound at ratio ' + ratio + '.'
            else
                dbg << '08_presence_test: ' + firstMask.count(true) + ' px'
        }
        texture1 = null

        // Cells and debris sitting in the gap read as high texture, so they
        // punch holes in the wound. Closing them recovers the true open area.
        long holesFilled = (selected != null && cfg.fillHoles) ? fillHoles(firstMask, w, h) : 0L
        debugMask(cfg, debugDir, stem, '09_holes_filled', firstMask, w, h)
        if (cfg.saveDebug)
            dbg << '09_holes_filled: ' + firstMask.count(true) + ' px (' +
                   holesFilled + ' px added; this step only ever adds pixels, ' +
                   'so it cannot be where a wound was lost)'
        boolean[] finalMask = firstMask
        double cut2 = Double.NaN
        String refineStatus = cfg.secondPass ? 'NO_COMPONENT' : 'DISABLED'

        if (selected != null && cfg.secondPass) {
            int band = Math.max(1, Math.round(cfg.refineBand / dsX) as int)
            boolean[] inner = erode(firstMask, w, h, band)
            boolean[] outer = dilate(firstMask, w, h, band)
            boolean[] searchBand = new boolean[w*h]
            for (int i=0; i<searchBand.length; i++) searchBand[i] = outer[i] && !inner[i] && field[i]
            outer = null
            debugMask(cfg, debugDir, stem, '10_refine_band', searchBand, w, h)
            float[] texture2 = textureMap(gray, w, h, cfg.refineVarianceRadius as int, cfg.refineSmoothSigma as double)
            if (cfg.saveDebug)
                dbg << debugMap(cfg, debugDir, stem, '11_refine_texture', texture2, w, h, searchBand)
            cut2 = otsu(texture2, searchBand)
            boolean[] refined = inner
            addBelow(texture2, searchBand, cut2, refined)
            texture2 = null; searchBand = null
            refined = morphology(refined, w, h, cfg.refineCloseIterations as int, cfg.refineOpenIterations as int)
            debugMask(cfg, debugDir, stem, '12_refined', refined, w, h)
            if (cfg.saveDebug)
                dbg << '12_refined (band ' + band + ' analysis px, threshold variance ' +
                       Math.expm1(cut2) + '): ' + refined.count(true) + ' px'
            Map best = largestComponent(refined, w, h, 1)
            refined = null
            if (best != null) {
                finalMask = best.mask
                selected = best
                // Refinement re-derives the boundary, so holes must be closed
                // again; the reported count always describes the final mask.
                if (cfg.fillHoles) holesFilled = fillHoles(finalMask, w, h)
                refineStatus = 'APPLIED'
            } else refineStatus = 'FALLBACK'
        }
        gray = null
        field = null

        debugMask(cfg, debugDir, stem, '13_final', finalMask, w, h)

        Map m = measurements(finalMask, w, h, vertical)
        double areaPx = m.area * dsX * dsY
        // Width runs across the scratch and length along it, so each scales
        // with the axis it was measured on.
        double widthScale = vertical ? dsX : dsY
        double lengthScale = vertical ? dsY : dsX
        def cal = server.getPixelCalibration()
        double pixelUm = cal.hasPixelSizeMicrons() ? cal.getAveragedPixelSizeMicrons() : Double.NaN

        if (cfg.saveDebug) {
            dbg << 'refinement: ' + refineStatus
            dbg << '13_final: ' + m.area + ' analysis px'
            dbg << 'reported width: mean ' + (m.meanWidth*widthScale) +
                   ' full-res px, from ' + m.samples + ' scan lines'
            Files.write(debugDir.resolve(stem + '_debug.txt'), dbg, StandardCharsets.UTF_8)
        }

        replaceGeneratedAnnotation(imageData, finalMask, w, h, dsX, dsY)
        entry.saveImageData(imageData)
        if (cfg.saveMasks)
            ImageIO.write(maskImage(finalMask,w,h), 'PNG', maskDir.resolve(stem+'_wound_mask.png').toFile())
        if (cfg.saveQC)
            ImageIO.write(qcImage(source, firstMask, finalMask, fieldRects), 'PNG', qcDir.resolve(stem+'_QC.png').toFile())
        if (cfg.saveProfiles)
            writeWidthProfile(qcDir.resolve(stem+'_width_profile.csv'), entry.getImageName(),
                vertical ? 'Vertical' : 'Horizontal', m.lines as List, dsX, dsY, widthScale, pixelUm,
                cfg.profileStride as int)

        return [image:entry.getImageName(), orientation:vertical ? 'Vertical' : 'Horizontal', areaPx:areaPx,
                areaUm2:Double.isNaN(pixelUm) ? Double.NaN : areaPx*pixelUm*pixelUm,
                holesFilled:holesFilled*dsX*dsY,
                percentOpen:100d*m.area/Math.max(1L, fieldArea), length:m.length*lengthScale,
                meanWidth:m.meanWidth*widthScale, medianWidth:m.medianWidth*widthScale, widthSD:m.widthSD*widthScale,
                widthSamples:m.samples, centroidX:m.cx*dsX, centroidY:m.cy*dsY,
                // Reported in variance units, the quantity they describe,
                // although the threshold is now chosen on its logarithm.
                threshold1:Math.expm1(cut1), threshold2:Math.expm1(cut2),
                textureRatio:ratio,
                restricted:restricted ? 'YES' : 'NO',
                fieldX:fieldRects.collect{it[0]}.min()*dsX, fieldY:fieldRects.collect{it[1]}.min()*dsY,
                fieldW:(fieldRects.collect{it[2]}.max()-fieldRects.collect{it[0]}.min())*dsX,
                fieldH:(fieldRects.collect{it[3]}.max()-fieldRects.collect{it[1]}.min())*dsY,
                detection:detection, refinement:refineStatus]
    } finally {
        // Each readImageData() builds its own server and tile cache. Without
        // this the whole project stays in memory until the script ends.
        try { imageData.getServer().close() } catch (Exception ignored) {}
        try { imageData.close() } catch (Exception ignored) {}
    }
}

/**
 * Analysis-field rectangles taken from annotations labelled "Restrict", in
 * analysis pixels and clipped to the image. An annotation counts if either its
 * classification or its name is "Restrict", case-insensitively, because QuPath
 * offers both and either is a reasonable way to label one. Any ROI shape is
 * accepted and its bounding box used. An empty list means the image carries no
 * such annotation and the whole field should be analysed.
 */
List restrictRects(imageData, String image, int w, int h, double dsX, double dsY) {
    def annotations = imageData.getHierarchy().getAnnotationObjects().findAll {
        String cls = it.getPathClass() == null ? null : it.getPathClass().getName()
        String name = it.getName()
        'restrict'.equalsIgnoreCase(cls?.trim()) || 'restrict'.equalsIgnoreCase(name?.trim())
    }
    if (annotations.isEmpty()) return []
    List rects = []
    annotations.each { a ->
        def roi = a.getROI()
        if (roi == null) return
        int x0 = Math.max(0, (int)Math.floor(roi.getBoundsX() / dsX))
        int y0 = Math.max(0, (int)Math.floor(roi.getBoundsY() / dsY))
        int x1 = Math.min(w, (int)Math.ceil((roi.getBoundsX() + roi.getBoundsWidth()) / dsX))
        int y1 = Math.min(h, (int)Math.ceil((roi.getBoundsY() + roi.getBoundsHeight()) / dsY))
        if (x1 > x0 && y1 > y0) rects << [x0, y0, x1, y1]
    }
    // Falling back to the whole image would silently measure something the user
    // asked not to be measured, so say so instead.
    if (rects.isEmpty())
        throw new IllegalArgumentException(
            "${image}: every 'Restrict' annotation falls outside the image or is empty at this downsample.")
    rects
}

/**
 * Refuse an image that cannot fit in the heap instead of dying with an
 * OutOfMemoryError halfway through the project. The per-pixel figures are
 * measured against the arrays this script actually allocates.
 */
void checkMemoryBudget(String name, int w, int h, Map cfg) {
    long px = (long)w * h
    long bytes = px * (cfg.secondPass ? 44L : 32L) + (cfg.saveQC ? px * 4L : 0L)
               + (cfg.saveDebug ? px * 6L : 0L)
    long budget = (long)(Runtime.getRuntime().maxMemory() * 0.6d)
    if (bytes > budget)
        throw new IllegalArgumentException(
            "${name}: needs roughly ${bytes >> 20} MB at downsample ${cfg.downsample}, but only ${budget >> 20} MB " +
            'of heap is usable. Increase the downsample, shrink the analysis field, turn off the second pass or ' +
            'QC overlays, or raise QuPath\'s memory limit (Edit > Preferences > Memory).')
}

/**
 * Every parameter described once: label, tooltip, default and kind.
 *
 * The form, the tooltips, the enable rules, the validation fallbacks and the
 * saved preferences all key off this one list. Two parallel lists of fields and
 * labels, which is what this replaces, silently mislabels every row below an
 * insertion.
 *
 * `kind` is 'text', 'check', 'choice' (fixed options) or 'classifier' (options
 * from the project, but free text allowed).
 */
List paramSpec() {
    [
    [key:'inputMode', kind:'choice', value:'Variance threshold',
     choices:['Variance threshold','Pixel classifier'],
     label:'Starting mask',
     tip:'Where the first-pass wound mask comes from. Variance threshold needs no training: it finds the smooth, low-texture region in a map of local intensity variance. Pixel classifier uses one you trained and saved in this project.'],
    [key:'classifierName', kind:'classifier', value:'', choices:[],
     label:'Saved pixel classifier',
     tip:'A pixel classifier saved in this project. It must suit every image you process: same channels, resolution and features. The box is editable, so a name missing from the list can be typed in.'],
    [key:'woundClass', kind:'text', value:'Wound',
     label:'Classifier wound class',
     tip:'The classifier output class that means open wound, for example Wound. Matching ignores case. Every other class counts as cell sheet.'],
    [key:'downsample', kind:'text', value:'4',
     label:'Downsample',
     tip:'Read the image at 1/N resolution. This is the main control on both speed and memory, and cost falls with the square: 8 is about four times cheaper than 4. Raise it if a run is slow or an image is refused; lower it if the wound edge looks blocky.'],
    [key:'analysisPercent', kind:'text', value:'90',
     label:'Analysis field (%)',
     tip:'Keep a centred box of this percentage of width and height and discard the border, which avoids vignetting and edge debris. Use 100 when comparing area or length against a known value, since anything less clips scan lines. Ignored on an image carrying a Restrict rectangle.'],
    [key:'varianceRadius', kind:'text', value:'5',
     label:'Variance radius (analysis px)',
     tip:'Radius of the square neighbourhood the local variance is measured over. It has to span about a cell to describe the texture of the sheet, and that sets the narrowest wound the method can resolve, around three cell diameters. Shrinking it does not rescue a narrow wound; it makes matters worse, because a small neighbourhood cannot characterise the sheet either.'],
    [key:'smoothSigma', kind:'text', value:'2',
     label:'Texture smoothing sigma',
     tip:'Gaussian blur applied to the variance map before thresholding, in analysis pixels. Higher is smoother and less speckled but rounds off real detail at the wound edge.'],
    [key:'minArea', kind:'text', value:'5000',
     label:'Minimum wound area (full-res px²)',
     tip:'A candidate wound smaller than this is discarded and the image reported as NOT_FOUND. Set it well below the smallest wound you expect, but above the largest clump of debris.'],
    [key:'closeIterations', kind:'text', value:'2',
     label:'Close iterations',
     tip:'Closing passes (dilate then erode) on the first-pass mask. Bridges small gaps and swallows speckle inside the wound. Too many round the corners off it.'],
    [key:'openIterations', kind:'text', value:'1',
     label:'Open iterations',
     tip:'Opening passes (erode then dilate) on the first-pass mask. Removes thin bridges and isolated specks. Too many erode a narrow wound away altogether.'],
    [key:'fillHoles', kind:'check', value:'true',
     label:'Fill holes in wound',
     tip:'Fill anything enclosed by the wound, such as debris and detached cells sitting in the gap, so the reported area is the true open area. This step only ever adds pixels, never removes them, and what it added goes in the Holes_Filled_px2 column.'],
    [key:'secondPass', kind:'check', value:'true',
     label:'Enable second pass',
     tip:'Re-threshold a narrow band around the first-pass edge at a finer texture scale, to sharpen the boundary. On the synthetic benchmark the default band happens to cancel the opposite bias of the first pass, which depends on halo width: re-check it against your own imagery if you change objective or camera.'],
    [key:'refineBand', kind:'text', value:'20',
     label:'Refinement band (full-res px)',
     tip:'How far either side of the first-pass edge the second pass may move the boundary. Nothing outside this band can change.'],
    [key:'refineVarianceRadius', kind:'text', value:'3',
     label:'Refinement variance radius',
     tip:'Variance radius for the second pass, in analysis pixels. Smaller than the first pass, because it only has to resolve the edge rather than characterise the whole sheet.'],
    [key:'refineSmoothSigma', kind:'text', value:'1',
     label:'Refinement smoothing sigma',
     tip:'Gaussian blur for the second-pass variance map, in analysis pixels. Lower than the first pass, because smoothing the map is what blurs the edge the second pass exists to sharpen.'],
    [key:'refineCloseIterations', kind:'text', value:'1',
     label:'Refinement close iterations',
     tip:'Closing passes (dilate then erode) on the refined mask. One is usually enough: the refined boundary is only being tidied, not rescued, and the first pass has already removed the speckle.'],
    [key:'refineOpenIterations', kind:'text', value:'0',
     label:'Refinement open iterations',
     tip:'Opening passes on the refined mask. Left at 0 by default, because the refined boundary is already narrow and opening it erodes the edge the second pass just found.'],
    [key:'minTextureRatio', kind:'text', value:'2.5',
     label:'Minimum sheet/wound texture ratio',
     tip:'Reject an image unless the sheet is at least this many times more textured than the proposed wound. Otsu always returns a threshold, even on a closed monolayer, so without this test a closed sheet reports a wound that is not there. 0 turns the test off. Calibrate it by running once at 0 and reading Sheet_Wound_Texture_Ratio for images you trust.'],
    [key:'saveMasks', kind:'check', value:'true',
     label:'Save masks',
     tip:'Write a binary PNG of the final wound per image, at analysis resolution, into masks/.'],
    [key:'saveQC', kind:'check', value:'true',
     label:'Save QC overlays',
     tip:'Write the source image per image into QC/, with the first-pass edge in yellow, the final edge in red and any Restrict rectangle in cyan.'],
    [key:'saveProfiles', kind:'check', value:'true',
     label:'Save width profile CSVs',
     tip:'Write one CSV per image into QC/ holding every measured width and the start and end coordinates of the scan line it came from, so a number in the summary can be drawn back onto the image that produced it.'],
    [key:'profileStride', kind:'text', value:'1',
     label:'Width profile stride (every Nth line)',
     tip:'Write only every Nth scan line to the profile CSV. This thins that file alone: the summary statistics are always computed over every line.'],
    [key:'saveDebug', kind:'check', value:'false',
     label:'Save per-step debug images',
     tip:'Write the mask after every pipeline step, plus the texture map and a text log, into debug/. This is how you find which step lost the wound. It is slow and writes a PNG per step per image, so point it at a few images rather than a whole project.'],
    ]
}

/**
 * The parameters the run will not read, given the rest of the form.
 *
 * Kept out of the form so the rule is one statement that can be checked without
 * JavaFX, rather than a scatter of setDisable calls. `needTexture` is the same
 * condition analyseImage uses to decide whether to build the variance map, so
 * the form cannot offer a parameter the run ignores, or hide one it reads.
 */
Set deadParams(String inputMode, boolean secondPass, boolean saveDebug,
               boolean saveProfiles, double minTextureRatio) {
    boolean classifier = inputMode == 'Pixel classifier'
    boolean needTexture = !classifier || minTextureRatio > 0d || saveDebug
    Set dead = [] as Set
    if (!classifier) dead.addAll(['classifierName','woundClass'])
    if (!needTexture) dead.addAll(['varianceRadius','smoothSigma'])
    if (!secondPass) dead.addAll(['refineBand','refineVarianceRadius','refineSmoothSigma',
                                  'refineCloseIterations','refineOpenIterations'])
    if (!saveProfiles) dead.add('profileStride')
    dead
}

/**
 * What to tell someone hovering an inactive row. Kept beside deadParams,
 * because a parameter that can be switched off needs to say what switches it
 * back on; tests/test_dialog.py checks that every key deadParams can return
 * has an entry here.
 */
Map inactiveReason() {
    String noTexture = 'Inactive: nothing in this run reads the variance map. The starting mask comes from the classifier, the presence test is off, and debug images are off. Turning on any one of those brings this back.'
    String noClassifier = 'Inactive: the starting mask is the variance threshold. Set Starting mask to Pixel classifier to use this.'
    String noSecondPass = 'Inactive: the second pass is off.'
    [classifierName:noClassifier, woundClass:noClassifier,
     varianceRadius:noTexture, smoothSigma:noTexture,
     refineBand:noSecondPass, refineVarianceRadius:noSecondPass, refineSmoothSigma:noSecondPass,
     refineCloseIterations:noSecondPass, refineOpenIterations:noSecondPass,
     profileStride:'Inactive: width profile CSVs are not being saved, and the stride thins that file alone.']
}

/**
 * Preference store for the last-used settings, or null where it is unavailable.
 *
 * java.util.prefs keeps these out of the project, so they follow the user
 * rather than the data. A locked-down JRE can refuse, and an unwritable store
 * throws only on flush, so every use is guarded: failing to remember settings
 * must never stop an analysis.
 */
java.util.prefs.Preferences settingsStore() {
    try { return java.util.prefs.Preferences.userRoot().node('qupath/scratchassay') }
    catch (Exception ignored) { return null }
}

String storeGet(store, String key) {
    if (store == null) return null
    try { return store.get(key, null) } catch (Exception ignored) { return null }
}

void storePut(store, String key, String value) {
    if (store == null) return
    // MAX_VALUE_LENGTH is 8192; the orientation list is the only entry that can
    // approach it, and dropping it is better than failing the run.
    if (value == null || value.length() >= 8192) return
    try { store.put(key, value) } catch (Exception ignored) { }
}

/** A tooltip that wraps instead of running off the screen. */
Tooltip helpTip(String text) {
    def t = new Tooltip(text)
    t.wrapText = true
    t.maxWidth = 420
    t
}

/**
 * QuPath runs scripts on a background thread, but JavaFX windows can only be
 * built and shown on the FX application thread. Marshal there and block until
 * the user dismisses the dialog.
 */
Map showSettings(project, List entries) {
    if (Platform.isFxApplicationThread())
        return buildSettingsDialog(project, entries)
    def task = new FutureTask<Map>({ buildSettingsDialog(project, entries) } as Callable)
    Platform.runLater(task)
    return task.get()
}

Map buildSettingsDialog(project, List entries) {
    List classifierNames
    try {
        classifierNames = new ArrayList(project.getPixelClassifiers().getNames()).sort()
    } catch (Exception ignored) {
        classifierNames = []
    }

    def store = settingsStore()
    List spec = paramSpec()
    Map byKey = spec.collectEntries { [(it.key): it] }
    byKey.classifierName.choices = classifierNames
    if (!classifierNames.empty) byKey.classifierName.value = classifierNames[0]
    // Captured before the stored values overwrite them, because a disabled
    // field is validated against its default rather than whatever text it holds.
    Map defaults = spec.collectEntries { [(it.key): it.value] }

    // Last run wins over the built-in defaults, so a project can be re-run
    // without setting the form up again. A stored value that is no longer
    // meaningful, such as a removed classifier or a renamed mode, falls back to
    // the default instead of failing.
    spec.each { p ->
        String saved = storeGet(store, 'param.' + p.key)
        if (saved == null) return
        if (p.kind == 'check') { if (saved=='true' || saved=='false') p.value = saved }
        else if (p.kind == 'choice') { if (p.choices.contains(saved)) p.value = saved }
        else p.value = saved
    }

    spec.each { p ->
        if (p.kind == 'check') {
            def c = new CheckBox(); c.selected = (p.value == 'true'); p.node = c
        } else if (p.kind == 'choice' || p.kind == 'classifier') {
            def c = new ComboBox(); c.items.addAll(p.choices)
            c.editable = (p.kind == 'classifier')
            if (p.value) c.value = p.value
            p.node = c
        } else {
            p.node = new TextField(p.value)
        }
        p.labelNode = new Label(p.label)
        // Both halves of the row carry the tip: whichever one the pointer
        // lands on should explain the parameter.
        p.node.tooltip = helpTip(p.tip)
        p.labelNode.tooltip = helpTip(p.tip)
    }

    // One row per project image: a tick to include it and its scratch
    // orientation. Positions match the caller's sorted entry list one for one.
    // Spelled out, because "vertical" alone leaves it open whether it describes
    // the scratch or the direction the width is measured in.
    String vLabel = 'Vertical scratch (width measured left-right)'
    String hLabel = 'Horizontal scratch (width measured top-bottom)'
    // Orientation is remembered by image name, unlike the ticks: it is a fact
    // about the experiment, so it is the same on every re-run, whereas which
    // subset to measure usually is not. Only the horizontal names are stored,
    // so an unknown image, including every image of a different project,
    // defaults to vertical.
    Set wasHorizontal = ((storeGet(store, 'horizontalImages') ?: '').split('\n') as List)
                            .findAll { it } as Set
    List picks = entries.collect { entry ->
        String name = entry.getImageName()
        def tick = new CheckBox(name); tick.selected = true
        def orient = new ComboBox(); orient.items.addAll(vLabel, hLabel)
        orient.value = wasHorizontal.contains(name) ? hLabel : vLabel
        [name:name, tick:tick, orient:orient]
    }
    def pickGrid = new GridPane(hgap:12, vgap:3)
    picks.eachWithIndex { r, i -> pickGrid.add(r.tick, 0, i); pickGrid.add(r.orient, 1, i) }
    // Setting twenty dropdowns by hand is worse than the problem being solved.
    def bulk = { String label, Closure action ->
        def b = new Button(label)
        b.setOnAction({ e -> picks.each(action) } as EventHandler)
        b
    }
    def toolbar = new HBox(6,
        bulk('All', { it.tick.selected = true }), bulk('None', { it.tick.selected = false }),
        bulk('All vertical', { it.orient.value = vLabel }),
        bulk('All horizontal', { it.orient.value = hLabel }))
    def pickScroll = new ScrollPane(pickGrid); pickScroll.fitToWidth = true; pickScroll.prefViewportHeight = 170
    def pickBox = new VBox(6, toolbar, pickScroll)

    def grid=new GridPane(hgap:10,vgap:7,padding:new Insets(12))
    grid.add(new Label("Images to measure (${entries.size()}) and scratch orientation"),0,0)
    grid.add(pickBox,1,0)
    spec.eachWithIndex { p,i -> grid.add(p.labelNode,0,i+1); grid.add(p.node,1,i+1) }

    Map reasons = inactiveReason()
    /**
     * Grey out a row rather than leave it looking live.
     *
     * The label is dimmed rather than disabled, deliberately: a disabled
     * JavaFX node receives no mouse events, so disabling it would swallow the
     * tooltip exactly when someone wants to know why the row has gone dead.
     * Dimming keeps it hoverable, and the tooltip then says what revives it.
     */
    def setLive = { String key, boolean live ->
        def p = byKey[key]
        p.node.disable = !live
        p.labelNode.opacity = live ? 1.0d : 0.45d
        p.labelNode.tooltip = helpTip(live ? p.tip : p.tip + '\n\n' + reasons[key])
    }
    def refresh = {
        // Mid-edit the text is routinely unparseable, and flickering the
        // texture rows disabled while someone types is worse than assuming the
        // test is on. Unparseable therefore counts as on.
        double ratio
        try { ratio = Double.parseDouble(byKey.minTextureRatio.node.text.trim()) }
        catch (Exception ignored) { ratio = 1d }
        Set dead = deadParams(byKey.inputMode.node.value as String,
                              byKey.secondPass.node.selected, byKey.saveDebug.node.selected,
                              byKey.saveProfiles.node.selected, ratio)
        spec.each { p -> setLive(p.key, !dead.contains(p.key)) }
    }
    // addListener is overloaded on ChangeListener and InvalidationListener, so
    // the cast is not decoration: a bare closure picks the wrong one.
    byKey.inputMode.node.valueProperty().addListener({ o,a,b -> refresh() } as ChangeListener)
    byKey.minTextureRatio.node.textProperty().addListener({ o,a,b -> refresh() } as ChangeListener)
    ['secondPass','saveDebug','saveProfiles'].each {
        byKey[it].node.selectedProperty().addListener({ o,a,b -> refresh() } as ChangeListener)
    }
    refresh()

    def reset = new Button('Reset to defaults')
    reset.tooltip = helpTip('Put every parameter back to the value it ships with, discarding the settings remembered from the last run. The image ticks and orientations are left alone.')
    reset.setOnAction({ e ->
        spec.each { p ->
            String d = defaults[p.key]
            if (p.kind == 'check') p.node.selected = (d == 'true')
            else if (p.kind == 'choice' || p.kind == 'classifier') p.node.value = d
            else p.node.text = d
        }
        refresh()
    } as EventHandler)
    grid.add(reset, 1, spec.size() + 1)

    def dialog=new Dialog<Map>(); dialog.title='Scratch Assay Analyzer'; dialog.initModality(Modality.APPLICATION_MODAL)
    // The picker makes the form tall enough to overflow a small screen.
    def scroll=new ScrollPane(grid); scroll.fitToWidth=true; scroll.prefViewportHeight=600
    dialog.dialogPane.content=scroll; dialog.resizable=true
    dialog.dialogPane.buttonTypes.addAll(ButtonType.OK,ButtonType.CANCEL)
    dialog.setResultConverter { it==ButtonType.OK ? byKey : null }
    def result=dialog.showAndWait(); if (!result.isPresent()) return null
    try {
        Map f=result.get()
        // A disabled parameter has no effect on the run, so it is read from its
        // default rather than from the form. Otherwise text left invalid before
        // a field was switched off would block a run it cannot influence.
        def txt = { String k -> f[k].node.disable ? defaults[k] : f[k].node.text }
        List selection=[]
        picks.eachWithIndex { r,i -> if (r.tick.selected)
            selection << [index:i, orientation:isHorizontal(r.orient.value) ? 'Horizontal' : 'Vertical'] }
        Map c=[selection:selection,
               inputMode:f.inputMode.node.value,
               classifierName:(f.classifierName.node.editor.text ?: f.classifierName.node.value ?: '').trim(),
               woundClass:txt('woundClass').trim(), downsample:positive(txt('downsample'),'Downsample'),
               analysisPercent:positive(txt('analysisPercent'),'Analysis field'),
               varianceRadius:nonnegativeInt(txt('varianceRadius'),'Variance radius'),
               smoothSigma:nonnegative(txt('smoothSigma'),'Smoothing'),
               minArea:positive(txt('minArea'),'Minimum area'),
               closeIterations:nonnegativeInt(txt('closeIterations'),'Close iterations'),
               openIterations:nonnegativeInt(txt('openIterations'),'Open iterations'),
               fillHoles:f.fillHoles.node.selected, secondPass:f.secondPass.node.selected,
               refineBand:positive(txt('refineBand'),'Refinement band'),
               refineVarianceRadius:nonnegativeInt(txt('refineVarianceRadius'),'Refinement radius'),
               refineSmoothSigma:nonnegative(txt('refineSmoothSigma'),'Refinement smoothing'),
               refineCloseIterations:nonnegativeInt(txt('refineCloseIterations'),'Refinement close'),
               refineOpenIterations:nonnegativeInt(txt('refineOpenIterations'),'Refinement open'),
               minTextureRatio:nonnegative(txt('minTextureRatio'),'Minimum texture ratio'),
               saveMasks:f.saveMasks.node.selected, saveQC:f.saveQC.node.selected,
               saveProfiles:f.saveProfiles.node.selected,
               profileStride:positiveInt(txt('profileStride'),'Profile stride'),
               saveDebug:f.saveDebug.node.selected]
        if (c.analysisPercent > 100) throw new IllegalArgumentException('Analysis field must not exceed 100')
        if (c.inputMode == 'Pixel classifier' && !c.classifierName)
            throw new IllegalArgumentException('Choose or enter a saved pixel classifier')
        if (c.inputMode == 'Pixel classifier' && !c.woundClass)
            throw new IllegalArgumentException('Enter the classifier class that represents the wound')
        // Remembered only once the settings are known to be valid, so a typo is
        // never what the next run starts from.
        spec.each { p ->
            String v
            if (p.kind == 'check') v = p.node.selected ? 'true' : 'false'
            else if (p.kind == 'choice') v = p.node.value as String
            else if (p.kind == 'classifier') v = c.classifierName
            else v = txt(p.key) as String
            storePut(store, 'param.' + p.key, v)
        }
        storePut(store, 'horizontalImages',
                 picks.findAll { isHorizontal(it.orient.value) }.collect { it.name }.join('\n'))
        return c
    } catch(Exception e) { Dialogs.showErrorMessage('Invalid settings',e.message); return null }
}

/**
 * Evaluate a saved QuPath pixel classifier and turn one of its labelled output
 * classes into the initial binary wound mask. Classification labels are read
 * from server metadata rather than assuming that the wound is label 0 or 1.
 */
boolean[] classifierMask(project, imageData, String classifierName, String woundClass,
                         int targetW, int targetH, double downsample) {
    def manager = project.getPixelClassifiers()
    def classifier = manager.get(classifierName)
    if (classifier == null)
        throw new IllegalArgumentException("Saved pixel classifier not found: ${classifierName}")

    def classificationServer = PixelClassifierTools.createPixelClassificationServer(imageData, classifier)
    try {
        Map labels = classificationServer.getMetadata().getClassificationLabels()
        def match = labels.find { key, pathClass ->
            String name = pathClass == null ? '' : (pathClass.respondsTo('getName') ? pathClass.getName() : pathClass.toString())
            name.equalsIgnoreCase(woundClass)
        }
        if (match == null) {
            String available = labels.values().collect { it == null ? '(unclassified)' : it.toString() }.join(', ')
            throw new IllegalArgumentException("Class '${woundClass}' is not an output of '${classifierName}'. Available classes: ${available}")
        }

        def request = RegionRequest.createInstance(classificationServer.getPath(), downsample,
            0, 0, classificationServer.getWidth(), classificationServer.getHeight())
        BufferedImage classified = classificationServer.readRegion(request)
        int wanted = match.key as int
        boolean[] mask = new boolean[targetW * targetH]
        // Image servers can differ by one pixel because dimensions are rounded at
        // a downsample. Nearest-neighbour lookup preserves categorical labels.
        for (int y=0; y<targetH; y++) {
            int sy = Math.min(classified.height-1, (int)(y * classified.height / (double)targetH))
            for (int x=0; x<targetW; x++) {
                int sx = Math.min(classified.width-1, (int)(x * classified.width / (double)targetW))
                mask[y*targetW+x] = classified.raster.getSample(sx, sy, 0) == wanted
            }
        }
        return mask
    } finally {
        try { classificationServer.close() } catch (Exception ignored) {}
    }
}

/** Anything that does not announce itself as horizontal is treated as vertical. */
boolean isHorizontal(Object label){ label != null && label.toString().toLowerCase().startsWith('horizontal') }

double positive(String s,String n){ double v=Double.parseDouble(s); if(!(v>0))throw new IllegalArgumentException("$n must be > 0");v }
double nonnegative(String s,String n){ double v=Double.parseDouble(s);if(v<0)throw new IllegalArgumentException("$n must be >= 0");v }
int positiveInt(String s,String n){ int v=nonnegativeInt(s,n);if(v<1)throw new IllegalArgumentException("$n must be at least 1");v }
int nonnegativeInt(String s,String n){ double v=nonnegative(s,n);if(v!=Math.rint(v))throw new IllegalArgumentException("$n must be an integer");v as int }

/**
 * Rec. 709 luminance of the image as read.
 *
 * One bulk getRGB per row rather than one call per pixel: the values are
 * identical, because the same colour conversion runs either way, but the
 * per-pixel call is the slow path. Note that for a grey image getRGB converts
 * linear grey to sRGB, so these are not the stored sample values - that is
 * fine for a texture measure, which only needs a monotone mapping.
 */
@CompileStatic
float[] luminance(BufferedImage im) {
    int w=im.width, h=im.height
    float[] a=new float[w*h]
    int[] row=new int[w]
    for(int y=0;y<h;y++){
        im.getRGB(0,y,w,1,row,0,w)
        int off=y*w
        for(int x=0;x<w;x++){
            int c=row[x]
            a[off+x]=(float)(0.2126*((c>>16)&255)+0.7152*((c>>8)&255)+0.0722*(c&255))
        }
    }
    a
}

/**
 * Sum of src (or of src squared) over a (2r+1)-square window, clipped at the
 * image border. Separable sliding windows keep this at two float arrays
 * instead of the pair of double integral images an earlier version used.
 */
@CompileStatic
float[] boxSum(float[] src,int w,int h,int r,boolean square) {
    if(src.length<(long)w*h) throw new IllegalArgumentException("boxSum: an array of ${src.length} pixels cannot cover ${w}x${h}")
    float[] tmp=new float[src.length]
    for(int y=0;y<h;y++){int row=y*w;double run=0
        for(int x=0;x<Math.min(w,r+1);x++){double v=src[row+x];run+=square?v*v:v}
        for(int x=0;x<w;x++){tmp[row+x]=(float)run;int add=x+r+1,drop=x-r
            if(add<w){double v=src[row+add];run+=square?v*v:v}
            if(drop>=0){double v=src[row+drop];run-=square?v*v:v}}}
    float[] out=new float[src.length]
    for(int x=0;x<w;x++){double run=0
        for(int y=0;y<Math.min(h,r+1);y++)run+=tmp[y*w+x]
        for(int y=0;y<h;y++){out[y*w+x]=(float)run;int add=y+r+1,drop=y-r
            if(add<h)run+=tmp[add*w+x]
            if(drop>=0)run-=tmp[drop*w+x]}}
    out
}

/** Local variance over a (2r+1)-square window. The result reuses one input buffer. */
@CompileStatic
float[] localVariance(float[] a,int w,int h,int r) {
    if(r<=0) return new float[a.length]
    float[] s1=boxSum(a,w,h,r,false),s2=boxSum(a,w,h,r,true)
    for(int y=0;y<h;y++){int ny=Math.min(h,y+r+1)-Math.max(0,y-r)
        for(int x=0;x<w;x++){int n=ny*(Math.min(w,x+r+1)-Math.max(0,x-r));int i=y*w+x
            double mean=s1[i]/n
            s1[i]=(float)Math.max(0d,s2[i]/n-mean*mean)}}
    s1
}

/** Separable Gaussian blur. Writes the result back into src to save an array. */
@CompileStatic
float[] gaussian(float[] src,int w,int h,double sigma) {
    if(src.length<(long)w*h) throw new IllegalArgumentException("gaussian: an array of ${src.length} pixels cannot cover ${w}x${h}")
    if(sigma<=0)return src; int r=Math.max(1,(int)Math.ceil(3*sigma));double[] k=new double[2*r+1];double total=0
    for(int i=-r;i<=r;i++){k[i+r]=Math.exp(-i*i/(2*sigma*sigma));total+=k[i+r]};for(int i=0;i<k.length;i++)k[i]/=total
    float[] tmp=new float[src.length]
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=src[y*w+Math.max(0,Math.min(w-1,x+j))]*k[j+r];tmp[y*w+x]=(float)s}
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=tmp[Math.max(0,Math.min(h-1,y+j))*w+x]*k[j+r];src[y*w+x]=(float)s};src
}

/**
 * Smoothed local variance, log transformed.
 *
 * Otsu assumes two compact classes. Raw local variance does not oblige: the
 * wound forms a tight class near zero while the cell sheet's is broad and
 * heavy-tailed, which drags the threshold far above the valley and swallows
 * much of the sheet. The variance of a textured field is roughly chi-square
 * distributed, so its logarithm is roughly Gaussian, which is the shape Otsu
 * expects. On the synthetic benchmark this is the difference between
 * misclassifying a third of the frame and misclassifying a twenty-fifth of it.
 *
 * Every threshold and comparison downstream is therefore in log units; the CSV
 * converts back so the exported numbers stay in variance units.
 */
@CompileStatic
float[] textureMap(float[] gray,int w,int h,int radius,double sigma){
    float[] t=gaussian(localVariance(gray,w,h,radius),w,h,sigma)
    for(int i=0;i<t.length;i++) t[i]=(float)Math.log1p(t[i])
    t
}

/**
 * How many times more textured the analysis field is outside the proposed
 * wound than inside it, or NaN when either side is empty - which is itself a
 * rejection, since a mask covering the whole field cannot be a wound.
 *
 * Because the map is log(1+variance), the difference of the two means is a log
 * ratio, so exponentiating gives a scale-free factor: bare substrate runs
 * several times smoother than a cell sheet, a duller patch of sheet does not.
 */
@CompileStatic
double textureRatio(float[] texture,boolean[] mask,boolean[] field){
    double inside=0, outside=0; long nIn=0, nOut=0
    for(int i=0;i<texture.length;i++){
        if(!field[i]) continue
        if(mask[i]){ inside+=texture[i]; nIn++ } else { outside+=texture[i]; nOut++ }
    }
    if(nIn==0||nOut==0) return Double.NaN
    Math.exp(outside/nOut - inside/nIn)
}

@CompileStatic
double otsu(float[] a,boolean[] use) {
    double min=Double.POSITIVE_INFINITY,max=Double.NEGATIVE_INFINITY;for(int i=0;i<a.length;i++)if(use[i]){min=Math.min(min,a[i]);max=Math.max(max,a[i])}
    if(!Double.isFinite(min)||max<=min)return min;long[] hist=new long[256];long n=0;double scale=255/(max-min)
    for(int i=0;i<a.length;i++)if(use[i]){hist[Math.max(0,Math.min(255,(int)((a[i]-min)*scale)))]++;n++}
    double total=0;for(int i=0;i<256;i++)total+=i*hist[i];long back=0;double sb=0,best=-1;int threshold=0
    for(int i=0;i<256;i++){back+=hist[i];if(back==0)continue;long fore=n-back;if(fore==0)break;sb+=i*hist[i];double d=sb/back-(total-sb)/fore,score=(double)back*fore*d*d;if(score>best){best=score;threshold=i}}
    min+threshold/scale
}

@CompileStatic
boolean[] morphology(boolean[] m,int w,int h,int closeN,int openN){boolean[] a=m;for(int i=0;i<closeN;i++)a=erode(dilate(a,w,h,1),w,h,1);for(int i=0;i<openN;i++)a=dilate(erode(a,w,h,1),w,h,1);a}

/**
 * Dilate with a (2r+1)-square structuring element. Separable sliding counts
 * make this two passes regardless of r, rather than r passes of a 3x3 kernel.
 */
@CompileStatic
boolean[] dilate(boolean[] a,int w,int h,int r){
    if(r<=0)return a
    boolean[] tmp=new boolean[a.length]
    for(int y=0;y<h;y++){int row=y*w,count=0
        for(int x=0;x<Math.min(w,r+1);x++)if(a[row+x])count++
        for(int x=0;x<w;x++){tmp[row+x]=count>0;int add=x+r+1,drop=x-r
            if(add<w&&a[row+add])count++
            if(drop>=0&&a[row+drop])count--}}
    boolean[] out=new boolean[a.length]
    for(int x=0;x<w;x++){int count=0
        for(int y=0;y<Math.min(h,r+1);y++)if(tmp[y*w+x])count++
        for(int y=0;y<h;y++){out[y*w+x]=count>0;int add=y+r+1,drop=y-r
            if(add<h&&tmp[add*w+x])count++
            if(drop>=0&&tmp[drop*w+x])count--}}
    out
}

/**
 * Erode with a (2r+1)-square structuring element. A pixel survives only when
 * the whole window lies inside the image and is set, so the border erodes away.
 */
@CompileStatic
boolean[] erode(boolean[] a,int w,int h,int r){
    if(r<=0)return a
    int span=2*r+1
    boolean[] tmp=new boolean[a.length]
    for(int y=0;y<h;y++){int row=y*w,count=0
        for(int x=0;x<Math.min(w,r+1);x++)if(a[row+x])count++
        for(int x=0;x<w;x++){tmp[row+x]=count==span;int add=x+r+1,drop=x-r
            if(add<w&&a[row+add])count++
            if(drop>=0&&a[row+drop])count--}}
    boolean[] out=new boolean[a.length]
    for(int x=0;x<w;x++){int count=0
        for(int y=0;y<Math.min(h,r+1);y++)if(tmp[y*w+x])count++
        for(int y=0;y<h;y++){out[y*w+x]=count==span;int add=y+r+1,drop=y-r
            if(add<h&&tmp[add*w+x])count++
            if(drop>=0&&tmp[drop*w+x])count--}}
    out
}

/**
 * Flood-fill the 4-connected component containing seed, returning
 * [area, sum of x, sum of y]. When out is non-null the component is written
 * into it. Callers supply the scratch arrays so nothing is allocated per call.
 */
@CompileStatic
long[] flood(boolean[] mask,boolean[] seen,int[] queue,int w,int h,int seed,boolean[] out){
    int head=0,tail=0;queue[tail++]=seed;seen[seed]=true;long sx=0,sy=0
    while(head<tail){int p=queue[head++],y=Math.floorDiv(p,w),x=p-y*w
        sx+=x;sy+=y;if(out!=null)out[p]=true
        if(x>0&&mask[p-1]&&!seen[p-1]){seen[p-1]=true;queue[tail++]=p-1}
        if(x<w-1&&mask[p+1]&&!seen[p+1]){seen[p+1]=true;queue[tail++]=p+1}
        if(y>0&&mask[p-w]&&!seen[p-w]){seen[p-w]=true;queue[tail++]=p-w}
        if(y<h-1&&mask[p+w]&&!seen[p+w]){seen[p+w]=true;queue[tail++]=p+w}}
    [(long)tail,sx,sy] as long[]
}

/**
 * Largest 4-connected component of at least `minimum` pixels, or null. The
 * image is flooded once to find the winner and once more to draw it, so only
 * a single component mask is ever held - peak memory does not grow with the
 * number of components, which is what a noisy threshold produces.
 */
@CompileStatic
Map largestComponent(boolean[] mask,int w,int h,int minimum){
    boolean[] seen=new boolean[mask.length]
    int[] queue=new int[mask.length]
    int bestSeed=-1;long bestArea=0
    for(int seed=0;seed<mask.length;seed++){
        if(!mask[seed]||seen[seed])continue
        long area=flood(mask,seen,queue,w,h,seed,null)[0]
        if(area>bestArea){bestArea=area;bestSeed=seed}}
    if(bestSeed<0||bestArea<minimum)return null
    Arrays.fill(seen,false)
    boolean[] own=new boolean[mask.length]
    long[] stats=flood(mask,seen,queue,w,h,bestSeed,own)
    [mask:own,area:stats[0],cx:stats[1]/(double)stats[0],cy:stats[2]/(double)stats[0]]
}

/**
 * Write a mask as a numbered debug PNG, or do nothing when debugging is off.
 * The flag is checked here so the call sites stay one line each.
 */
void debugMask(Map cfg,Path dir,String stem,String step,boolean[] m,int w,int h){
    if (!cfg.saveDebug) return
    ImageIO.write(maskImage(m,w,h),'PNG',dir.resolve(stem+'_'+step+'.png').toFile())
}

/** Write the image as read, so the debug series starts from the input. */
void debugImage(Map cfg,Path dir,String stem,String step,BufferedImage im){
    if (!cfg.saveDebug) return
    ImageIO.write(im,'PNG',dir.resolve(stem+'_'+step+'.png').toFile())
}

/**
 * Write a float map as an 8-bit PNG, scaled linearly between its own extremes
 * over `use`, and return a note recording that scaling.
 *
 * A texture map has no natural display range, so the note matters as much as
 * the picture: without the range the grey levels cannot be related back to the
 * threshold the report says was applied.
 */
String debugMap(Map cfg,Path dir,String stem,String step,float[] v,int w,int h,boolean[] use){
    if (!cfg.saveDebug) return ''
    double mn=Double.POSITIVE_INFINITY, mx=Double.NEGATIVE_INFINITY
    for(int i=0;i<v.length;i++) if(use[i]){ mn=Math.min(mn,v[i]); mx=Math.max(mx,v[i]) }
    if(!Double.isFinite(mn)||!(mx>mn)){ mn=0d; mx=1d }
    BufferedImage out=new BufferedImage(w,h,BufferedImage.TYPE_BYTE_GRAY)
    double scale=255d/(mx-mn)
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){
        int g=(int)Math.round((v[y*w+x]-mn)*scale)
        out.raster.setSample(x,y,0,g<0?0:(g>255?255:g))
    }
    ImageIO.write(out,'PNG',dir.resolve(stem+'_'+step+'.png').toFile())
    step+': grey 0..255 spans log-variance ' + mn + ' .. ' + mx
}

/**
 * Fill background pockets that the mask fully encloses, and return how many
 * pixels were added.
 *
 * This only ever sets pixels, never clears them, so the wound it is handed can
 * grow but can never shrink or disappear. If a wound seems to vanish "at fill
 * holes", the step before it cleared the mask - most likely the wound-presence
 * test. The debug dump writes 08_presence_test for exactly that reason. Background reachable from the image border is left alone,
 * so a wound that runs off the edge of the analysis field is not flooded shut -
 * only genuine interior holes, the cells and debris inside the gap, are closed.
 */
@CompileStatic
long fillHoles(boolean[] mask,int w,int h){
    boolean[] outside=new boolean[mask.length]
    int[] queue=new int[mask.length]
    int head=0,tail=0
    for(int x=0;x<w;x++){int top=x,bottom=(h-1)*w+x
        if(!mask[top]&&!outside[top]){outside[top]=true;queue[tail++]=top}
        if(!mask[bottom]&&!outside[bottom]){outside[bottom]=true;queue[tail++]=bottom}}
    for(int y=0;y<h;y++){int left=y*w,right=y*w+w-1
        if(!mask[left]&&!outside[left]){outside[left]=true;queue[tail++]=left}
        if(!mask[right]&&!outside[right]){outside[right]=true;queue[tail++]=right}}
    while(head<tail){int p=queue[head++],y=Math.floorDiv(p,w),x=p-y*w
        if(x>0&&!mask[p-1]&&!outside[p-1]){outside[p-1]=true;queue[tail++]=p-1}
        if(x<w-1&&!mask[p+1]&&!outside[p+1]){outside[p+1]=true;queue[tail++]=p+1}
        if(y>0&&!mask[p-w]&&!outside[p-w]){outside[p-w]=true;queue[tail++]=p-w}
        if(y<h-1&&!mask[p+w]&&!outside[p+w]){outside[p+w]=true;queue[tail++]=p+w}}
    long filled=0
    for(int i=0;i<mask.length;i++)if(!mask[i]&&!outside[i]){mask[i]=true;filled++}
    filled
}

/**
 * Area, centroid and width statistics for a mask. Width is always measured
 * across the scratch: the horizontal run in each row for a vertical scratch,
 * the vertical run in each column for a horizontal one. Measuring the
 * transposed axis is exactly equivalent to rotating the image a quarter turn
 * and measuring rows, but needs no second copy of the image. Every other step
 * in the pipeline uses square kernels and 4-connectivity, so nothing else in
 * the segmentation depends on the orientation.
 */
/**
 * Whole-image reductions kept out of `measurements` so they can be statically
 * compiled. Both walk every pixel, and Groovy's dynamic dispatch on an inner
 * loop that size costs more than the rest of the pipeline put together.
 */
@CompileStatic
long[] maskExtent(boolean[] m,int w,int h){
    long area=0,sx=0,sy=0; int minX=w,maxX=-1,minY=h,maxY=-1
    for(int y=0;y<h;y++){int row=y*w
        for(int x=0;x<w;x++)if(m[row+x]){area++;sx+=x;sy+=y
            if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y}}
    [area,sx,sy,(long)minX,(long)maxX,(long)minY,(long)maxY] as long[]
}

/** First and last set pixel of every scan line, as pairs; -1,-1 for an empty line. */
@CompileStatic
int[] scanRuns(boolean[] m,int w,int h,boolean vertical){
    int n=vertical?h:w
    int[] out=new int[2*n]
    if(vertical){for(int y=0;y<h;y++){int row=y*w,first=-1,last=-1
        for(int x=0;x<w;x++)if(m[row+x]){if(first<0)first=x;last=x}
        out[2*y]=first;out[2*y+1]=last}}
    else{for(int x=0;x<w;x++){int first=-1,last=-1
        for(int y=0;y<h;y++)if(m[y*w+x]){if(first<0)first=y;last=y}
        out[2*x]=first;out[2*x+1]=last}}
    out
}

/**
 * The three whole-image mask writes. A NaN cut fails every comparison, which is
 * what the caller wants: no threshold means no pixels claimed.
 */
@CompileStatic
void maskBelow(float[] src,boolean[] gate,double cut,boolean[] out){
    for(int i=0;i<out.length;i++) out[i] = gate[i] && src[i]<=cut
}

@CompileStatic
void addBelow(float[] src,boolean[] gate,double cut,boolean[] out){
    for(int i=0;i<out.length;i++) if(gate[i] && src[i]<=cut) out[i]=true
}

@CompileStatic
void andMask(boolean[] out,boolean[] gate){
    for(int i=0;i<out.length;i++) out[i] = out[i] && gate[i]
}

Map measurements(boolean[] m,int w,int h,boolean vertical){
    long[] ex=maskExtent(m,w,h)
    long area=ex[0],sx=ex[1],sy=ex[2]
    int minX=(int)ex[3],maxX=(int)ex[4],minY=(int)ex[5],maxY=(int)ex[6]
    // Keep where each scan line entered and left the wound, as
    // [startX,startY,endX,endY] in analysis pixels, so every width in the
    // summary can be drawn back onto the image it came from.
    int[] runs=scanRuns(m,w,h,vertical);List lines=[]
    if(vertical){for(int y=0;y<h;y++){int first=runs[2*y],last=runs[2*y+1];if(first>=0)lines<<[first,y,last,y]}}
    else{for(int x=0;x<w;x++){int first=runs[2*x],last=runs[2*x+1];if(first>=0)lines<<[x,first,x,last]}}
    if(area==0)return [area:0,cx:Double.NaN,cy:Double.NaN,length:Double.NaN,meanWidth:Double.NaN,medianWidth:Double.NaN,widthSD:Double.NaN,samples:0,lines:[]]
    // Length runs along the scratch, width across it. Reporting both makes it
    // obvious at a glance whether the orientation was set the right way round.
    double length=vertical ? (maxY-minY+1) : (maxX-minX+1)
    // One of the two deltas is always zero, so this is the run either way.
    List widths=lines.collect{ (it[2]-it[0])+(it[3]-it[1])+1 }
    List ranked=new ArrayList(widths); ranked.sort()
    double mean=widths.sum()/(double)widths.size(),med=ranked.size()%2?ranked[ranked.size()/2]:(ranked[ranked.size()/2-1]+ranked[ranked.size()/2])/2d
    double sd=Math.sqrt(widths.collect{(it-mean)*(it-mean)}.sum()/widths.size());[area:area,cx:sx/(double)area,cy:sy/(double)area,length:length,meanWidth:mean,medianWidth:med,widthSD:sd,samples:widths.size(),lines:lines]}

void replaceGeneratedAnnotation(imageData,boolean[] mask,int w,int h,double dsX,double dsY){def hierarchy=imageData.getHierarchy();def cls=PathClassFactory.getPathClass('Scratch wound');def old=hierarchy.getAnnotationObjects().findAll{it.getPathClass()==cls};if(!old.empty)hierarchy.removeObjects(old,true)
    Area area=new Area();for(int y=0;y<h;y++){int start=-1;for(int x=0;x<=w;x++){boolean on=x<w&&mask[y*w+x];if(on&&start<0)start=x;if(!on&&start>=0){area.add(new Area(new Rectangle2D.Double(start*dsX,y*dsY,(x-start)*dsX,dsY)));start=-1}}}
    if(!area.isEmpty()){def roi=ROIs.createAreaROI(area,ImagePlane.getDefaultPlane());def obj=PathObjects.createAnnotationObject(roi,cls);obj.setName('Scratch wound (generated)');obj.getMeasurementList().put('Scratch assay generated',1d);hierarchy.addObject(obj)}}

BufferedImage maskImage(boolean[] m,int w,int h){BufferedImage out=new BufferedImage(w,h,BufferedImage.TYPE_BYTE_GRAY);for(int y=0;y<h;y++)for(int x=0;x<w;x++)out.raster.setSample(x,y,0,m[y*w+x]?255:0);out}
BufferedImage qcImage(BufferedImage source,boolean[] p1,boolean[] fin,List rects){int w=source.width,h=source.height;BufferedImage out=new BufferedImage(w,h,BufferedImage.TYPE_INT_RGB);Graphics2D g=out.createGraphics();g.drawImage(source,0,0,null);g.dispose();for(int y=1;y<h-1;y++)for(int x=1;x<w-1;x++){int i=y*w+x;if(boundary(p1,i,w)&&!boundary(fin,i,w))out.setRGB(x,y,0xFFFF00);if(boundary(fin,i,w))out.setRGB(x,y,0xFF0000)};rects.each{r->int x0=r[0] as int,y0=r[1] as int,x1=(r[2] as int)-1,y1=(r[3] as int)-1
    for(int x=x0;x<=x1;x++){out.setRGB(x,y0,0x00FFFF);out.setRGB(x,y1,0x00FFFF)}
    for(int y=y0;y<=y1;y++){out.setRGB(x0,y,0x00FFFF);out.setRGB(x1,y,0x00FFFF)}};out}
boolean boundary(boolean[] m,int i,int w){m[i]&&(!m[i-1]||!m[i+1]||!m[i-w]||!m[i+w])}

void writeCsv(Path p,List rows){def d=new DecimalFormat('0.######');List names=['Image','Orientation','Wound_Area_px2','Wound_Area_um2','Holes_Filled_px2','Percent_Open','Restricted','Field_X_px','Field_Y_px','Field_W_px','Field_H_px','Scratch_Length_px','Mean_Width_px','Median_Width_px','Width_SD_px','Width_Samples','Centroid_X_px','Centroid_Y_px','Pass1_Threshold','Pass2_Threshold','Sheet_Wound_Texture_Ratio','Detection_Status','Refinement_Status'];def keys=['image','orientation','areaPx','areaUm2','holesFilled','percentOpen','restricted','fieldX','fieldY','fieldW','fieldH','length','meanWidth','medianWidth','widthSD','widthSamples','centroidX','centroidY','threshold1','threshold2','textureRatio','detection','refinement'];List lines=[names.join(',')];rows.each{r->lines<<keys.collect{k->def v=r[k];v instanceof Number?(Double.isFinite(v as double)?d.format(v):'NA'):('"'+v.toString().replace('"','""')+'"')}.join(',')};Files.write(p,lines,StandardCharsets.UTF_8)}
/**
 * One row per scan line for a single image: where the line entered and left the
 * wound, and how wide it was. This is the raw material behind Mean_Width_px and
 * friends, so a measurement can be drawn back over the image that produced it.
 * Coordinates are given both full resolution, matching the summary CSV and the
 * QuPath annotation, and in analysis pixels, matching the QC and mask PNGs.
 * A stride above 1 thins this file only; the summary statistics are always
 * computed over every line.
 */
void writeWidthProfile(Path p,String image,String orientation,List lines,double dsX,double dsY,double widthScale,double pixelUm,int stride){
    def d=new DecimalFormat('0.######')
    List out=['Image,Orientation,Line_Index,Start_X_px,Start_Y_px,End_X_px,End_Y_px,Width_px,Width_um,' +
              'Start_X_analysis_px,Start_Y_analysis_px,End_X_analysis_px,End_Y_analysis_px,Width_analysis_px']
    String img='"'+image.replace('"','""')+'"',ori='"'+orientation+'"'
    lines.eachWithIndex{ l,i ->
        // Sampling thins the file only. Line_Index stays the true position of
        // the line, so a strided profile still points at the right image rows.
        if (i % stride != 0) return
        int ax0=l[0] as int,ay0=l[1] as int,ax1=l[2] as int,ay1=l[3] as int
        int wa=(ax1-ax0)+(ay1-ay0)+1
        double wFull=wa*widthScale
        out<<([img,ori,(i+1) as String,
               d.format(ax0*dsX),d.format(ay0*dsY),d.format(ax1*dsX),d.format(ay1*dsY),
               d.format(wFull),Double.isFinite(pixelUm)?d.format(wFull*pixelUm):'NA',
               ax0 as String,ay0 as String,ax1 as String,ay1 as String,wa as String].join(','))
    }
    Files.write(p,out,StandardCharsets.UTF_8)
}

void writeSettings(Path p,String version,Map cfg,List order){List lines=["Scratch Assay Analyzer version=${version}","Generated=${ZonedDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX"))}"];cfg.each{k,v->lines<<"${k}=${v}"};lines<<'Images measured:';order.eachWithIndex{n,i->lines<<"${i+1}\t${n}"};Files.write(p,lines,StandardCharsets.UTF_8)}
String safeStem(String n){n.replaceFirst(/\.[^.]+$/,'').replaceAll(/[^A-Za-z0-9._-]+/,'_')}
int naturalCompare(String a,String b){def aa=a.toLowerCase().split(/(?<=\D)(?=\d)|(?<=\d)(?=\D)/),bb=b.toLowerCase().split(/(?<=\D)(?=\d)|(?<=\d)(?=\D)/);for(int i=0;i<Math.min(aa.length,bb.length);i++){int c=(aa[i]==~ /\d+/&&bb[i]==~ /\d+/)?new BigInteger(aa[i])<=>new BigInteger(bb[i]):aa[i]<=>bb[i];if(c)return c};aa.length<=>bb.length}
