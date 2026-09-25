#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#import "AppScanner.h"

static NSString * const kPreferencesPath =
    @"/var/mobile/Library/Preferences/com.mg.adskip.plist";

static NSString * const kEnabledKey = @"Enabled";
static NSString * const kAppsKey = @"Apps";
static NSString * const kLegacyAppsKey = @"enabledApps";
static NSString * const kCategoryKey = @"AppCategory";
static NSString * const kChangedNotification = @"com.mg.adskip.preferences.changed";

@interface AdSkipRootListController : PSListController

@property(nonatomic, strong) NSArray<ADSkipApp *> *allApps;
@property(nonatomic, assign) NSInteger selectedCategory;
@property(nonatomic, strong) UISegmentedControl *categoryControl;

@end

@implementation AdSkipRootListController

static NSArray<ADSkipApp *> *sCachedApps = nil;
static BOOL sScanInProgress = NO;
static NSDate *sLastScanAt = nil;

- (instancetype)init
{
    self = [super init];
    if (self) {
        _selectedCategory = [[NSUserDefaults standardUserDefaults] integerForKey:kCategoryKey];
        if (_selectedCategory < 0 || _selectedCategory > 2) {
            _selectedCategory = 0;
        }
        _allApps = sCachedApps ?: @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.title = @"广告跳过";

    self.categoryControl = [[UISegmentedControl alloc] initWithItems:@[
        @"全部", @"商店", @"系统"
    ]];
    self.categoryControl.selectedSegmentIndex = self.selectedCategory;
    [self.categoryControl addTarget:self
                             action:@selector(categoryChanged:)
                   forControlEvents:UIControlEventValueChanged];
    self.categoryControl.accessibilityLabel = @"应用分类";

    [self startApplicationScanIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self startApplicationScanIfNeeded];
}

// 由于缓存里只保留 iconPath，不保留 UIImage，进入 Settings 时需要
// 重新恢复 iconImage，避免空图标 / 表格卡顿 / 反复刷新的问题。
- (void)hydrateIconForApp:(ADSkipApp *)app
{
    if (!app || app.iconImage) {
        return;
    }

    UIImage *image = nil;
    if (app.iconPath.length > 0) {
        image = [UIImage imageWithContentsOfFile:app.iconPath];
    }

    if (!image) {
        return;
    }

    CGSize size = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = NO;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    app.iconImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:6.0];
        [path addClip];
        [image drawInRect:rect];
    }];
}

