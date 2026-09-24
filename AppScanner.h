#import <Foundation/Foundation.h>

@interface ADSkipApp : NSObject
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
@end

@interface AppScanner : NSObject
+ (NSArray<ADSkipApp *> *)scanApplications;
@end
