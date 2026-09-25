#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDEvent.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <CoreMotion/CoreMotion.h>

#ifdef ADSKIP_LOG
#define ADLOG(fmt, ...) NSLog(@"[AdSkip] " fmt, ##__VA_ARGS__)
#else
#define ADLOG(fmt, ...) ((void)0)
#endif

static NSTimeInterval nowTs(void) {
    return [[NSDate date] timeIntervalSinceReferenceDate];
}

static NSTimeInterval gSessionStart = 0;
static BOOL gSessionActive = NO;
static BOOL gColdSession = YES;
static BOOL gSkipFired = NO;
static CFRunLoopTimerRef gEngineTimer = NULL;
static int gTickCount = 0;
static int gIdleTicks = 0;
static int gSessionTaps = 0;
static UIView *gLastTappedView = nil;
static int gTapRetry = 0;
static BOOL gSignalSeen = NO;
static NSTimeInterval gLastOcrTime = 0;
static int gOcrShots = 0;
static NSTimeInterval gLastHID = 0;
static BOOL gAdContainerSeen = NO;


static BOOL isKeyboardProcess(void) {
    NSString *pbid = [NSBundle mainBundle].bundleIdentifier.lowercaseString;
    if (pbid.length && ([pbid containsString:@".keyboard"] || [pbid containsString:@"inputmethod"]
        || [pbid hasSuffix:@".ime"])) return YES;
    return NO;
}static BOOL gCountdownTarget = NO;

// ============ 用户级配置（Enabled + Apps） ============

static BOOL gUserDisabled = NO;
static NSDictionary *gEnabledApps = nil;
static NSArray *gUserExcluded = nil;
static CFNotificationCenterRef gAdSkipDarwinCenter = NULL;

static NSString *adSkipBundleID(void)
{
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    return bid.length ? bid : @"";
}

static NSDictionary *adSkipDictionaryValue(CFPropertyListRef value)
{
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        return nil;
    }

    id obj = CFBridgingRelease(CFRetain(value));
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSDictionary *loadAdSkipPreferences(void)
{
    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    // 优先用 plist 做主数据源，避免 cfprefsd 缓存导致旧值覆盖
    NSString *path = @"/var/mobile/Library/Preferences/com.mg.adskip.plist";
    NSDictionary *fileConfig = [NSDictionary dictionaryWithContentsOfFile:path];
    if ([fileConfig isKindOfClass:[NSDictionary class]]) {
        [config addEntriesFromDictionary:fileConfig];
    }

    CFPreferencesAppSynchronize(CFSTR("com.mg.adskip"));

    CFPropertyListRef enabled = CFPreferencesCopyAppValue(CFSTR("Enabled"), CFSTR("com.mg.adskip"));
    CFPropertyListRef apps = CFPreferencesCopyAppValue(CFSTR("Apps"), CFSTR("com.mg.adskip"));
    CFPropertyListRef legacyApps = CFPreferencesCopyAppValue(CFSTR("enabledApps"), CFSTR("com.mg.adskip"));

    if (enabled) {
        id value = CFBridgingRelease(enabled);
        if ([value isKindOfClass:[NSNumber class]]) {
            config[@"Enabled"] = value;
        }
    }

    NSDictionary *appsDict = adSkipDictionaryValue(apps);
    NSDictionary *legacyDict = adSkipDictionaryValue(legacyApps);

    if ([appsDict isKindOfClass:[NSDictionary class]] && appsDict.count > 0) {
        config[@"Apps"] = appsDict;
    } else if ([legacyDict isKindOfClass:[NSDictionary class]] && legacyDict.count > 0) {
        config[@"Apps"] = legacyDict;
    }

    if (![config[@"Enabled"] isKindOfClass:[NSNumber class]]) {
        config[@"Enabled"] = @YES;
    }

    if (![config[@"Apps"] isKindOfClass:[NSDictionary class]]) {
        config[@"Apps"] = @{};
    }

    return config;
}

static void loadUserConfig(void)
{
    NSDictionary *config = loadAdSkipPreferences();

    NSNumber *enabled = config[@"Enabled"];
    gUserDisabled = enabled ? ![enabled boolValue] : NO;

    NSDictionary *apps = config[@"Apps"];
    gEnabledApps = [apps isKindOfClass:[NSDictionary class]] ? [apps copy] : @{};

    NSArray *excluded = config[@"excludedBundles"];
    gUserExcluded = [excluded isKindOfClass:[NSArray class]] ? [excluded copy] : @[];

    NSNumber *legacyDisabled = config[@"disabled"];
    if ([legacyDisabled isKindOfClass:[NSNumber class]] &&
        [legacyDisabled boolValue]) {
        gUserDisabled = YES;
    }

    NSString *bid = adSkipBundleID();
    NSNumber *state = gEnabledApps[bid];

    ADLOG(@"config bundle=%@ enabled=%@ appState=%@ apps=%@",
          bid,
          enabled ?: @YES,
          state ?: @NO,
          gEnabledApps);
}

static BOOL userExcludedBundle(void)
{
    NSString *bid = adSkipBundleID();

    if (gUserDisabled) {
        return YES;
    }

    if ([bid isEqualToString:@"com.apple.Preferences"] ||
        [bid isEqualToString:@"com.apple.springboard"]) {
        return YES;
    }

    for (NSString *excluded in gUserExcluded) {
        if ([excluded isKindOfClass:[NSString class]] &&
            [bid caseInsensitiveCompare:excluded] == NSOrderedSame) {
            return YES;
        }
    }

    return NO;
}

static BOOL adSkipEnabledForCurrentApp(void)
{
    loadUserConfig();

    if (gUserDisabled) {
        return NO;
    }

    NSString *bid = adSkipBundleID();
    if (bid.length == 0) {
        return NO;
    }

    if ([bid isEqualToString:@"com.apple.Preferences"] ||
        [bid isEqualToString:@"com.apple.springboard"]) {
        return NO;
    }

    NSNumber *state = gEnabledApps[bid];
    if (![state isKindOfClass:[NSNumber class]]) {
        ADLOG(@"disabled: no Apps entry for bundle=%@", bid);
        return NO;
    }

    BOOL enabled = [state boolValue];
    ADLOG(@"enabled check bundle=%@ result=%d", bid, enabled);
    return enabled;
}

static void stopEngineTimer(void);
static void startEngineTimer(void);

static void adSkipPreferencesChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo)
{
    loadUserConfig();
    ADLOG(@"preferences changed, refresh config");
}

static void beginSession(BOOL cold) {
    stopEngineTimer();
    gSessionStart = nowTs();
    gColdSession = cold;
    gSessionActive = YES;
    gSkipFired = NO;
    gTickCount = 0;
    gIdleTicks = 0;
    gSessionTaps = 0;
    gLastTappedView = nil;
    gTapRetry = 0;
    gSignalSeen = NO;
    gAdContainerSeen = NO;
    gCountdownTarget = NO;
    gLastOcrTime = 0;
    gOcrShots = 0;

    // Do not wait for a UILabel/UIButton/ad-container hook to wake the engine.
    // Some ads are rendered by WKWebView, Metal, CALayer or custom SwiftUI
    // views and therefore produce no useful Objective-C text hook. Starting
    // the short-lived polling engine at session start guarantees those apps
    // still get a chance to be detected after injection.
    startEngineTimer();
}

static void endSession(void) {
    stopEngineTimer();
    gSessionActive = NO;
    gSkipFired = NO;
    gAdContainerSeen = NO;
    gLastTappedView = nil;
}