- (void)startApplicationScanIfNeeded
{
    if (sScanInProgress) {
        return;
    }

    if (sCachedApps.count > 0) {
        self.allApps = sCachedApps;
        for (ADSkipApp *app in self.allApps) {
            [self hydrateIconForApp:app];
        }

        // 只要缓存还有效，就不要在每次进入 Settings 时重复全量扫描，
        // 否则就会出现“每次进去插件都要等一会才加载所有应用”。
        if (sLastScanAt != nil) {
            NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:sLastScanAt];
            if (age < 60.0) {
                return;
            }
        }
    }

    sScanInProgress = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<ADSkipApp *> *apps = [AppScanner scanApplications] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            sScanInProgress = NO;
            sCachedApps = [apps copy];
            sLastScanAt = [NSDate date];

            self.allApps = sCachedApps;
            for (ADSkipApp *app in self.allApps) {
                [self hydrateIconForApp:app];
            }

            if (self.isViewLoaded && self.view.window != nil) {
                self->_specifiers = nil;
                [self reloadSpecifiers];
            }
        });
    });
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != 1) {
        return nil;
    }

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = [UIColor clearColor];

    self.categoryControl.selectedSegmentIndex = self.selectedCategory;
    self.categoryControl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.categoryControl];

    [NSLayoutConstraint activateConstraints:@[
        [self.categoryControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [self.categoryControl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [self.categoryControl.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [self.categoryControl.heightAnchor constraintEqualToConstant:32.0]
    ]];

    return container;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return section == 1 ? 50.0 : 22.0;
}

- (NSMutableDictionary *)configuration
{
    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    NSDictionary *fileConfig = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    if ([fileConfig isKindOfClass:[NSDictionary class]]) {
        [config addEntriesFromDictionary:fileConfig];
    }

    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));

    CFTypeRef enabled = CFPreferencesCopyAppValue(CFSTR("Enabled"), CFSTR("com.mg.adskip"));
    CFTypeRef apps = CFPreferencesCopyAppValue(CFSTR("Apps"), CFSTR("com.mg.adskip"));
    CFTypeRef legacyApps = CFPreferencesCopyAppValue(CFSTR("enabledApps"), CFSTR("com.mg.adskip"));

    if (enabled) {
        config[kEnabledKey] = CFBridgingRelease(enabled);
    }
    if (apps) {
        config[kAppsKey] = CFBridgingRelease(apps);
    } else if (legacyApps) {
        config[kAppsKey] = CFBridgingRelease(legacyApps);
    }

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
    NSDictionary *apps = [configuration[kAppsKey] isKindOfClass:[NSDictionary class]]
        ? configuration[kAppsKey]
        : @{};
    NSNumber *enabled = [configuration[kEnabledKey] isKindOfClass:[NSNumber class]]
        ? configuration[kEnabledKey]
        : @YES;

    NSMutableDictionary *normalized = [configuration mutableCopy];
    normalized[kEnabledKey] = enabled;
    normalized[kAppsKey] = apps;
    normalized[kLegacyAppsKey] = apps;

    [normalized writeToFile:kPreferencesPath atomically:YES];

    CFPreferencesSetAppValue(CFSTR("Enabled"),
                             (__bridge CFPropertyListRef)enabled,
                             CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("Apps"),
                             (__bridge CFPropertyListRef)apps,
                             CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("enabledApps"),
                             (__bridge CFPropertyListRef)apps,
                             CFSTR("com.mg.adskip"));
    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.mg.adskip.preferences.changed"),
        NULL,
        NULL,
        true
    );
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers
{
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"🛡️ 广告跳过"];
    [specifiers addObject:header];

    PSSpecifier *globalSwitch = [PSSpecifier preferenceSpecifierNamed:@"启用插件"
        target:self
        set:@selector(setGlobalEnabled:specifier:)
        get:@selector(globalEnabled:)
        detail:nil
        cell:PSSwitchCell
        edit:nil];
    [specifiers addObject:globalSwitch];

    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"应用控制"];
    [specifiers addObject:appsGroup];

    NSDictionary *appsState = [self configuration][kAppsKey];

    for (ADSkipApp *app in [self filteredApps]) {
        [self hydrateIconForApp:app];

        PSSpecifier *appSpecifier =
            [PSSpecifier preferenceSpecifierNamed:(app.displayName ?: app.bundleID)
                target:self
                set:@selector(setAppEnabled:specifier:)
                get:@selector(appEnabled:)
                detail:nil
                cell:PSSwitchCell
                edit:nil];

        [appSpecifier setProperty:app.bundleID forKey:@"bundleID"];
        [appSpecifier setProperty:app.type forKey:@"appType"];
        [appSpecifier setProperty:app.displayName ?: app.bundleID forKey:@"appName"];
        [appSpecifier setProperty:(app.iconPath ?: @"") forKey:@"iconPath"];

        if (app.iconImage) {
            [appSpecifier setProperty:app.iconImage forKey:@"iconImage"];
        }

        NSNumber *state = appsState[app.bundleID];
        [appSpecifier setProperty:(state ?: @NO) forKey:@"defaultValue"];
        [specifiers addObject:appSpecifier];
    }

    PSSpecifier *resetGroup = [PSSpecifier groupSpecifierWithName:@"其他设置"];
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
    return [self.allApps filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *bindings) {
            return [app.type isEqualToString:type];
        }]];
}

- (id)globalEnabled:(PSSpecifier *)specifier
{
    NSNumber *value = [self configuration][kEnabledKey];
    return value ?: @YES;
}

- (void)setGlobalEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier
{
    NSMutableDictionary *config = [self configuration];
    config[kEnabledKey] = @([value boolValue]);
    [self saveConfiguration:config];
}

- (void)categoryChanged:(UISegmentedControl *)sender
{
    self.selectedCategory = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:self.selectedCategory forKey:kCategoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)appEnabled:(PSSpecifier *)specifier
{
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];
    if (bundleID.length == 0) {
        return @NO;
    }

    NSDictionary *apps = [self configuration][kAppsKey];
    NSNumber *state = apps[bundleID];
    return [state isKindOfClass:[NSNumber class]] ? state : @NO;
}

- (void)setAppEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier
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

    // 只要某个应用被显式打开，就保证全局开关默认为开启。
    // 否则很容易出现“设置里开了单应用开关，但整个插件全局关闭”的状态错乱。
    if ([value boolValue]) {
        config[kEnabledKey] = @YES;
    }

    config[kAppsKey] = apps;
    [self saveConfiguration:config];
}

- (void)resetSettings
{
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[kEnabledKey] = @NO;
    config[kAppsKey] = @{};
    [self saveConfiguration:config];

    self.selectedCategory = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kCategoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
