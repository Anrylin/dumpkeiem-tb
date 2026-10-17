// Tweak.xm —— ThemeBoxDump v1
// 钩住 ThemeBox 的 DIY/主题方法，抓出它的真实路径和文件命名
// 注入到【有 ThemeBox 的那个微信】

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *gDir = nil;
static FILE *gFp = NULL;
static NSRecursiveLock *gLock = nil;

static NSString *Dir(void) {
    if (gDir) return gDir;
    NSArray *cands = @[
        @"/var/mobile/Media/tb_dump",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/tb_dump"],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in cands) {
        @try {
            [fm createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil];
            gDir = c;
            return c;
        } @catch (NSException *e) {}
    }
    gDir = cands.lastObject;
    return gDir;
}

static void LogLine(NSString *fmt, ...) {
    if (!gFp) {
        NSString *p = [Dir() stringByAppendingPathComponent:@"log.txt"];
        gFp = fopen(p.UTF8String, "a");
        if (!gFp) return;
    }
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    df.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    fprintf(gFp, "[%s] %s\n", ts.UTF8String, s.UTF8String);
    fflush(gFp);
}

// 打印一个对象里的 ivar（UIImage 等）
static void __attribute__((unused)) DumpObj(id o, NSString *tag) {
    @try {
        NSString *desc = [o description];
        LogLine(@"%@ : %@", tag, desc ?: @"(nil)");
        if ([o isKindOfClass:[UIImage class]]) {
            UIImage *img = (UIImage *)o;
            LogLine(@"  size=%.0fx%.0f scale=%.1f", img.size.width, img.size.height, img.scale);
        }
    } @catch (NSException *e) {
        LogLine(@"%@ : <异常 %@>", tag, e);
    }
}

static int InstallHooks(void) {
    int done = 0;
    unsigned int ncls = 0;
    Class *cls = objc_copyClassList(&ncls);
    for (unsigned int i = 0; i < ncls; i++) {
        Class c = cls[i];
        NSString *cn = NSStringFromClass(c);
        // 只关心 ThemeBox 相关的类（包含 ThemeBox 或 obfuscated 长名）
        if (![cn containsString:@"ThemeBox"] && ![cn containsString:@"Theme"] && cn.length < 20) continue;

        // 1) currentThemeDIYPath -> 返回 DIY 路径
        SEL s1 = NSSelectorFromString(@"currentThemeDIYPath");
        if ([c instancesRespondToSelector:s1]) {
            Method m = class_getInstanceMethod(c, s1);
            IMP orig = method_getImplementation(m);
            IMP r = imp_implementationWithBlock(^id(id self) {
                id ret = ((id(*)(id, SEL))orig)(self, s1);
                LogLine(@"★ currentThemeDIYPath = %@", ret);
                return ret;
            });
            method_setImplementation(m, r);
            done++;
            LogLine(@"钩 currentThemeDIYPath -[%@]", cn);
        }
        // 2) themePath / baseThemePath
        for (NSString *sn in @[@"themePath", @"baseThemePath"]) {
            SEL s = NSSelectorFromString(sn);
            if ([c instancesRespondToSelector:s]) {
                Method m = class_getInstanceMethod(c, s);
                IMP orig = method_getImplementation(m);
                IMP r = imp_implementationWithBlock(^id(id self) {
                    id ret = ((id(*)(id, SEL))orig)(self, s);
                    LogLine(@"★ %@ = %@", sn, ret);
                    return ret;
                });
                method_setImplementation(m, r);
                done++;
                LogLine(@"钩 %@ -[%@]", sn, cn);
            }
        }
        // 3) loadDIYFiles / loadThemeDIYFiles / loadCustomThemeFiles
        for (NSString *sn in @[@"loadDIYFiles", @"loadThemeDIYFiles", @"loadCustomThemeFiles"]) {
            SEL s = NSSelectorFromString(sn);
            if ([c instancesRespondToSelector:s]) {
                Method m = class_getInstanceMethod(c, s);
                IMP orig = method_getImplementation(m);
                IMP r = imp_implementationWithBlock(^void(id self) {
                    LogLine(@"★ %@ 被调用 -[%@]", sn, NSStringFromClass([self class]));
                    ((void(*)(id, SEL))orig)(self, s);
                    // 调用后 dump 相关 ivar
                    @try {
                        id fm = [self valueForKey:@"diyFileMap"];
                        if (fm) LogLine(@"  diyFileMap = %@ (共 %lu 键)", [fm class], (unsigned long)[(NSDictionary *)fm count]);
                        id fm2 = [self valueForKey:@"themeDIYFileMap"];
                        if (fm2) LogLine(@"  themeDIYFileMap = %@ (共 %lu 键)", [fm2 class], (unsigned long)[(NSDictionary *)fm2 count]);
                    } @catch (NSException *e) { LogLine(@"  dump ivar 异常 %@", e); }
                });
                method_setImplementation(m, r);
                done++;
                LogLine(@"钩 %@ -[%@]", sn, cn);
            }
        }
        // 4) diyImageNamed: -> 抓它查找的名字
        SEL s4 = NSSelectorFromString(@"diyImageNamed:");
        if ([c instancesRespondToSelector:s4]) {
            Method m = class_getInstanceMethod(c, s4);
            IMP orig = method_getImplementation(m);
            IMP r = imp_implementationWithBlock(^id(id self, id name) {
                LogLine(@"★ diyImageNamed:%@  -[%@]", name, NSStringFromClass([self class]));
                id ret = ((id(*)(id, SEL, id))orig)(self, s4, name);
                return ret;
            });
            method_setImplementation(m, r);
            done++;
            LogLine(@"钩 diyImageNamed: -[%@]", cn);
        }
    }
    free(cls);
    return done;
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        gLock = [NSRecursiveLock new];
        LogLine(@"===== ThemeBoxDump v1 启动 =====");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    int n = InstallHooks();
                    LogLine(@"已挂钩 %d 个方法", n);
                    LogLine(@"===== 日志目录 %@ =====", Dir());
                }
            });
    }
}
