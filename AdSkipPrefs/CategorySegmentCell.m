
#import "CategorySegmentCell.h"
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>

@interface CategorySegmentCell ()
@property(nonatomic,strong) UISegmentedControl *segment;
@end

@implementation CategorySegmentCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSArray *items = @[@"全部",@"商店",@"系统"];
        _segment = [[UISegmentedControl alloc] initWithItems:items];
        _segment.translatesAutoresizingMaskIntoConstraints = NO;
        NSInteger current = [[[NSUserDefaults standardUserDefaults] objectForKey:@"AppCategory"] integerValue];
        _segment.selectedSegmentIndex = current;
        [_segment addTarget:self action:@selector(categoryChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_segment];

        [NSLayoutConstraint activateConstraints:@[
            [_segment.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_segment.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_segment.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [_segment.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8]
        ]];
    }
    return self;
}

- (void)categoryChanged:(UISegmentedControl *)sender
{
    [[NSUserDefaults standardUserDefaults] setInteger:sender.selectedSegmentIndex forKey:@"AppCategory"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    id target = self.specifier.target;
    if ([target respondsToSelector:@selector(reloadSpecifiers)]) {
        [target reloadSpecifiers];
    }
}

@end
