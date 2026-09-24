#import <Foundation/Foundation.h>

@interface ADSkipApp : NSObject

@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *type;

@end

@interface AppScanner : NSObject

+ (NSArray<ADSkipApp *> *)scanApplications;

@end
