/* $Id: ios_dev.m 3979 2012-03-20 08:55:33Z ming $ */
/*
 * Copyright (C) 2012 Samuel Vinson (samuelv0304@gmail.com)
 * Copyright (C) 2008-2011 Teluu Inc. (http://www.teluu.com)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */
#include <pjmedia-videodev/videodev_imp.h>
#include <pj/assert.h>
#include <pj/log.h>
#include <pj/os.h>

#if defined(PJMEDIA_VIDEO_DEV_HAS_IOS) && PJMEDIA_VIDEO_DEV_HAS_IOS != 0 &&\
    defined(PJMEDIA_HAS_VIDEO) && (PJMEDIA_HAS_VIDEO != 0)

#import <Availability.h>
#ifdef __IPHONE_4_0

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#include <libyuv.h>

#define ORIENTATION 0
#define SWITCH_ON_MAIN_THREAD 1
#define OPTIMIZED_CAP 0

/*#ifdef __IPHONE_5_0 || __IPHONE_6_0
#define GLES_RENDERER 1
#import <GLKit/GLKit.h>
#else*/
#define UI_RENDERER 1
//#endif

#if 0
#   define TRACE_(x)    PJ_LOG(1,x)
#else
#   define TRACE_(x)
#endif
#define THIS_FILE		"ios_dev.m"
#define DEFAULT_CLOCK_RATE	90000
//#define DEFAULT_WIDTH		480
//#define DEFAULT_HEIGHT	360
#define DEFAULT_WIDTH		352
#define DEFAULT_HEIGHT		288
//#define DEFAULT_WIDTH		640
//#define DEFAULT_HEIGHT		480
#define DEFAULT_FPS		15

#ifdef GLES_RENDERER
// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_UV,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];
#endif

#if ORIENTATION
typedef struct ios_orient
{
  pjmedia_orient pjmedia_orientation;
  AVCaptureVideoOrientation av_orientation;
  UIImageOrientation ui_orientation;
} ios_orient;

static ios_orient ios_orients[] =
{
  {PJMEDIA_ORIENT_NATURAL, AVCaptureVideoOrientationPortrait,
    UIImageOrientationUp},
  {PJMEDIA_ORIENT_ROTATE_180DEG, AVCaptureVideoOrientationPortraitUpsideDown,
    UIImageOrientationDown},
  {PJMEDIA_ORIENT_ROTATE_90DEG,  AVCaptureVideoOrientationLandscapeRight,
    UIImageOrientationRight},
  {PJMEDIA_ORIENT_ROTATE_270DEG, AVCaptureVideoOrientationLandscapeLeft,
    UIImageOrientationLeft},
} ;
#endif /* ORIENTATION */


typedef struct ios_fmt_info
{
    pjmedia_format_id   pjmedia_format;
    UInt32		ios_format;
} ios_fmt_info;

