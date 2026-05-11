#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stddef.h>
#import <string.h>
#import <sys/sysctl.h>

extern CFTypeRef MGCopyAnswer(CFStringRef key);
extern CFDictionaryRef MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options);

static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.vphone.identity.plist";
static NSString *const kLogPath = @"/var/mobile/Library/Logs/vphone_identity_spoof.log";

static NSDictionary *VPIOverrides(void) {
    static NSDictionary *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *configured = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
        NSMutableDictionary *base = [@{
            @"ProductType": @"iPhone17,3",
            @"HWModelStr": @"D47AP",
            @"DeviceClass": @"iPhone",
            @"SerialNumber": @"G6TX00000000",
            @"UniqueDeviceID": @"0000000000000000000000000000000000000000",
            @"IsVirtualDevice": @NO,
        } mutableCopy];
        if ([configured isKindOfClass:NSDictionary.class]) {
            [base addEntriesFromDictionary:configured];
        }
        overrides = [base copy];
    });
    return overrides;
}

static void VPILog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!message.length) return;

    NSString *line = [NSString stringWithFormat:@"%@ [identity-spoof] %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    [[NSFileManager defaultManager] createDirectoryAtPath:kLogPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!handle) {
        [data writeToFile:kLogPath atomically:YES];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static CFTypeRef VPICopyOverride(CFStringRef key) {
    if (!key) return NULL;
    id value = VPIOverrides()[(__bridge NSString *)key];
    if (!value) return NULL;
    VPILog(@"%@ => %@", (__bridge NSString *)key, value);
    return CFBridgingRetain(value);
}

typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef key);
static CFTypeRef VPI_MGCopyAnswer(CFStringRef key) {
    CFTypeRef override = VPICopyOverride(key);
    if (override) return override;

    static MGCopyAnswerFn original;
    if (!original) original = (MGCopyAnswerFn)dlsym(RTLD_NEXT, "MGCopyAnswer");
    return original ? original(key) : NULL;
}

typedef CFDictionaryRef (*MGCopyMultipleAnswersFn)(CFArrayRef questions, CFDictionaryRef options);
static CFDictionaryRef VPI_MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options) {
    static MGCopyMultipleAnswersFn original;
    if (!original) original = (MGCopyMultipleAnswersFn)dlsym(RTLD_NEXT, "MGCopyMultipleAnswers");

    NSMutableDictionary *result = nil;
    if (original) {
        CFDictionaryRef existing = original(questions, options);
        if (existing) {
            result = [(__bridge NSDictionary *)existing mutableCopy];
            CFRelease(existing);
        }
    }
    if (!result) result = [NSMutableDictionary dictionary];

    NSArray *keys = (__bridge NSArray *)questions;
    for (id key in keys) {
        if (![key isKindOfClass:NSString.class]) continue;
        id value = VPIOverrides()[key];
        if (value) result[key] = value;
    }
    return CFBridgingRetain(result);
}

typedef int (*sysctlbynameFn)(const char *, void *, size_t *, void *, size_t);
static int VPI_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && strcmp(name, "hw.machine") == 0) {
        const char *machine = "iPhone17,3";
        size_t needed = strlen(machine) + 1;
        if (oldlenp) {
            if (oldp && *oldlenp >= needed) {
                memcpy(oldp, machine, needed);
            } else if (oldp && *oldlenp < needed) {
                errno = ENOMEM;
                return -1;
            }
            *oldlenp = needed;
        }
        VPILog(@"sysctl hw.machine => %s", machine);
        return 0;
    }

    static sysctlbynameFn original;
    if (!original) original = (sysctlbynameFn)dlsym(RTLD_NEXT, "sysctlbyname");
    return original ? original(name, oldp, oldlenp, newp, newlen) : -1;
}

struct interpose_entry {
    const void *replacement;
    const void *replacee;
};

extern void dyld_dynamic_interpose(const struct mach_header *mh,
                                   const struct interpose_entry array[],
                                   size_t count);

__attribute__((used)) static const struct interpose_entry vpiInterposes[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)VPI_MGCopyAnswer, (const void *)MGCopyAnswer },
    { (const void *)VPI_MGCopyMultipleAnswers, (const void *)MGCopyMultipleAnswers },
    { (const void *)VPI_sysctlbyname, (const void *)sysctlbyname },
};

__attribute__((constructor))
static void VPIInit(void) {
    VPILog(@"loaded in %@ overrides=%@", NSProcessInfo.processInfo.processName, VPIOverrides());
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        dyld_dynamic_interpose(header, vpiInterposes, sizeof(vpiInterposes) / sizeof(vpiInterposes[0]));
    }
    VPILog(@"applied dynamic interpose to %u images", count);
}
