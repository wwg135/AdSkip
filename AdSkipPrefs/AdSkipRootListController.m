#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <spawn.h>

#import "AppScanner.h"

static NSString * const kPreferencesPath =
    @"/var/mobile/Library/Preferences/com.mg.adskip.plist";

static NSString * const kEnabledKey = @"Enabled";
static NSString * const kAppsKey = @"Apps";

@interface AdSkipRootListController : PSListController

@property(nonatomic, strong) NSArray<ADSkipApp *> *allApps;
@property(nonatomic, assign) NSInteger selectedCategory;

@end

@implementation AdSkipRootListController

- (instancetype)init
{
    self = [super init];

    if (self) {
        _selectedCategory = 0;
        _allApps = @[];
    }

    return self;
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }

    return _specifiers;
}

#pragma mark - Configuration

- (NSMutableDictionary *)configuration
{
    NSDictionary *saved =
        [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];

    NSMutableDictionary *config =
        saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];

    if (![config[kEnabledKey] isKindOfClass:[NSNumber class]]) {
        config[kEnabledKey] = @YES;
    }

    if (![config[kAppsKey] isKindOfClass:[NSDictionary class]]) {
        config[kAppsKey] = @{};
    }

    return config;
}

- (void)saveConfiguration:(NSDictionary *)configuration
{
    [configuration writeToFile:kPreferencesPath atomically:YES];

    CFPreferencesSetAppValue(
        CFSTR("Enabled"),
        (__bridge CFPropertyListRef)configuration[kEnabledKey],
        CFSTR("com.mg.adskip")
    );

    CFPreferencesSetAppValue(
        CFSTR("Apps"),
        (__bridge CFPropertyListRef)configuration[kAppsKey],
        CFSTR("com.mg.adskip")
    );

    // 与旧版本配置保持兼容
    CFPreferencesSetAppValue(
        CFSTR("enabledApps"),
        (__bridge CFPropertyListRef)configuration[kAppsKey],
        CFSTR("com.mg.adskip")
    );

    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));
}

#pragma mark - Specifiers

- (NSMutableArray *)buildSpecifiers
{
    if (self.allApps.count == 0) {
        self.allApps = [AppScanner scanApplications];
    }

    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header =
        [PSSpecifier groupSpecifierWithName:@"AdSkip"];

    [specifiers addObject:header];

    PSSpecifier *globalSwitch =
        [PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                        target:self
                                           set:@selector(setGlobalEnabled:specifier:)
                                           get:@selector(globalEnabled:)
                                        detail:nil
                                          cell:PSSwitchCell
                                          edit:nil];

    [specifiers addObject:globalSwitch];

    PSSpecifier *categoryGroup =
        [PSSpecifier groupSpecifierWithName:@"应用分类"];

    [specifiers addObject:categoryGroup];

    PSSpecifier *allButton =
        [PSSpecifier preferenceSpecifierNamed:@"全部"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

    allButton.buttonAction = @selector(showAllApps);
    [specifiers addObject:allButton];

    PSSpecifier *storeButton =
        [PSSpecifier preferenceSpecifierNamed:@"商店"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

    storeButton.buttonAction = @selector(showStoreApps);
    [specifiers addObject:storeButton];

    PSSpecifier *systemButton =
        [PSSpecifier preferenceSpecifierNamed:@"系统"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

    systemButton.buttonAction = @selector(showSystemApps);
    [specifiers addObject:systemButton];

    PSSpecifier *appsGroup =
        [PSSpecifier groupSpecifierWithName:@"应用列表"];

    [specifiers addObject:appsGroup];

    NSDictionary *appsState = [self configuration][kAppsKey];

    for (ADSkipApp *app in [self filteredApps]) {
        PSSpecifier *appSpecifier =
            [PSSpecifier preferenceSpecifierNamed:app.displayName
                                            target:self
                                               set:@selector(setAppEnabled:specifier:)
                                               get:@selector(appEnabled:)
                                            detail:nil
                                              cell:PSSwitchCell
                                              edit:nil];

        [appSpecifier setProperty:app.bundleID forKey:@"bundleID"];
        [appSpecifier setProperty:app.type forKey:@"appType"];
        [appSpecifier setProperty:app.displayName forKey:@"appName"];

        NSNumber *state = appsState[app.bundleID];

        if (!state) {
            state = @NO;
        }

        [appSpecifier setProperty:state forKey:@"defaultValue"];

        [specifiers addObject:appSpecifier];
    }

    PSSpecifier *respringGroup =
        [PSSpecifier groupSpecifierWithName:@"应用设置后需要注销 SpringBoard 才会完全生效"];

    [specifiers addObject:respringGroup];

    PSSpecifier *respring =
        [PSSpecifier preferenceSpecifierNamed:@"注销并应用设置"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

    respring.buttonAction = @selector(respring);
    [specifiers addObject:respring];

    return specifiers;
}

- (NSArray<ADSkipApp *> *)filteredApps
{
    if (self.selectedCategory == 0) {
        return self.allApps;
    }

    NSString *type =
        self.selectedCategory == 1 ? @"store" : @"system";

    NSPredicate *predicate =
        [NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *bindings) {
            return [app.type isEqualToString:type];
        }];

    return [self.allApps filteredArrayUsingPredicate:predicate];
}

#pragma mark - Global switch

- (id)globalEnabled:(PSSpecifier *)specifier
{
    NSNumber *value = [self configuration][kEnabledKey];
    return value ?: @YES;
}

- (void)setGlobalEnabled:(NSNumber *)value
              specifier:(PSSpecifier *)specifier
{
    NSMutableDictionary *config = [self configuration];
    config[kEnabledKey] = @([value boolValue]);
    [self saveConfiguration:config];
}

#pragma mark - App switches

- (id)appEnabled:(PSSpecifier *)specifier
{
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];

    NSDictionary *apps = [self configuration][kAppsKey];
    NSNumber *value = apps[bundleID];

    return value ?: @NO;
}

- (void)setAppEnabled:(NSNumber *)value
            specifier:(PSSpecifier *)specifier
{
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];

    if (bundleID.length == 0) {
        return;
    }

    NSMutableDictionary *config = [self configuration];
    NSMutableDictionary *apps =
        [config[kAppsKey] mutableCopy];

    if (!apps) {
        apps = [NSMutableDictionary dictionary];
    }

    apps[bundleID] = @([value boolValue]);
    config[kAppsKey] = apps;

    [self saveConfiguration:config];
}

#pragma mark - Categories

- (void)showAllApps
{
    self.selectedCategory = 0;
    [self reloadSpecifiers];
}

- (void)showStoreApps
{
    self.selectedCategory = 1;
    [self reloadSpecifiers];
}

- (void)showSystemApps
{
    self.selectedCategory = 2;
    [self reloadSpecifiers];
}

#pragma mark - Respring

- (void)respring
{
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"是否注销？"
                                             message:@"注销 SpringBoard 后设置才会完全生效。"
                                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"取消"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"确定"
                                 style:UIAlertActionStyleDestructive
                               handler:^(__unused UIAlertAction *action) {
        pid_t pid = 0;

        char *const args[] = {
            (char *)"killall",
            (char *)"SpringBoard",
            NULL
        };

        posix_spawn(
            &pid,
            "/usr/bin/killall",
            NULL,
            NULL,
            args,
            NULL
        );
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
