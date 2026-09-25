#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#import "AppScanner.h"

static NSString * const kPreferencesPath =
    @"/var/mobile/Library/Preferences/com.mg.adskip.plist";

static NSString * const kEnabledKey = @"Enabled";
static NSString * const kAppsKey = @"Apps";
static NSString * const kCategoryKey = @"AppCategory";
static NSString * const kAppCachePath = @"/var/mobile/Library/Preferences/com.mg.adskip.appcache.plist";

@interface AdSkipRootListController : PSListController

@property(nonatomic, strong) NSArray<ADSkipApp *> *allApps;
@property(nonatomic, assign) NSInteger selectedCategory;
@property(nonatomic, strong) UISegmentedControl *categoryControl;

@end

@implementation AdSkipRootListController

- (instancetype)init
{
    self = [super init];
    if (self) {
        _selectedCategory = [[NSUserDefaults standardUserDefaults] integerForKey:kCategoryKey];
        if (_selectedCategory < 0 || _selectedCategory > 2) {
            _selectedCategory = 0;
        }
        _allApps = [self loadCachedApplications];
    }
    return self;
}

- (NSArray<ADSkipApp *> *)loadCachedApplications
{
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kAppCachePath];
    NSArray *items = [root[@"apps"] isKindOfClass:[NSArray class]] ? root[@"apps"] : nil;
    if (items.count == 0) {
        return @[];
    }

    NSMutableArray *apps = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *bundleID = item[@"bundleID"];
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) continue;

        ADSkipApp *app = [ADSkipApp new];
        app.bundleID = bundleID;
        app.displayName = [item[@"displayName"] isKindOfClass:[NSString class]] ? item[@"displayName"] : bundleID;
        app.type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"store";
        app.iconPath = [item[@"iconPath"] isKindOfClass:[NSString class]] ? item[@"iconPath"] : nil;

        NSData *iconData = [item[@"iconPNG"] isKindOfClass:[NSData class]] ? item[@"iconPNG"] : nil;
        if (iconData.length > 0) {
            app.iconImage = [UIImage imageWithData:iconData scale:[UIScreen mainScreen].scale];
        }
        [apps addObject:app];
    }

    return apps;
}

- (void)saveApplicationCache:(NSArray<ADSkipApp *> *)apps
{
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:apps.count];
    for (ADSkipApp *app in apps) {
        if (app.bundleID.length == 0) continue;
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"bundleID"] = app.bundleID;
        item[@"displayName"] = app.displayName ?: app.bundleID;
        item[@"type"] = app.type ?: @"store";
        if (app.iconPath.length) item[@"iconPath"] = app.iconPath;
        if (app.iconImage) {
            NSData *png = UIImagePNGRepresentation(app.iconImage);
            if (png.length) item[@"iconPNG"] = png;
        }
        [items addObject:item];
    }
    NSDictionary *root = @{ @"version": @1, @"apps": items };
    [root writeToFile:kAppCachePath atomically:YES];
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

    // Do not scan applications while Settings is opening. App discovery and
    // icon decoding run on a utility queue instead of blocking the UI thread.
    [self startApplicationScanIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self startApplicationScanIfNeeded];
}

- (void)startApplicationScanIfNeeded
{
    static BOOL scanning = NO;
    if (scanning) {
        return;
    }

    // Cached applications are used immediately to make the controller open
    // without waiting. Always refresh in the background so newly installed or
    // removed apps appear on the next refresh without blocking Settings.
    scanning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<ADSkipApp *> *apps = [AppScanner scanApplications];
        dispatch_async(dispatch_get_main_queue(), ^{
            scanning = NO;
            self.allApps = apps ?: @[];
            [self saveApplicationCache:self.allApps];
            _specifiers = nil;
            [self reloadSpecifiers];
        });
    });
}

#pragma mark - Category header

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
    // Do not call an optional/private PSListController implementation here.
    // Returning a fixed native-style height avoids selector/runtime issues.
    return section == 1 ? 50.0 : 22.0;
}

#pragma mark - Specifiers

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }
    return _specifiers;
}

- (NSMutableDictionary *)configuration
{
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    NSMutableDictionary *config = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];

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
    // Keep the plist file as the single source used by the tweak, while also
    // updating CFPreferences so both PreferenceLoader and injected processes
    // see the same values immediately.
    [configuration writeToFile:kPreferencesPath atomically:YES];

    CFPreferencesSetAppValue(CFSTR("Enabled"),
                             (__bridge CFPropertyListRef)configuration[kEnabledKey],
                             CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("Apps"),
                             (__bridge CFPropertyListRef)configuration[kAppsKey],
                             CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("enabledApps"),
                             (__bridge CFPropertyListRef)configuration[kAppsKey],
                             CFSTR("com.mg.adskip"));
    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));

    // Tell an already-running injected app that its per-app switch changed.
    // The tweak listens on the Darwin notification center, so a relaunch is
    // not required just to apply an enable/disable change.
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.mg.adskip.preferences.changed"),
                                          NULL,
                                          NULL,
                                          true);
}

- (NSMutableArray *)buildSpecifiers
{
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *header = [PSSpecifier groupSpecifierWithName:@"🛡️ 广告跳过"];
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

    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"应用控制"];
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
        [appSpecifier setProperty:(app.iconPath ?: @"") forKey:@"iconPath"];

        // Use a pre-scaled 29x29 image. Passing the original 120/180px PNG
        // makes Preferences enlarge the image and causes adjacent rows to
        // overlap, which is what the previous build showed.
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
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *bindings) {
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

- (void)setGlobalEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier
{
    NSMutableDictionary *config = [self configuration];
    config[kEnabledKey] = @([value boolValue]);
    [self saveConfiguration:config];
}

#pragma mark - Category

- (void)categoryChanged:(UISegmentedControl *)sender
{
    self.selectedCategory = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:self.selectedCategory forKey:kCategoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - App switches

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
    config[kAppsKey] = apps;
    [self saveConfiguration:config];

    // No reload here. The switch has already changed visually and the value
    // is persisted immediately; rebuilding the whole table used to make
    // PreferenceLoader appear to lose the toggle.
}

#pragma mark - Reset

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
