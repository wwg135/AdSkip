#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (NSString *)appCachePath
{
    return @"/var/mobile/Library/Preferences/com.mg.adskip.appcache.plist";
}

+ (NSArray<ADSkipApp *> *)loadCachedApplications
{
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:[self appCachePath]];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSNumber *ts = root[@"timestamp"];
    if (![ts isKindOfClass:[NSNumber class]]) {
        return @[];
    }
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - ts.doubleValue;
    if (age > 3600.0) {
        return @[];
    }

    NSArray *items = root[@"apps"];
    if (![items isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ADSkipApp *> *apps = [NSMutableArray array];
    for (NSDictionary *dict in items) {
        if (![dict isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *bundleID = dict[@"bundleID"];
        NSString *displayName = dict[@"displayName"];
        NSString *type = dict[@"type"];
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
            continue;
        }

        ADSkipApp *app = [ADSkipApp new];
        app.bundleID = bundleID;
        app.displayName = ([displayName isKindOfClass:[NSString class]] && displayName.length > 0)
            ? displayName
            : bundleID;
        app.type = ([type isKindOfClass:[NSString class]] && type.length > 0) ? type : @"store";
        app.iconPath = ([dict[@"iconPath"] isKindOfClass:[NSString class]]
                        && ((NSString *)dict[@"iconPath"]).length > 0)
            ? (NSString *)dict[@"iconPath"]
            : nil;
        [apps addObject:app];
    }

    return [apps copy];
}

+ (void)saveCachedApplications:(NSArray<ADSkipApp *> *)apps
{
    NSMutableArray *items = [NSMutableArray array];
    for (ADSkipApp *app in apps) {
        if (!app || ![app.bundleID isKindOfClass:[NSString class]] || app.bundleID.length == 0) {
            continue;
        }
        if (![app.type isKindOfClass:[NSString class]] || app.type.length == 0) {
            app.type = @"store";
        }
        [items addObject:@{
            @"bundleID": app.bundleID ?: @"",
            @"displayName": app.displayName ?: app.bundleID ?: @"",
            @"type": app.type ?: @"store",
            @"iconPath": app.iconPath ?: @""
        }];
    }

    NSDictionary *root = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"apps": items
    };
    [root writeToFile:[self appCachePath] atomically:YES];
}

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


#pragma mark - LaunchServices fallback

+ (id)launchServicesProxyForBundleID:(NSString *)bundleID
{
    if (bundleID.length == 0) return nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:selector]) return nil;

    @try {
        id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        return send(proxyClass, selector, bundleID);
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (NSString *)launchServicesLocalizedNameForBundleID:(NSString *)bundleID
                                             fallback:(NSString *)fallback
{
    id proxy = [self launchServicesProxyForBundleID:bundleID];
    if (!proxy) return fallback;

    @try {
        SEL selector = NSSelectorFromString(@"localizedName");
        if ([proxy respondsToSelector:selector]) {
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
            if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                return name;
            }
        }
    } @catch (NSException *exception) {
    }
    return fallback;
}

+ (UIImage *)launchServicesIconForBundleID:(NSString *)bundleID
{
    id proxy = [self launchServicesProxyForBundleID:bundleID];
    if (!proxy) return nil;

    SEL selector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:selector]) return nil;

    // Variant 2 is commonly used for the normal iPhone icon. Try a few
    // variants because different iOS releases / icon caches expose different
    // variant IDs.
    for (NSNumber *variant in @[@2, @1, @0, @3]) {
        @try {
            id (*send)(id, SEL, int) = (id (*)(id, SEL, int))objc_msgSend;
            id value = send(proxy, selector, variant.intValue);
            if ([value isKindOfClass:[UIImage class]]) {
                return value;
            }
            if (![value isKindOfClass:[NSData class]]) continue;

            NSData *data = (NSData *)value;
            UIImage *image = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
            if (image) return image;

            // iconDataForVariant: is not a PNG on many iOS versions.
            // It commonly contains a 32-byte header followed by BGRA pixels.
            // Infer the square dimensions from the payload instead of reading
            // undocumented header offsets (the previous offsets caused DingTalk
            // and Dopamine to return nil on newer systems).
            if (data.length > 32 && ((data.length - 32) % 4) == 0) {
                NSUInteger pixelCount = (data.length - 32) / 4;
                NSUInteger side = (NSUInteger)llround(sqrt((double)pixelCount));
                if (side >= 16 && side <= 1024 && side * side == pixelCount) {
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                                              side,
                                                              side,
                                                              8,
                                                              side * 4,
                                                              colorSpace,
                                                              kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                    if (ctx) {
                        void *dst = CGBitmapContextGetData(ctx);
                        memcpy(dst, data.bytes + 32, side * side * 4);
                        CGImageRef cg = CGBitmapContextCreateImage(ctx);
                        CGContextRelease(ctx);
                        CGColorSpaceRelease(colorSpace);
                        if (cg) {
                            UIImage *image = [UIImage imageWithCGImage:cg
                                                                  scale:[UIScreen mainScreen].scale
                                                            orientation:UIImageOrientationUp];
                            CGImageRelease(cg);
                            if (image) return image;
                        }
                    } else {
                        CGColorSpaceRelease(colorSpace);
                    }
                }
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

+ (UIImage *)normalizedIcon:(UIImage *)image
{
    if (!image) return nil;

    // Preferences cells are laid out in points. Normalize both the pixel
    // dimensions and the UIImage scale so a 120/180px source cannot make the
    // neighboring rows overlap.
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

    return [self normalizedIcon:image];
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

    // LaunchServices is the same system registry iOS uses for the installed
    // app name. Prefer it over hand-parsing InfoPlist.strings: this fixes apps
    // whose localization is compiled/packaged in a way that NSBundle cannot
    // resolve correctly from Settings.
    // Swiftgram is intentionally kept on its bundle/localization name.
    // On some RootHide/iOS combinations LaunchServices returns an invalid
    // localizedName payload for app.swiftgram.ios, which was rendered as
    // garbage text in Preferences. Round16's bundle-based result is the
    // correct value for this app.
    if (![bundleID isEqualToString:@"app.swiftgram.ios"]) {
        NSString *lsName = [self launchServicesLocalizedNameForBundleID:bundleID fallback:nil];
        if (lsName.length > 0) {
            displayName = lsName;
        }
    }

    ADSkipApp *app = [ADSkipApp new];
    app.bundleID = bundleID;
    app.displayName = displayName;
    app.type = type;
    app.iconPath = [self iconPathForInfo:info appPath:appPath];
    UIImage *icon = [self loadIconForAppPath:appPath iconPath:app.iconPath info:info];
    if (!icon) {
        icon = [self launchServicesIconForBundleID:bundleID];
    }
    app.iconImage = [self normalizedIcon:icon];

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
    NSArray<ADSkipApp *> *cached = [self loadCachedApplications];
    if (cached.count > 0) {
        return cached;
    }

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

    NSArray<ADSkipApp *> *sorted = [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) {
        NSComparisonResult order = [a.displayName localizedCaseInsensitiveCompare:b.displayName];
        if (order == NSOrderedSame) {
            return [a.bundleID compare:b.bundleID];
        }
        return order;
    }];

    [self saveCachedApplications:sorted];
    return sorted;
}

@end
