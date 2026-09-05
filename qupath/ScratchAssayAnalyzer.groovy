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
Files.createDirectories(output)
if (cfg.saveQC || cfg.saveProfiles) Files.createDirectories(qcDir)
if (cfg.saveMasks) Files.createDirectories(maskDir)

List rows = []
jobs.eachWithIndex { job, i ->
    // Each image is analysed in its own method call so that every large array
    // it allocates becomes unreachable as soon as the call returns.
    rows << analyseImage(project, job.entry, job.orientation as String, cfg, maskDir, qcDir)
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
Map analyseImage(project, entry, String orientation, Map cfg, Path maskDir, Path qcDir) {
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
        float[] gray = luminance(source)

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

        boolean[] pass1
        double cut1 = Double.NaN
        if (cfg.inputMode == 'Pixel classifier') {
            pass1 = classifierMask(project, imageData, cfg.classifierName as String,
                cfg.woundClass as String, w, h, ds)
            for (int i=0; i<pass1.length; i++) pass1[i] = pass1[i] && field[i]
        } else {
            float[] texture1 = gaussian(localVariance(gray, w, h, cfg.varianceRadius as int), w, h, cfg.smoothSigma as double)
            cut1 = otsu(texture1, field)
            pass1 = new boolean[w*h]
            for (int i=0; i<pass1.length; i++) pass1[i] = field[i] && texture1[i] <= cut1
            texture1 = null
        }
        pass1 = morphology(pass1, w, h, cfg.closeIterations as int, cfg.openIterations as int)

        Map selected = largestComponent(pass1, w, h, (cfg.minArea / (dsX*dsY)) as int)
        pass1 = null
        boolean[] firstMask = selected == null ? new boolean[w*h] : selected.mask
        // Cells and debris sitting in the gap read as high texture, so they
        // punch holes in the wound. Closing them recovers the true open area.
        long holesFilled = (selected != null && cfg.fillHoles) ? fillHoles(firstMask, w, h) : 0L
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
            float[] texture2 = gaussian(localVariance(gray, w, h, cfg.refineVarianceRadius as int), w, h, cfg.refineSmoothSigma as double)
            cut2 = otsu(texture2, searchBand)
            boolean[] refined = inner
            for (int i=0; i<refined.length; i++) if (searchBand[i] && texture2[i] <= cut2) refined[i] = true
            texture2 = null; searchBand = null
            refined = morphology(refined, w, h, cfg.refineCloseIterations as int, cfg.refineOpenIterations as int)
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

        Map m = measurements(finalMask, w, h, vertical)
        double areaPx = m.area * dsX * dsY
        // Width runs across the scratch and length along it, so each scales
        // with the axis it was measured on.
        double widthScale = vertical ? dsX : dsY
        double lengthScale = vertical ? dsY : dsX
        def cal = server.getPixelCalibration()
        double pixelUm = cal.hasPixelSizeMicrons() ? cal.getAveragedPixelSizeMicrons() : Double.NaN

        replaceGeneratedAnnotation(imageData, finalMask, w, h, dsX, dsY)
        entry.saveImageData(imageData)
        String stem = safeStem(entry.getImageName())
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
                threshold1:cut1, threshold2:cut2,
                restricted:restricted ? 'YES' : 'NO',
                fieldX:fieldRects.collect{it[0]}.min()*dsX, fieldY:fieldRects.collect{it[1]}.min()*dsY,
                fieldW:(fieldRects.collect{it[2]}.max()-fieldRects.collect{it[0]}.min())*dsX,
                fieldH:(fieldRects.collect{it[3]}.max()-fieldRects.collect{it[1]}.min())*dsY,
                detection:selected == null ? 'NOT_FOUND' : 'FOUND', refinement:refineStatus]
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
    long budget = (long)(Runtime.getRuntime().maxMemory() * 0.6d)
    if (bytes > budget)
        throw new IllegalArgumentException(
            "${name}: needs roughly ${bytes >> 20} MB at downsample ${cfg.downsample}, but only ${budget >> 20} MB " +
            'of heap is usable. Increase the downsample, shrink the analysis field, turn off the second pass or ' +
            'QC overlays, or raise QuPath\'s memory limit (Edit > Preferences > Memory).')
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
    // One row per project image: a tick to include it and its scratch
    // orientation. Positions match the caller's sorted entry list one for one.
    // Spelled out, because "vertical" alone leaves it open whether it describes
    // the scratch or the direction the width is measured in.
    String vLabel = 'Vertical scratch (width measured left-right)'
    String hLabel = 'Horizontal scratch (width measured top-bottom)'
    List picks = entries.collect { entry ->
        def tick = new CheckBox(entry.getImageName()); tick.selected = true
        def orient = new ComboBox(); orient.items.addAll(vLabel, hLabel); orient.value = vLabel
        [tick:tick, orient:orient]
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

    def fields = [
        inputMode:new ComboBox(), classifierName:new ComboBox(),
        woundClass:new TextField('Wound'),
        downsample:new TextField('4'), analysisPercent:new TextField('90'), varianceRadius:new TextField('5'),
        smoothSigma:new TextField('2'), minArea:new TextField('5000'), closeIterations:new TextField('2'),
        openIterations:new TextField('1'), fillHoles:new CheckBox(), secondPass:new CheckBox(),
        refineBand:new TextField('20'),
        refineVarianceRadius:new TextField('3'), refineSmoothSigma:new TextField('1'),
        refineCloseIterations:new TextField('1'), refineOpenIterations:new TextField('0'),
        saveMasks:new CheckBox(), saveQC:new CheckBox(), saveProfiles:new CheckBox(),
        profileStride:new TextField('1')
    ]
    fields.inputMode.items.addAll('Variance threshold', 'Pixel classifier')
    fields.inputMode.value='Variance threshold'
    fields.classifierName.items.addAll(classifierNames)
    fields.classifierName.editable=true
    if (!classifierNames.empty) fields.classifierName.value=classifierNames[0]
    fields.fillHoles.selected=true
    fields.secondPass.selected=true; fields.saveMasks.selected=true
    fields.saveQC.selected=true; fields.saveProfiles.selected=true
    def labels=['Starting mask','Saved pixel classifier','Classifier wound class','Downsample','Analysis field (%)',
                'Variance radius (analysis px)','Texture smoothing sigma',
                'Minimum wound area (full-res px²)','Close iterations','Open iterations',
                'Fill holes in wound','Enable second pass',
                'Refinement band (full-res px)','Refinement variance radius','Refinement smoothing sigma',
                'Refinement close iterations','Refinement open iterations','Save masks','Save QC overlays',
                'Save width profile CSVs','Width profile stride (every Nth line)']
    def grid=new GridPane(hgap:10,vgap:7,padding:new Insets(12))
    grid.add(new Label("Images to measure (${entries.size()}) and scratch orientation"),0,0)
    grid.add(pickBox,1,0)
    fields.values().eachWithIndex { node,i -> grid.add(new Label(labels[i]),0,i+1); grid.add(node,1,i+1) }
    def dialog=new Dialog<Map>(); dialog.title='Scratch Assay Analyzer'; dialog.initModality(Modality.APPLICATION_MODAL)
    // The picker makes the form tall enough to overflow a small screen.
    def scroll=new ScrollPane(grid); scroll.fitToWidth=true; scroll.prefViewportHeight=600
    dialog.dialogPane.content=scroll; dialog.resizable=true
    dialog.dialogPane.buttonTypes.addAll(ButtonType.OK,ButtonType.CANCEL)
    dialog.setResultConverter { it==ButtonType.OK ? fields : null }
    def result=dialog.showAndWait(); if (!result.isPresent()) return null
    try {
        Map f=result.get()
        List selection=[]
        picks.eachWithIndex { r,i -> if (r.tick.selected)
            selection << [index:i, orientation:isHorizontal(r.orient.value) ? 'Horizontal' : 'Vertical'] }
        Map c=[selection:selection,
               inputMode:f.inputMode.value, classifierName:(f.classifierName.editor.text ?: f.classifierName.value ?: '').trim(),
               woundClass:f.woundClass.text.trim(), downsample:positive(f.downsample.text,'Downsample'), analysisPercent:positive(f.analysisPercent.text,'Analysis field'),
               varianceRadius:nonnegativeInt(f.varianceRadius.text,'Variance radius'), smoothSigma:nonnegative(f.smoothSigma.text,'Smoothing'),
               minArea:positive(f.minArea.text,'Minimum area'), closeIterations:nonnegativeInt(f.closeIterations.text,'Close iterations'),
               openIterations:nonnegativeInt(f.openIterations.text,'Open iterations'),
               fillHoles:f.fillHoles.selected, secondPass:f.secondPass.selected,
               refineBand:positive(f.refineBand.text,'Refinement band'), refineVarianceRadius:nonnegativeInt(f.refineVarianceRadius.text,'Refinement radius'),
               refineSmoothSigma:nonnegative(f.refineSmoothSigma.text,'Refinement smoothing'),
               refineCloseIterations:nonnegativeInt(f.refineCloseIterations.text,'Refinement close'),
               refineOpenIterations:nonnegativeInt(f.refineOpenIterations.text,'Refinement open'),
               saveMasks:f.saveMasks.selected, saveQC:f.saveQC.selected,
               saveProfiles:f.saveProfiles.selected,
               profileStride:positiveInt(f.profileStride.text,'Profile stride')]
        if (c.analysisPercent > 100) throw new IllegalArgumentException('Analysis field must not exceed 100')
        if (c.inputMode == 'Pixel classifier' && !c.classifierName)
            throw new IllegalArgumentException('Choose or enter a saved pixel classifier')
        if (c.inputMode == 'Pixel classifier' && !c.woundClass)
            throw new IllegalArgumentException('Enter the classifier class that represents the wound')
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

float[] luminance(BufferedImage im) { int w=im.width,h=im.height; float[] a=new float[w*h]; for(int y=0;y<h;y++)for(int x=0;x<w;x++){int c=im.getRGB(x,y);a[y*w+x]=(float)(0.2126*((c>>16)&255)+0.7152*((c>>8)&255)+0.0722*(c&255))};a }

/**
 * Sum of src (or of src squared) over a (2r+1)-square window, clipped at the
 * image border. Separable sliding windows keep this at two float arrays
 * instead of the pair of double integral images an earlier version used.
 */
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
float[] gaussian(float[] src,int w,int h,double sigma) {
    if(src.length<(long)w*h) throw new IllegalArgumentException("gaussian: an array of ${src.length} pixels cannot cover ${w}x${h}")
    if(sigma<=0)return src; int r=Math.max(1,(int)Math.ceil(3*sigma));double[] k=new double[2*r+1];double total=0
    for(int i=-r;i<=r;i++){k[i+r]=Math.exp(-i*i/(2*sigma*sigma));total+=k[i+r]};for(int i=0;i<k.length;i++)k[i]/=total
    float[] tmp=new float[src.length]
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=src[y*w+Math.max(0,Math.min(w-1,x+j))]*k[j+r];tmp[y*w+x]=(float)s}
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=tmp[Math.max(0,Math.min(h-1,y+j))*w+x]*k[j+r];src[y*w+x]=(float)s};src
}

double otsu(float[] a,boolean[] use) {
    double min=Double.POSITIVE_INFINITY,max=Double.NEGATIVE_INFINITY;for(int i=0;i<a.length;i++)if(use[i]){min=Math.min(min,a[i]);max=Math.max(max,a[i])}
    if(!Double.isFinite(min)||max<=min)return min;long[] hist=new long[256];long n=0;double scale=255/(max-min)
    for(int i=0;i<a.length;i++)if(use[i]){hist[Math.max(0,Math.min(255,(int)((a[i]-min)*scale)))]++;n++}
    double total=0;for(int i=0;i<256;i++)total+=i*hist[i];long back=0;double sb=0,best=-1;int threshold=0
    for(int i=0;i<256;i++){back+=hist[i];if(back==0)continue;long fore=n-back;if(fore==0)break;sb+=i*hist[i];double d=sb/back-(total-sb)/fore,score=(double)back*fore*d*d;if(score>best){best=score;threshold=i}}
    min+threshold/scale
}

boolean[] morphology(boolean[] m,int w,int h,int closeN,int openN){boolean[] a=m;for(int i=0;i<closeN;i++)a=erode(dilate(a,w,h,1),w,h,1);for(int i=0;i<openN;i++)a=dilate(erode(a,w,h,1),w,h,1);a}

/**
 * Dilate with a (2r+1)-square structuring element. Separable sliding counts
 * make this two passes regardless of r, rather than r passes of a 3x3 kernel.
 */
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
 * Fill background pockets that the mask fully encloses, and return how many
 * pixels were added. Background reachable from the image border is left alone,
 * so a wound that runs off the edge of the analysis field is not flooded shut -
 * only genuine interior holes, the cells and debris inside the gap, are closed.
 */
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
Map measurements(boolean[] m,int w,int h,boolean vertical){long area=0,sx=0,sy=0;List lines=[]
    int minX=w,maxX=-1,minY=h,maxY=-1
    for(int y=0;y<h;y++)for(int x=0;x<w;x++)if(m[y*w+x]){area++;sx+=x;sy+=y
        if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y}
    // Keep where each scan line entered and left the wound, as
    // [startX,startY,endX,endY] in analysis pixels, so every width in the
    // summary can be drawn back onto the image it came from.
    if(vertical){for(int y=0;y<h;y++){int first=-1,last=-1;for(int x=0;x<w;x++)if(m[y*w+x]){if(first<0)first=x;last=x};if(first>=0)lines<<[first,y,last,y]}}
    else{for(int x=0;x<w;x++){int first=-1,last=-1;for(int y=0;y<h;y++)if(m[y*w+x]){if(first<0)first=y;last=y};if(first>=0)lines<<[x,first,x,last]}}
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

void writeCsv(Path p,List rows){def d=new DecimalFormat('0.######');List names=['Image','Orientation','Wound_Area_px2','Wound_Area_um2','Holes_Filled_px2','Percent_Open','Restricted','Field_X_px','Field_Y_px','Field_W_px','Field_H_px','Scratch_Length_px','Mean_Width_px','Median_Width_px','Width_SD_px','Width_Samples','Centroid_X_px','Centroid_Y_px','Pass1_Threshold','Pass2_Threshold','Detection_Status','Refinement_Status'];def keys=['image','orientation','areaPx','areaUm2','holesFilled','percentOpen','restricted','fieldX','fieldY','fieldW','fieldH','length','meanWidth','medianWidth','widthSD','widthSamples','centroidX','centroidY','threshold1','threshold2','detection','refinement'];List lines=[names.join(',')];rows.each{r->lines<<keys.collect{k->def v=r[k];v instanceof Number?(Double.isFinite(v as double)?d.format(v):'NA'):('"'+v.toString().replace('"','""')+'"')}.join(',')};Files.write(p,lines,StandardCharsets.UTF_8)}
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