static ios_fmt_info ios_fmts[] =
{
    {PJMEDIA_FORMAT_I420 , kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
//	{PJMEDIA_FORMAT_NV12, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
//	{PJMEDIA_FORMAT_I420, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange},
// Unsupported
//    {PJMEDIA_FORMAT_YUY2, kCVPixelFormatType_422YpCbCr8_yuvs},
//    {PJMEDIA_FORMAT_UYVY, kCVPixelFormatType_422YpCbCr8},
};
static ios_fmt_info ios_rend_fmts[] =
{
    //    { , kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange},
    //    { , kCVPixelFormatType_420YpCbCr8BiPlanarFullRange},
    {PJMEDIA_FORMAT_BGRA, kCVPixelFormatType_32BGRA},
    // Unsupported
    // {PJMEDIA_FORMAT_YUY2, kCVPixelFormatType_422YpCbCr8_yuvs},
    // {PJMEDIA_FORMAT_UYVY, kCVPixelFormatType_422YpCbCr8},
};

/* ios device info */
struct ios_dev_info
{
    pjmedia_vid_dev_info	 info;
    char			         dev_id[192];
};

/* ios factory */
struct ios_factory
{
    pjmedia_vid_dev_factory	 base;
    pj_pool_t			*pool;
    pj_pool_t			*dev_pool;
    pj_pool_factory		*pf;

    unsigned			 dev_count;
    struct ios_dev_info		*dev_info;
};

struct ios_stream;
typedef pj_status_t (*func_ptr)(struct ios_stream *strm);


@interface VOutDelegate: NSObject
			 <AVCaptureVideoDataOutputSampleBufferDelegate>
{
@public
    struct ios_stream *strm;
    func_ptr           func;
    pj_status_t        status;
}

- (void)run_func;
@end

/* Video stream. */
struct ios_stream
{
    pjmedia_vid_dev_stream  base;	    /**< Base stream       */
    pjmedia_vid_dev_param   param;	    /**< Settings	       */
    pj_pool_t		   *pool;           /**< Memory pool       */

    pj_timestamp	    cap_frame_ts;   /**< Captured frame tstamp */
    unsigned		    cap_ts_inc;	    /**< Increment	       */

    pjmedia_vid_dev_cb	    vid_cb;		/**< Stream callback   */
    void		   *user_data;          /**< Application data  */

    pj_bool_t		    cap_thread_initialized;
    pj_thread_desc	    cap_thread_desc;
    pj_thread_t		   *cap_thread;

    struct ios_factory     *qf;

    pj_bool_t               is_running;
    pj_bool_t               cap_exited;

#if SWITCH_ON_MAIN_THREAD
    void *data; // Switch
#endif /* SWITCH_ON_MAIN_THREAD */

    AVCaptureVideoPreviewLayer  *preview_layer;

    AVCaptureVideoDataOutput	*video_output;
    VOutDelegate		*vout_delegate;
  
    void		    *buf;
    
#if UI_RENDERER
    UIImageView		*imgView;
    unsigned         frame_size;
    pjmedia_rect_size       size;
    pj_uint8_t              bpp;
    unsigned                bytes_per_row;
    
    dispatch_queue_t     render_queue;
#endif
#if GLES_RENDERER
    EAGLContext *glContext;
    GLKView     *glView;
    GLuint 		 glProgram;

    CVOpenGLESTextureCacheRef videoTextureCache;
    CVOpenGLESTextureRef      videoTextureRef;
    //CVOpenGLESTextureRef    lumaTexture;
    //CVOpenGLESTextureRef    chromaTexture;
#endif
};


/* Prototypes */
static pj_status_t ios_factory_init(pjmedia_vid_dev_factory *f);
static pj_status_t ios_factory_destroy(pjmedia_vid_dev_factory *f);
static pj_status_t ios_factory_refresh(pjmedia_vid_dev_factory *f);
static unsigned    ios_factory_get_dev_count(pjmedia_vid_dev_factory *f);
static pj_status_t ios_factory_get_dev_info(pjmedia_vid_dev_factory *f,
					   unsigned index,
					   pjmedia_vid_dev_info *info);
static pj_status_t ios_factory_default_param(pj_pool_t *pool,
					    pjmedia_vid_dev_factory *f,
					    unsigned index,
					    pjmedia_vid_dev_param *param);
static pj_status_t ios_factory_create_stream(
					pjmedia_vid_dev_factory *f,
					pjmedia_vid_dev_param *param,
					const pjmedia_vid_dev_cb *cb,
					void *user_data,
					pjmedia_vid_dev_stream **p_vid_strm);

static pj_status_t ios_stream_get_param(pjmedia_vid_dev_stream *strm,
				       pjmedia_vid_dev_param *param);
static pj_status_t ios_stream_get_cap(pjmedia_vid_dev_stream *strm,
				     pjmedia_vid_dev_cap cap,
				     void *value);
static pj_status_t ios_stream_set_cap(pjmedia_vid_dev_stream *strm,
				     pjmedia_vid_dev_cap cap,
				     const void *value);
static pj_status_t ios_stream_start(pjmedia_vid_dev_stream *strm);
static pj_status_t ios_stream_put_frame(pjmedia_vid_dev_stream *strm,
					const pjmedia_frame *frame);
static pj_status_t ios_stream_stop(pjmedia_vid_dev_stream *strm);
static pj_status_t ios_stream_destroy(pjmedia_vid_dev_stream *strm);

/* Operations */
static pjmedia_vid_dev_factory_op factory_op =
{
    &ios_factory_init,
    &ios_factory_destroy,
    &ios_factory_get_dev_count,
    &ios_factory_get_dev_info,
    &ios_factory_default_param,
    &ios_factory_create_stream,
    &ios_factory_refresh
};

static pjmedia_vid_dev_stream_op stream_op =
{
    &ios_stream_get_param,
    &ios_stream_get_cap,
    &ios_stream_set_cap,
    &ios_stream_start,
    NULL,
    &ios_stream_put_frame,
    &ios_stream_stop,
    &ios_stream_destroy
};


/****************************************************************************
 * Factory operations
 */
/*
 * Init ios_ video driver.
 */
extern "C" pjmedia_vid_dev_factory* pjmedia_ios_factory(pj_pool_factory *pf)
{
    struct ios_factory *f;
    pj_pool_t *pool;

    pool = pj_pool_create(pf, "ios video", 512, 512, NULL);
    f = PJ_POOL_ZALLOC_T(pool, struct ios_factory);
    f->pf = pf;
    f->pool = pool;
    f->base.op = &factory_op;

    return &f->base;
}


/* API: init factory */
static pj_status_t ios_factory_init(pjmedia_vid_dev_factory *f)
{
    return ios_factory_refresh(f);
}

/* API: destroy factory */
static pj_status_t ios_factory_destroy(pjmedia_vid_dev_factory *f)
{
    struct ios_factory *qf = (struct ios_factory*)f;
    pj_pool_t *pool = qf->pool;

    if (qf->dev_pool)
        pj_pool_release(qf->dev_pool);
    qf->pool = NULL;
    if (pool)
        pj_pool_release(pool);

    return PJ_SUCCESS;
}

/* API: refresh the list of devices */
static pj_status_t ios_factory_refresh(pjmedia_vid_dev_factory *f)
{
    struct ios_factory *qf = (struct ios_factory*)f;
    struct ios_dev_info *qdi;
    pjmedia_format *fmt;
    unsigned i, dev_count = 0;
    NSAutoreleasePool *apool = [[NSAutoreleasePool alloc]init];
    NSArray *dev_array = nil;

    if (qf->dev_pool) {
        pj_pool_release(qf->dev_pool);
        qf->dev_pool = NULL;
    }

    dev_array = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    dev_count = [dev_array count];

#if UI_RENDERER
    /* Add renderer device */
    dev_count += 1;
#endif
#if GLES_RENDERER
    /* Add renderer device */
    dev_count += 1;
#endif
    /* Initialize input and output devices here */
    qf->dev_count = 0;
    qf->dev_pool = pj_pool_create(qf->pf, "ios video", 500, 500, NULL);
    
    qf->dev_info = (struct ios_dev_info*)
    pj_pool_calloc(qf->dev_pool, dev_count,
                   sizeof(struct ios_dev_info));
    
#if UI_RENDERER
    qdi = &qf->dev_info[qf->dev_count++];
    pj_bzero(qdi, sizeof(*qdi));
    strcpy(qdi->info.name, "iOS UIView");
    strcpy(qdi->info.driver, "iOS");
    qdi->info.dir = PJMEDIA_DIR_RENDER;
    qdi->info.has_callback = PJ_FALSE;
    qdi->info.caps = PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW | PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION |
        PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE | PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE |
        PJMEDIA_VID_DEV_CAP_FORMAT;
    fmt = &qdi->info.fmt[qdi->info.fmt_cnt++];
    pjmedia_format_init_video(fmt,
                              ios_rend_fmts[0].pjmedia_format,
                              DEFAULT_WIDTH,
                              DEFAULT_HEIGHT,
                              DEFAULT_FPS, 1);
#endif
#if GLES_RENDERER
    qdi = &qf->dev_info[qf->dev_count++];
    pj_bzero(qdi, sizeof(*qdi));
    strcpy(qdi->info.name, "iOS GLView");
    strcpy(qdi->info.driver, "iOS GL");
    qdi->info.dir = PJMEDIA_DIR_RENDER;
    qdi->info.has_callback = PJ_FALSE;
    qdi->info.caps = PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW | PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION |
    		PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE | PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE |
    		PJMEDIA_VID_DEV_CAP_FORMAT;
    fmt = &qdi->info.fmt[qdi->info.fmt_cnt++];
    pjmedia_format_init_video(fmt,
//                              ios_rend_fmts[1].pjmedia_format,
    						  ios_rend_fmts[0].pjmedia_format,
                              DEFAULT_WIDTH,
                              DEFAULT_HEIGHT,
                              DEFAULT_FPS, 1);
#endif
    
    for (i = 0; i < [dev_array count]; i++) {
        unsigned l;
        AVCaptureDevice *dev = [dev_array objectAtIndex:i];
        qdi = &qf->dev_info[qf->dev_count++];
        pj_bzero(qdi, sizeof(*qdi));
        [[dev localizedName] getCString:qdi->info.name
                                 maxLength:sizeof(qdi->info.name)
                                 encoding:
                                 [NSString defaultCStringEncoding]];
        [[dev uniqueID] getCString:qdi->dev_id
                            maxLength:sizeof(qdi->dev_id)
                             encoding:[NSString defaultCStringEncoding]];
        strcpy(qdi->info.driver, "iOS");
        qdi->info.dir = PJMEDIA_DIR_CAPTURE;
        qdi->info.has_callback = PJ_TRUE;
        qdi->info.fmt_cnt = 0;
        qdi->info.caps = PJMEDIA_VID_DEV_CAP_INPUT_PREVIEW |
            PJMEDIA_VID_DEV_CAP_SWITCH |
            PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW |
            PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW_FLAGS;
      qdi->info.caps |= PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE | PJMEDIA_VID_DEV_CAP_FORMAT;

#if ORIENTATION
      qdi->info.caps |= PJMEDIA_VID_DEV_CAP_ORIENTATION;
#endif /* ORIENTATION */
#if OPTIMIZED_CAP
        qdi->info.caps |= PJMEDIA_VID_DEV_CAP_FORMAT;
#endif /* OPTIMIZED_CAP */
        for (l = 0; l < PJ_ARRAY_SIZE(ios_fmts); l++) {
            fmt = &qdi->info.fmt[qdi->info.fmt_cnt++];
            pjmedia_format_init_video(fmt,
                                      ios_fmts[l].pjmedia_format,
                                      DEFAULT_WIDTH,
                                      DEFAULT_HEIGHT,
                                      DEFAULT_FPS, 1);	
        }
        PJ_LOG(4, (THIS_FILE, " dev_id %d: %s", i, qdi->info.name)); 
    }
                     
/*    for (i = 0; i < qf->dev_count; i++) {
       unsigned l;
	   qdi = &qf->dev_info[i];
        qdi->info.caps |= PJMEDIA_VID_DEV_CAP_FORMAT;

       for (l = 0; l < PJ_ARRAY_SIZE(ios_fmts); l++) {
	       pjmedia_format *fmt = &qdi->info.fmt[qdi->info.fmt_cnt++];
	       pjmedia_format_init_video(fmt,
				      ios_fmts[l].pjmedia_format,
				      DEFAULT_WIDTH,
				      DEFAULT_HEIGHT,
				      DEFAULT_FPS, 1);	
	   }
       PJ_LOG(4, (THIS_FILE, " dev_id %d: %s", i, qdi->info.name)); 
    }*/
    
    [apool release];
    
    PJ_LOG(4, (THIS_FILE, "iOS video has %d devices",
	       qf->dev_count));
    
    return PJ_SUCCESS;
}

/* API: get number of devices */
static unsigned ios_factory_get_dev_count(pjmedia_vid_dev_factory *f)
{
    struct ios_factory *qf = (struct ios_factory*)f;
    return qf->dev_count;
}

/* API: get device info */
static pj_status_t ios_factory_get_dev_info(pjmedia_vid_dev_factory *f,
					    unsigned index,
					    pjmedia_vid_dev_info *info)
{
    struct ios_factory *qf = (struct ios_factory*)f;

    PJ_ASSERT_RETURN(index < qf->dev_count, PJMEDIA_EVID_INVDEV);

    pj_memcpy(info, &qf->dev_info[index].info, sizeof(*info));

    return PJ_SUCCESS;
}

/* API: create default device parameter */
static pj_status_t ios_factory_default_param(pj_pool_t *pool,
					     pjmedia_vid_dev_factory *f,
					     unsigned index,
					     pjmedia_vid_dev_param *param)
{
    struct ios_factory *qf = (struct ios_factory*)f;
    struct ios_dev_info *di = &qf->dev_info[index];

    PJ_ASSERT_RETURN(index < qf->dev_count, PJMEDIA_EVID_INVDEV);

    PJ_UNUSED_ARG(pool);

    pj_bzero(param, sizeof(*param));
    if (di->info.dir & PJMEDIA_DIR_CAPTURE) {
      param->dir = PJMEDIA_DIR_CAPTURE;
      param->cap_id = index;
      param->rend_id = PJMEDIA_VID_INVALID_DEV;
#if ORIENTATION
      //param->orient = PJMEDIA_ORIENT_NATURAL;
      //param->orient = PJMEDIA_ORIENT_ROTATE_180DEG;
      param->orient = PJMEDIA_ORIENT_ROTATE_90DEG;
#endif /* ORIENTATION */
#if UI_RENDERER || GLES_RENDERER
    } else if (di->info.dir & PJMEDIA_DIR_RENDER) {
	param->dir = PJMEDIA_DIR_RENDER;
	param->rend_id = index;
	param->cap_id = PJMEDIA_VID_INVALID_DEV;
#endif
    } else {
	return PJMEDIA_EVID_INVDEV;
    }
    
    param->flags = PJMEDIA_VID_DEV_CAP_FORMAT;
    param->fmt.type = PJMEDIA_TYPE_VIDEO;
    param->clock_rate = DEFAULT_CLOCK_RATE;
    pj_memcpy(&param->fmt, &di->info.fmt[0], sizeof(param->fmt));

    return PJ_SUCCESS;
}

static ios_fmt_info* get_ios_format_info(pj_uint32_t /*pjmedia_format_id*/ id)
{
    unsigned i;
    
    for (i = 0; i < PJ_ARRAY_SIZE(ios_fmts); i++) {
        if (ios_fmts[i].pjmedia_format == (pjmedia_format_id)id)
            return &ios_fmts[i];
    }
    for (i = 0; i < PJ_ARRAY_SIZE(ios_rend_fmts); i++) {
        if (ios_rend_fmts[i].pjmedia_format == (pjmedia_format_id)id)
            return &ios_rend_fmts[i];
    }
    
    return NULL;
}

#if 1
void * operator new(size_t n)
{
  void * const p = malloc(n);
  // handle p == 0
  return p;
}

void operator delete(void * p) // or delete(void *, std::size_t)
{
  free(p);
}

void * operator new[](size_t n)
{
  void * const p = malloc(n);
  // handle p == 0
  return p;
}

void  operator delete[](void* p)
{
	free(p);
}

#endif

@implementation VOutDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput 
		      didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
		      fromConnection:(AVCaptureConnection *)connection
{
    pjmedia_frame frame;
    CVImageBufferRef imageBuffer;

    if (!strm->is_running) {
        strm->cap_exited = PJ_TRUE;
        return;
    }

    //PJ_LOG(1,(THIS_FILE, "Capture thread will start..."));
    if (strm->cap_thread_initialized == 0 || !pj_thread_is_registered())
    {
        pj_bzero(strm->cap_thread_desc, sizeof(pj_thread_desc));
        //PJ_LOG(1,(THIS_FILE, "Capture thread starting..."));
        pj_thread_register("ios_cap", strm->cap_thread_desc,
			   &strm->cap_thread);
        strm->cap_thread_initialized = 1;
        PJ_LOG(5,(THIS_FILE, "Capture thread started"));
    }

    if (!sampleBuffer)
        return;
    /* Get a CMSampleBuffer's Core Video image buffer for the media data */
    imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    /* Lock the base address of the pixel buffer */
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly); 
    
    frame.type = PJMEDIA_FRAME_TYPE_VIDEO;
    frame.bit_info = 0;
    frame.timestamp.u64 = strm->cap_frame_ts.u64;

    size_t ysize = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0) *
    		CVPixelBufferGetHeightOfPlane(imageBuffer,0);
    pj_uint8_t *u = (pj_uint8_t *)strm->buf + ysize;
    pj_uint8_t *v = u + ysize/4; //uv_width * uv_height;
    pj_int32_t width = CVPixelBufferGetWidthOfPlane(imageBuffer,0);
    pj_int32_t height = CVPixelBufferGetHeightOfPlane(imageBuffer,0);

    libyuv::NV12ToI420Rotate((pj_uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,0),
    		CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0),
    		(pj_uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,1),
    		CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,1),
    		(pj_uint8_t *)strm->buf, height,
    		u, height/2,
    		v, height/2,
    		width, height,
    		libyuv::kRotate90);

    frame.buf = strm->buf;
    frame.size = ysize + ysize/2;
  
    if (strm->vid_cb.capture_cb)
        (*strm->vid_cb.capture_cb)(&strm->base, strm->user_data, &frame);

    strm->cap_frame_ts.u64 += strm->cap_ts_inc;
    
    /* Unlock the pixel buffer */
    CVPixelBufferUnlockBaseAddress(imageBuffer,kCVPixelBufferLock_ReadOnly);
}