// 广告窗口判定：hook 热路径第一道门，必须最便宜（两次布尔 + 两次浮点比较）
static BOOL inAdWindow(void) {
    if (!adSkipEnabledForCurrentApp()) {
        return NO;
    }

    if (isKeyboardProcess()) return NO;   // keyboard extension processes never active
    if (!gSessionActive || gSkipFired) return NO;

    NSTimeInterval e = nowTs() - gSessionStart;
    return e >= 0 && e <= (gColdSession ? 30.0 : 15.0);
}

// 一级「跳过」：正常 UI 里几乎不存在（新手引导除外），门控稍宽
static BOOL containsSkipWordStrict(NSString *s) {
    if (!s.length || s.length > 40) return NO;
    if ([s containsString:@"跳过"] || [s containsString:@"跳過"]) return YES;
    NSString *low = s.lowercaseString;
    NSRange r = [low rangeOfString:@"skip"];
    while (r.location != NSNotFound) {
        NSUInteger st = r.location;
        NSUInteger en = r.location + r.length;
        BOOL leftOK = (st == 0)
            || ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:[low characterAtIndex:st - 1]];
        BOOL rightOK = (en >= low.length)
            || ![[NSCharacterSet alphanumericCharacterSet] characterIsMember:[low characterAtIndex:en]];
        if (leftOK && rightOK) return YES;
        if (en >= low.length) break;
        NSRange rest = NSMakeRange(en, low.length - en);
        r = [low rangeOfString:@"skip" options:0 range:rest];
    }
    if ([s containsString:@">>"]) return YES;
    return NO;
}

