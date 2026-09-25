#import <UIKit/UIKit.h>
#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

#pragma mark - Localized display name

+ (NSString *)localizedStringForKey:(NSString *)key inBundlePath:(NSString *)appPath fallback:(NSString *)fallback
{
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return fallback;
    }

    // First let NSBundle resolve the normal InfoPlist.strings localization rules.
    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    NSString *localized = [bundle localizedInfoDictionary][key];
    if ([localized isKindOfClass:[NSString class]] && localized.length > 0) {
        return localized;
    }

    localized = [bundle objectForInfoDictionaryKey:key];
    if ([localized isKindOfClass:[NSString class]] && localized.length > 0) {
        return localized;
    }

    // Some system/app bundles expose InfoPlist.strings only through their lproj
    // directory. Resolve the current preferred language explicitly as a fallback.
    NSArray<NSString *> *languages = [NSLocale preferredLanguages];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *language in languages) {
        if (language.length > 0) {
            [candidates addObject:language];
            NSString *base = [language componentsSeparatedByString:@"-"].firstObject;
            if (base.length > 0 && ![candidates containsObject:base]) {
                [candidates addObject:base];
            }
        }
    }
    if (![candidates containsObject:@"en"]) {
        [candidates addObject:@"en"];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *language in candidates) {
        NSString *stringsPath = [appPath stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.lproj/InfoPlist.strings", language]];
        if (![fm fileExistsAtPath:stringsPath]) {
            continue;
        }

        NSDictionary *strings = [NSDictionary dictionaryWithContentsOfFile:stringsPath];
        NSString *value = strings[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            return value;
        }
    }

    return fallback;
}

#pragma mark - Icon discovery

+ (NSString *)iconPathForInfo:(NSDictionary *)info appPath:(NSString *)appPath
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];

    NSDictionary *icons = info[@"CFBundleIcons"];
    NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
    NSArray *primaryFiles = primary[@"CFBundleIconFiles"];
    if ([primaryFiles isKindOfClass:[NSArray class]]) {
        [names addObjectsFromArray:primaryFiles];
    }

    NSArray *legacyFiles = info[@"CFBundleIconFiles"];
    if ([legacyFiles isKindOfClass:[NSArray class]]) {
        for (NSString *name in legacyFiles) {
            if ([name isKindOfClass:[NSString class]] && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
    }

    NSArray *fallbacks = @[
        @"AppIcon60x60",
        @"AppIcon60x60@2x",
        @"AppIcon60x60@3x",
        @"AppIcon29x29",
        @"AppIcon29x29@2x",
        @"AppIcon29x29@3x",
        @"icon",
        @"Icon"
    ];
    for (NSString *name in fallbacks) {
        if (![names containsObject:name]) {
            [names addObject:name];
        }
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rawName in names.reverseObjectEnumerator) {
        if (![rawName isKindOfClass:[NSString class]] || rawName.length == 0) {
            continue;
        }

        NSString *name = rawName.stringByDeletingPathExtension;
        NSArray<NSString *> *extensions = @[@"png", @"PNG"];
        for (NSString *ext in extensions) {
            NSString *candidate = [appPath stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"%@.%@", name, ext]];
            if ([fm fileExistsAtPath:candidate]) {
                return candidate;
            }
        }

        NSString *direct = [appPath stringByAppendingPathComponent:rawName];
        if ([fm fileExistsAtPath:direct]) {
            return direct;
        }
    }

    return nil;
}

#pragma mark - App scanning

+ (void)addApplicationAtPath:(NSString *)appPath
                         type:(NSString *)type
                       result:(NSMutableDictionary<NSString *, ADSkipApp *> *)result
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

    NSString *fallbackName = info[@"CFBundleDisplayName"];
    if (![fallbackName isKindOfClass:[NSString class]] || fallbackName.length == 0) {
        fallbackName = info[@"CFBundleName"];
    }
    if (![fallbackName isKindOfClass:[NSString class]] || fallbackName.length == 0) {
        fallbackName = appPath.lastPathComponent.stringByDeletingPathExtension;
    }

    NSString *displayName = [self localizedStringForKey:@"CFBundleDisplayName"
                                           inBundlePath:appPath
                                               fallback:fallbackName];
    if (displayName.length == 0 || [displayName isEqualToString:fallbackName]) {
        displayName = [self localizedStringForKey:@"CFBundleName"
                                       inBundlePath:appPath
                                           fallback:fallbackName];
    }
    if (displayName.length == 0) {
        displayName = bundleID;
    }

    ADSkipApp *app = [ADSkipApp new];
    app.bundleID = bundleID;
    app.displayName = displayName;
    app.type = type;

    app.iconPath = [self iconPathForInfo:info appPath:appPath];
    if (app.iconPath.length > 0) {
        app.iconImage = [UIImage imageWithContentsOfFile:app.iconPath];
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
    NSMutableDictionary<NSString *, ADSkipApp *> *result = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];

    // User-installed applications. This is deliberately the only source marked
    // "store", so system applications cannot accidentally appear in that tab.
    NSArray<NSString *> *storeRoots = @[
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application"
    ];

    for (NSString *storeRoot in storeRoots) {
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:storeRoot error:nil];
        for (NSString *uuid in uuids) {
            NSString *uuidPath = [storeRoot stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:uuidPath isDirectory:&isDir] || !isDir) {
                continue;
            }
            [self scanDirectAppsInDirectory:uuidPath type:@"store" result:result];
        }
    }

    // System applications. These locations are kept separate from the user-app
    // scan above so the category switch remains deterministic.
    NSArray<NSString *> *systemRoots = @[
        @"/Applications",
        @"/System/Applications",
        @"/System/Library/CoreServices"
    ];

    for (NSString *root in systemRoots) {
        [self scanDirectAppsInDirectory:root type:@"system" result:result];
    }

    return [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) {
        NSComparisonResult order = [a.displayName localizedCaseInsensitiveCompare:b.displayName];
        if (order == NSOrderedSame) {
            return [a.bundleID compare:b.bundleID];
        }
        return order;
    }];
}

@end