#if UI_RENDERER
- (void)update_image
{
    // TODO using OpenGL
    //
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    /* Create a device-dependent RGB color space */
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB(); 
    
    /* Create a bitmap graphics context with the sample buffer data */
  //NSLog(@"update_image %dx%d", strm->size.w, strm->size.h);
    CGContextRef context =
	CGBitmapContextCreate(strm->buf, strm->size.w, strm->size.h, 8,
			      strm->bytes_per_row, colorSpace,
			      kCGBitmapByteOrder32Little |
			      kCGImageAlphaPremultipliedFirst);
    
    /**
     * Create a Quartz image from the pixel data in the bitmap graphics
     * context
     */
    CGImageRef quartzImage = CGBitmapContextCreateImage(context); 
    
    /* Free up the context and color space */
    CGContextRelease(context); 
    CGColorSpaceRelease(colorSpace);

    /* Create an image object from the Quartz image */
    // TODO check orientation strm->param.orient and use transform of UIView
    UIImage *image = [UIImage imageWithCGImage:quartzImage scale:1.0
			      orientation:UIImageOrientationUp];
    
    /* Release the Quartz image */
    CGImageRelease(quartzImage);
#if 1
    dispatch_async(dispatch_get_main_queue(),
                   ^{[strm->imgView setImage:image];});
#else
    [strm->imgView performSelectorOnMainThread:@selector(setImage:)
		     withObject:image waitUntilDone:NO];
#endif
    [pool release];
}
#endif