// 二级「关闭」：正常 UI 里到处都是，必须容器确认（gAdContainerSeen）才允许命中。
// 调用方负责先确认容器——本函数只管词，门控在 gateCloseTap。
static BOOL containsCloseWord(NSString *s) {
    if (!s.length || s.length > 40) return NO;
    if ([s containsString:@"关闭"] || [s containsString:@"關閉"] || [s containsString:@"關闭"] || [s containsString:@"闭广"] || [s containsString:@"閉廣"]) return YES;
    if ([s rangeOfString:@"close" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

// 「跳过 3 / 3s跳过 / 3 | 跳过 / 跳过广告5」：剥离数字/空白/分隔符后匹配任一级词表
static BOOL containsCountdownSkipWord(NSString *s) {
    if (!s.length || s.length > 40) return NO;
    NSMutableString *stripped = [s mutableCopy];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < stripped.length; i++) {
        unichar c = [stripped characterAtIndex:i];
        if ([digits characterIsMember:c] || [ws characterIsMember:c]) continue;
        [out appendFormat:@"%C", c];
    }
    stripped = out;
    for (NSString *sep in @[@"|", @"s", @"S", @"秒"]) {
        [stripped replaceOccurrencesOfString:sep withString:@"" options:0 range:NSMakeRange(0, stripped.length)];
    }
    return containsSkipWordStrict(stripped) || containsCloseWord(stripped);
}

static BOOL isSplashAdClass(UIView *v);   // 前向声明（定义在下方 Splash 词根区）

// 二级门控：关字命中 → 只在容器已确认（或当前视图本身就在确认容器内）才放行
static BOOL gateCloseTap(UIView *v) {
    if (gAdContainerSeen) return YES;
    // 视图祖先链上有 splash 容器 → 等价容器确认（setText 可能早于容器标记）
    UIView *cur = v;
    for (int i = 0; i < 8 && cur; i++) {
        if (isSplashAdClass(cur)) { gAdContainerSeen = YES; return YES; }
        cur = cur.superview;
    }
    return NO;
}

// 图像 close 无文字：容器确认 + UIControl + 小尺寸 + 角落先验区（右上/右下）
static BOOL plausibleCloseCorner(UIView *v) {
    UIWindow *w = v.window;
    if (!w) return NO;
    CGRect fr = [w convertRect:v.bounds fromView:v];
    CGFloat scrW = w.bounds.size.width, scrH = w.bounds.size.height;
    if (scrW < 100 || scrH < 100) return NO;
    CGFloat cx = CGRectGetMidX(fr), cy = CGRectGetMidY(fr);
    BOOL corner = (cx > scrW * 0.6 && cy < scrH * 0.30) || (cx > scrW * 0.6 && cy > scrH * 0.70);
    return corner;
}

static BOOL isSkipButtonClass(UIView *v) {
    if (!v) return NO;
    NSString *low = NSStringFromClass([v class]).lowercaseString;
    if (!low.length) return NO;
    if ([low containsString:@"skip"]) return YES;
    if ([low containsString:@"跳过"] || [low containsString:@"跳過"]) return YES;
    return NO;
}

// 全行业通用词根（认词根不认 SDK 前缀：Splash/Skip 是全行业词根，QAD/BU/CSJ 是各家前缀）
static BOOL isSplashAdClass(UIView *v) {
    if (!v) return NO;
    NSString *low = NSStringFromClass([v class]).lowercaseString;
    if (!low.length) return NO;
    if ([low containsString:@"splash"]) return YES;
    if ([low containsString:@"launchad"] || [low containsString:@"launch_ad"]) return YES;
    if ([low containsString:@"adsplash"] || [low containsString:@"ad_splash"]) return YES;
    if ([low containsString:@"开屏"] || [low containsString:@"開屏"]) return YES;
    if ([low containsString:@"adview"] || [low containsString:@"adcontainer"] || [low containsString:@"advert"]) return YES;
    if ([low containsString:@"shakead"] || [low containsString:@"shake_ad"] || [low containsString:@"shakeview"]) return YES;
    if ([low containsString:@"yaoyao"] || [low containsString:@"yao_yao"]) return YES;
    return NO;
}

static NSString *viewTextOf(UIView *v) {
    NSString *t = nil;
    @try { t = [v valueForKey:@"currentTitle"]; if (t.length) return [t copy]; } @catch (NSException *e) {}
    @try { t = [v valueForKey:@"text"]; if (t.length) return [t copy]; } @catch (NSException *e) {}
    @try {
        t = [v valueForKey:@"attributedText"];
        if ([t isKindOfClass:[NSAttributedString class]] && ((NSAttributedString *)t).string.length) return [((NSAttributedString *)t).string copy];
    } @catch (NSException *e) {}
    @try {
        t = [v valueForKey:@"currentAttributedTitle"];
        if ([t isKindOfClass:[NSAttributedString class]] && ((NSAttributedString *)t).string.length) return [((NSAttributedString *)t).string copy];
    } @catch (NSException *e) {}
    @try { t = [v valueForKey:@"accessibilityLabel"]; if (t.length) return [t copy]; } @catch (NSException *e) {}
    @try { t = [v valueForKey:@"accessibilityValue"]; if (t.length) return [t copy]; } @catch (NSException *e) {}
    @try {
        id lab = [v valueForKey:@"titleLabel"];
        if (lab) { t = [lab valueForKey:@"text"]; if (t.length) return [t copy]; }
    } @catch (NSException *e) {}
    return nil;
}

// ============ 只读搜索（纯查询，无副作用） ============
static UIView *findSkipViewInHierarchy(UIView *v, int depth) {
    if (!v || depth > 14 || v.hidden || v.alpha < 0.05) return nil;
    NSString *txt = viewTextOf(v);
    if (txt.length && containsSkipWordStrict(txt)) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (w >= 13 && h >= 13 && w < 600 && h < 600) return v;  // v3.2.4: 20→13 与 eventGatePass 一致
    }
    for (UIView *sub in v.subviews) {
        UIView *hit = findSkipViewInHierarchy(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIView *gFoundContainer = nil;

static BOOL gScreenChecked = NO;
static CGFloat gScrW = 0, gScrH = 0;

static void cacheScreenSize(void) {
    if (gScreenChecked) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    gScrW = sb.size.width; gScrH = sb.size.height;
    gScreenChecked = YES;
}

// 真开屏容器必覆盖屏幕 ≥80%（直播吧首页广告卡片类名含 adview 词根但只占一格——
// 非全屏的"广告位组件"绝不是开屏容器，绝不能开锁/采样）
static BOOL isFullscreenish(UIView *v) {
    if (!v) return NO;
    cacheScreenSize();
    if (gScrW < 100 || gScrH < 100) return NO;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    return (w * h) >= (gScrW * gScrH * 0.80);
}

static void findSplashContainerRec(UIView *v, int depth) {
    if (gFoundContainer || !v || depth > 12 || v.hidden || v.alpha < 0.05) return;
    if (isSplashAdClass(v)) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (w > 100 && h > 100 && isFullscreenish(v)) { gFoundContainer = v; return; }
    }
    for (UIView *sub in v.subviews) findSplashContainerRec(sub, depth + 1);
}

static UIView *findSkipButtonInView(UIView *v, int depth) {
    if (!v || depth > 16 || v.hidden || v.alpha < 0.05) return nil;
    if (isSkipButtonClass(v)) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (w >= 13 && h >= 13 && w < 400 && h < 400) return v;  // v3.2.4: 20→13 与 eventGatePass 一致
    }
    for (UIView *sub in v.subviews) {
        UIView *hit = findSkipButtonInView(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

// 广告主图 = 点击跳转落地页的按钮（优酷误点跳拼多多根因），绝不能当 close 点。
// 收集全部候选可点控件，按 close 特征打分，只点最高分且 ≥3 分的：
//   +3 角落先验区（右上/右下）；+2 带跳过/关闭词根文字；+2 小面积(<容器8%)；
//   -5 大面积(>容器25%，=主图)；-4 居中(主图特征)；-3 有 WKWebView 祖先(H5 落地页)
static UIView *gBestCloseView = nil;
static int gBestCloseScore = 0;
static CGFloat gCloseCtxW = 0, gCloseCtxH = 0;

static void scoreCloseCandidate(UIView *v) {
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    CGFloat areaRatio = (w * h) / (gCloseCtxW * gCloseCtxH);
    if (areaRatio > 0.25) return;   // 主图，直接淘汰
    int score = 0;
    if (areaRatio < 0.08) score += 2;
    if (plausibleCloseCorner(v)) score += 3;
    NSString *txt = viewTextOf(v);
    if (txt.length && (containsSkipWordStrict(txt) || containsCloseWord(txt))) score += 2;
    // 居中大控件 = 主图特征
    UIView *sup = v.superview;
    if (sup) {
        CGFloat cx = CGRectGetMidX(v.frame), cy = CGRectGetMidY(v.frame);
        BOOL centered = fabs(cx - sup.bounds.size.width/2) < sup.bounds.size.width*0.15
                     && fabs(cy - sup.bounds.size.height/2) < sup.bounds.size.height*0.15;
        if (centered && areaRatio > 0.10) score -= 4;
    }
    if (score > gBestCloseScore) { gBestCloseScore = score; gBestCloseView = v; }
}

static void findCloseCandidatesRec(UIView *v, int depth) {
    if (!v || depth > 16 || v.hidden || v.alpha < 0.05) return;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    if (w >= 13 && h >= 13 && w <= 300 && h <= 300) {  // v3.2.4: 20→13（主图25%淘汰线不变）
        Class ctrlCls = NSClassFromString(@"UIControl");
        BOOL isCtrl = (ctrlCls && [v isKindOfClass:ctrlCls]);
        BOOL hasTap = NO;
        Class tapCls = NSClassFromString(@"UITapGestureRecognizer");
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (tapCls && [g isKindOfClass:tapCls]) { hasTap = YES; break; }
        }
        if (isCtrl || hasTap) scoreCloseCandidate(v);
    }
    for (UIView *sub in v.subviews) findCloseCandidatesRec(sub, depth + 1);
}

// 及格线 3 分：角落(+3) 或 小面积(+2)+词根(+2)——纯"随机小控件"永远不够格
static UIView *findBestCloseButton(UIView *container) {
    if (!container || container.bounds.size.width < 50) return nil;
    gBestCloseView = nil; gBestCloseScore = 0;
    gCloseCtxW = container.bounds.size.width; gCloseCtxH = container.bounds.size.height;
    @try { findCloseCandidatesRec(container, 0); } @catch (NSException *e) { return nil; }
    return (gBestCloseScore >= 3) ? gBestCloseView : nil;
}

// 先锚定 Splash 容器再找按钮（准确）；无容器才全树找 Skip 词根按钮
static UIView *findSkipViewByClassName(UIWindow *win) {
    if (!win) return nil;
    @try {
        gFoundContainer = nil;
        findSplashContainerRec(win, 0);
        if (gFoundContainer) {
            UIView *btn = findSkipButtonInView(gFoundContainer, 0);
            if (btn) return btn;
            btn = findBestCloseButton(gFoundContainer);
            if (btn) return btn;
        }
        return findSkipButtonInView(win, 0);
    } @catch (NSException *e) {
        return nil;
    }
}

static CALayer *findSkipTextLayerInLayer(CALayer *layer, int depth) {
    if (!layer || depth > 16) return nil;
    @try {
        id s = nil;
        @try { s = [layer valueForKey:@"string"]; } @catch (NSException *e) {}
        if (![s isKindOfClass:[NSString class]]) {
            @try { s = [layer valueForKey:@"name"]; } @catch (NSException *e) {}
        }
        if ([s isKindOfClass:[NSString class]] && containsSkipWordStrict((NSString *)s)) return layer;
        for (CALayer *sub in layer.sublayers) {
            CALayer *hit = findSkipTextLayerInLayer(sub, depth + 1);
            if (hit) return hit;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ============ 触摸层：直调 touches + HID 物理注入 + KIF 合成（保留 2.x 验证过的实现） ============
static void spinRunLoop(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static IOHIDEventRef buildHidEventForTouch(CGPoint pt, CGSize screenSize, NSUInteger phase, double uptime) {
    IOHIDFloat nx = (IOHIDFloat)(pt.x / screenSize.width);
    IOHIDFloat ny = (IOHIDFloat)(pt.y / screenSize.height);
    AbsoluteTime ts; memset(&ts, 0, sizeof(ts));
    uint64_t ns = (uint64_t)(uptime * 1000000000.0);
    ts.hi = (UInt32)(ns >> 32); ts.lo = (UInt32)(ns & 0xFFFFFFFF);
    Boolean touch = (phase != 3);
    IOHIDFloat pressure = (phase == 3) ? 0.0f : 1.0f;
    uint32_t eventMask = kIOHIDDigitizerEventTouch;
    if (phase == 1) eventMask |= kIOHIDDigitizerEventPosition;
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kIOHIDDigitizerTransducerTypeHand,
        0, 0, eventMask, 0,
        nx, ny, 0, pressure, 0,
        touch, touch, 0);
    if (!parent) return NULL;
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
        kCFAllocatorDefault, ts,
        1, 2, eventMask,
        nx, ny, 0, pressure, 0,
        5.0f, 5.0f, 1.0f, 5.0f, 1.0f,
        touch, touch, 0);
    if (finger) {
        IOHIDEventAppendEvent(parent, finger);
        CFRelease(finger);
    }
    return parent;
}

static id makeKFITouch(UIView *view, CGPoint windowPoint) {
    @try {
        Class touchCls = objc_getClass("UITouch");
        if (!touchCls) return nil;
        id touch = [[touchCls alloc] init];
        if (!touch) return nil;
        UIWindow *w = view ? view.window : nil;
        if (!w) {
            id app = [UIApplication performSelector:@selector(sharedApplication)];
            w = [app performSelector:@selector(keyWindow)];
        }
        SEL s;
        s = NSSelectorFromString(@"setWindow:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,id))objc_msgSend)(touch, s, w);
        s = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,CGPoint,BOOL))objc_msgSend)(touch, s, windowPoint, YES);
        else [touch setValue:[NSValue valueWithCGPoint:windowPoint] forKey:@"_locationInWindow"];
        if (view) {
            s = NSSelectorFromString(@"setView:");
            if ([touch respondsToSelector:s]) ((void(*)(id,SEL,id))objc_msgSend)(touch, s, view);
        }
        s = NSSelectorFromString(@"_setIsFirstTouchForView:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,BOOL))objc_msgSend)(touch, s, YES);
        s = NSSelectorFromString(@"setIsTap:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,BOOL))objc_msgSend)(touch, s, YES);
        s = NSSelectorFromString(@"setTapCount:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, s, 1);
        s = NSSelectorFromString(@"setGestureView:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,id))objc_msgSend)(touch, s, view);
        return touch;
    } @catch (NSException *e) {
        return nil;
    }
}

static id makeKFIEvent(id touch, CGPoint pt, CGSize sz, NSUInteger phase, double uptime) {
    @try {
        Class evtCls = objc_getClass("UIEvent");
        if (!evtCls) return nil;
        id event = [[evtCls alloc] init];
        if (!event) return nil;
        @try { [event setValue:@[touch] forKey:@"_touches"]; } @catch (NSException *e) {}
        IOHIDEventRef hid = buildHidEventForTouch(pt, sz, phase, uptime);
        if (hid) {
            SEL sh = NSSelectorFromString(@"_setHIDEvent:");
            if ([event respondsToSelector:sh]) ((void(*)(id,SEL,IOHIDEventRef))objc_msgSend)(event, sh, hid);
            if ([touch respondsToSelector:sh]) ((void(*)(id,SEL,IOHIDEventRef))objc_msgSend)(touch, sh, hid);
            CFRelease(hid);
        }
        return event;
    } @catch (NSException *e) {
        return nil;
    }
}

static BOOL kfiSendEvent(id event) {
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app || !event) return NO;
        [app performSelector:@selector(sendEvent:) withObject:event];
        spinRunLoop(0.05);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

static void simulateTapAtWindowPoint(UIWindow *win, CGPoint pt) {
    if (!win) return;
    @try {
        UIView *hitView = [win hitTest:pt withEvent:nil];
        UIWindow *w = (UIWindow *)(hitView ? hitView.window : win);
        UIView *targetView = hitView ?: (UIView *)win;
        id touch = makeKFITouch(targetView, pt);
        if (!touch) return;
        NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
        CGSize sz = w.bounds.size;
        SEL ph = NSSelectorFromString(@"setPhase:");
        SEL ts = NSSelectorFromString(@"setTimestamp:");
        if ([touch respondsToSelector:ph]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, ph, 0);
        if ([touch respondsToSelector:ts]) ((void(*)(id,SEL,double))objc_msgSend)(touch, ts, uptime);
        id eBegan = makeKFIEvent(touch, pt, sz, 0, uptime);
        if (eBegan) kfiSendEvent(eBegan);
        CGPoint jitter = CGPointMake(pt.x + 0.5, pt.y + 0.5);
        SEL ml = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
        if ([touch respondsToSelector:ml]) ((void(*)(id,SEL,CGPoint,BOOL))objc_msgSend)(touch, ml, jitter, NO);
        if ([touch respondsToSelector:ph]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, ph, 1);
        if ([touch respondsToSelector:ts]) ((void(*)(id,SEL,double))objc_msgSend)(touch, ts, uptime + 0.04);
        id eMoved = makeKFIEvent(touch, jitter, sz, 1, uptime + 0.04);
        if (eMoved) kfiSendEvent(eMoved);
        if ([touch respondsToSelector:ph]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, ph, 3);
        if ([touch respondsToSelector:ts]) ((void(*)(id,SEL,double))objc_msgSend)(touch, ts, uptime + 0.09);
        id eEnded = makeKFIEvent(touch, jitter, sz, 3, uptime + 0.09);
        if (eEnded) kfiSendEvent(eEnded);
    } @catch (NSException *e) {}
}

// ===== HID 物理注入（AutoTouch 同款，穿越 SDK 反合成触摸检测） =====
static void *(*S_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, Boolean, Boolean, uint32_t, uint32_t) = NULL;
static void *(*S_IOHIDEventCreateDigitizerFingerEventWithQuality)(CFAllocatorRef, uint32_t, uint32_t, uint32_t, uint32_t, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, CFIndex, Boolean, Boolean, uint32_t) = NULL;
static void *(*S_IOHIDEventAppendEvent)(void*, void*) = NULL;

static void initHidSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) return;
        void *a = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        void *b = dlsym(h, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        void *c = dlsym(h, "IOHIDEventAppendEvent");
        if (a) memcpy(&S_IOHIDEventCreateDigitizerEvent, &a, sizeof(a));
        if (b) memcpy(&S_IOHIDEventCreateDigitizerFingerEventWithQuality, &b, sizeof(b));
        if (c) memcpy(&S_IOHIDEventAppendEvent, &c, sizeof(c));
    });
}

static BOOL hidInjectTapAtPoint(UIWindow *win, CGPoint pt) {
    @try {
        NSTimeInterval now = nowTs();
        if (now - gLastHID < 0.25) return NO; // 限速 0.25s（QQ 手势系统崩溃根因）
        initHidSymbols();
        if (!S_IOHIDEventCreateDigitizerEvent) return NO;
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app) return NO;
        CGSize sz = win.bounds.size;
        IOHIDFloat nx = (IOHIDFloat)(pt.x / sz.width);
        IOHIDFloat ny = (IOHIDFloat)(pt.y / sz.height);
        uint64_t ns = (uint64_t)(now * 1000000000.0);
        AbsoluteTime ts; memset(&ts, 0, sizeof(ts));
        ts.hi = (UInt32)(ns >> 32); ts.lo = (UInt32)(ns & 0xFFFFFFFF);
        uint32_t typeHand = 3;
        uint32_t mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange;
        void *parent = S_IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, (uint32_t)ts.hi, typeHand,
            0, 0, mask, 0,
            (CFIndex)nx, (CFIndex)ny, 0, 1,
            true, true, 0, 0);
        if (!parent) return NO;
        SEL hh = NSSelectorFromString(@"_handleHIDEvent:");
        if (![app respondsToSelector:hh]) { CFRelease(parent); return NO; }
        ((void(*)(id,SEL,void*))objc_msgSend)(app, hh, parent);
        // up 事件（时间戳 hi+1，pressure=0）
        void *parentUp = S_IOHIDEventCreateDigitizerEvent(
            kCFAllocatorDefault, (uint32_t)(ts.hi + 100000), typeHand,
            0, 0, mask, 0,
            (CFIndex)nx, (CFIndex)ny, 0, 0,
            false, false, 0, 0);
        if (parentUp) {
            ((void(*)(id,SEL,void*))objc_msgSend)(app, hh, parentUp);
            CFRelease(parentUp);
        }
        CFRelease(parent);
        gLastHID = now;
        spinRunLoop(0.04);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// 直调 touches 回调（自绘按钮通路）：必须传真实 UITouch 塞进 NSSet，传 nil=SDK 取不到空转
static void directTouchesOnView(UIView *v, CGPoint windowPoint) {
    if (!v || !v.window) return;
    @try {
        Class touchCls = objc_getClass("UITouch");
        if (!touchCls) return;
        id touch = [[touchCls alloc] init];
        if (!touch) return;
        UIWindow *w = v.window;
        SEL s;
        s = NSSelectorFromString(@"setWindow:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,id))objc_msgSend)(touch, s, w);
        s = NSSelectorFromString(@"setView:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,id))objc_msgSend)(touch, s, v);
        s = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,CGPoint,BOOL))objc_msgSend)(touch, s, windowPoint, YES);
        else [touch setValue:[NSValue valueWithCGPoint:windowPoint] forKey:@"_locationInWindow"];
        s = NSSelectorFromString(@"setTapCount:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, s, 1);
        s = NSSelectorFromString(@"setPhase:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, s, 0);
        NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
        s = NSSelectorFromString(@"setTimestamp:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,double))objc_msgSend)(touch, s, uptime);
        NSSet *beginSet = [NSSet setWithObject:touch];
        SEL tb = NSSelectorFromString(@"touchesBegan:withEvent:");
        SEL te = NSSelectorFromString(@"touchesEnded:withEvent:");
        UIView *tc = v;
        for (int i = 0; i < 3 && tc; i++) {
            if ([tc respondsToSelector:tb]) ((void(*)(id,SEL,id,id))objc_msgSend)(tc, tb, beginSet, nil);
            tc = tc.superview;
        }
        s = NSSelectorFromString(@"setPhase:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,NSUInteger))objc_msgSend)(touch, s, 3);
        s = NSSelectorFromString(@"setTimestamp:");
        if ([touch respondsToSelector:s]) ((void(*)(id,SEL,double))objc_msgSend)(touch, s, uptime + 0.05);
        UIView *te_v = v;
        for (int i = 0; i < 3 && te_v; i++) {
            if ([te_v respondsToSelector:te]) ((void(*)(id,SEL,id,id))objc_msgSend)(te_v, te, beginSet, nil);
            te_v = te_v.superview;
        }
    } @catch (NSException *e) {}
}

static void tapView(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha < 0.05) return;
    if (gSessionTaps >= 12) return; // 点击预算（防无限攻坚乱触）
    gSessionTaps++;
    // 通道0：父链每层 UIControl 直发 action（解禁倒计时门控后触发）
    BOOL firedAction = NO;
    UIView *cur = v;
    for (int i = 0; i < 6 && cur; i++) {
        if ([cur isKindOfClass:NSClassFromString(@"UIControl")]) {
            UIControl *ctl = (UIControl *)cur;
            @try {
                SEL setEn = NSSelectorFromString(@"setEnabled:");
                if ([ctl respondsToSelector:setEn]) ((void(*)(id,SEL,BOOL))objc_msgSend)(ctl, setEn, YES);
                [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
                [ctl sendActionsForControlEvents:UIControlEventTouchDown];
                [ctl sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
                firedAction = YES;
            } @catch (NSException *e) {}
        }
        cur = cur.superview;
    }
    if (!firedAction) {
        cur = v;
        for (int i = 0; i < 6 && cur; i++) {
            for (UIGestureRecognizer *g in cur.gestureRecognizers) {
                if (!g) continue;
                @try {
                    [g setValue:@3 forKey:@"state"];
                    break;
                } @catch (NSException *e) {}
            }
            cur = cur.superview;
        }
    }
    CGPoint wp = [v.window convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) fromView:v];
    directTouchesOnView(v, wp);
    if (!hidInjectTapAtPoint(v.window, wp)) {
        simulateTapAtWindowPoint(v.window, wp);
    }
}

static void tapPointAtWindow(UIWindow *win, CGPoint p) {
    if (!win) return;
    if (gSessionTaps >= 12) return;
    gSessionTaps++;
    @try {
        if (!hidInjectTapAtPoint(win, p)) {
            UIView *hitV = [win hitTest:p withEvent:nil];
            if (hitV) directTouchesOnView(hitV, p);
            simulateTapAtWindowPoint(win, p);
        }
    } @catch (NSException *e) {}
}

// ============ 事件驱动识别（秒跳核心：信号出现瞬间点击，0 轮询延迟） ============
// 位置门控：跳过按钮只在顶部条（<28% 高）或右侧区（>40% 宽）出现。
// 主界面正中的"跳过"（游戏引导/教程）不在此区，双保险防误触。
static BOOL plausibleSkipPosition(UIView *v) {
    UIWindow *w = v.window;
    if (!w) return NO;
    CGRect fr = [w convertRect:v.bounds fromView:v];
    CGFloat scrW = w.bounds.size.width, scrH = w.bounds.size.height;
    if (scrW < 100 || scrH < 100) return NO;
    CGFloat cx = CGRectGetMidX(fr), cy = CGRectGetMidY(fr);
    BOOL topStrip = cy < scrH * 0.28;
    BOOL rightZone = cx > scrW * 0.40;
    return topStrip || rightZone;
}

// 通用门控（所有事件驱动入口共用）：
// 会话激活 + 广告窗口内 + 未跳过 + 可见 + 尺寸像按钮 + 位置合理 + 非正常UI结构 → tapView
static BOOL eventGatePass(UIView *v, CGFloat maxSide) {
    if (!inAdWindow()) return NO;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    // v3.2.4：minSide 20→13（开云「跳过 1s」标签实测 37x16pt 被 20pt 误杀）
    if (w < 13 || h < 13 || w > maxSide || h > maxSide) return NO;
    if (!plausibleSkipPosition(v)) return NO;
    return YES;
}

// gSignalSeen 仍用于记录是否观察到广告信号；引擎现在由 beginSession 直接启动
static void startEngineTimer(void);
static void engineTimerCallback(CFRunLoopTimerRef timer, void *info);
static void noteSignalAndArmEngine(void) {
    gSignalSeen = YES;
    // beginSession 已经启动引擎；这里不再负责懒启动。
    startEngineTimer();
}

static void handleEventDrivenSkip(UIView *v) {
    if (!inAdWindow()) return;
    if (!v.window) return; // setText 时机可能早于挂载，无 window 就先记信号不点击
    if (!eventGatePass(v, 600)) return;
    NSString *vt = viewTextOf(v);
    if (vt.length && vt.length <= 40) {
        for (NSUInteger ci = 0; ci < vt.length; ci++) {
            unichar ch = [vt characterAtIndex:ci];
            if (ch >= '0' && ch <= '9') { gCountdownTarget = YES; break; }
        }
    }
    noteSignalAndArmEngine();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!inAdWindow()) return;
        if (!v.window || v.hidden || v.alpha < 0.05) return;
        tapView(v);
        gLastTappedView = v;
        gTapRetry = 0;
    });
}

static void handleEventDrivenSkipByClass(UIView *v) {
    if (!inAdWindow()) return;
    if (!eventGatePass(v, 400)) return;
    noteSignalAndArmEngine();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!inAdWindow()) return;
        if (!v.window || v.hidden || v.alpha < 0.05) return;
        tapView(v);
        gLastTappedView = v;
        gTapRetry = 0;
    });
}

// Splash 容器挂载：容器出现即视为广告信号（武装引擎），
// 跳过按钮常异步晚于容器加载 → 0.05/0.2/0.35/0.5s 四次采样
static void handleEventDrivenSplashContainer(UIView *container) {
    if (!inAdWindow()) return;
    noteSignalAndArmEngine();
    NSArray *delays = @[@0.05, @0.2, @0.35, @0.5];
    for (NSNumber *dn in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dn.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!inAdWindow()) return;
            if (!container.window || container.hidden || container.alpha < 0.05) return;
            UIView *btn = findBestCloseButton(container);
            if (btn && btn.window && !btn.hidden && btn.alpha >= 0.05) {
                tapView(btn);
                gLastTappedView = btn;
                gTapRetry = 0;
            }
        });
    }
}

