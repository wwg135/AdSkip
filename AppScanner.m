#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (void)addApplicationAtPath:(NSString *)appPath
                         type:(NSString *)type
                        result:(NSMutableDictionary<NSString *, ADSkipApp *> *)result
{
    NSString *infoPath =
        [appPath stringByAppendingPathComponent:@"Info.plist"];

    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfFile:infoPath];

    if (![info isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *bundleID = info[@"CFBundleIdentifier"];

    if (![bundleID isKindOfClass:[NSString class]] ||
        bundleID.length == 0) {
        return;
    }

    if (result[bundleID] != nil) {
        return;
    }

    NSString *displayName = info[@"CFBundleDisplayName"];

    if (![displayName isKindOfClass:[NSString class]] ||
        displayName.length == 0) {
        displayName = info[@"CFBundleName"];
    }

    if (![displayName isKindOfClass:[NSString class]] ||
        displayName.length == 0) {
        displayName = appPath.lastPathComponent.stringByDeletingPathExtension;
    }

    ADSkipApp *app = [ADSkipApp new];
    app.bundleID = bundleID;
    app.displayName = displayName;
    app.type = type;

    result[bundleID] = app;
}

+ (void)scanDirectAppsInDirectory:(NSString *)directory
                              type:(NSString *)type
                            result:(NSMutableDictionary<NSString *, ADSkipApp *> *)result
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSArray<NSString *> *items =
        [fileManager contentsOfDirectoryAtPath:directory error:nil];

    for (NSString *item in items) {
        NSString *path = [directory stringByAppendingPathComponent:item];

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
            continue;
        }

        if (!isDirectory) {
            continue;
        }

        if ([path.pathExtension.lowercaseString isEqualToString:@"app"]) {
            [self addApplicationAtPath:path type:type result:result];
        }
    }
}

+ (void)scanStoreApplicationsWithResult:
    (NSMutableDictionary<NSString *, ADSkipApp *> *)result
{
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSArray<NSString *> *uuidDirectories =
        [fileManager contentsOfDirectoryAtPath:root error:nil];

    for (NSString *uuid in uuidDirectories) {
        NSString *uuidPath = [root stringByAppendingPathComponent:uuid];

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:uuidPath isDirectory:&isDirectory]) {
            continue;
        }

        if (!isDirectory) {
            continue;
        }

        // 商店 App 通常位于：
        // /var/containers/Bundle/Application/<UUID>/<App>.app
        [self scanDirectAppsInDirectory:uuidPath
                                   type:@"store"
                                 result:result];
    }
}

+ (NSArray<ADSkipApp *> *)scanApplications
{
    NSMutableDictionary<NSString *, ADSkipApp *> *result =
        [NSMutableDictionary dictionary];

    @autoreleasepool {
        [self scanStoreApplicationsWithResult:result];

        [self scanDirectAppsInDirectory:@"/Applications"
                                   type:@"system"
                                 result:result];

        [self scanDirectAppsInDirectory:@"/System/Library/CoreServices"
                                   type:@"system"
                                 result:result];
    }

    NSArray *apps =
        [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a,
                                                                          ADSkipApp *b) {
        NSComparisonResult order =
            [a.displayName localizedCaseInsensitiveCompare:b.displayName];

        if (order == NSOrderedSame) {
            return [a.bundleID compare:b.bundleID];
        }

        return order;
    }];

    return apps;
}

@end