- (void)run_func
{
	status = (*func)(strm);
}


@end

static void run_func_on_main_thread(struct ios_stream *strm, func_ptr func,
		pj_status_t *retval)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    VOutDelegate *delg = [[VOutDelegate alloc] init];

    delg->strm = strm;
    delg->func = func;
    //delg->status = PJ_SUCCESS;
    [delg performSelectorOnMainThread:@selector(run_func)
                           withObject:nil waitUntilDone:YES];
    
    // FIXME useful ?
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);

    *retval = delg->status;

    [delg release];
    [pool release];
}

static pj_status_t init_ios_cap(struct ios_stream *strm)
{
    const pjmedia_video_format_detail *vfd;
    ios_fmt_info *qfi = get_ios_format_info(strm->param.fmt.id);
    NSError *error = nil;
    
    if (!qfi) {
        return PJMEDIA_EVID_BADFORMAT;
    }

    /* Create capture stream here */
	AVCaptureSession *cap_session = [[AVCaptureSession alloc] init];
	if (!cap_session) {
	    return PJ_ENOMEM;
	}
  
  // TODO select the nearest best resolution
#if defined(DEFAULT_WIDTH) && DEFAULT_WIDTH==352
  [cap_session setSessionPreset: AVCaptureSessionPreset352x288];
  strm->param.fmt.det.vid.size.w = DEFAULT_HEIGHT;
  strm->param.fmt.det.vid.size.h = DEFAULT_WIDTH;
#elif defined(DEFAULT_WIDTH) && DEFAULT_WIDTH==640
  [cap_session setSessionPreset: AVCaptureSessionPreset640x480];
  strm->param.fmt.det.vid.size.w = DEFAULT_HEIGHT;
  strm->param.fmt.det.vid.size.h = DEFAULT_WIDTH;
#else
  [cap_session setSessionPreset: AVCaptureSessionPresetMedium];
  // TODO switch the size
#endif
	
	/* Open video device */
	AVCaptureDevice *videoDevice =
        [AVCaptureDevice deviceWithUniqueID:
                        [NSString stringWithCString:
                                  strm->qf->dev_info[strm->param.cap_id].dev_id
                                  encoding:
                                  [NSString defaultCStringEncoding]]];
    
	if (!videoDevice) {
    [cap_session release];
    return PJMEDIA_EVID_SYSERR;
	}
	
	/* Add the video device to the session as a device input */
  AVCaptureDeviceInput *dev_input = [AVCaptureDeviceInput
                                     deviceInputWithDevice:videoDevice
                                     error: &error];
	if (error || !dev_input ||
	    ![cap_session canAddInput:dev_input]) {
    if (error)
      PJ_LOG(1, (THIS_FILE,"Failed to init capture device (%d); %@",
                 [error code], [error localizedDescription]));
    [cap_session release];
		return PJMEDIA_EVID_SYSERR;
	}
  [cap_session addInput:dev_input];
	
	strm->video_output = [[AVCaptureVideoDataOutput alloc] init];
	if (!strm->video_output ||
	    ![cap_session canAddOutput:strm->video_output]) {
    [cap_session release];
		return PJMEDIA_EVID_SYSERR;
	}

	[cap_session addOutput:strm->video_output];
	
	[strm->video_output setAlwaysDiscardsLateVideoFrames:YES];
    
	vfd = pjmedia_format_get_video_format_detail(&strm->param.fmt,
                                               PJ_TRUE);
    
	[strm->video_output setVideoSettings:
     [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithInt:qfi->ios_format],
      kCVPixelBufferPixelFormatTypeKey,
#if 0 // Not supported :-(
      [NSNumber numberWithInt: vfd->size.w],
      kCVPixelBufferWidthKey,
      [NSNumber numberWithInt: vfd->size.h],
      kCVPixelBufferHeightKey,
#endif
      nil]];
    
	pj_assert(vfd->fps.num);
    strm->cap_ts_inc = PJMEDIA_SPF2(strm->param.clock_rate, &vfd->fps, 1);

#if defined(__IPHONE_5_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_5_0
    AVCaptureConnection *connectionVO = [strm->video_output connectionWithMediaType:AVMediaTypeVideo];
    connectionVO.videoMinFrameDuration = CMTimeMake(vfd->fps.denum, vfd->fps.num);
    //connectionVO.videoOrientation = AVCaptureVideoOrientationPortrait;
#elif defined(__IPHONE_4_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
	strm->video_output.minFrameDuration = CMTimeMake(vfd->fps.denum,
                                                   vfd->fps.num);
#endif

	strm->vout_delegate = [[VOutDelegate alloc]init];
	strm->vout_delegate->strm = strm;

#if 0
	dispatch_queue_t queue = dispatch_queue_create("iosQueue", DISPATCH_QUEUE_SERIAL);
	[strm->video_output setSampleBufferDelegate:strm->vout_delegate
                                          queue:queue];
	dispatch_release(queue);
#endif

  strm->preview_layer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:cap_session];
#if defined(__IPHONE_6_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_6_0
  AVCaptureConnection *connectionPL = [strm->preview_layer connection];
  [connectionPL setAutomaticallyAdjustsVideoMirroring: YES];