// ============ WebView JS 注入（H5 开屏） ============
@interface AdSkipWV : UIView
- (void)evaluateJavaScript:(NSString *)js completionHandler:(void (^)(id, NSError *))h;
@end

static void findWebViewsInView(UIView *v, int depth, NSMutableArray *out) {
    if (!v || v.hidden || v.alpha < 0.05 || out.count >= 4) return;
    Class wkCls = NSClassFromString(@"WKWebView");
    if (wkCls && [v isKindOfClass:wkCls] && [v respondsToSelector:@selector(evaluateJavaScript:completionHandler:)]) {
        [out addObject:v];
        return;
    }
    for (UIView *sub in v.subviews) findWebViewsInView(sub, depth + 1, out);
}

static NSString *const kSkipJs =
@"(function(){"
"function f(doc){"
"var els=doc.querySelectorAll('a,button,div,span,p,li');"
"var best=null;"
"for(var i=0;i<els.length;i++){"
"var el=els[i];"
"var t=(el.innerText||el.textContent||'').replace(/\\s+/g,'');"
"if(t.length<1||t.length>16)continue;"
// JS 侧同样只认跳过，不认关闭（H5 主界面"关闭"弹窗防误触）
"if(!/^(跳过|跳過|跳過廣告|跳过广告|skip)(.{0,6})?$/i.test(t))continue;"
"var r=el.getBoundingClientRect();"
"if(r.width<15||r.height<15)continue;"
"if(!best||r.top<best.top){best={x:r.left+r.width/2,y:r.top+r.height/2,el:el};}"
"}"
"if(best){"
"var e=best.el;"
"try{e.style.pointerEvents='auto';}catch(_){}"
"try{"
"var o={identifier:1,target:e,clientX:best.x,clientY:best.y,pageX:best.x,pageY:best.y,radiusX:5,radiusY:5,rotationAngle:0,force:1};"
"var t=new Touch(o);"
"e.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
"e.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));"
"}catch(_){}"
"try{e.click();}catch(_){}"
"try{e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:best.x,clientY:best.y}));}catch(_){}"
"return Math.round(best.x)+','+Math.round(best.y);"
"}"
"return '';"
"}"
"var r=f(document);"
"if(!r){var fs=document.querySelectorAll('iframe');for(var i=0;i<fs.length;i++){try{r=f(fs[i].contentDocument);if(r)break;}catch(_){}}}"
"return r;"
"})()";

