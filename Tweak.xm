// LuckyHook v7 - 瑞幸 App Token 一键读取/更换（悬浮窗 UI）
//
// 基于 v6 已验证成功的「源头注入」方案，新增可拖动悬浮窗：
//   · 悬浮球：拖动移位，点击展开面板
//   · 面板：显示当前 Token / 输入新 Token / 粘贴·复制 / 应用并重启
//   · 写入：NSUserDefaults(com.luckincoffee.network.uid) + MMKV 双写
//   · 关键：出站请求头只观测不改写，保证 App 自身签名与 token 一致

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <substrate.h>

#define HOOK_TAG @"[LuckyHook]"

static NSString *kUidKey     = @"com.luckincoffee.network.uid";
static NSString *kConfigTxt  = @"/var/mobile/Library/Preferences/LuckyHook.txt";
static NSString *kConfigPlist= @"/var/mobile/Library/Preferences/LuckyHook.plist";
static NSString *kAutoKey    = @"/var/mobile/Library/Preferences/LuckyHook.auto";

// ==================== 全局 ====================
static NSString *gNewToken = nil;
static NSString *gNewMid   = nil;
static BOOL      gObserve  = NO;
static BOOL      gAutoApply = YES;
static double    gLastLoad = 0;

// ==================== dump ====================
static NSString *gDumpPath = nil;
static NSMutableSet *gSeen = nil;
static NSLock *gLock = nil;

static void dumpAppend(NSString *line) {
    @autoreleasepool {
        if (!gLock) gLock = [[NSLock alloc] init];
        [gLock lock];
        @try {
            if (!gDumpPath) {
                NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
                if (!d.count) { [gLock unlock]; return; }
                gDumpPath = [d[0] stringByAppendingPathComponent:@"LuckyHook_dump.txt"];
            }
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gDumpPath]) [fm createFileAtPath:gDumpPath contents:data attributes:nil];
            else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gDumpPath];
                if (fh) { [fh seekToEndOfFile]; [fh writeData:data]; [fh closeFile]; }
            }
        } @catch (NSException *e) { }
        [gLock unlock];
    }
}
static void dumpUnique(NSString *tag, NSString *val) {
    if (!val) return;
    @autoreleasepool {
        if (!gSeen) gSeen = [NSMutableSet set];
        NSString *k = [NSString stringWithFormat:@"%@|%@", tag, val];
        if ([gSeen containsObject:k] || gSeen.count > 3000) return;
        [gSeen addObject:k];
        dumpAppend([NSString stringWithFormat:@"[%@] %@", tag, val]);
    }
}

// ==================== 配置 ====================
static void loadConfig(void) {
    double now = [NSDate date].timeIntervalSince1970;
    if (gNewToken && (now - gLastLoad) < 5.0) return;
    gLastLoad = now;
    gObserve = NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:kAutoKey]) {
        NSString *a = [NSString stringWithContentsOfFile:kAutoKey encoding:NSUTF8StringEncoding error:nil];
        gAutoApply = !(a && [[a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"0"]);
    }

    NSString *t = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:kConfigTxt]) {
        t = [NSString stringWithContentsOfFile:kConfigTxt encoding:NSUTF8StringEncoding error:nil];
        if (t) {
            t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([t isEqualToString:@"OBSERVE"]) { gObserve = YES; t = nil; }
        }
    }
    if ((!t || t.length < 20) && [[NSFileManager defaultManager] fileExistsAtPath:kConfigPlist]) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPlist];
        if ([d[@"NewToken"] isKindOfClass:[NSString class]]) t = d[@"NewToken"];
        if ([d[@"Observe"] respondsToSelector:@selector(boolValue)] && [d[@"Observe"] boolValue]) gObserve = YES;
    }
    if (!t || t.length < 20) t = gNewToken ?: nil;

    if (t && ![t isEqualToString:gNewToken]) {
        gNewToken = [t copy];
        gNewMid = nil;
        NSArray *parts = [gNewToken componentsSeparatedByString:@"-"];
        if (parts.count >= 6) {
            NSArray *tail = [parts subarrayWithRange:NSMakeRange(5, parts.count - 5)];
            if (tail.count >= 1) gNewMid = [tail[0] copy];
        }
    }
}