#else
  [strm->preview_layer setAutomaticallyAdjustsMirroring: YES];
#endif
  [strm->preview_layer setVideoGravity:AVLayerVideoGravityResizeAspectFill];

  /* Init buffer to rotate the acquired frame */
  // FIXME init in captureOuput: callback ?
  pj_memcpy(&strm->size, &vfd->size, sizeof(vfd->size));
  strm->bytes_per_row = strm->size.w * strm->bpp / 8;
  strm->frame_size = strm->bytes_per_row * strm->size.h;
  strm->buf = pj_pool_zalloc(strm->pool, strm->frame_size);
  
  /* Apply the remaining settings */
  if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION) {
    ios_stream_set_cap(&strm->base,
                       PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION,
                       &strm->param.window_pos);
  }
  if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE) {
    ios_stream_set_cap(&strm->base,
                       PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE,
                       &strm->param.window_hide);
  }
  
  [cap_session release];
  
	return PJ_SUCCESS;
}

#if UI_RENDERER
static pj_status_t init_ios_ren(struct ios_stream *strm)
{
    const pjmedia_video_format_detail *vfd;
    ios_fmt_info *qfi = get_ios_format_info(strm->param.fmt.id);
    
    if (!qfi) {
        return PJMEDIA_EVID_BADFORMAT;
    }
    
    vfd = pjmedia_format_get_video_format_detail(&strm->param.fmt, PJ_TRUE);
    pj_memcpy(&strm->size, &vfd->size, sizeof(vfd->size));
    //strm->bpp = vfi->bpp;
    strm->bytes_per_row = strm->size.w * strm->bpp / 8;
    strm->frame_size = strm->bytes_per_row * strm->size.h;
    
    /* Get the main window */
	UIWindow *window = [[UIApplication sharedApplication] keyWindow];
	
	if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW &&
        strm->param.window.info.ios.window)
	    window = (UIWindow *)strm->param.window.info.ios.window;
	
	pj_assert(window);
	strm->imgView = [[UIImageView alloc] initWithFrame:[window bounds]];
	if (!strm->imgView) {
	    return PJ_ENOMEM;
	}
  [strm->imgView  setContentMode:UIViewContentModeScaleAspectFit|UIViewContentModeTop];
  //[strm->imgView  setContentMode:UIViewContentModeCenter];

//  strm->imgView.transform = CGAffineTransformMakeRotation(-M_PI_2);
	
	if (!strm->vout_delegate) {
	    strm->vout_delegate = [[VOutDelegate alloc]init];
	    strm->vout_delegate->strm = strm;
	}
    
    strm->render_queue = dispatch_queue_create("com.pjsip.render_queue",
                                               NULL);
    if (!strm->render_queue) {
        return PJ_ENOMEM;
    }
	
	strm->buf = pj_pool_zalloc(strm->pool, strm->frame_size);
    /* Apply the remaining settings */
    if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION) {
        ios_stream_set_cap(&strm->base,
                           PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION,
                           &strm->param.window_pos);
    }
    if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE) {
        ios_stream_set_cap(&strm->base,
                           PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE,
                           &strm->param.window_hide);
    }
    return PJ_SUCCESS;
}
#elif GLES_RENDERER
static pj_status_t init_ios_ren(struct ios_stream *strm)
{
    const pjmedia_video_format_detail *vfd;
    ios_fmt_info *qfi = get_ios_format_info(strm->param.fmt.id);

    if (!qfi) {
        return PJMEDIA_EVID_BADFORMAT;
    }

    vfd = pjmedia_format_get_video_format_detail(&strm->param.fmt, PJ_TRUE);
    pj_memcpy(&strm->size, &vfd->size, sizeof(vfd->size));


    /* Get the main window */
	UIWindow *window = [[UIApplication sharedApplication] keyWindow];

	if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW &&
        strm->param.window.info.ios.window)
	    window = (UIWindow *)strm->param.window.info.ios.window;

    strm->glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!strm->glContext) {
    	//strm->gl_context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
    	PJ_LOG(1, (THIS_FILE,"Failed to create ES context"));
        return PJMEDIA_EVID_SYSERR;
    }

    strm->glView = [[GLKView alloc] initWithFrame:[window bounds]
                                          context:strm->glContext];
    if (!strm->glView) {
    	return PJ_ENOMEM;
    }
    //[window addSubview:strm->glView];

    // SetupGL
    [EAGLContext setCurrentContext:strm->glContext];

    [self loadShaders];

    glUseProgram(strm->glProgram);

    glUniform1i(uniforms[UNIFORM_Y], 0);
    glUniform1i(uniforms[UNIFORM_UV], 1);


    /* Apply the remaining settings */
    if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION) {
        ios_stream_set_cap(&strm->base,
                           PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION,
                           &strm->param.window_pos);
    }
    if (strm->param.flags & PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE) {
        ios_stream_set_cap(&strm->base,
                           PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE,
                           &strm->param.window_hide);
    }

	return PJ_SUCCESS;
}
#endif
                     
/* API: create stream */
static pj_status_t ios_factory_create_stream(
					pjmedia_vid_dev_factory *f,
					pjmedia_vid_dev_param *param,
					const pjmedia_vid_dev_cb *cb,
					void *user_data,
					pjmedia_vid_dev_stream **p_vid_strm)
{
    struct ios_factory *qf = (struct ios_factory*)f;
    pj_pool_t *pool;
    struct ios_stream *strm;
    const pjmedia_video_format_info *vfi;
    pj_status_t status = PJ_SUCCESS;

    PJ_ASSERT_RETURN(f && param && p_vid_strm, PJ_EINVAL);
    PJ_ASSERT_RETURN(param->fmt.type == PJMEDIA_TYPE_VIDEO &&
		     param->fmt.detail_type == PJMEDIA_FORMAT_DETAIL_VIDEO &&
                     (param->dir == PJMEDIA_DIR_CAPTURE ||
                     param->dir == PJMEDIA_DIR_RENDER),
		     PJ_EINVAL);
    TRACE_((THIS_FILE, "ios_factory_create_stream"));
    vfi = pjmedia_get_video_format_info(NULL, param->fmt.id);
    if (!vfi)
        return PJMEDIA_EVID_BADFORMAT;

    /* Create and Initialize stream descriptor */
    pool = pj_pool_create(qf->pf, "ios-dev", 4000, 4000, NULL);
    PJ_ASSERT_RETURN(pool != NULL, PJ_ENOMEM);

    strm = PJ_POOL_ZALLOC_T(pool, struct ios_stream);
    pj_memcpy(&strm->param, param, sizeof(*param));
    strm->pool = pool;
    strm->qf = qf;
    pj_memcpy(&strm->vid_cb, cb, sizeof(*cb));
    strm->user_data = user_data;


    /* Create capture stream here */
    if (param->dir & PJMEDIA_DIR_CAPTURE) {
        strm->bpp = vfi->bpp;
        run_func_on_main_thread(strm, init_ios_cap, &status);
        if (status != PJ_SUCCESS)
            goto on_error;
      
        pj_memcpy(param, &strm->param, sizeof(*param));
#if UI_RENDERER || GLES_RENDERER
    } else if (param->dir & PJMEDIA_DIR_RENDER) {
        /* Create renderer stream here */
        /* Get the main window */
      //NSLog(@"ios_factory_create_stream %dx%d",
      //      strm->param.fmt.det.vid.size.w, strm->param.fmt.det.vid.size.h);
      int w = strm->param.fmt.det.vid.size.w;
      strm->param.fmt.det.vid.size.w = strm->param.fmt.det.vid.size.h;
      strm->param.fmt.det.vid.size.h = w;
        strm->bpp = vfi->bpp;
        run_func_on_main_thread(strm, init_ios_ren, &status);
        if (status != PJ_SUCCESS)
            goto on_error;
      pj_memcpy(param, &strm->param, sizeof(*param));
#endif
    }

    /* Apply the remaining settings */
    /*    
     if (param->flags & PJMEDIA_VID_DEV_CAP_INPUT_SCALE) {
	ios_stream_set_cap(&strm->base,
			  PJMEDIA_VID_DEV_CAP_INPUT_SCALE,
			  &param->fmt);
     }
     */
    /* Done */
    strm->base.op = &stream_op;
    *p_vid_strm = &strm->base;
    
    return PJ_SUCCESS;
    
on_error:
    ios_stream_destroy((pjmedia_vid_dev_stream *)strm);
    
    return status;
}