static void jsTapWebViews(void) {
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app) return;
        NSArray *wins = [app performSelector:@selector(windows)];
        NSMutableArray *wvs = [NSMutableArray array];
        for (UIWindow *w in wins) {
            if (!w || w.hidden) continue;
            findWebViewsInView(w, 0, wvs);
        }
        for (id wk in wvs) {
            UIView *wv = (UIView *)wk;
            [((AdSkipWV *)wk) evaluateJavaScript:kSkipJs completionHandler:^(id result, NSError *err) {
                if (!inAdWindow()) return;
                if (![result isKindOfClass:[NSString class]] || ![(NSString *)result length]) return;
                NSArray *p = [(NSString *)result componentsSeparatedByString:@","];
                if (p.count != 2) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!inAdWindow() || !wv.window) return;
                    CGFloat x = [p[0] floatValue], y = [p[1] floatValue];
                    UIScrollView *sv = nil;
                    @try { sv = [wv valueForKey:@"scrollView"]; } @catch (NSException *e) {}
                    CGPoint wp = CGPointMake(wv.frame.origin.x + x - (sv ? sv.contentOffset.x : 0),
                                             wv.frame.origin.y + y - (sv ? sv.contentOffset.y : 0));
                    tapPointAtWindow(wv.window, wp);
                });
            }];
        }
    } @catch (NSException *e) {}
}

