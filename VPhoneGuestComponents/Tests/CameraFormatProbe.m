#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>
int main(void) { @autoreleasepool {
  NSMutableArray *rows=[NSMutableArray array]; int failures=0; NSUInteger devices=0;
  for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if (![device.uniqueID hasPrefix:@"vphone:vcam:"]) continue;
    devices++; BOOL best=NO;
    for (AVCaptureDeviceFormat *format in device.formats) {
      double lo=CMTimeGetSeconds(format.minExposureDuration), hi=CMTimeGetSeconds(format.maxExposureDuration);
      BOOL highest=format.isHighestPhotoQualitySupported; best|=highest;
      BOOL valid=isfinite(lo)&&isfinite(hi)&&lo>0&&hi>lo&&isfinite(format.minISO)&&isfinite(format.maxISO)&&format.minISO>0&&format.maxISO>format.minISO&&format.videoFieldOfView>0&&format.videoFieldOfView<180;
      if (!valid) failures++;
      [rows addObject:@{@"highest":@(highest),@"minISO":@(format.minISO),@"maxISO":@(format.maxISO),@"minExposure":@(isfinite(lo)?lo:-1),@"maxExposure":@(isfinite(hi)?hi:-1),@"fieldOfView":@(format.videoFieldOfView),@"valid":@(valid)}];
    }
    if (!best) failures++;
  }
  if (!devices) failures++;
  NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"devices":@(devices),@"failures":@(failures),@"formats":rows} options:NSJSONWritingPrettyPrinted error:nil];
  puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  return failures?1:0;
} }