/* API: Get stream info. */
static pj_status_t ios_stream_get_param(pjmedia_vid_dev_stream *s,
				        pjmedia_vid_dev_param *pi)
{
    struct ios_stream *strm = (struct ios_stream*)s;

    PJ_ASSERT_RETURN(strm && pi, PJ_EINVAL);

    pj_memcpy(pi, &strm->param, sizeof(*pi));

/*    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_INPUT_SCALE,
                            &pi->fmt.info_size) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_INPUT_SCALE;
    }
*/

    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW,
                           &pi->window) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW;
    }
    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION,
                           &pi->window_pos) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION;
    }
    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE,
                           &pi->disp_size) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE;
    }
    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE,
                           &pi->window_hide) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE;
    }
    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW_FLAGS,
                           &pi->window_flags) == PJ_SUCCESS)
    {
        pi->flags |= PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW_FLAGS;
    }
#if ORIENTATION
    if (ios_stream_get_cap(s, PJMEDIA_VID_DEV_CAP_ORIENTATION,
                         &pi->window_hide) == PJ_SUCCESS)
    {
      pi->flags |= PJMEDIA_VID_DEV_CAP_ORIENTATION;
    }
#endif /* ORIENTATION */

    return PJ_SUCCESS;
}

/* API: get capability */
static pj_status_t ios_stream_get_cap(pjmedia_vid_dev_stream *s,
				      pjmedia_vid_dev_cap cap,
				      void *pval)
{
    struct ios_stream *strm = (struct ios_stream*)s;

    PJ_UNUSED_ARG(strm);

    PJ_ASSERT_RETURN(s && pval, PJ_EINVAL);

    if (cap==PJMEDIA_VID_DEV_CAP_INPUT_SCALE)
    {
        return PJMEDIA_EVID_INVCAP;
    } else if (cap == PJMEDIA_VID_DEV_CAP_INPUT_PREVIEW) {
        *((pj_bool_t *)pval) = PJ_TRUE;
        return PJ_SUCCESS;
#if ORIENTATION
    } else if (cap == PJMEDIA_VID_DEV_CAP_ORIENTATION) {
      int i;
      AVCaptureVideoOrientation videoOrientation;
    	pjmedia_orient *orient = (pjmedia_orient *)pval;
      //*orient = PJMEDIA_ORIENT_UNKNOWN;
      *orient = PJMEDIA_ORIENT_ROTATE_90DEG;
      // TODO Manage renderer and capture
      // videoOrientation = AVCaptureConnection videoOrientation
      /*for (i = 0; i < PJ_ARRAY_SIZE(ios_orients); ++i)
        if (ios_orients[i].av_orientation == videoOrientation)
          *orient = ios_orients[i].pjmedia_orient;*/
      return PJ_SUCCESS;
#endif /* ORIENTATION */
#if UI_RENDERER
    } else if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW) {
        pjmedia_vid_dev_hwnd *wnd = (pjmedia_vid_dev_hwnd *)pval;
        wnd->info.ios.window = nil;
        if (strm->imgView)
        {
            wnd->info.ios.window = strm->imgView;
            return PJ_SUCCESS;
        }
        /*else*/ if (strm->preview_layer) {
        	wnd->info.ios.window = strm->preview_layer;
        	return PJ_SUCCESS;
        }
    }  else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW_FLAGS) {
      if (strm->preview_layer) {
        unsigned *wnd_flags = (unsigned *)pval;
        //if ([strm->preview_layer borderWidth] != 0)
          *wnd_flags |= PJMEDIA_VID_DEV_WND_BORDER;
        //if (flag & SDL_WINDOW_RESIZABLE)
          *wnd_flags &= ~PJMEDIA_VID_DEV_WND_RESIZABLE;
        return PJ_SUCCESS;
      }
    }  else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE) {
        pjmedia_rect_size *size = (pjmedia_rect_size *)pval;
        if (strm->imgView) {
          CGRect frame = [strm->imgView frame];
          size->w = frame.size.width;
          size->h = frame.size.height;
          return PJ_SUCCESS;
        }
        else if (strm->preview_layer) {
          CGRect frame = [strm->preview_layer frame];
          size->w = frame.size.width;
          size->h = frame.size.height;
          return PJ_SUCCESS;
        }
    } else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION) {
        pjmedia_coord *pos = (pjmedia_coord *)pval;
        if (strm->imgView) {
          CGRect frame = [strm->imgView frame];
          pos->x = frame.origin.x;
          pos->y = frame.origin.y;
          return PJ_SUCCESS;
        }
        else if (strm->preview_layer) {
          CGRect frame = [strm->preview_layer frame];
          pos->x = frame.origin.x;
          pos->y = frame.origin.y;
          return PJ_SUCCESS;
        }
    } else if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE) {
        if (strm->imgView) {
          *((pj_bool_t *)pval) = ([strm->imgView isHidden] ? PJ_TRUE : PJ_FALSE);
          return PJ_SUCCESS;
        }
        else if (strm->preview_layer) {
          *((pj_bool_t *)pval) = ([strm->preview_layer isHidden] ? PJ_TRUE : PJ_FALSE);
          return PJ_SUCCESS;
        }
#endif /* UI_RENDERER */
    } //else {
	return PJMEDIA_EVID_INVCAP;
    //}
}

#if SWITCH_ON_MAIN_THREAD
static pj_status_t ios_cap_switch(struct ios_stream *strm)
#else /* !SWITCH_ON_MAIN_THREAD */
static pj_status_t ios_cap_switch(struct ios_stream *strm,
                                  pjmedia_vid_dev_switch_param *switch_prm)