// ==================== 读写 token ====================
static NSString *currentStoredToken(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        id v = [ud objectForKey:kUidKey];
        return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
    } @catch (NSException *e) { return nil; }
}

static void writeTokenEverywhere(NSString *tok) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:tok forKey:kUidKey];
        [ud synchronize];
    } @catch (NSException *e) { }
    @try {
        Class c = objc_getClass("MMKV");
        if (c) {
            id inst = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("defaultMMKV"));
            if (inst) {
                SEL s = sel_registerName("setString:forKey:");
                if ([inst respondsToSelector:s])
                    ((void (*)(id, SEL, NSString *, NSString *))objc_msgSend)(inst, s, tok, kUidKey);
            }
        }
    } @catch (NSException *e) { }
    // 落盘到配置文件（重启后仍然生效）
    [tok writeToFile:kConfigTxt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gNewToken = [tok copy];
    gLastLoad = 0;
    NSArray *parts = [tok componentsSeparatedByString:@"-"];
    if (parts.count >= 6) {
        NSArray *tail = [parts subarrayWithRange:NSMakeRange(5, parts.count - 5)];
        if (tail.count >= 1) gNewMid = [tail[0] copy];
    }
}

// ==================== 源头改写 ====================
static NSString *rewriteString(NSString *s) {
    if (gObserve || !gNewToken) return s;
    if (![s isKindOfClass:[NSString class]] || s.length < 40) return s;
    if ([s containsString:gNewToken]) return s;
    if ([s rangeOfString:@"-"].location == NSNotFound) return s;
    static NSRegularExpression *re = nil;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:
        @"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\d{13}-\\d+-[A-Za-z0-9._\\-]+"
        options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return s;
    dumpUnique(@"源头捕获", [s substringWithRange:m.range]);
    return [s stringByReplacingCharactersInRange:m.range withString:gNewToken];
}

// ==================== Hook: NSUserDefaults ====================
typedef id (*UDGetObj)(id, SEL, NSString *);
static UDGetObj orig_ud_obj = NULL;

static id hook_ud_obj(id self, SEL _cmd, NSString *key) {
    @try {
        id v = orig_ud_obj ? orig_ud_obj(self, _cmd, key) : nil;
        if ([key isKindOfClass:[NSString class]] && [key isEqualToString:kUidKey]) {
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 20)
                dumpUnique(@"读[uid]", (NSString *)v);
            if (gAutoApply && !gObserve && gNewToken) return gNewToken;
        }
        return v;
    } @catch (NSException *e) { return nil; }
}
static void hookUserDefaults(void) {
    Class c = objc_getClass("NSUserDefaults");
    if (!c) return;
    MSHookMessageEx(c, sel_registerName("objectForKey:"), (IMP)hook_ud_obj, (IMP *)&orig_ud_obj);
}

// ==================== Hook: MMKV ====================
typedef NSString *(*MMKVGetStr)(id, SEL, NSString *);
static MMKVGetStr orig_mmkv_str = NULL;
static NSString *hook_mmkv_str(id self, SEL _cmd, NSString *key) {
    @try {
        NSString *v = orig_mmkv_str ? orig_mmkv_str(self, _cmd, key) : nil;
        if ([v isKindOfClass:[NSString class]] && v.length > 40)
            dumpUnique([NSString stringWithFormat:@"mmkv[%@]", key], v);
        return rewriteString(v);
    } @catch (NSException *e) { return nil; }
}
static void hookMMKV(void) {
    Class c = objc_getClass("MMKV");
    if (!c) return;
    MSHookMessageEx(c, sel_registerName("getStringForKey:"), (IMP)hook_mmkv_str, (IMP *)&orig_mmkv_str);
}

