#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

// A signed, self-contained debug distribution. The embedded ZIP is packaging, not
// encryption. macOS still needs a real bundle for LaunchServices and privacy identity.
static volatile sig_atomic_t interrupted;
static void interrupt_handler(int number) { interrupted = number; }

static int run(NSString *path, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path]; task.arguments = arguments;
    NSError *error;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
    }
    [task waitUntilExit]; return task.terminationStatus;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned long size = 0;
        const uint8_t *payload = getsectiondata(&_mh_execute_header, "__DATA", "__oizys", &size);
        if (!payload || !size || size > UINT32_MAX) return 1;
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(payload, (CC_LONG)size, hash);
        NSMutableString *revision = [NSMutableString string];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [revision appendFormat:@"%02x", hash[i]];
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *base = [[files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                      URLByAppendingPathComponent:@"Oizys/Portable" isDirectory:YES];
        NSError *error;
        if (![files createDirectoryAtURL:base withIntermediateDirectories:YES
                              attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        struct stat info;
        if (lstat(base.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) return 1;
        NSURL *directory = [base URLByAppendingPathComponent:revision isDirectory:YES];
        NSURL *bundle = [directory URLByAppendingPathComponent:@"Oizys-debug.app" isDirectory:YES];
        if (![files fileExistsAtPath:bundle.path]) {
            NSURL *temporary = [base URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
            if (![files createDirectoryAtURL:temporary withIntermediateDirectories:NO
                                  attributes:@{NSFilePosixPermissions:@0700} error:&error]) return 1;
            NSURL *archive = [temporary URLByAppendingPathComponent:@"payload.zip"];
            BOOL written = [[NSData dataWithBytesNoCopy:(void *)payload length:size freeWhenDone:NO]
                            writeToURL:archive options:NSDataWritingAtomic error:&error];
            int result = written ? run(@"/usr/bin/ditto", @[@"-x", @"-k", archive.path, temporary.path]) : 1;
            [files removeItemAtURL:archive error:NULL];
            if (!result) {
                NSURL *staged = [temporary URLByAppendingPathComponent:@"Oizys-debug.app"];
                result = run(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", staged.path]);
            }
            if (result || ![files moveItemAtURL:temporary toURL:directory error:&error]) {
                [files removeItemAtURL:temporary error:NULL];
                if (result || ![files fileExistsAtPath:bundle.path]) return 1;
            }
        }
        if (run(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", bundle.path])) return 1;
        NSString *driver = [bundle.path stringByAppendingPathComponent:@"Contents/MacOS/OizysDriver"];
        // All command-line controls are available without opening the developer GUI.
        if (argc > 1 && (!strcmp(argv[1], "--cli") || argv[1][0] != '-')) {
            int first = !strcmp(argv[1], "--cli") ? 2 : 1;
            char **arguments = calloc((size_t)argc + 2, sizeof(char *));
            if (!arguments) return 1;
            arguments[0] = strdup(driver.fileSystemRepresentation);
            for (int i = first; i < argc; i++) arguments[i - first + 1] = (char *)argv[i];
            execv(arguments[0], arguments); perror("Oizys CLI"); return 1;
        }
        signal(SIGINT, interrupt_handler); signal(SIGTERM, interrupt_handler);
        NSTask *application = [[NSTask alloc] init];
        application.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
        NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[@"-n", @"-W", @"-a", bundle.path, @"--args"]];
        for (int i = 1; i < argc; i++) [arguments addObject:[NSString stringWithUTF8String:argv[i]]];
        application.arguments = arguments;
        if (![application launchAndReturnError:&error]) return 1;
        BOOL sent = NO;
        while (application.running) {
            if (interrupted && !sent) {
                for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
                    if ([app.bundleURL.path isEqualToString:bundle.path]) { kill(app.processIdentifier, SIGTERM); sent = YES; }
                }
            }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        // Also recover production after an abnormal GUI exit. No user login item is installed.
        run(driver, @[@"service", @"recover-debug"]);
        return interrupted ? 128 + interrupted : application.terminationStatus;
    }
}
