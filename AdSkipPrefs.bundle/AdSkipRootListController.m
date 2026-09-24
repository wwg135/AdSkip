#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <spawn.h>
#import <signal.h>

#import "../AppScanner.h"

static NSString * const kAdSkipDomain = @"com.mg.adskip";
static NSString * const kEnabledKey = @"Enabled";
static NSString * const kAppsKey = @"Apps";

@interface AdSkipRootListController : PSListController

@property(nonatomic, strong) NSArray<ADSkipApp *> *apps;
@property(nonatomic, assign) NSInteger category;

@end

@implementation AdSkipRootListController

#pragma mark - PreferenceLoader

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }

    return _specifiers;
}

#pragma mark - Configuration

- (NSString *)configPath {
    return @"/var/mobile/Library/Preferences/com.mg.adskip.plist";
}

- (NSDictionary *)config {
    NSDictionary *config =
        [NSDictionary dictionaryWithContentsOfFile:[self configPath]];

    if (![config isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    return config;
}

- (NSMutableDictionary *)mutableConfig {
    return [[self config] mutableCopy];
}

- (NSDictionary *)appStates {
    NSDictionary *apps = [self config][kAppsKey];

    if (![apps isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    return apps;
}

- (void)writeConfig:(NSDictionary *)config {
    if (![config isKindOfClass:[NSDictionary class]]) {
        return;
    }

    [config writeToFile:[self configPath] atomically:YES];

    NSDictionary *apps = config[kAppsKey];
    NSNumber *enabled = config[kEnabledKey];

    if (![enabled isKindOfClass:[NSNumber class]]) {
        enabled = @YES;
    }

    if (![apps isKindOfClass:[NSDictionary class]]) {
        apps = @{};
    }

    CFPreferencesSetAppValue(
        (__bridge CFStringRef)kEnabledKey,
        (__bridge CFPropertyListRef)enabled,
        (__bridge CFStringRef)kAdSkipDomain
    );

    CFPreferencesSetAppValue(
        (__bridge CFStringRef)kAppsKey,
        (__bridge CFPropertyListRef)apps,
        (__bridge CFStringRef)kAdSkipDomain
    );

    // 兼容现有 Tweak.xm 使用的 enabledApps 配置。
    CFPreferencesSetAppValue(
        CFSTR("enabledApps"),
        (__bridge CFPropertyListRef)apps,
        CFSTR("com.mg.adskip")
    );

    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)kAdSkipDomain
    );
}

#pragma mark - Build specifiers

- (NSArray *)buildSpecifiers {
    NSMutableArray *result = [NSMutableArray array];

    PSSpecifier *header =
        [PSSpecifier groupSpecifierWithName:@"AdSkip\nSmart Ad Bypass"];

    [result addObject:header];

    PSSpecifier *enabled =
        [PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                        target:self
                                           set:@selector(setGlobalEnabled:specifier:)
                                           get:@selector(globalEnabled:)
                                        detail:nil
                                          cell:PSSwitchCell
                                          edit:nil];

    [enabled setProperty:kAdSkipDomain forKey:@"defaults"];
    [enabled setProperty:kEnabledKey forKey:@"key"];
    [enabled setProperty:@YES forKey:@"default"];

    [result addObject:enabled];

    PSSpecifier *category =
        [PSSpecifier preferenceSpecifierNamed:@"应用分类"
                                        target:self
                                           set:@selector(setCategory:specifier:)
                                           get:@selector(categoryValue:)
                                        detail:nil
                                          cell:PSSegmentCell
                                          edit:nil];

    [category setProperty:@[@"全部", @"商店", @"系统"] forKey:@"values"];
    [category setProperty:@[@"全部", @"商店", @"系统"] forKey:@"titles"];

    [result addObject:category];

    PSSpecifier *appsGroup =
        [PSSpecifier groupSpecifierWithName:@"应用列表"];

    [result addObject:appsGroup];

    NSDictionary *states = [self appStates];

    for (ADSkipApp *app in [self filteredApps]) {
        if (![app.bundleID isKindOfClass:[NSString class]]) {
            continue;
        }

        PSSpecifier *appSpecifier =
            [PSSpecifier preferenceSpecifierNamed:app.displayName
                                            target:self
                                               set:@selector(setAppEnabled:specifier:)
                                               get:@selector(appEnabled:)
                                            detail:nil
                                              cell:PSSwitchCell
                                              edit:nil];

        [appSpecifier setProperty:app.bundleID forKey:@"bundleID"];
        [appSpecifier setProperty:app.displayName forKey:@"appName"];
        [appSpecifier setProperty:app.type forKey:@"appType"];
        [appSpecifier setProperty:app.bundleID forKey:@"key"];
        [appSpecifier setProperty:app.bundleID forKey:@"footerText"];

        NSNumber *state = states[app.bundleID];

        if (![state isKindOfClass:[NSNumber class]]) {
            state = @NO;
        }

        [appSpecifier setProperty:state forKey:@"default"];

        [result addObject:appSpecifier];
    }

    PSSpecifier *respring =
        [PSSpecifier preferenceSpecifierNamed:@"注销并应用设置"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

    [respring setButtonAction:@selector(respring)];

    [result addObject:respring];

    return result;
}

#pragma mark - App filtering

- (NSArray<ADSkipApp *> *)allApps {
    if (!self.apps) {
        self.apps = [AppScanner scanApplications];
    }

    return self.apps;
}

- (NSArray<ADSkipApp *> *)filteredApps {
    NSArray<ADSkipApp *> *apps = [self allApps];

    if (self.category == 0) {
        return apps;
    }

    NSString *wantedType =
        self.category == 1 ? @"store" : @"system";

    NSPredicate *predicate =
        [NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *bindings) {
            return [app.type isEqualToString:wantedType];
        }];

    return [apps filteredArrayUsingPredicate:predicate];
}

#pragma mark - Global switch

- (BOOL)globalEnabled:(PSSpecifier *)specifier {
    NSDictionary *config = [self config];
    NSNumber *value = config[kEnabledKey];

    if (![value isKindOfClass:[NSNumber class]]) {
        return YES;
    }

    return [value boolValue];
}

- (void)setGlobalEnabled:(NSNumber *)value
              specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *config = [self mutableConfig];

    BOOL enabled = [value respondsToSelector:@selector(boolValue)]
        ? [value boolValue]
        : NO;

    config[kEnabledKey] = @(enabled);

    [self writeConfig:config];
}

#pragma mark - Category

- (NSNumber *)categoryValue:(PSSpecifier *)specifier {
    return @(self.category);
}

- (void)setCategory:(NSNumber *)value
         specifier:(PSSpecifier *)specifier {
    self.category = value.integerValue;

    self.apps = nil;

    [self reloadSpecifiers];
}

#pragma mark - Per-app switch

- (BOOL)appEnabled:(PSSpecifier *)specifier {
    NSString *bundleID =
        [specifier propertyForKey:@"bundleID"];

    if (![bundleID isKindOfClass:[NSString class]] ||
        bundleID.length == 0) {
        return NO;
    }

    NSDictionary *states = [self appStates];
    NSNumber *value = states[bundleID];

    if (![value isKindOfClass:[NSNumber class]]) {
        return NO;
    }

    return [value boolValue];
}

- (void)setAppEnabled:(NSNumber *)value
           specifier:(PSSpecifier *)specifier {
    NSString *bundleID =
        [specifier propertyForKey:@"bundleID"];

    if (![bundleID isKindOfClass:[NSString class]] ||
        bundleID.length == 0) {
        return;
    }

    NSMutableDictionary *config = [self mutableConfig];
    NSMutableDictionary *apps =
        [config[kAppsKey] mutableCopy];

    if (![apps isKindOfClass:[NSMutableDictionary class]]) {
        apps = [NSMutableDictionary dictionary];
    }

    BOOL enabled = [value respondsToSelector:@selector(boolValue)]
        ? [value boolValue]
        : NO;

    apps[bundleID] = @(enabled);
    config[kAppsKey] = apps;

    [self writeConfig:config];
}

#pragma mark - Respring

- (void)respring {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"是否注销？"
                                            message:@"注销 SpringBoard 后设置才会对所有应用生效。"
                                     preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancel =
        [UIAlertAction actionWithTitle:@"取消"
                                 style:UIAlertActionStyleCancel
                               handler:nil];

    UIAlertAction *confirm =
        [UIAlertAction actionWithTitle:@"确定"
                                 style:UIAlertActionStyleDestructive
                               handler:^(__unused UIAlertAction *action) {
        pid_t pid = 0;

        const char *args[] = {
            "killall",
            "SpringBoard",
            NULL
        };

        posix_spawn(
            &pid,
            "/usr/bin/killall",
            NULL,
            NULL,
            (char * const *)args,
            NULL
        );
    }];

    [alert addAction:cancel];
    [alert addAction:confirm];

    UIViewController *presenter = self;

    if (self.navigationController.topViewController) {
        presenter = self.navigationController.topViewController;
    }

    [presenter presentViewController:alert
                            animated:YES
                          completion:nil];
}

@end
