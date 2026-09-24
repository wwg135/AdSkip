#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (NSArray<NSString *> *)applicationRoots {
    return @[
        @"/var/containers/Bundle/Application",
        @"/Applications",
        @"/System/Library/CoreServices"
    ];
}

+ (NSString *)displayNameForInfo:(NSDictionary *)info fallback:(NSString *)fallback {
    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        name = info[@"CFBundleName"];
    }
    return ([name isKindOfClass:NSString.class] && name.length) ? name : fallback;
}

+ (void)scanDirectory:(NSString *)directory type:(NSString *)type output:(NSMutableDictionary<NSString *, ADSkipApp *> *)output {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *child in children) {
        NSString *path = [directory stringByAppendingPathComponent:child];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) continue;

        if ([child.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
            if (output[bid] != nil) continue;

            ADSkipApp *app = [ADSkipApp new];
            app.bundleID = bid;
            app.path = path;
            app.type = type;
            app.displayName = [self displayNameForInfo:info fallback:child.stringByDeletingPathExtension];
            output[bid] = app;
            continue;
        }

        // Store apps are nested one level below a UUID directory.
        [self scanDirectory:path type:type output:output];
    }
}

+ (NSArray<ADSkipApp *> *)scanApplications {
    NSMutableDictionary<NSString *, ADSkipApp *> *found = [NSMutableDictionary dictionary];
    [self scanDirectory:@"/var/containers/Bundle/Application" type:@"store" output:found];
    [self scanDirectory:@"/Applications" type:@"system" output:found];
    [self scanDirectory:@"/System/Library/CoreServices" type:@"system" output:found];

    NSArray *apps = [found.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) {
        NSComparisonResult result = [a.displayName localizedCaseInsensitiveCompare:b.displayName];
        return result == NSOrderedSame ? [a.bundleID compare:b.bundleID] : result;
    }];
    return apps;
}

@end
