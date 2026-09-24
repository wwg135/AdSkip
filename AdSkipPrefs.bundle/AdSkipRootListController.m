#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "AppScanner.h"

static NSString * const kDomain = @"com.mg.adskip";
static NSString * const kEnabled = @"Enabled";
static NSString * const kApps = @"Apps";

@interface AdSkipRootListController : PSListController
@property(nonatomic, strong) NSArray<ADSkipApp *> *apps;
@property(nonatomic, assign) NSInteger category;
@end

@implementation AdSkipRootListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *result = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"AdSkip\nSmart Ad Bypass"];
    [result addObject:header];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                                            target:self
                                                               set:@selector(setGlobalEnabled:specifier:)
                                                               get:@selector(globalEnabled:)
                                                            detail:nil
                                                              cell:PSLinkCell
                                                              edit:nil];
    enabled.properties[@"cell"] = @(PSSwitchCell);
    enabled.properties[@"key"] = kEnabled;
    enabled.properties[@@"defaults"] = kDomain;
    [result addObject:enabled];

    PSSpecifier *category = [PSSpecifier preferenceSpecifierNamed:@"应用分类"
                                                              target:self
                                                                 set:@selector(setCategory:specifier:)
                                                                 get:@selector(categoryValue:)
                                                              detail:nil
                                                                cell:PSLinkCell
                                                                edit:nil];
    category.properties[@"cell"] = @(PSSegmentCell);
    category.properties[@"values"] = @[@"全部", @"商店", @"系统"];
    category.properties[@"titles"] = @[@"全部", @"商店", @"系统"];
    [result addObject:category];

    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"应用列表"];
    [result addObject:appsGroup];

    NSDictionary *config = [self config];
    NSDictionary *states = config[kApps];
    for (ADSkipApp *app in [self filteredApps]) {
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:app.displayName
                                                              target:self
                                                                 set:@selector(setAppEnabled:specifier:)
                                                                 get:@selector(appEnabled:)
                                                              detail:nil
                                                                cell:PSSwitchCell
                                                                edit:nil];
        spec.properties[@"bundleID"] = app.bundleID;
        spec.properties[@"appName"] = app.displayName;
        spec.properties[@"appType"] = app.type;
        spec.properties[@"key"] = app.bundleID;
        spec.properties[@"defaultValue"] = @NO;
        spec.properties[@"footerText"] = app.bundleID;
        // Keep the current state in the specifier so PSListController does not
        // depend on PreferenceLoader's defaults domain for dynamic keys.
        spec.properties[@"value"] = states[app.bundleID] ?: @NO;
        [result addObject:spec];
    }

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"注销并应用设置"
                                                              target:self
                                                                 set:nil
                                                                 get:nil
                                                              detail:nil
                                                                cell:PSButtonCell
                                                                edit:nil];
    respring.buttonAction = @selector(respring);
    [result addObject:respring];
    return result;
}

- (NSDictionary *)config {
    NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mg.adskip.plist"];
    return value ?: @{};
}

- (void)writeConfig:(NSMutableDictionary *)config {
    NSString *path = @"/var/mobile/Library/Preferences/com.mg.adskip.plist";
    [config writeToFile:path atomically:YES];
    CFPreferencesSetAppValue((__bridge CFStringRef)kEnabled, (__bridge CFPropertyListRef)config[kEnabled], (__bridge CFStringRef)kDomain);
    CFPreferencesSetAppValue((__bridge CFStringRef)kApps, (__bridge CFPropertyListRef)config[kApps], (__bridge CFStringRef)kDomain);
    CFPreferencesSetAppValue(CFSTR("enabledApps"), (__bridge CFPropertyListRef)config[kApps], CFSTR("com.mg.adskip"));
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}

- (BOOL)globalEnabled:(PSSpecifier *)specifier { return [self config][kEnabled] ? [self config][kEnabled].boolValue : YES; }
- (void)setGlobalEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *config = [[self config] mutableCopy]; config[kEnabled] = @([value boolValue]); [self writeConfig:config];
}
- (id)categoryValue:(PSSpecifier *)specifier { return @(_category); }
- (void)setCategory:(NSNumber *)value specifier:(PSSpecifier *)specifier { _category = value.integerValue; [self reloadSpecifiers]; }

- (NSArray<ADSkipApp *> *)filteredApps {
    if (!_apps) _apps = [AppScanner scanApplications];
    if (_category == 0) return _apps;
    NSString *type = _category == 1 ? @"store" : @"system";
    return [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *_) { return [app.type isEqualToString:type]; }]];
}

- (BOOL)appEnabled:(PSSpecifier *)specifier { return [self config][kApps][specifier.properties[@"bundleID"]] ? [self config][kApps][specifier.properties[@"bundleID"]].boolValue : NO; }
- (void)setAppEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *config = [[self config] mutableCopy];
    NSMutableDictionary *apps = [config[kApps] mutableCopy] ?: [NSMutableDictionary dictionary];
    apps[specifier.properties[@"bundleID"]] = @([value boolValue]); config[kApps] = apps; [self writeConfig:config];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"是否注销？" message:@"注销 SpringBoard 后设置才会对所有应用生效。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        pid_t pid = 0; const char *args[] = {"killall", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char * const *)args, NULL);
    }]];
    [self.presentedViewController ?: self.navigationController.topViewController presentViewController:alert animated:YES completion:nil];
}
@end
