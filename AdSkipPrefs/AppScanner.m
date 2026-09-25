#import <UIKit/UIKit.h>
#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

#pragma mark - Localized display name

+ (NSString *)localizedStringForKey:(NSString *)key
                       inBundlePath:(NSString *)appPath
                           fallback:(NSString *)fallback
{
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return fallback;
    }

    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    if (bundle) {
        // This is the canonical Foundation lookup for InfoPlist.strings.
        NSString *localized = [bundle localizedStringForKey:key
                                                      value:nil
                                                      table:@"InfoPlist"];
        if ([localized isKindOfClass:[NSString class]] && localized.length > 0 &&
            ![localized isEqualToString:key]) {
            return localized;
        }

        localized = [bundle localizedInfoDictionary][key];
        if ([localized isKindOfClass:[NSString class]] && localized.length > 0) {
            return localized;
        }
    }

    // Some apps do not expose InfoPlist.strings through NSBundle when their
    // bundle is scanned outside the app process. Read the lproj files directly
    // and rank them according to the user's preferred languages.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = [fm contentsOfDirectoryAtPath:appPath error:nil];
    NSMutableArray<NSString *> *languages = [NSMutableArray array];

    for (NSString *language in [NSLocale preferredLanguages]) {
        if (language.length == 0) continue;
        [languages addObject:language];

        NSString *dashBase = [language componentsSeparatedByString:@"-"].firstObject;
        if (dashBase.length > 0 && ![languages containsObject:dashBase]) {
            [languages addObject:dashBase];
        }

        NSString *underscore = [language stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        if (underscore.length > 0 && ![languages containsObject:underscore]) {
            [languages addObject:underscore];
        }
    }

    // Chinese variants commonly found in iOS bundles.
    NSArray *zhVariants = @[
        @"zh-Hans", @"zh-Hans-CN", @"zh_CN", @"zh-CN", @"zh-Hant",
        @"zh-Hant-TW", @"zh_TW", @"zh-TW", @"zh"
    ];
    for (NSString *variant in zhVariants) {
        if (![languages containsObject:variant]) {
            [languages addObject:variant];
        }
    }

    // Finally append every actual lproj directory, so a valid localization is
    // still found even when the app uses a nonstandard locale identifier.
    NSMutableArray<NSString *> *lprojNames = [NSMutableArray array];
    for (NSString *dir in dirs) {
        if ([dir hasSuffix:@".lproj"]) {
            NSString *name = [dir stringByDeletingPathExtension];
            if (name.length > 0 && ![lprojNames containsObject:name]) {
                [lprojNames addObject:name];
            }
        }
    }
    for (NSString *name in lprojNames) {
        if (![languages containsObject:name]) {
            [languages addObject:name];
        }
    }

    for (NSString *language in languages) {
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
        for (NSString *name in primaryFiles) {
            if ([name isKindOfClass:[NSString class]] && name.length > 0 && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
    }

    NSArray *legacyFiles = info[@"CFBundleIconFiles"];
    if ([legacyFiles isKindOfClass:[NSArray class]]) {
        for (NSString *name in legacyFiles) {
            if ([name isKindOfClass:[NSString class]] && name.length > 0 && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
    }

    NSArray *fallbacks = @[
        @"AppIcon60x60", @"AppIcon", @"AppIcon-60x60", @"icon", @"Icon"
    ];
    for (NSString *name in fallbacks) {
        if (![names containsObject:name]) {
            [names addObject:name];
        }
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    // Try the bundle-declared names in their original order first. Do not use
    // reverseObjectEnumerator: it often picked @3x assets and made the cell
    // render a huge bitmap.
    for (NSString *rawName in names) {
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

+ (UIImage *)loadIconForAppPath:(NSString *)appPath
                       iconPath:(NSString *)iconPath
                           info:(NSDictionary *)info
{
    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    UIImage *image = nil;

    // imageNamed:inBundle: can resolve asset-catalog based app icons that do
    // not exist as a standalone PNG next to Info.plist.
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSDictionary *primary = [info[@"CFBundleIcons"] isKindOfClass:[NSDictionary class]]
        ? info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"] : nil;
    NSArray *files = [primary isKindOfClass:[NSDictionary class]] ? primary[@"CFBundleIconFiles"] : nil;
    if ([files isKindOfClass:[NSArray class]]) {
        [names addObjectsFromArray:files];
    }
    NSArray *legacy = info[@"CFBundleIconFiles"];
    if ([legacy isKindOfClass:[NSArray class]]) {
        for (NSString *name in legacy) {
            if ([name isKindOfClass:[NSString class]] && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
    }
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon", @"icon", @"Icon"]];

    if (bundle) {
        for (NSString *name in names) {
            if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
            image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
            if (image) break;
        }
    }

    if (!image && iconPath.length > 0) {
        image = [UIImage imageWithContentsOfFile:iconPath];
    }

    if (!image) {
        return nil;
    }

    // Normalize every icon to the actual Preferences row footprint. This is
    // important because PSSwitchCell may otherwise use the source pixel size.
    CGSize target = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0, 0, target.width, target.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:6.0];
        [path addClip];
        [image drawInRect:rect];
    }];
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
    if (displayName.length == 0 || [displayName isEqualToString:@"CFBundleDisplayName"]) {
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
    app.iconImage = [self loadIconForAppPath:appPath iconPath:app.iconPath info:info];

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

    NSArray<NSString *> *storeRoots = @[
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application"
    ];

    for (NSString *storeRoot in storeRoots) {
        NSArray *uuids = [fm contentsOfDirectoryAtPath:storeRoot error:nil];
        for (NSString *uuid in uuids) {
            NSString *uuidPath = [storeRoot stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:uuidPath isDirectory:&isDir] || !isDir) {
                continue;
            }
            [self scanDirectAppsInDirectory:uuidPath type:@"store" result:result];
        }
    }

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