// ==================== Hook: 出站请求（只观测，不改写）====================
typedef void (*SetValIMP)(id, SEL, NSString *, NSString *);
static SetValIMP orig_setval = NULL, orig_addval = NULL;
static void hook_setval(id self, SEL _cmd, NSString *value, NSString *field) {
    @try {
        if ([value isKindOfClass:[NSString class]] && value.length > 40 &&
            ([field isEqualToString:@"Cookie"] || [field.lowercaseString containsString:@"lk-"]))
            dumpUnique([NSString stringWithFormat:@"出站[%@]", field], value);
    } @catch (NSException *e) { }
    if (orig_setval) orig_setval(self, _cmd, value, field);
}
static void hook_addval(id self, SEL _cmd, NSString *value, NSString *field) {
    @try {
        if ([value isKindOfClass:[NSString class]] && value.length > 40 &&
            ([field isEqualToString:@"Cookie"] || [field.lowercaseString containsString:@"lk-"]))
            dumpUnique([NSString stringWithFormat:@"出站[%@]", field], value);
    } @catch (NSException *e) { }
    if (orig_addval) orig_addval(self, _cmd, value, field);
}
static void hookRequests(void) {
    Class c = objc_getClass("NSMutableURLRequest");
    if (!c) return;
    MSHookMessageEx(c, sel_registerName("setValue:forHTTPHeaderField:"), (IMP)hook_setval, (IMP *)&orig_setval);
    MSHookMessageEx(c, sel_registerName("addValue:forHTTPHeaderField:"), (IMP)hook_addval, (IMP *)&orig_addval);
}

// ==================== 悬浮窗 UI ====================
static UIWindow *gWin = nil;
static UIView   *gBall = nil;
static UIView   *gPanel = nil;
static UITextView  *gCurView = nil;
static UITextField *gInput   = nil;
static UILabel  *gHint = nil;

@interface LKPassthroughView : UIView
@end
@implementation LKPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

// ★ 关键：在 Window 层拦截，命中空白区域时返回 nil，
//   让事件继续下发给 App 自己的窗口（否则整个界面都会失去触摸）
@interface LKPassthroughWindow : UIWindow
@end
@implementation LKPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface LKUIHelper : NSObject
@end
static LKUIHelper *gHelper = nil;
static CGFloat gPanelW = 320.0;
static CGFloat gPanelH = 430.0;

@implementation LKUIHelper