// ============ accessibility 无障碍遍历（识别通道C：专治文字自绘/KVC 读不到） ============
static UIView *gAclFoundView = nil;
static CGRect gAclFoundFrame;
static BOOL gAclFoundFrameValid = NO;

static void aclScan(id container, int depth) {
    if (gAclFoundView || gAclFoundFrameValid || depth > 20) return;
    @try {
        NSInteger cnt = 0;
        SEL sc = NSSelectorFromString(@"accessibilityElementCount");
        if ([container respondsToSelector:sc]) {
            cnt = (NSInteger)((NSUInteger(*)(id,SEL))objc_msgSend)(container, sc);
        }
        for (NSInteger i = 0; i < cnt; i++) {
            SEL sa = NSSelectorFromString(@"accessibilityElementAtIndex:");
            id el = nil;
            if ([container respondsToSelector:sa]) {
                el = ((id(*)(id,SEL,NSInteger))objc_msgSend)(container, sa, i);
            }
            if (!el) continue;
            NSString *label = nil, *value = nil, *hint = nil;
            @try { label = [el accessibilityLabel]; if (![label isKindOfClass:[NSString class]]) label = nil; } @catch (NSException *e) {}
            @try { value = [el accessibilityValue]; if (![value isKindOfClass:[NSString class]]) value = nil; } @catch (NSException *e) {}
            @try { hint = [el accessibilityHint]; if (![hint isKindOfClass:[NSString class]]) hint = nil; } @catch (NSException *e) {}
            BOOL isHit = (label.length && containsSkipWordStrict(label))
                      || (value.length && containsSkipWordStrict(value))
                      || (hint.length && containsSkipWordStrict(hint));
            if (!isHit) { aclScan(el, depth + 1); continue; }
            @try {
                CGRect fr = CGRectNull;
                id frv = [el valueForKey:@"accessibilityFrame"];
                if ([frv isKindOfClass:[NSValue class]]) fr = [frv CGRectValue];
                if (CGRectIsNull(fr)) {
                    Class vc = NSClassFromString(@"UIView");
                    if (vc && [el isKindOfClass:vc]) { gAclFoundView = (UIView *)el; return; }
                    aclScan(el, depth + 1);
                    continue;
                }
                CGFloat cx = fr.origin.x + fr.size.width / 2.0;
                CGFloat cy = fr.origin.y + fr.size.height / 2.0;
                if (cx > 0 && cy > 0 && cx < [UIScreen mainScreen].bounds.size.width
                    && cy < [UIScreen mainScreen].bounds.size.height) {
                    gAclFoundFrame = fr; gAclFoundFrameValid = YES; return;
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
}

static BOOL tapSkipInAccessibility(void) {
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app) return NO;
        NSArray *windows = [app performSelector:@selector(windows)];
        for (UIWindow *win in windows) {
            if (!win || win.hidden) continue;
            gAclFoundView = nil; gAclFoundFrameValid = NO;
            aclScan(win, 0);
            if (gAclFoundView) {
                tapView(gAclFoundView);
                return YES;
            }
            if (gAclFoundFrameValid) {
                CGFloat cx = gAclFoundFrame.origin.x + gAclFoundFrame.size.width / 2.0;
                CGFloat cy = gAclFoundFrame.origin.y + gAclFoundFrame.size.height / 2.0;
                tapPointAtWindow([UIApplication performSelector:@selector(keyWindow)], CGPointMake(cx, cy));
                return YES;
            }
        }
        return NO;
    } @catch (NSException *e) {
        return NO;
    }
}

// ============ OCR（最后手段：每会话最多 4 次截图，无 dispatch_sync） ============
static CGRect bboxToScreenRect(CGRect bbox, CGSize size) {
    CGFloat x = bbox.origin.x * size.width;
    CGFloat y = (1.0 - bbox.origin.y - bbox.size.height) * size.height;
    return CGRectMake(x, y, bbox.size.width * size.width, bbox.size.height * size.height);
}

static void runOCROnMain(void) {
    if (!inAdWindow()) return;
    NSTimeInterval now = nowTs();
    if (now - gLastOcrTime < 1.2) return;   // 节流
    if (gOcrShots >= 4) return;             // 每会话截图预算
    gOcrShots++;
    gLastOcrTime = now;
    // 此刻必然在主线程（engine timer 挂主 runloop）
    UIWindow *shotWin = nil;
    CGRect screenBounds = CGRectZero;
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        NSArray *wins = [app performSelector:@selector(windows)];
        NSArray *sorted = [wins sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            CGFloat la = [a windowLevel], lb = [b windowLevel];
            if (la > lb) return NSOrderedAscending;
            if (la < lb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (UIWindow *w in sorted) {
            if (!w || w.hidden) continue;
            CGRect b = w.bounds;
            if (CGRectIsEmpty(b) || b.size.width < 200 || b.size.height < 200) continue;
            shotWin = w;
            screenBounds = b;
            break;
        }
        if (!shotWin) return;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:screenBounds.size];
        UIImage *shot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [shotWin drawViewHierarchyInRect:CGRectMake(0, 0, screenBounds.size.width, screenBounds.size.height) afterScreenUpdates:YES];
        }];
        if (!shot) return;
        Class handlerCls = NSClassFromString(@"VNImageRequestHandler");
        Class reqCls = NSClassFromString(@"VNRecognizeTextRequest");
        if (!handlerCls || !reqCls) return;
        UIWindow *w = shotWin;
        CGSize sz = screenBounds.size;
        id request = [[reqCls alloc] performSelector:@selector(initWithCompletionHandler:)
                                          withObject:^(id req, NSError *err) {
            // Vision 回调（后台线程）：只做文字匹配，点击回主线程
            if (err || !inAdWindow()) return;
            NSArray *results = [req performSelector:@selector(results)];
            for (id obs in results) {
                NSArray *cands = ((NSArray *(*)(id, SEL, NSUInteger))objc_msgSend)(obs, @selector(topCandidates:), 1);
                if (!cands.count) continue;
                NSString *text = [cands[0] performSelector:@selector(string)];
                if (!text.length || !containsSkipWordStrict(text)) continue;
                CGRect bbox = [(NSValue *)[obs performSelector:@selector(boundingBox)] CGRectValue];
                CGRect r = bboxToScreenRect(bbox, sz);
                if (r.size.width < 8 || r.size.height < 8) continue;
                if (r.size.width > sz.width * 0.6) continue;
                CGPoint center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
                BOOL inTopStrip = (center.y < sz.height * 0.22);
                BOOL inBottomStrip = (center.y > sz.height * 0.78);
                BOOL inRightZone = (center.x > sz.width * 0.4);
                if (!inRightZone && !inTopStrip && !inBottomStrip) continue;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (inAdWindow() && w) tapPointAtWindow(w, center);
                });
                break;
            }
        }];
        [request setValue:@1 forKey:@"recognitionLevel"];
        @try { [request setValue:@[@"zh-Hans", @"en-US"] forKey:@"recognitionLanguages"]; } @catch (NSException *e) {}
        [request setValue:@YES forKey:@"usesLanguageCorrection"];
        id handler = [[handlerCls alloc] initWithCGImage:shot.CGImage options:@{}];
        NSError *reqErr = nil;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [handler performSelector:@selector(performRequests:error:) withObject:@[request] withObject:(__bridge id)(void *)&reqErr];
        #pragma clang diagnostic pop
    } @catch (NSException *e) {}
}

