/**
 * Scratch Assay Analyzer for QuPath, version 1.0.0.
 *
 * Run from QuPath's script editor with a project open. The implementation is
 * deliberately dependency-free: image processing uses Java arrays so that the
 * script works in standard QuPath installations.
 */

import javafx.geometry.Insets
import javafx.scene.control.*
import javafx.scene.layout.GridPane
import javafx.stage.Modality
import qupath.lib.gui.QuPathGUI
import qupath.lib.gui.dialogs.Dialogs
import qupath.lib.objects.PathObjects
import qupath.lib.objects.classes.PathClassFactory
import qupath.lib.regions.ImagePlane
import qupath.lib.regions.RegionRequest
import qupath.lib.roi.ROIs
import qupath.lib.classifiers.pixel.PixelClassifierTools

import javax.imageio.ImageIO
import java.awt.*
import java.awt.geom.Area
import java.awt.geom.Rectangle2D
import java.awt.image.BufferedImage
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.text.DecimalFormat

final String VERSION = '1.0.0'
def project = getProject()
if (project == null) {
    Dialogs.showErrorMessage('Scratch Assay Analyzer', 'Open a QuPath project before running this script.')
    return
}

Map cfg = showSettings(project)
if (cfg == null) return

List entries = new ArrayList(project.getImageList())
entries.sort { a, b -> naturalCompare(a.getImageName(), b.getImageName()) }
if (entries.isEmpty()) {
    Dialogs.showErrorMessage('Scratch Assay Analyzer', 'The current project contains no images.')
    return
}

Path output = Path.of(project.getPath().getParent().toString(), 'Scratch_Assay_Results')
Path qcDir = output.resolve('QC')
Path maskDir = output.resolve('Masks')
Files.createDirectories(qcDir)
if (cfg.saveMasks) Files.createDirectories(maskDir)

List rows = []
Map previous = null
Double baselineArea = null
entries.eachWithIndex { entry, frame ->
    def imageData = entry.readImageData()
    def server = imageData.getServer()
    double ds = cfg.downsample as double
    int w = Math.max(1, (int)Math.ceil(server.getWidth() / ds))
    int h = Math.max(1, (int)Math.ceil(server.getHeight() / ds))
    if ((long)w * h > 100_000_000L)
        throw new IllegalArgumentException("${entry.getImageName()}: analysis image exceeds 100 million pixels; increase downsample")
    def request = RegionRequest.createInstance(server.getPath(), ds, 0, 0, server.getWidth(), server.getHeight())
    BufferedImage source = server.readRegion(request)
    float[] gray = luminance(source)

    int marginX = Math.round(w * (100d - cfg.analysisPercent) / 200d) as int
    int marginY = Math.round(h * (100d - cfg.analysisPercent) / 200d) as int
    boolean[] field = new boolean[w * h]
    for (int y = marginY; y < h - marginY; y++)
        Arrays.fill(field, y*w + marginX, y*w + (w-marginX), true)

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
    }
    float[] texture1 = gaussian(localVariance(gray, w, h, cfg.varianceRadius as int), w, h, cfg.smoothSigma as double)
    double cut1 = otsu(texture1, field)
    boolean[] pass1 = new boolean[w*h]
    for (int i=0; i<pass1.length; i++) pass1[i] = field[i] && texture1[i] <= cut1
    pass1 = morphology(pass1, w, h, cfg.closeIterations as int, cfg.openIterations as int)
    List components = components(pass1, w, h, (cfg.minArea / (ds*ds)) as int)
    Map selected = selectComponent(components, previous, cfg.maxTrackShift / ds)
    boolean[] firstMask = selected == null ? new boolean[w*h] : selected.mask
    boolean[] finalMask = firstMask
    double cut2 = Double.NaN
    String refineStatus = cfg.secondPass ? 'NO_COMPONENT' : 'DISABLED'

    if (selected != null && cfg.secondPass) {
        int band = Math.max(1, Math.round(cfg.refineBand / ds) as int)
        boolean[] inner = erode(firstMask, w, h, band)
        boolean[] outer = dilate(firstMask, w, h, band)
        boolean[] searchBand = new boolean[w*h]
        for (int i=0; i<searchBand.length; i++) searchBand[i] = outer[i] && !inner[i] && field[i]
        float[] texture2 = gaussian(localVariance(gray, w, h, cfg.refineVarianceRadius as int), w, h, cfg.refineSmoothSigma as double)
        cut2 = otsu(texture2, searchBand)
        boolean[] refined = inner.clone()
        for (int i=0; i<refined.length; i++) if (searchBand[i] && texture2[i] <= cut2) refined[i] = true
        refined = morphology(refined, w, h, cfg.refineCloseIterations as int, cfg.refineOpenIterations as int)
        List refinedComponents = components(refined, w, h, 1)
        Map best = nearest(refinedComponents, selected.cx as double, selected.cy as double)
        if (best != null) {
            finalMask = best.mask
            selected = best
            refineStatus = 'APPLIED'
        } else refineStatus = 'FALLBACK'
    }

    Map m = measurements(finalMask, w, h)
    if (m.area > 0 && baselineArea == null) baselineArea = m.area as double
    double areaPx = m.area * ds * ds
    double pixelUm = server.getPixelCalibration().hasPixelSizeMicrons() ?
        server.getPixelCalibration().getAveragedPixelSizeMicrons() : Double.NaN
    double time = frame * (cfg.frameInterval as double)
    double closure = baselineArea == null ? Double.NaN : 100d * (1d - m.area / baselineArea)
    rows << [frame:frame+1, time:time, image:entry.getImageName(), areaPx:areaPx,
             areaUm2:Double.isNaN(pixelUm) ? Double.NaN : areaPx*pixelUm*pixelUm,
             percentOpen:100d*m.area/Math.max(1, field.count(true)), closure:closure,
             meanWidth:m.meanWidth*ds, medianWidth:m.medianWidth*ds, widthSD:m.widthSD*ds,
             widthSamples:m.samples, centroidX:m.cx*ds, centroidY:m.cy*ds,
             threshold1:cut1, threshold2:cut2, tracking:selected == null ? 'NOT_FOUND' :
                (previous == null ? 'INITIAL' : 'TRACKED'), refinement:refineStatus]

    replaceGeneratedAnnotation(imageData, finalMask, w, h, ds)
    entry.saveImageData(imageData)
    String stem = safeStem(entry.getImageName())
    if (cfg.saveMasks) ImageIO.write(maskImage(finalMask,w,h), 'PNG', maskDir.resolve(stem+'_wound_mask.png').toFile())
    ImageIO.write(qcImage(source, firstMask, finalMask, marginX, marginY), 'PNG', qcDir.resolve(stem+'_QC.png').toFile())
    previous = m.area > 0 ? m : previous
    println "Scratch assay ${frame+1}/${entries.size()}: ${entry.getImageName()} (${m.area} analysis pixels)"
}

