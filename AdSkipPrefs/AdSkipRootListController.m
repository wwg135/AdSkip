#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import "AppScanner.h"

static NSString * const kPreferencesPath = @"/var/mobile/Library/Preferences/com.mg.adskip.plist";
static NSString * const kEnabledKey = @"Enabled";
static NSString * const kAppsKey = @"Apps";
static NSString * const kLegacyAppsKey = @"enabledApps";
static NSString * const kCategoryKey = @"AppCategory";

@interface AdSkipRootListController : PSListController
@property(nonatomic, strong) NSArray<ADSkipApp *> *allApps;
@property(nonatomic, assign) NSInteger selectedCategory;
@property(nonatomic, strong) UISegmentedControl *categoryControl;
@end

@implementation AdSkipRootListController

static NSArray<ADSkipApp *> *sCachedApps;
static BOOL sScanInProgress;
static NSDate *sLastScanAt;

- (instancetype)init {
    self = [super init];
    if (self) {
        _selectedCategory = [[NSUserDefaults standardUserDefaults] integerForKey:kCategoryKey];
        if (_selectedCategory < 0 || _selectedCategory > 2) _selectedCategory = 0;
        _allApps = sCachedApps ?: @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = @"广告跳过";
    self.categoryControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"商店", @"系统"]];
    self.categoryControl.selectedSegmentIndex = self.selectedCategory;
    [self.categoryControl addTarget:self action:@selector(categoryChanged:) forControlEvents:UIControlEventValueChanged];
    [self startApplicationScanIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self startApplicationScanIfNeeded];
}

- (void)hydrateIconForApp:(ADSkipApp *)app {
    if (!app || app.iconImage || !app.iconPath.length) return;
    UIImage *image = [UIImage imageWithContentsOfFile:app.iconPath];
    if (!image) return;
    CGSize size = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    app.iconImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:6.0];
        [path addClip];
        [image drawInRect:(CGRect){CGPointZero, size}];
    }];
}

- (void)startApplicationScanIfNeeded {
    if (sCachedApps.count) {
        self.allApps = sCachedApps;
        for (ADSkipApp *app in self.allApps) [self hydrateIconForApp:app];
        if (sLastScanAt && -[sLastScanAt timeIntervalSinceNow] < 60.0) return;
    }
    if (sScanInProgress) return;
    sScanInProgress = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *apps = [AppScanner scanApplications] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            sScanInProgress = NO;
            sLastScanAt = [NSDate date];
            sCachedApps = [apps copy];
            self.allApps = sCachedApps;
            for (ADSkipApp *app in self.allApps) [self hydrateIconForApp:app];
            if (self.isViewLoaded && self.view.window) {
                self->_specifiers = nil;
                [self reloadSpecifiers];
            }
        });
    });
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 1) return nil;
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    self.categoryControl.selectedSegmentIndex = self.selectedCategory;
    self.categoryControl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.categoryControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.categoryControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [self.categoryControl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [self.categoryControl.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [self.categoryControl.heightAnchor constraintEqualToConstant:32]
    ]];
    return container;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return section == 1 ? 50.0 : 22.0; }

- (NSMutableDictionary *)configuration {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:kPreferencesPath];
    if ([file isKindOfClass:[NSDictionary class]]) [config addEntriesFromDictionary:file];
    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));
    CFTypeRef enabled = CFPreferencesCopyAppValue(CFSTR("Enabled"), CFSTR("com.mg.adskip"));
    CFTypeRef apps = CFPreferencesCopyAppValue(CFSTR("Apps"), CFSTR("com.mg.adskip"));
    CFTypeRef legacy = CFPreferencesCopyAppValue(CFSTR("enabledApps"), CFSTR("com.mg.adskip"));
    if (enabled) config[kEnabledKey] = CFBridgingRelease(enabled);
    if (apps) config[kAppsKey] = CFBridgingRelease(apps);
    else if (legacy) config[kAppsKey] = CFBridgingRelease(legacy);
    if (![config[kEnabledKey] isKindOfClass:[NSNumber class]]) config[kEnabledKey] = @YES;
    if (![config[kAppsKey] isKindOfClass:[NSDictionary class]]) config[kAppsKey] = @{};
    return config;
}

