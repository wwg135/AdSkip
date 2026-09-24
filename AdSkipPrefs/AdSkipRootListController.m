#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>

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

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.navigationItem.title = @"广告跳过";
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.allApps = [AppScanner scanApplications];
    [self reloadSpecifiers];
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
        [PSSpecifier groupSpecifierWithName:@"🛡️ 广告跳过"];

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

    PSSpecifier *categorySpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"应用分类"
                                        target:self
                                           set:@selector(setCategory:specifier:)
                                           get:@selector(category:)
                                        detail:nil
                                          cell:PSSegmentCell
                                          edit:nil];

    [categorySpecifier setProperty:@[@"全部", @"商店", @"系统"] forKey:@"titles"];
    [categorySpecifier setProperty:@[@"0", @"1", @"2"] forKey:@"values"];
    [specifiers addObject:categorySpecifier];

    NSString *categoryName = self.selectedCategory == 1 ? @"商店应用" : (self.selectedCategory == 2 ? @"系统应用" : @"全部应用");

    PSSpecifier *appsGroup =
        [PSSpecifier groupSpecifierWithName:categoryName];

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
        [appSpecifier setProperty:app.iconPath ?: @"" forKey:@"iconPath"];
        if (app.iconPath.length > 0) {
            [appSpecifier setProperty:app.iconPath forKey:@"icon"];
        }

        NSNumber *state = appsState[app.bundleID];
        if (!state) {
            state = @NO;
        }

        [appSpecifier setProperty:state forKey:@"defaultValue"];
        [specifiers addObject:appSpecifier];
    }

    PSSpecifier *resetGroup =
        [PSSpecifier groupSpecifierWithName:@"其他设置"];
    [specifiers addObject:resetGroup];

    PSSpecifier *reset =
        [PSSpecifier preferenceSpecifierNamed:@"重置设置"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];
    reset.buttonAction = @selector(resetSettings);
    [specifiers addObject:reset];

    return specifiers;
}

- (NSArray<ADSkipApp *> *)filteredApps
{
    if (self.selectedCategory == 0) {
        return self.allApps;
    }

    NSString *type = self.selectedCategory == 1 ? @"store" : @"system";

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
    [self reloadSpecifiers];
}

#pragma mark - Category

- (id)category:(PSSpecifier *)specifier
{
    return @(self.selectedCategory);
}

- (void)setCategory:(NSNumber *)value
          specifier:(PSSpecifier *)specifier
{
    self.selectedCategory = [value integerValue];
    _specifiers = nil;
    [self reloadSpecifiers];
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
    NSMutableDictionary *apps = [config[kAppsKey] mutableCopy];

    if (!apps) {
        apps = [NSMutableDictionary dictionary];
    }

    apps[bundleID] = @([value boolValue]);
    config[kAppsKey] = apps;

    [self saveConfiguration:config];
    [self reloadSpecifiers];
}

#pragma mark - Reset

- (void)resetSettings
{
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[kEnabledKey] = @NO;
    config[kAppsKey] = @{};
    [self saveConfiguration:config];
    [self reloadSpecifiers];
}


@end