// ============ 只读全窗搜索（轮询引擎的一轮） ============
static UIView *searchSkipView(void) {
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app) return nil;
        NSArray *windows = [app performSelector:@selector(windows)];
        if (!windows.count) return nil;
        NSArray *sorted = [windows sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            CGFloat la = [a windowLevel], lb = [b windowLevel];
            if (la > lb) return NSOrderedAscending;
            if (la < lb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (UIWindow *win in sorted) {
            if (!win || win.hidden || win.alpha < 0.05) continue;
            CGRect b = win.bounds;
            if (CGRectIsEmpty(b) || b.size.width < 200 || b.size.height < 200) continue;
            UIView *hit = findSkipViewInHierarchy(win, 0);
            if (hit) return hit;
            CALayer *tl = findSkipTextLayerInLayer(win.layer, 0);
            if (tl) {
                CALayer *l = tl;
                UIView *ownerView = nil;
                Class viewCls = NSClassFromString(@"UIView");
                for (int i = 0; i < 10 && l; i++) {
                    id d = l.delegate;
                    if (viewCls && [d isKindOfClass:viewCls]) { ownerView = (UIView *)d; break; }
                    l = l.superlayer;
                }
                if (ownerView && ownerView.window) return ownerView;
            }
            UIView *byClass = findSkipViewByClassName(win);
            if (byClass) return byClass;
        }
    } @catch (NSException *e) {}
    return nil;
}

// ============ 轮询引擎（会话开始即启动；0.35s 间隔） ============
static void startEngineTimer(void) {
    if (gEngineTimer || !gSessionActive) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gEngineTimer || !gSessionActive) return;
        CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
        gEngineTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                            CFAbsoluteTimeGetCurrent() + 0.35,
                                            0.35, 0, 0, engineTimerCallback, &ctx);
        if (gEngineTimer) CFRunLoopAddTimer(CFRunLoopGetMain(), gEngineTimer, kCFRunLoopCommonModes);
    });
}

static void stopEngineTimer(void) {
    if (gEngineTimer) {
        CFRunLoopTimerInvalidate(gEngineTimer);
        CFRelease(gEngineTimer);
        gEngineTimer = NULL;
    }
}

// 摇一摇广告的按钮跳过仍走正常通道（文字 hook / 采样 / 引擎兜底）。
static BOOL isShakeAdView(UIView *v) {
    if (!v) return NO;
    NSString *low = NSStringFromClass([v class]).lowercaseString;
    if (!low.length) return NO;
    if ([low containsString:@"shakead"] || [low containsString:@"shake_ad"] || [low containsString:@"shakeview"]) return YES;
    if ([low containsString:@"yaoyao"] || [low containsString:@"yao_yao"]) return YES;
    return NO;
}