- (void)saveConfiguration:(NSDictionary *)configuration {
    NSDictionary *apps = [configuration[kAppsKey] isKindOfClass:[NSDictionary class]] ? configuration[kAppsKey] : @{};
    NSNumber *enabled = [configuration[kEnabledKey] isKindOfClass:[NSNumber class]] ? configuration[kEnabledKey] : @YES;
    NSMutableDictionary *normalized = [configuration mutableCopy];
    normalized[kEnabledKey] = enabled;
    normalized[kAppsKey] = apps;
    normalized[kLegacyAppsKey] = apps;
    [normalized writeToFile:kPreferencesPath atomically:YES];
    CFPreferencesSetAppValue(CFSTR("Enabled"), (__bridge CFPropertyListRef)enabled, CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("Apps"), (__bridge CFPropertyListRef)apps, CFSTR("com.mg.adskip"));
    CFPreferencesSetAppValue(CFSTR("enabledApps"), (__bridge CFPropertyListRef)apps, CFSTR("com.mg.adskip"));
    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.mg.adskip.preferences.changed"), NULL, NULL, true);
}

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [[self buildSpecifiers] mutableCopy];
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *result = [NSMutableArray array];
    [result addObject:[PSSpecifier groupSpecifierWithName:@"🛡️ 广告跳过"]];
    [result addObject:[PSSpecifier preferenceSpecifierNamed:@"启用插件" target:self set:@selector(setGlobalEnabled:specifier:) get:@selector(globalEnabled:) detail:nil cell:PSSwitchCell edit:nil]];
    [result addObject:[PSSpecifier groupSpecifierWithName:@"应用控制"]];
    NSDictionary *states = [self configuration][kAppsKey];
    for (ADSkipApp *app in [self filteredApps]) {
        [self hydrateIconForApp:app];
        PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:(app.displayName ?: app.bundleID) target:self set:@selector(setAppEnabled:specifier:) get:@selector(appEnabled:) detail:nil cell:PSSwitchCell edit:nil];
        [s setProperty:app.bundleID forKey:@"bundleID"];
        [s setProperty:app.type forKey:@"appType"];
        [s setProperty:(app.iconPath ?: @"") forKey:@"iconPath"];
        if (app.iconImage) [s setProperty:app.iconImage forKey:@"iconImage"];
        NSNumber *state = states[app.bundleID];
        [s setProperty:([state isKindOfClass:[NSNumber class]] ? state : @NO) forKey:@"defaultValue"];
        [result addObject:s];
    }
    [result addObject:[PSSpecifier groupSpecifierWithName:@"其他设置"]];
    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"重置设置" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    reset.buttonAction = @selector(resetSettings);
    [result addObject:reset];
    return result;
}

- (NSArray *)filteredApps {
    if (self.selectedCategory == 0) return self.allApps;
    NSString *type = self.selectedCategory == 1 ? @"store" : @"system";
    return [self.allApps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ADSkipApp *app, NSDictionary *_) { return [app.type isEqualToString:type]; }]];
}

- (id)globalEnabled:(PSSpecifier *)specifier { return [self configuration][kEnabledKey] ?: @YES; }
- (void)setGlobalEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *config = [self configuration];
    config[kEnabledKey] = @([value boolValue]);
    [self saveConfiguration:config];
}

- (void)categoryChanged:(UISegmentedControl *)sender {
    self.selectedCategory = sender.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:self.selectedCategory forKey:kCategoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (id)appEnabled:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"bundleID"];
    NSNumber *state = [self configuration][kAppsKey][bid];
    return [state isKindOfClass:[NSNumber class]] ? state : @NO;
}

- (void)setAppEnabled:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"bundleID"];
    if (!bid.length) return;
    NSMutableDictionary *config = [self configuration];
    NSMutableDictionary *apps = [config[kAppsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    apps[bid] = @([value boolValue]);
    config[kAppsKey] = apps;
    if ([value boolValue]) config[kEnabledKey] = @YES;
    [self saveConfiguration:config];
}

- (void)resetSettings {
    [self saveConfiguration:@{kEnabledKey:@NO, kAppsKey:@{}}];
    self.selectedCategory = 0;
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:kCategoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    _specifiers = nil;
    [self reloadSpecifiers];
}
@end
