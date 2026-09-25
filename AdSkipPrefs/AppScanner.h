#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface ADSkipApp : NSObject

@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *iconPath;
@property(nonatomic, strong) UIImage *iconImage;

@end

@interface AppScanner : NSObject

+ (NSArray<ADSkipApp *> *)scanApplications;

@end
