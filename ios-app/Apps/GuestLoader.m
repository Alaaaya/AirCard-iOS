// GuestLoader.m — AirCard's own minimal in-process app loader ("Container", Beta).
//
// Written from scratch for AirCard. It follows the publicly known idea of
// loading an iOS app's main executable as a library (the approach LiveContainer
// popularised), but contains no LiveContainer code (LiveContainer is AGPL-3.0).
//
// Flow:
//   1. The Apps tab writes the guest's bundle/data paths to NSUserDefaults and
//      relaunches AirCard.
//   2. main() (see main.m) calls AirCardGuestLaunchIfRequested() before
//      SwiftUI starts. If a launch is pending it consumes it (one-shot), points
//      HOME/TMPDIR at the guest's private data folder, makes +[NSBundle
//      mainBundle] return the guest bundle, dlopen()s the guest executable
//      (already patched to MH_DYLIB and signed with the user's dev cert by
//      rust-core/src/container.rs) and jumps to its LC_MAIN entry point.
//   3. If anything fails, the error is stored and AirCard starts normally.
//
// Not supported (documented in the README): app extensions/widgets, push
// notifications, app groups, separate keychain (guests share AirCard's),
// CFBundleGetMainBundle / CFPreferences isolation, URL schemes of the guest.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <crt_externs.h>

static NSString *const kBundleKey = @"aircard.guest.bundlePath";
static NSString *const kDataKey   = @"aircard.guest.dataPath";
static NSString *const kErrorKey  = @"aircard.guest.lastError";

static NSBundle *gGuestBundle = nil;

static NSBundle *AirCardGuestMainBundle(id self, SEL _cmd) {
    return gGuestBundle;
}

static void AirCardGuestFail(NSString *msg) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:msg forKey:kErrorKey];
    [d synchronize];
    NSLog(@"[AirCard Container] %@", msg);
}

static const struct mach_header_64 *AirCardFindImage(const char *path) {
    char want[PATH_MAX];
    if (!realpath(path, want)) strlcpy(want, path, sizeof(want));
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        char have[PATH_MAX];
        if (!realpath(name, have)) strlcpy(have, name, sizeof(have));
        if (strcmp(have, want) == 0) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static uint64_t AirCardEntryOffset(const struct mach_header_64 *h) {
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_MAIN) {
            return ((const struct entry_point_command *)lc)->entryoff;
        }
        p += lc->cmdsize;
    }
    return 0;
}

static char *gOrigHome, *gOrigFixed, *gOrigTmp;

static void AirCardRestoreEnv(void) {
    if (gOrigHome) setenv("HOME", gOrigHome, 1); else unsetenv("HOME");
    if (gOrigFixed) setenv("CFFIXED_USER_HOME", gOrigFixed, 1); else unsetenv("CFFIXED_USER_HOME");
    if (gOrigTmp) setenv("TMPDIR", gOrigTmp, 1); else unsetenv("TMPDIR");
}

static void AirCardPrepareDataDir(NSString *data) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sub in @[@"Documents", @"Library/Preferences", @"Library/Caches",
                            @"Library/Application Support", @"tmp"]) {
        [fm createDirectoryAtPath:[data stringByAppendingPathComponent:sub]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
    setenv("HOME", data.fileSystemRepresentation, 1);
    setenv("CFFIXED_USER_HOME", data.fileSystemRepresentation, 1);
    NSString *tmp = [[data stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
    setenv("TMPDIR", tmp.fileSystemRepresentation, 1);
}

/// Returns only when no guest launch is pending or the launch failed.
/// On success the guest's main() runs and the process exits with its status.
int AirCardGuestLaunchIfRequested(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSString *bundlePath = [d stringForKey:kBundleKey];
        NSString *dataPath = [d stringForKey:kDataKey];
        if (bundlePath.length == 0) return -1;

        // One-shot: the next normal launch of AirCard opens AirCard again.
        [d removeObjectForKey:kBundleKey];
        [d removeObjectForKey:kDataKey];
        [d synchronize];

        NSBundle *guest = [NSBundle bundleWithPath:bundlePath];
        NSString *exe = guest.executablePath;
        if (!guest || exe.length == 0) {
            AirCardGuestFail([NSString stringWithFormat:@"Guest bundle missing: %@", bundlePath]);
            return -1;
        }

        // Remember Mirsa's own environment so a failed launch can put it back;
        // otherwise Mirsa keeps running with the guest's HOME and nests its files.
        const char *oh = getenv("HOME"), *oc = getenv("CFFIXED_USER_HOME"), *ot = getenv("TMPDIR");
        gOrigHome = oh ? strdup(oh) : NULL;
        gOrigFixed = oc ? strdup(oc) : NULL;
        gOrigTmp = ot ? strdup(ot) : NULL;
        if (dataPath.length) AirCardPrepareDataDir(dataPath);

        // +[NSBundle mainBundle] -> guest bundle (Info.plist, resources, bundle id).
        gGuestBundle = guest;
        Method m = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        IMP original = method_setImplementation(m, (IMP)AirCardGuestMainBundle);

        void *handle = dlopen(exe.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL);
        if (!handle) {
            const char *err = dlerror();
            AirCardGuestFail([NSString stringWithFormat:@"dlopen failed: %s", err ? err : "unknown"]);
            // Restore so AirCard itself keeps working.
            gGuestBundle = nil;
            method_setImplementation(m, original);
            AirCardRestoreEnv();
            return -1;
        }

        const struct mach_header_64 *h = AirCardFindImage(exe.fileSystemRepresentation);
        uint64_t off = h ? AirCardEntryOffset(h) : 0;
        if (!h || off == 0) {
            AirCardGuestFail(@"Guest has no LC_MAIN entry point");
            gGuestBundle = nil;
            method_setImplementation(m, original);
            AirCardRestoreEnv();
            return -1;
        }

        typedef int (*guest_main_t)(int, char **, char **, char **);
        guest_main_t entry = (guest_main_t)((const uint8_t *)h + off);

        char *gargv[2] = { (char *)exe.fileSystemRepresentation, NULL };
        char *apple[1] = { NULL };
        NSLog(@"[AirCard Container] launching %@", guest.bundleIdentifier);
        int rc = entry(1, gargv, *_NSGetEnviron(), apple);
        exit(rc);
    }
}
