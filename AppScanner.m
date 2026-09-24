#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (void)scanDirectory:(NSString *)directory
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

        if ([item.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSString *infoPath =
                [path stringByAppendingPathComponent:@"Info.plist"];

            NSDictionary *info =
                [NSDictionary dictionaryWithContentsOfFile:infoPath];

            if (![info isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSString *bundleID = info[@"CFBundleIdentifier"];
            if (![bundleID isKindOfClass:[NSString class]] ||
                bundleID.length == 0) {
                continue;
            }

            if (result[bundleID] != nil) {
                continue;
            }

            NSString *displayName = info[@"CFBundleDisplayName"];

            if (![displayName isKindOfClass:[NSString class]] ||
                displayName.length == 0) {
                displayName = info[@"CFBundleName"];
            }

            if (![displayName isKindOfClass:[NSString class]] ||
                displayName.length == 0) {
                displayName = item.stringByDeletingPathExtension;
            }

            ADSkipApp *app = [ADSkipApp new];
            app.bundleID = bundleID;
            app.displayName = displayName;
            app.type = type;

            result[bundleID] = app;
            continue;
        }

        // 递归扫描 UUID 目录和系统子目录
        [self scanDirectory:path type:type result:result];
    }
}

+ (NSArray<ADSkipApp *> *)scanApplications
{
    NSMutableDictionary<NSString *, ADSkipApp *> *result =
        [NSMutableDictionary dictionary];

    [self scanDirectory:@"/var/containers/Bundle/Application"
                   type:@"store"
                 result:result];

    [self scanDirectory:@"/Applications"
                   type:@"system"
                 result:result];

    [self scanDirectory:@"/System/Library/CoreServices"
                   type:@"system"
                 result:result];

    NSArray *apps = [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    return apps;
}

@end
