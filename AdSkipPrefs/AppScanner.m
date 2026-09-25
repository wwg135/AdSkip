#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "AppScanner.h"

@implementation ADSkipApp
@end

@implementation AppScanner

+ (NSString *)cachePath { return @"/var/mobile/Library/Preferences/com.mg.adskip.appcache.plist"; }

+ (UIImage *)normalizedIcon:(UIImage *)image {
    if (!image) return nil;
    CGSize size = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:6.0];
        [path addClip];
        [image drawInRect:(CGRect){CGPointZero, size}];
    }];
}

+ (NSString *)iconPathFromInfo:(NSDictionary *)info appPath:(NSString *)path {
    NSMutableArray *names = [NSMutableArray array];
    NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
    NSArray *declared = primary[@"CFBundleIconFiles"];
    if ([declared isKindOfClass:[NSArray class]]) [names addObjectsFromArray:declared];
    declared = info[@"CFBundleIconFiles"];
    if ([declared isKindOfClass:[NSArray class]]) [names addObjectsFromArray:declared];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon", @"AppIcon-60x60", @"icon", @"Icon"]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (id raw in names) {
        if (![raw isKindOfClass:[NSString class]] || ![raw length]) continue;
        NSString *name = [(NSString *)raw stringByDeletingPathExtension];
        for (NSString *ext in @[@"png", @"PNG"]) {
            NSString *candidate = [path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", name, ext]];
            if ([fm fileExistsAtPath:candidate]) return candidate;
        }
        NSString *direct = [path stringByAppendingPathComponent:(NSString *)raw];
        if ([fm fileExistsAtPath:direct]) return direct;
    }
    return nil;
}

+ (UIImage *)iconForAppPath:(NSString *)path iconPath:(NSString *)iconPath info:(NSDictionary *)info {
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSMutableArray *names = [NSMutableArray array];
    NSDictionary *primary = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
    NSArray *files = primary[@"CFBundleIconFiles"];
    if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
    files = info[@"CFBundleIconFiles"];
    if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon", @"icon", @"Icon"]];
    UIImage *image;
    for (id name in names) {
        if ([name isKindOfClass:[NSString class]] && [name length] && bundle) {
            image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
            if (image) return [self normalizedIcon:image];
        }
    }
    image = iconPath.length ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    return [self normalizedIcon:image];
}

+ (void)addApplicationAtPath:(NSString *)path type:(NSString *)type result:(NSMutableDictionary *)result {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![info isKindOfClass:[NSDictionary class]] || ![bid isKindOfClass:[NSString class]] || !bid.length || result[bid]) return;
    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = info[@"CFBundleName"];
    if (![name isKindOfClass:[NSString class]] || !name.length) name = bid;
    ADSkipApp *app = [ADSkipApp new];
    app.bundleID = bid;
    app.displayName = name;
    app.type = type ?: @"store";
    app.iconPath = [self iconPathFromInfo:info appPath:path];
    app.iconImage = [self iconForAppPath:path iconPath:app.iconPath info:info];
    result[bid] = app;
}

+ (void)scanDirectory:(NSString *)directory type:(NSString *)type result:(NSMutableDictionary *)result {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        NSString *path = [directory stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir && [item.lowercaseString hasSuffix:@".app"]) [self addApplicationAtPath:path type:type result:result];
    }
}

+ (NSArray *)loadCache {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:[self cachePath]];
    NSNumber *stamp = root[@"timestamp"];
    NSArray *items = root[@"apps"];
    if (![stamp isKindOfClass:[NSNumber class]] || ![items isKindOfClass:[NSArray class]] || [[NSDate date] timeIntervalSince1970] - stamp.doubleValue > 3600) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *d in items) {
        NSString *bid = d[@"bundleID"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        ADSkipApp *app = [ADSkipApp new];
        app.bundleID = bid;
        app.displayName = [d[@"displayName"] isKindOfClass:[NSString class]] ? d[@"displayName"] : bid;
        app.type = [d[@"type"] isKindOfClass:[NSString class]] ? d[@"type"] : @"store";
        app.iconPath = [d[@"iconPath"] isKindOfClass:[NSString class]] ? d[@"iconPath"] : nil;
        [result addObject:app];
    }
    return result;
}

+ (void)saveCache:(NSArray *)apps {
    NSMutableArray *items = [NSMutableArray array];
    for (ADSkipApp *app in apps) if (app.bundleID.length) [items addObject:@{ @"bundleID":app.bundleID, @"displayName":app.displayName ?: app.bundleID, @"type":app.type ?: @"store", @"iconPath":app.iconPath ?: @"" }];
    NSDictionary *root = @{ @"timestamp": @([[NSDate date] timeIntervalSince1970]), @"apps":items };
    [root writeToFile:[self cachePath] atomically:YES];
}

+ (NSArray<ADSkipApp *> *)scanApplications {
    NSArray *cached = [self loadCache];
    if (cached.count) return cached;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in @[@"/var/containers/Bundle/Application", @"/private/var/containers/Bundle/Application"]) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *dir = [root stringByAppendingPathComponent:uuid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
            [self scanDirectory:dir type:@"store" result:result];
        }
    }
    for (NSString *root in @[@"/Applications", @"/System/Applications", @"/System/Library/CoreServices"]) [self scanDirectory:root type:@"system" result:result];
    NSArray *apps = [result.allValues sortedArrayUsingComparator:^NSComparisonResult(ADSkipApp *a, ADSkipApp *b) { NSComparisonResult r = [a.displayName localizedCaseInsensitiveCompare:b.displayName]; return r == NSOrderedSame ? [a.bundleID compare:b.bundleID] : r; }];
    [self saveCache:apps];
    return apps;
}
@end