- (void)ballTapped {
    gPanel.hidden = !gPanel.hidden;
    if (!gPanel.hidden) [self refreshCurrent];
}
- (void)ballPanned:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    CGPoint c = v.center;
    c.x += t.x; c.y += t.y;
    CGFloat w = v.superview.bounds.size.width, h = v.superview.bounds.size.height;
    c.x = MAX(28, MIN(w - 28, c.x));
    c.y = MAX(48, MIN(h - 28, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:v.superview];
}
- (void)refreshCurrent {
    NSString *raw = nil;
    @try {
        if (orig_ud_obj) {
            id v = orig_ud_obj([NSUserDefaults standardUserDefaults],
                               sel_registerName("objectForKey:"), kUidKey);
            if ([v isKindOfClass:[NSString class]]) raw = (NSString *)v;
        }
    } @catch (NSException *e) { }
    if (!raw) raw = currentStoredToken();
    gCurView.text = raw.length ? raw : @"(未读取到)";
    gHint.text = gNewToken.length
        ? [NSString stringWithFormat:@"目标 mid: %@", gNewMid ?: @"?"]
        : @"未设置目标 Token";
    if (gNewToken.length) gInput.text = gNewToken;
}
- (void)pasteTapped {
    NSString *s = UIPasteboard.generalPasteboard.string;
    if (s.length) { gInput.text = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]; }
}
- (void)copyTapped {
    if (gCurView.text.length) {
        UIPasteboard.generalPasteboard.string = gCurView.text;
        gHint.text = @"当前 Token 已复制";
    }
}
- (void)applyTapped {
    NSString *t = [gInput.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 40) { gHint.text = @"Token 太短，请检查"; return; }
    writeTokenEverywhere(t);
    [self refreshCurrent];
    gHint.text = @"✅ 已写入，正在重启 App…";
    dumpAppend([NSString stringWithFormat:@"[UI] 应用新 token mid=%@", gNewMid ?: @"?"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(0);
    });
}
- (void)observeTapped:(UIButton *)b {
    gAutoApply = !gAutoApply;
    [gAutoApply ? @"1" : @"0" writeToFile:kAutoKey atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [b setTitle:gAutoApply ? @"接管:开" : @"接管:关" forState:UIControlStateNormal];
    gHint.text = gAutoApply ? @"已开启 token 接管" : @"已关闭接管（仅显示）";
}
- (void)closeTapped { gPanel.hidden = YES; }
@end

static UIButton *mkBtn(NSString *title, id target, SEL act, UIColor *bg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 8;
    [b addTarget:target action:act forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UILabel *mkLabel(NSString *text, CGFloat size, UIColor *color, BOOL bold) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = color;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    return l;
}

static void setupUI(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (!scene) return;

    if (!gHelper) gHelper = [[LKUIHelper alloc] init];

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = [[LKPassthroughView alloc] initWithFrame:scene.coordinateSpace.bounds];
    vc.view.backgroundColor = UIColor.clearColor;

    gWin = [[LKPassthroughWindow alloc] initWithWindowScene:scene];
    gWin.frame = scene.coordinateSpace.bounds;
    gWin.windowLevel = UIWindowLevelAlert + 100;
    gWin.backgroundColor = UIColor.clearColor;
    gWin.rootViewController = vc;
    gWin.hidden = NO;

    CGFloat W = scene.coordinateSpace.bounds.size.width;
    CGFloat H = scene.coordinateSpace.bounds.size.height;

    // ---- 悬浮球 ----
    gBall = [[UIView alloc] initWithFrame:CGRectMake(W - 74, H * 0.45, 54, 54)];
    gBall.backgroundColor = [UIColor colorWithRed:0.13 green:0.42 blue:0.85 alpha:0.92];
    gBall.layer.cornerRadius = 27;
    gBall.layer.shadowColor = UIColor.blackColor.CGColor;
    gBall.layer.shadowOpacity = 0.35;
    gBall.layer.shadowRadius = 6;
    gBall.layer.shadowOffset = CGSizeMake(0, 2);
    gBall.userInteractionEnabled = YES;
    UILabel *icon = mkLabel(@"🔑", 24, UIColor.whiteColor, YES);
    icon.frame = gBall.bounds;
    icon.textAlignment = NSTextAlignmentCenter;
    [gBall addSubview:icon];
    [gBall addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gHelper action:@selector(ballTapped)]];
    [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:gHelper action:@selector(ballPanned:)]];
    [vc.view addSubview:gBall];

    // ---- 面板 ----
    CGFloat px = (W - gPanelW) / 2, py = MAX(70, H * 0.5 - gPanelH / 2);
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(px, py, gPanelW, gPanelH)];
    gPanel.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.98];
    gPanel.layer.cornerRadius = 16;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    gPanel.hidden = YES;
    gPanel.userInteractionEnabled = YES;

    CGFloat y = 14, pad = 16, iw = gPanelW - pad * 2;

    UILabel *title = mkLabel(@"🔑 瑞幸 Token 切换", 16, UIColor.whiteColor, YES);
    title.frame = CGRectMake(pad, y, iw - 30, 22);
    [gPanel addSubview:title];
    UIButton *x = mkBtn(@"✕", gHelper, @selector(closeTapped), UIColor.clearColor);
    x.frame = CGRectMake(gPanelW - 42, y - 4, 30, 30);
    [x setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateNormal];
    [gPanel addSubview:x];
    y += 30;

    [gPanel addSubview:mkLabel(@"当前 Token", 12, [UIColor colorWithWhite:1 alpha:0.55], NO)];
    ((UILabel *)gPanel.subviews.lastObject).frame = CGRectMake(pad, y, iw, 16);
    y += 20;

    gCurView = [[UITextView alloc] initWithFrame:CGRectMake(pad, y, iw, 78)];
    gCurView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    gCurView.textColor = [UIColor colorWithRed:0.95 green:0.72 blue:0.25 alpha:1];
    gCurView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gCurView.editable = NO;
    gCurView.layer.cornerRadius = 8;
    [gPanel addSubview:gCurView];
    y += 86;

    UIButton *cp = mkBtn(@"复制当前", gHelper, @selector(copyTapped), [UIColor colorWithWhite:1 alpha:0.12]);
    cp.frame = CGRectMake(pad, y, 88, 30);
    [gPanel addSubview:cp];
    y += 40;

    [gPanel addSubview:mkLabel(@"新 Token", 12, [UIColor colorWithWhite:1 alpha:0.55], NO)];
    ((UILabel *)gPanel.subviews.lastObject).frame = CGRectMake(pad, y, iw, 16);
    y += 20;

    gInput = [[UITextField alloc] initWithFrame:CGRectMake(pad, y, iw, 38)];
    gInput.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    gInput.textColor = UIColor.whiteColor;
    gInput.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gInput.layer.cornerRadius = 8;
    gInput.layer.borderWidth = 1;
    gInput.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    gInput.placeholder = @"粘贴或输入新 Token";
    gInput.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"粘贴或输入新 Token"
            attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:0.3]}];
    gInput.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 38)];
    gInput.leftViewMode = UITextFieldViewModeAlways;
    gInput.autocorrectionType = UITextAutocorrectionTypeNo;
    gInput.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [gPanel addSubview:gInput];
    y += 46;

    UIButton *pst = mkBtn(@"📋 粘贴", gHelper, @selector(pasteTapped), [UIColor colorWithWhite:1 alpha:0.12]);
    pst.frame = CGRectMake(pad, y, 88, 30);
    [gPanel addSubview:pst];
    UIButton *obs = mkBtn(gAutoApply ? @"接管:开" : @"接管:关", gHelper, @selector(observeTapped:), [UIColor colorWithWhite:1 alpha:0.12]);
    obs.frame = CGRectMake(pad + 96, y, 88, 30);
    [gPanel addSubview:obs];
    y += 40;

    UIButton *apply = mkBtn(@"✅ 应用并重启", gHelper, @selector(applyTapped), [UIColor colorWithRed:0.13 green:0.55 blue:0.28 alpha:1]);
    apply.frame = CGRectMake(pad, y, iw, 42);
    apply.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [gPanel addSubview:apply];
    y += 50;

    gHint = mkLabel(@"", 11, [UIColor colorWithWhite:1 alpha:0.5], NO);
    gHint.frame = CGRectMake(pad, y, iw, 16);
    gHint.textAlignment = NSTextAlignmentCenter;
    [gPanel addSubview:gHint];

    [vc.view addSubview:gPanel];
    [gHelper refreshCurrent];
    dumpAppend(@"[UI] 悬浮窗已创建");
}

// ==================== 入口 ====================
static void LuckyHookInit(void) {
    @autoreleasepool {
        loadConfig();
        dumpAppend(@"==== LuckyHook v7 (悬浮窗 UI) ====");
        dumpAppend([NSString stringWithFormat:@"目标 mid=%@ observe=%d auto=%d", gNewMid, (int)gObserve, (int)gAutoApply]);
        @try { if (gAutoApply && !gObserve && gNewToken) writeTokenEverywhere(gNewToken); } @catch (NSException *e) { }
        @try { hookUserDefaults(); } @catch (NSException *e) { }
        @try { hookMMKV(); }         @catch (NSException *e) { }
        @try { hookRequests(); }     @catch (NSException *e) { }
        dumpAppend(@"hook 就绪");
    }
}

%ctor {
    LuckyHookInit();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        gLastLoad = 0; loadConfig();
        if (!gWin) setupUI();
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gWin) setupUI();
    });
}