// 图像 close 搜索：容器确认后，在容器内找 角落 + ≤120pt + UIControl/带tap手势 的小控件。
// 广告画面主体是 UIImageView（非控件），只有 close 是可点控件——结构天然区分。
static UIView *findImageCloseButtonRec(UIView *v, int depth) {
    if (!v || depth > 16 || v.hidden || v.alpha < 0.05) return nil;
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    if (w >= 20 && w <= 120 && h >= 20 && h <= 120) {
        BOOL isControl = [v isKindOfClass:NSClassFromString(@"UIControl")];
        BOOL hasTap = NO;
        Class tapCls = NSClassFromString(@"UITapGestureRecognizer");
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (tapCls && [g isKindOfClass:tapCls]) { hasTap = YES; break; }
        }
        if ((isControl || hasTap) && plausibleCloseCorner(v)) return v;
    }
    for (UIView *sub in v.subviews) {
        UIView *hit = findImageCloseButtonRec(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIView *findImageCloseButton(void) {
    @try {
        id app = [UIApplication performSelector:@selector(sharedApplication)];
        if (!app) return nil;
        NSArray *wins = [app performSelector:@selector(windows)];
        for (UIWindow *win in wins) {
            if (!win || win.hidden || win.alpha < 0.05) continue;
            CGRect b = win.bounds;
            if (CGRectIsEmpty(b) || b.size.width < 200 || b.size.height < 200) continue;
            gFoundContainer = nil;
            findSplashContainerRec(win, 0);
            if (!gFoundContainer) continue;   // 只在确认的容器内找，绝不全局扫控件
            UIView *hit = findImageCloseButtonRec(gFoundContainer, 0);
            if (hit) return hit;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 引擎职责与 2.x 不同：事件驱动已负责"秒跳"，引擎只做三件事：
//   ① 验证已点击目标（1 tick 后还在 → 重试，最多 3 次）
//   ② 兜底搜索（文字/CALayer/类名/accessibility 四通道 + JS + OCR）
//   ③ 自动收摊（连续 5 tick 无命中且已点过 → 会话目标完成，停引擎）
static void engineTimerCallback(CFRunLoopTimerRef timer, void *info) {
    gTickCount++;
    if (!inAdWindow()) {
        stopEngineTimer();
        return;
    }
    // ① 点击验证
    if (gLastTappedView) {
        BOOL stillVisible = (gLastTappedView.window != nil && !gLastTappedView.hidden && gLastTappedView.alpha >= 0.05);
        if (!stillVisible) {
            // 按钮消失 = 成功
            gSkipFired = YES;
            stopEngineTimer();
            return;
        }
        // 倒计时按钮（SDK 内部拦截点击到倒计时结束）：重试上限放宽到 14 次
        // （覆盖 10s 倒计时），文字每秒 setText 刷新会持续重触发，点到消失为止
        int retryLimit = gCountdownTarget ? 14 : 3;
        if (gTapRetry < retryLimit) {
            gTapRetry++;
            tapView(gLastTappedView);
            return;
        }
        // 重试耗尽：放弃这个目标（不删不隐藏），继续靠 JS/OCR 找别的机会
        gLastTappedView = nil;
        gTapRetry = 0;
        jsTapWebViews();
        return;
    }
    // ② 兜底搜索
    UIView *hit = searchSkipView();
    if (hit) {
        gIdleTicks = 0;
        noteSignalAndArmEngine();
        tapView(hit);
        gLastTappedView = hit;
        gTapRetry = 0;
        return;
    }
    if (tapSkipInAccessibility()) return;
    jsTapWebViews();
    runOCROnMain();
    // ②b 容器已确认但找不到任何带字按钮 → 扫角落图像 close（无文字广告）
    if (gAdContainerSeen && !gLastTappedView) {
        UIView *iconClose = findImageCloseButton();
        if (iconClose && iconClose.window && !iconClose.hidden && iconClose.alpha >= 0.05) {
            gIdleTicks = 0;
            tapView(iconClose);
            gLastTappedView = iconClose;
            gTapRetry = 0;
        }
    }
    // 不再因为前 3~5 秒没有发现文字按钮就关闭引擎。
    // 许多开屏广告先展示图片/视频，随后才创建关闭控件；会话本身由
    // inAdWindow 的时间窗负责收尾。这样“无文字信号”的广告也能持续被扫描。
}

// ============ hook（全部严格门控，热路径第一行就是 inAdWindow 便宜判断） ============
%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (!inAdWindow()) return;
    if (!text.length) return;
    if (containsSkipWordStrict(text) || containsCountdownSkipWord(text)) {
        handleEventDrivenSkip(self);
        return;
    }
    // 二级「关闭」：必须容器先确认（防主界面弹窗/正常 UI 误触）
    if (containsCloseWord(text) && gateCloseTap(self)) {
        handleEventDrivenSkip(self);
    }
}
- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    if (!inAdWindow() || !text.string.length) return;
    if (containsSkipWordStrict(text.string) || containsCountdownSkipWord(text.string)) {
        handleEventDrivenSkip(self);
        return;
    }
    if (containsCloseWord(text.string) && gateCloseTap(self)) {
        handleEventDrivenSkip(self);
    }
}
%end

%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if (!inAdWindow() || !title.length) return;
    if (containsSkipWordStrict(title) || containsCountdownSkipWord(title)) {
        handleEventDrivenSkip(self);
        return;
    }
    if (containsCloseWord(title) && gateCloseTap(self)) {
        handleEventDrivenSkip(self);
    }
}
%end

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!inAdWindow()) return;
    if (!self.window) return;
    if (isSkipButtonClass(self)) {
        handleEventDrivenSkipByClass(self);
        return;
    }
    if (isSplashAdClass(self)) {
        // 全屏校验：非全屏的广告位组件（如信息流广告卡片）绝不开锁
        if (isFullscreenish(self)) {
            gAdContainerSeen = YES;   // 容器确认：开锁「关闭」词表 + 图像✕ + 防摇
            handleEventDrivenSplashContainer(self);
        }
        return;
    }
    if (isShakeAdView(self)) {
        gAdContainerSeen = YES;   // 摇一摇触发视图：仅开锁（防摇+关字+图像✕），不触发点击
        noteSignalAndArmEngine(); // 武装引擎等按钮出现
    }
}
%end

// 摇一摇广告的跳转触发器是加速度传感器，不是任何视图——点它反而触发跳转。
// 正确解法：容器确认期间拒绝 SDK 拿到传感器数据，摇一摇"摇不响"。
// 安全边界：gAdContainerSeen 为 NO 时（无广告/非广告容器），%orig 原样放行，
// 传感器行为分毫不变；容器确认本身必须过类名词根（isSplashAdClass）才置位。
%hook CMMotionManager
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMAccelerometerData *, NSError *))handler {
    if (gAdContainerSeen && inAdWindow()) return;   // 广告期：不启动，SDK 永远收不到数据
    %orig;
}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMDeviceMotion *, NSError *))handler {
    if (gAdContainerSeen && inAdWindow()) return;
    %orig;
}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(void (^)(CMGyroData *, NSError *))handler {
    if (gAdContainerSeen && inAdWindow()) return;
    %orig;
}
- (void)startAccelerometerUpdates {
    if (gAdContainerSeen && inAdWindow()) return;
    %orig;
}
- (void)startDeviceMotionUpdates {
    if (gAdContainerSeen && inAdWindow()) return;
    %orig;
}
%end

// ============ 入口：始终安装会话监听，支持设置即时生效 ============
%ctor {
    loadUserConfig();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        adSkipPreferencesChanged,
        CFSTR("com.mg.adskip.preferences.changed"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    if (userExcludedBundle()) {
        return;
    }

    beginSession(YES);

    @autoreleasepool {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil
                            queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            beginSession(YES);
        }];

        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                            queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            beginSession(YES);
        }];

        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                            queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            beginSession(YES);
        }];
    }
}
