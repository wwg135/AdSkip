#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (void)addApplicationAtPath:(NSString *)appPath type:(NSString *)type result:(NSMutableDictionary<NSString *, ADSkipApp *> *)result
{
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];

    if (![info isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *bundleID = info[@"CFBundleIdentifier"];
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
        return;
    }

    if (result[bundleID] != nil) {
        return;
    }

    NSString *displayName = info[@"CFBundleDisplayName"];
    if (![displayName isKindOfClass:[NSString class]] || displayName.length == 0) {
        displayName = info[@"CFBundleName"];
    }
    if (![displayName isKindOfClass:[NSString class]] || displayName.length == 0) {
        displayName = appPath.lastPathComponent.stringByDeletingPathExtension;
    }

    ADSkipApp *app = [ADSkipApp new];
    app.bundleID = bundleID;
    app.displayName = displayName;
    app.type = type;

    NSArray *iconFiles = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if ([iconFiles isKindOfClass:[NSArray class]] && iconFiles.count > 0) {
        NSString *icon = iconFiles.lastObject;
        app.iconPath = [appPath stringByAppendingPathComponent:[icon stringByAppendingString:@".png"]];
    }

    if (app.iconPath.length == 0) {
        NSArray *fallbacks = @[@"AppIcon60x60@2x.png", @"AppIcon29x29@2x.png"];
        for (NSString *file in fallbacks) {
            NSString *candidate = [appPath stringByAppendingPathComponent:file];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                app.iconPath = candidate;
                break;
            }
        }
    }

    result[bundleID] = app;
}

+ (void)scanDirectAppsInDirectory:(NSString *)directory
                             type:(NSString *)type
                            result:(NSMutableDictionary<NSString *, ADSkipApp *> *)result
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:directory error:nil];

    for (NSString *item in items) {
        NSString *path = [directory stringByAppendingPathComponent:item];

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
            continue;
        }

        if ([item.lowercaseString hasSuffix:@".app"]) {
            [self addApplicationAtPath:path type:type result:result];
        }
    }
}

+ (NSArray<ADSkipApp *> *)scanApplications
{
    NSMutableDictionary<NSString *, ADSkipApp *> *result =
        [NSMutableDictionary dictionary];

    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *storeRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *storeUUIDs =
        [fm contentsOfDirectoryAtPath:storeRoot error:nil];

    for (NSString *uuid in storeUUIDs) {
        NSString *uuidPath = [storeRoot stringByAppendingPathComponent:uuid];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:uuidPath isDirectory:&isDir] || !isDir) {
            continue;
        }

        [self scanDirectAppsInDirectory:uuidPath type:@"store" result:result];
    }

    [self scanDirectAppsInDirectory:@"/Applications" type:@"system" result:result];
    [self scanDirectAppsInDirectory:@"/System/Library/CoreServices" type:@"system" result:result];

    NSArray *apps = [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) {
        NSComparisonResult order = [a.displayName localizedCaseInsensitiveCompare:b.displayName];
        if (order == NSOrderedSame) {
            return [a.bundleID compare:b.bundleID];
        }
        return order;
    }];

    return apps;
}

@end