writeCsv(output.resolve('Scratch_Assay_Texture_Tracking.csv'), rows)
writeSettings(output.resolve('Scratch_Assay_Settings.txt'), VERSION, cfg, entries*.getImageName())
Dialogs.showInfoNotification('Scratch Assay Analyzer', "Processed ${entries.size()} image(s). Results: ${output}")

Map showSettings(project) {
    List classifierNames
    try {
        classifierNames = new ArrayList(project.getPixelClassifiers().getNames()).sort()
    } catch (Exception ignored) {
        classifierNames = []
    }
    def fields = [
        inputMode:new ComboBox(), classifierName:new ComboBox(), woundClass:new TextField('Wound'),
Map showSettings() {
    def fields = [
        downsample:new TextField('2'), analysisPercent:new TextField('90'), varianceRadius:new TextField('5'),
        smoothSigma:new TextField('2'), minArea:new TextField('5000'), closeIterations:new TextField('2'),
        openIterations:new TextField('1'), maxTrackShift:new TextField('250'), frameInterval:new TextField('1'),
        secondPass:new CheckBox(), refineBand:new TextField('20'), refineVarianceRadius:new TextField('3'),
        refineSmoothSigma:new TextField('1'), refineCloseIterations:new TextField('1'),
        refineOpenIterations:new TextField('0'), saveMasks:new CheckBox()
    ]
    fields.inputMode.items.addAll('Variance threshold', 'Pixel classifier')
    fields.inputMode.value='Variance threshold'
    fields.classifierName.items.addAll(classifierNames)
    fields.classifierName.editable=true
    if (!classifierNames.empty) fields.classifierName.value=classifierNames[0]
    fields.secondPass.selected=true; fields.saveMasks.selected=true
    def labels=['Starting mask','Saved pixel classifier','Classifier wound class','Downsample','Analysis field (%)','Variance radius (analysis px)','Texture smoothing sigma',
    fields.secondPass.selected=true; fields.saveMasks.selected=true
    def labels=['Downsample','Analysis field (%)','Variance radius (analysis px)','Texture smoothing sigma',
                'Minimum wound area (full-res px²)','Close iterations','Open iterations',
                'Maximum tracking shift (full-res px)','Frame interval (hours)','Enable second pass',
                'Refinement band (full-res px)','Refinement variance radius','Refinement smoothing sigma',
                'Refinement close iterations','Refinement open iterations','Save masks']
    def grid=new GridPane(hgap:10,vgap:7,padding:new Insets(12))
    fields.values().eachWithIndex { node,i -> grid.add(new Label(labels[i]),0,i); grid.add(node,1,i) }
    def dialog=new Dialog<Map>(); dialog.title='Scratch Assay Analyzer'; dialog.initModality(Modality.APPLICATION_MODAL)
    dialog.dialogPane.content=grid; dialog.dialogPane.buttonTypes.addAll(ButtonType.OK,ButtonType.CANCEL)
    dialog.setResultConverter { it==ButtonType.OK ? fields : null }
    def result=dialog.showAndWait(); if (!result.isPresent()) return null
    try {
        Map f=result.get()
        Map c=[inputMode:f.inputMode.value, classifierName:(f.classifierName.editor.text ?: f.classifierName.value ?: '').trim(),
               woundClass:f.woundClass.text.trim(), downsample:positive(f.downsample.text,'Downsample'), analysisPercent:positive(f.analysisPercent.text,'Analysis field'),
        Map c=[downsample:positive(f.downsample.text,'Downsample'), analysisPercent:positive(f.analysisPercent.text,'Analysis field'),
               varianceRadius:nonnegativeInt(f.varianceRadius.text,'Variance radius'), smoothSigma:nonnegative(f.smoothSigma.text,'Smoothing'),
               minArea:positive(f.minArea.text,'Minimum area'), closeIterations:nonnegativeInt(f.closeIterations.text,'Close iterations'),
               openIterations:nonnegativeInt(f.openIterations.text,'Open iterations'), maxTrackShift:positive(f.maxTrackShift.text,'Tracking shift'),
               frameInterval:positive(f.frameInterval.text,'Frame interval'), secondPass:f.secondPass.selected,
               refineBand:positive(f.refineBand.text,'Refinement band'), refineVarianceRadius:nonnegativeInt(f.refineVarianceRadius.text,'Refinement radius'),
               refineSmoothSigma:nonnegative(f.refineSmoothSigma.text,'Refinement smoothing'),
               refineCloseIterations:nonnegativeInt(f.refineCloseIterations.text,'Refinement close'),
               refineOpenIterations:nonnegativeInt(f.refineOpenIterations.text,'Refinement open'), saveMasks:f.saveMasks.selected]
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
    def classifier = manager.getResource(classifierName)
    if (classifier == null)
        throw new IllegalArgumentException("Saved pixel classifier not found: ${classifierName}")

    def classificationServer = PixelClassifierTools.createPixelClassificationServer(imageData, classifier)
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
}

double positive(String s,String n){ double v=Double.parseDouble(s); if(!(v>0))throw new IllegalArgumentException("$n must be > 0");v }
double nonnegative(String s,String n){ double v=Double.parseDouble(s);if(v<0)throw new IllegalArgumentException("$n must be >= 0");v }
int nonnegativeInt(String s,String n){ double v=nonnegative(s,n);if(v!=Math.rint(v))throw new IllegalArgumentException("$n must be an integer");v as int }

float[] luminance(BufferedImage im) { int w=im.width,h=im.height; float[] a=new float[w*h]; for(int y=0;y<h;y++)for(int x=0;x<w;x++){int c=im.getRGB(x,y);a[y*w+x]=(float)(0.2126*((c>>16)&255)+0.7152*((c>>8)&255)+0.0722*(c&255))};a }

float[] localVariance(float[] a,int w,int h,int r) {
    double[] sum=new double[(w+1)*(h+1)], sq=new double[sum.length]
    for(int y=1;y<=h;y++){double rs=0,rq=0;for(int x=1;x<=w;x++){double v=a[(y-1)*w+x-1];rs+=v;rq+=v*v;int i=y*(w+1)+x;sum[i]=sum[i-(w+1)]+rs;sq[i]=sq[i-(w+1)]+rq}}
    float[] out=new float[a.length]
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){int x0=Math.max(0,x-r),y0=Math.max(0,y-r),x1=Math.min(w,x+r+1),y1=Math.min(h,y+r+1),n=(x1-x0)*(y1-y0);double s=box(sum,w,x0,y0,x1,y1),q=box(sq,w,x0,y0,x1,y1);out[y*w+x]=(float)Math.max(0,q/n-(s/n)*(s/n))}
    out
}
double box(double[] ii,int w,int x0,int y0,int x1,int y1){int z=w+1;ii[y1*z+x1]-ii[y0*z+x1]-ii[y1*z+x0]+ii[y0*z+x0]}

float[] gaussian(float[] src,int w,int h,double sigma) {
    if(sigma<=0)return src; int r=Math.max(1,(int)Math.ceil(3*sigma));double[] k=new double[2*r+1];double total=0
    for(int i=-r;i<=r;i++){k[i+r]=Math.exp(-i*i/(2*sigma*sigma));total+=k[i+r]};for(int i=0;i<k.length;i++)k[i]/=total
    float[] tmp=new float[src.length],out=new float[src.length]
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=src[y*w+Math.max(0,Math.min(w-1,x+j))]*k[j+r];tmp[y*w+x]=(float)s}
    for(int y=0;y<h;y++)for(int x=0;x<w;x++){double s=0;for(int j=-r;j<=r;j++)s+=tmp[Math.max(0,Math.min(h-1,y+j))*w+x]*k[j+r];out[y*w+x]=(float)s};out
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
boolean[] dilate(boolean[] a,int w,int h,int radius){boolean[] out=a;for(int n=0;n<radius;n++){boolean[] b=new boolean[a.length];for(int y=0;y<h;y++)for(int x=0;x<w;x++){boolean v=false;for(int yy=Math.max(0,y-1);yy<=Math.min(h-1,y+1)&&!v;yy++)for(int xx=Math.max(0,x-1);xx<=Math.min(w-1,x+1);xx++)if(out[yy*w+xx]){v=true;break};b[y*w+x]=v};out=b};out}
boolean[] erode(boolean[] a,int w,int h,int radius){boolean[] out=a;for(int n=0;n<radius;n++){boolean[] b=new boolean[a.length];for(int y=0;y<h;y++)for(int x=0;x<w;x++){boolean v=x>0&&y>0&&x<w-1&&y<h-1;for(int yy=y-1;yy<=y+1&&v;yy++)for(int xx=x-1;xx<=x+1;xx++)if(!out[yy*w+xx]){v=false;break};b[y*w+x]=v};out=b};out}

List components(boolean[] mask,int w,int h,int minimum){boolean[] seen=new boolean[mask.length];List result=[];int[] queue=new int[mask.length]
    for(int seed=0;seed<mask.length;seed++)if(mask[seed]&&!seen[seed]){int head=0,tail=0;queue[tail++]=seed;seen[seed]=true;long sx=0,sy=0
        while(head<tail){int p=queue[head++],x=p%w,y=(int)(p/w);sx+=x;sy+=y;int[] ns=[p-1,p+1,p-w,p+w];for(int q:ns)if(q>=0&&q<mask.length&&!seen[q]&&mask[q]&&(q/w==p/w||q%w==p%w)){seen[q]=true;queue[tail++]=q}}
        if(tail>=minimum){boolean[] own=new boolean[mask.length];for(int i=0;i<tail;i++)own[queue[i]]=true;result<<[mask:own,area:tail,cx:sx/(double)tail,cy:sy/(double)tail]}}
    result}
Map selectComponent(List c,Map previous,double shift){if(c.empty)return null;if(previous==null)return c.max{it.area};Map n=nearest(c,previous.cx as double,previous.cy as double);Math.hypot(n.cx-previous.cx,n.cy-previous.cy)<=shift?n:null}
Map nearest(List c,double x,double y){c.empty?null:c.min{Math.hypot(it.cx-x,it.cy-y)}}

Map measurements(boolean[] m,int w,int h){long area=0,sx=0,sy=0;List widths=[];for(int y=0;y<h;y++){int first=-1,last=-1;for(int x=0;x<w;x++)if(m[y*w+x]){area++;sx+=x;sy+=y;if(first<0)first=x;last=x};if(first>=0)widths<<last-first+1}
    if(area==0)return [area:0,cx:Double.NaN,cy:Double.NaN,meanWidth:Double.NaN,medianWidth:Double.NaN,widthSD:Double.NaN,samples:0]
    widths.sort();double mean=widths.sum()/(double)widths.size(),med=widths.size()%2?widths[widths.size()/2]:(widths[widths.size()/2-1]+widths[widths.size()/2])/2d
    double sd=Math.sqrt(widths.collect{(it-mean)*(it-mean)}.sum()/widths.size());[area:area,cx:sx/(double)area,cy:sy/(double)area,meanWidth:mean,medianWidth:med,widthSD:sd,samples:widths.size()]}

void replaceGeneratedAnnotation(imageData,boolean[] mask,int w,int h,double ds){def hierarchy=imageData.getHierarchy();def cls=PathClassFactory.getPathClass('Scratch wound');def old=hierarchy.getAnnotationObjects().findAll{it.getPathClass()==cls};if(!old.empty)hierarchy.removeObjects(old,true)
    Area area=new Area();for(int y=0;y<h;y++){int start=-1;for(int x=0;x<=w;x++){boolean on=x<w&&mask[y*w+x];if(on&&start<0)start=x;if(!on&&start>=0){area.add(new Area(new Rectangle2D.Double(start*ds,y*ds,(x-start)*ds,ds)));start=-1}}}
    if(!area.isEmpty()){def roi=ROIs.createAreaROI(area,ImagePlane.getDefaultPlane());def obj=PathObjects.createAnnotationObject(roi,cls);obj.setName('Scratch wound (generated)');obj.getMeasurementList().put('Scratch assay generated',1d);hierarchy.addObject(obj)}}

BufferedImage maskImage(boolean[] m,int w,int h){BufferedImage out=new BufferedImage(w,h,BufferedImage.TYPE_BYTE_GRAY);for(int y=0;y<h;y++)for(int x=0;x<w;x++)out.raster.setSample(x,y,0,m[y*w+x]?255:0);out}
BufferedImage qcImage(BufferedImage source,boolean[] p1,boolean[] fin,int mx,int my){int w=source.width,h=source.height;BufferedImage out=new BufferedImage(w,h,BufferedImage.TYPE_INT_RGB);Graphics2D g=out.createGraphics();g.drawImage(source,0,0,null);g.dispose();for(int y=1;y<h-1;y++)for(int x=1;x<w-1;x++){int i=y*w+x;if(boundary(p1,i,w)&&!boundary(fin,i,w))out.setRGB(x,y,0xFFFF00);if(boundary(fin,i,w))out.setRGB(x,y,0xFF0000)};for(int x=mx;x<w-mx;x++){out.setRGB(x,my,0x00FFFF);out.setRGB(x,h-my-1,0x00FFFF)};for(int y=my;y<h-my;y++){out.setRGB(mx,y,0x00FFFF);out.setRGB(w-mx-1,y,0x00FFFF)};out}
boolean boundary(boolean[] m,int i,int w){m[i]&&(!m[i-1]||!m[i+1]||!m[i-w]||!m[i+w])}

void writeCsv(Path p,List rows){def d=new DecimalFormat('0.######');List names=['Frame','Time_h','Image','Wound_Area_px2','Wound_Area_um2','Percent_Open','Percent_Closure','Mean_Width_px','Median_Width_px','Width_SD_px','Width_Samples','Centroid_X_px','Centroid_Y_px','Pass1_Threshold','Pass2_Threshold','Tracking_Status','Refinement_Status'];def keys=['frame','time','image','areaPx','areaUm2','percentOpen','closure','meanWidth','medianWidth','widthSD','widthSamples','centroidX','centroidY','threshold1','threshold2','tracking','refinement'];List lines=[names.join(',')];rows.each{r->lines<<keys.collect{k->def v=r[k];v instanceof Number?(Double.isFinite(v as double)?d.format(v):'NA'):('"'+v.toString().replace('"','""')+'"')}.join(',')};Files.write(p,lines,StandardCharsets.UTF_8)}
void writeSettings(Path p,String version,Map cfg,List order){List lines=["Scratch Assay Analyzer version=${version}","Generated=${new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")}"];cfg.each{k,v->lines<<"${k}=${v}"};lines<<'Frame order:';order.eachWithIndex{n,i->lines<<"${i+1}\t${n}"};Files.write(p,lines,StandardCharsets.UTF_8)}
String safeStem(String n){n.replaceFirst(/\.[^.]+$/,'').replaceAll(/[^A-Za-z0-9._-]+/,'_')}
int naturalCompare(String a,String b){def aa=a.toLowerCase().split(/(?<=\D)(?=\d)|(?<=\d)(?=\D)/),bb=b.toLowerCase().split(/(?<=\D)(?=\d)|(?<=\d)(?=\D)/);for(int i=0;i<Math.min(aa.length,bb.length);i++){int c=(aa[i]==~ /\d+/&&bb[i]==~ /\d+/)?new BigInteger(aa[i])<=>new BigInteger(bb[i]):aa[i]<=>bb[i];if(c)return c};aa.length<=>bb.length}