#endif /* SWITCH_ON_MAIN_THREAD */
{
#if SWITCH_ON_MAIN_THREAD
  pjmedia_vid_dev_switch_param *switch_prm = (pjmedia_vid_dev_switch_param *)strm->data;
#endif /* SWITCH_ON_MAIN_THREAD */
  pjmedia_vid_dev_info info;
  NSError *error;
  pj_status_t status;
  
  TRACE_((THIS_FILE, "ios_cap_switch start"));
  //if (!switch_prm)
  //    return PJ_EINVAL;
  
  /* Verify the capture device */
  status = pjmedia_vid_dev_get_info(switch_prm->target_id, &info);
  if (status != PJ_SUCCESS) {
    PJ_LOG(1, (THIS_FILE,"Failed to check the capture device %d",
               switch_prm->target_id));
    return PJ_EINVAL;
  }
  
  [[strm->preview_layer session] beginConfiguration];
  
  for (AVCaptureInput *oldInput in [[strm->preview_layer session] inputs]) {
    [[strm->preview_layer session] removeInput:oldInput];
  }

  /* Open video device */
  AVCaptureDevice *videoDevice = [AVCaptureDevice deviceWithUniqueID:
                                  [NSString stringWithCString:
                                   strm->qf->dev_info[info.id].dev_id
                                                     encoding:
                                   [NSString defaultCStringEncoding]]];
  
  if (!videoDevice) {
    PJ_LOG(1, (THIS_FILE,"Failed to open capture device: %s (%s)",
               info.name, strm->qf->dev_info[info.id].dev_id));
    [[strm->preview_layer session] commitConfiguration];
    return PJMEDIA_EVID_SYSERR;
  }
  
  /* Add the video device to the session as a device input */
  AVCaptureDeviceInput *dev_input = [AVCaptureDeviceInput
                                     deviceInputWithDevice:videoDevice
                                     error: &error];
  if (error || !dev_input) {
    PJ_LOG(1, (THIS_FILE,"Failed to init capture device (%d); %@",
               [error code], [error localizedDescription]));
    [[strm->preview_layer session] commitConfiguration];
    return PJMEDIA_EVID_SYSERR;
  }
  
  if ([[strm->preview_layer session] canAddInput:dev_input])
    [[strm->preview_layer session] addInput:dev_input];
  
  [[strm->preview_layer session] commitConfiguration];
  
  TRACE_((THIS_FILE, "ios_cap_switch end"));
  
  return PJ_SUCCESS;
}

/* API: set capability */
static pj_status_t ios_stream_set_cap(pjmedia_vid_dev_stream *s,
				      pjmedia_vid_dev_cap cap,
				      const void *pval)
{
    struct ios_stream *strm = (struct ios_stream*)s;


    PJ_ASSERT_RETURN(s && pval, PJ_EINVAL);

  if (cap == PJMEDIA_VID_DEV_CAP_FORMAT)
  {
    pjmedia_format *format = (pjmedia_format *)pval;
    //pj_status_t status;
    //status = change_format(strm, (pjmedia_format *)pval);
    NSLog(@"PJMEDIA_VID_DEV_CAP_FORMAT %dx%d (%d,%d)",
          format->det.vid.size.w, format->det.vid.size.h,
          strm->imgView, strm->preview_layer);
  }
  if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE) {
    // TODO -- actually as disp_size is never used this is useless;
    pjmedia_rect_size *new_disp_size = (pjmedia_rect_size *)pval;
    NSLog(@"PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE %dx%d  (%d,%d)",
          new_disp_size->w, new_disp_size->h,
          strm->imgView, strm->preview_layer);
  }

  
  
    if (cap==PJMEDIA_VID_DEV_CAP_INPUT_SCALE)
    {
	return PJ_SUCCESS;
    }
    else if (cap == PJMEDIA_VID_DEV_CAP_INPUT_PREVIEW)
    {
        //pj_bool_t enable = *((pj_bool_t *)pval);
        return PJ_SUCCESS;
    }
    else if (cap==PJMEDIA_VID_DEV_CAP_SWITCH)
    {
    	pj_status_t status;

    	if (!pval)
    		return PJ_EINVAL;

#if SWITCH_ON_MAIN_THREAD
      strm->data = (void *)pval;
    	run_func_on_main_thread(strm, ios_cap_switch, &status);
      strm->data = NULL;
#else /* !SWITCH_ON_MAIN_THREAD */
      status = ios_cap_switch(strm, (pjmedia_vid_dev_switch_param *)pval);
#endif /* SWITCH_ON_MAIN_THREAD */

    	return status;
    }
#if ORIENTATION
    else if (cap==PJMEDIA_VID_DEV_CAP_ORIENTATION)
    {
    	pjmedia_orient *orient = (pjmedia_orient *)pval;
      /*
       * AVCaptureConnection
       * @property(nonatomic) AVCaptureVideoOrientation videoOrientation
       *
       * enum {
       AVCaptureVideoOrientationPortrait           = 1,
       AVCaptureVideoOrientationPortraitUpsideDown = 2,
       AVCaptureVideoOrientationLandscapeRight     = 3,
       AVCaptureVideoOrientationLandscapeLeft      = 4,
       };
       typedef NSInteger AVCaptureVideoOrientation;
       */
    	return PJ_SUCCESS;
    }
#endif /* ORIENTATION */
    if (strm->preview_layer)
    {
        if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE)
        {
            pjmedia_rect_size *size = (pjmedia_rect_size *)pval;
            CGRect frame = [strm->preview_layer frame];
            frame.size.width = size->w;
            frame.size.height = size->h;
            [strm->preview_layer setFrame:frame];
            return PJ_SUCCESS;
        }
        else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION)
        {
            pjmedia_coord *pos = (pjmedia_coord *)pval;
            CGRect frame = [strm->preview_layer frame];
            frame.origin.x = pos->x;
            frame.origin.y = pos->y;
            [strm->preview_layer setFrame:frame];
            return PJ_SUCCESS;
        }
        /*else if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW)
        {
        	UIView *window = (UIView *)strm->param.window.info.ios.window;
        	[window.layer addSublayer:strm->preview_layer];
          return PJ_SUCCESS;
        }*/
        else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE)
        {
          pj_bool_t hide = *(pj_bool_t *)pval;
          [strm->preview_layer setHidden:(hide ? YES : NO)];
          return PJ_SUCCESS;
        }
        else if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW_FLAGS)
        {
          unsigned *wnd_flags = (unsigned *)pval;
          if (*wnd_flags & PJMEDIA_VID_DEV_WND_BORDER)
          {
            [strm->preview_layer setCornerRadius:10.0f];
            [strm->preview_layer setBorderColor:[[UIColor whiteColor] CGColor]];
            [strm->preview_layer setBorderWidth:2.0f];
          }
          return PJ_SUCCESS;
        }
    }
