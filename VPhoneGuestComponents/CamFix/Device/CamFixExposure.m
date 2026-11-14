// Exposure state for the virtual camera.
//
// A real camera reports its lens aperture, exposure duration and ISO on the
// device, and stamps the same numbers into every frame's {Exif} attachment.
// The vcam device answers zero for all of them, so a client that computes
// an exposure value, EV = log2(N^2 / t) - log2(ISO / 100), gets -inf, which
// NSJSONSerialization refuses with an exception. Report the numbers a phone
// camera shows indoors, and stamp them onto delivered frames.

#import "CamFixPrivate.h"

#define CFX_APERTURE 2.2f
#define CFX_ISO 100.0f
#define CFX_EXPOSURE CMTimeMake(1, 30)
#define CFX_FRAME_DURATION CMTimeMake(1, 30)

static BOOL cfx_is_vcam_device(id dev) {
  NSString *uid = nil;
  @try { uid = [dev valueForKey:@"uniqueID"]; } @catch (NSException *e) {}
  return [uid isEqualToString:VCAM_UID];
}

static IMP cfx_orig_aperture, cfx_orig_iso, cfx_orig_exposure;
static IMP cfx_orig_min_frame, cfx_orig_max_frame;

static float cfx_aperture_hook(id self, SEL _cmd) {
  if (cfx_is_vcam_device(self)) return CFX_APERTURE;
  return ((float (*)(id, SEL))cfx_orig_aperture)(self, _cmd);
}

static float cfx_iso_hook(id self, SEL _cmd) {
  if (cfx_is_vcam_device(self)) return CFX_ISO;
  return ((float (*)(id, SEL))cfx_orig_iso)(self, _cmd);
}

static CMTime cfx_exposure_hook(id self, SEL _cmd) {
  if (cfx_is_vcam_device(self)) return CFX_EXPOSURE;
  return ((CMTime (*)(id, SEL))cfx_orig_exposure)(self, _cmd);
}

static CMTime cfx_min_frame_hook(id self, SEL _cmd) {
  CMTime real = ((CMTime (*)(id, SEL))cfx_orig_min_frame)(self, _cmd);
  if (cfx_is_vcam_device(self) && !CMTIME_IS_NUMERIC(real)) return CFX_FRAME_DURATION;
  return real;
}

static CMTime cfx_max_frame_hook(id self, SEL _cmd) {
  CMTime real = ((CMTime (*)(id, SEL))cfx_orig_max_frame)(self, _cmd);
  if (cfx_is_vcam_device(self) && !CMTIME_IS_NUMERIC(real)) return CFX_FRAME_DURATION;
  return real;
}

// The synthetic camera has fixed exposure and no ISP to service custom
// exposure requests. Complete with that fixed value instead of entering the
// hardware-only setter (Kino's record transition otherwise throws).
static IMP cfx_orig_custom_exposure;
static void cfx_custom_exposure_hook(id self, SEL cmd, CMTime duration,
                                     float iso, void (^completion)(CMTime)) {
  if (cfx_is_vcam_device(self)) {
    if (completion) completion(CFX_EXPOSURE);
    return;
  }
  ((void (*)(id, SEL, CMTime, float, void (^)(CMTime)))cfx_orig_custom_exposure)(
      self, cmd, duration, iso, completion);
}

static IMP cfx_orig_white_balance_mode;
static void cfx_white_balance_mode_hook(id self, SEL cmd, NSInteger mode) {
  // Synthetic frames have no hardware white-balance controls to lock.
  if (cfx_is_vcam_device(self)) return;
  ((void (*)(id, SEL, NSInteger))cfx_orig_white_balance_mode)(self, cmd, mode);
}

static void cfx_hook_getter(Class cls, SEL sel, IMP hook, IMP *orig) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return;
  *orig = method_setImplementation(m, hook);
  cfxlog(@"installed exposure getter %@", NSStringFromSelector(sel));
}

void cfx_install_exposure_hooks(void) {
  Class cls = NSClassFromString(@"AVCaptureFigVideoDevice");
  if (!cls) return;
  cfx_hook_getter(cls, @selector(setExposureModeCustomWithDuration:ISO:completionHandler:),
                  (IMP)cfx_custom_exposure_hook, &cfx_orig_custom_exposure);
  cfx_hook_getter(cls, @selector(setWhiteBalanceMode:),
                  (IMP)cfx_white_balance_mode_hook, &cfx_orig_white_balance_mode);
  cfx_hook_getter(cls, @selector(lensAperture), (IMP)cfx_aperture_hook, &cfx_orig_aperture);
  cfx_hook_getter(cls, @selector(ISO), (IMP)cfx_iso_hook, &cfx_orig_iso);
  cfx_hook_getter(cls, @selector(exposureDuration), (IMP)cfx_exposure_hook, &cfx_orig_exposure);
  cfx_hook_getter(cls, @selector(activeVideoMinFrameDuration), (IMP)cfx_min_frame_hook,
                  &cfx_orig_min_frame);
  cfx_hook_getter(cls, @selector(activeVideoMaxFrameDuration), (IMP)cfx_max_frame_hook,
                  &cfx_orig_max_frame);
}

// {Exif} for a delivered frame. BrightnessValue (APEX Bv = Av + Tv - Sv)
// follows the frame's mean luma so "too dark / too bright" checks still see
// the picture: mid-grey (118) gives the Bv of the fixed exposure above.
void cfx_stamp_exif(CMSampleBufferRef sb, double meanLuma) {
  double t = CMTimeGetSeconds(CFX_EXPOSURE);
  double av = log2(CFX_APERTURE * CFX_APERTURE);
  double tv = -log2(t);
  double sv = log2(CFX_ISO / 3.125);
  double bv = av + tv - sv + log2(fmax(meanLuma, 1.0) / 118.0);
  NSDictionary *exif = @{
    (NSString *)kCGImagePropertyExifFNumber: @(CFX_APERTURE),
    (NSString *)kCGImagePropertyExifApertureValue: @(av),
    (NSString *)kCGImagePropertyExifExposureTime: @(t),
    (NSString *)kCGImagePropertyExifShutterSpeedValue: @(tv),
    (NSString *)kCGImagePropertyExifISOSpeedRatings: @[@(CFX_ISO)],
    (NSString *)kCGImagePropertyExifBrightnessValue: @(bv),
  };
  CMSetAttachment(sb, kCGImagePropertyExifDictionary, (__bridge CFDictionaryRef)exif,
                  kCMAttachmentMode_ShouldPropagate);
}