#endif
#if UI_RENDERER
    if (strm->imgView)
    {
        if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_RESIZE)
        {
            pjmedia_rect_size *size = (pjmedia_rect_size *)pval;
            CGRect frame = [strm->imgView frame];
            frame.size.width = size->w;
            frame.size.height = size->h;
            [strm->imgView setFrame:frame];
            return PJ_SUCCESS;            
        }
        else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_POSITION)
        {
            pjmedia_coord *pos = (pjmedia_coord *)pval;
            CGRect frame = [strm->imgView frame];
            frame.origin.x = pos->x;
            frame.origin.y = pos->y;
            [strm->imgView setFrame:frame];
            return PJ_SUCCESS;
        }
        else if (cap==PJMEDIA_VID_DEV_CAP_OUTPUT_HIDE)
        {
            pj_bool_t hide = *(pj_bool_t *)pval;
            [strm->imgView setHidden:(hide ? YES : NO)];
            return PJ_SUCCESS;
        }
        /*else if (cap == PJMEDIA_VID_DEV_CAP_OUTPUT_WINDOW)
        {
        	UIView *window = (UIView *)strm->param.window.info.ios.window;
        	[window addSubview:strm->imgView];
        }*/
    }
#endif
    return PJMEDIA_EVID_INVCAP;
}

static pj_status_t start_ios(struct ios_stream *strm)
{
	dispatch_queue_t queue = dispatch_queue_create("iosQueue", DISPATCH_QUEUE_SERIAL);
	[strm->video_output setSampleBufferDelegate:strm->vout_delegate
                                          queue:queue];
	dispatch_release(queue);
    [[strm->preview_layer session] startRunning];
    return PJ_SUCCESS;
}

static pj_status_t stop_ios(struct ios_stream *strm)
{
    [[strm->preview_layer session] stopRunning];
	[strm->video_output setSampleBufferDelegate:nil queue:nil];
    return PJ_SUCCESS;
}

/* API: Start stream. */
static pj_status_t ios_stream_start(pjmedia_vid_dev_stream *strm)
{
    struct ios_stream *stream = (struct ios_stream*)strm;
    pj_status_t status;

TRACE_((THIS_FILE, "ios_stream_start"));
    PJ_LOG(4, (THIS_FILE, "Starting ios video stream"));

    if ([stream->preview_layer session]) {
        run_func_on_main_thread(stream, start_ios, &status);
    
	if (![[stream->preview_layer session] isRunning])
	    return PJMEDIA_EVID_NOTREADY;
        
        stream->is_running = PJ_TRUE;
    }

    return PJ_SUCCESS;
}

#if UI_RENDERER
/* API: Put frame from stream */
static pj_status_t ios_stream_put_frame(pjmedia_vid_dev_stream *strm,
					const pjmedia_frame *frame)
{
    struct ios_stream *stream = (struct ios_stream*)strm;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    pj_assert(stream->frame_size >= frame->size);
    pj_memcpy(stream->buf, frame->buf, frame->size);
    /* Perform video display in a background thread */
/*   
    [stream->vout_delegate update_image];
    [NSThread detachNewThreadSelector:@selector(update_image)
	      toTarget:stream->vout_delegate withObject:nil];
*/
    dispatch_async(stream->render_queue,
                   ^{[stream->vout_delegate update_image];});
    
    [pool release];

    return PJ_SUCCESS;
}
#endif
#if GLES_RENDERER
/* API: Put frame from stream */
static pj_status_t ios_stream_put_frame(pjmedia_vid_dev_stream *strm,
                                        const pjmedia_frame *frame)
{
    struct ios_stream *stream = (struct ios_stream*)strm;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    pj_assert(stream->frame_size >= frame->size);
    //pj_memcpy(stream->buf, frame->buf, frame->size);
    /* Perform video display in a background thread */
    /*
     [stream->vout_delegate update_image];
     [NSThread detachNewThreadSelector:@selector(update_image)
     toTarget:stream->vout_delegate withObject:nil];
     */
    dispatch_async(stream->render_queue,
                   ^{[stream->vout_delegate update_image];});
    
    [pool release];
    
    return PJ_SUCCESS;
}
#endif

/* API: Stop stream. */
static pj_status_t ios_stream_stop(pjmedia_vid_dev_stream *strm)
{
    struct ios_stream *stream = (struct ios_stream*)strm;
    pj_status_t status;

TRACE_((THIS_FILE, "ios_stream_stop"));
    PJ_LOG(4, (THIS_FILE, "Stopping ios video stream"));

    //if (stream->cap_session && [stream->cap_session isRunning]) {
  if ([[stream->preview_layer session] isRunning]) {
    int i;
TRACE_((THIS_FILE, "ios_stream_stopping"));        
    stream->cap_exited = PJ_FALSE;
    run_func_on_main_thread(stream, stop_ios, &status);
    
    stream->is_running = PJ_FALSE;
    for (i = 50; i >= 0 && !stream->cap_exited; i--) {
        pj_thread_sleep(10);
    }
  }
    
  return PJ_SUCCESS;
}

static pj_status_t destroy_ios(struct ios_stream *stream)
{
	/* Destroy capture stream */
    /*[stream->cap_session beginConfiguration];
    [stream->cap_session removeInput:stream->dev_input];
    [stream->cap_session removeOutput:stream->video_output];
    [stream->cap_session commitConfiguration];*/
    
#if GLES_RENDERER
    if (stream->texture) {
	glDeleteTextures(1, &stream->texture);
	strm->texture = 0;
    }
    [EAGLContext setCurrentContext:stream->glContext];

    glDeleteBuffers(1, &_positionVBO);
    glDeleteBuffers(1, &_texcoordVBO);
    glDeleteBuffers(1, &_indexVBO);

    if (stream->glProgram) {
        glDeleteProgram(stream->glProgram);
        stream->glProgram = 0;
    }

    if ([EAGLContext currentContext] == stream->glContext) {
        [EAGLContext setCurrentContext:nil];
        strm->glContext = NULL;
    }
#endif /* GLES_RENDERER */

  if (stream->video_output) {
    [stream->video_output release];
    stream->video_output = nil;
  }
  
  if (stream->preview_layer) {
    [stream->preview_layer removeFromSuperlayer];
    [stream->preview_layer release];
    stream->preview_layer = nil;
  }

  if (stream->vout_delegate) {
    [stream->vout_delegate release];
    stream->vout_delegate = nil;
  }

#if UI_RENDERER
  if (stream->render_queue) {
      dispatch_release(stream->render_queue);
      stream->render_queue = NULL;
  }
  if (stream->imgView) {
    [stream->imgView removeFromSuperview];
    [stream->imgView release];
    stream->imgView = nil;
  }
#endif

    return PJ_SUCCESS;
}

/* API: Destroy stream. */
static pj_status_t ios_stream_destroy(pjmedia_vid_dev_stream *strm)
{
    struct ios_stream *stream = (struct ios_stream*)strm;
    pj_pool_t *pool = stream->pool;
    pj_status_t status;

    PJ_ASSERT_RETURN(stream != NULL, PJ_EINVAL);
    TRACE_((THIS_FILE, "ios_stream_destroy"));
    ios_stream_stop(strm);

    run_func_on_main_thread(stream, destroy_ios, &status);
    if (status != PJ_SUCCESS)
    	return status;
    
    pj_bzero(stream->buf, stream->frame_size);
    pj_bzero(stream, sizeof(*stream));
    pj_pool_release(pool);

    return PJ_SUCCESS;
}

#endif	/* PJMEDIA_VIDEO_DEV_HAS_IOS */
