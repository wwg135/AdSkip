#import "CategorySegmentCell.h"

@interface NSObject (AdSkipCategory)
- (void)setCategory:(NSNumber *)category specifier:(PSSpecifier *)specifier;
@end

@interface CategorySegmentCell ()
@property(nonatomic,strong) UISegmentedControl *segment;
@end

@implementation CategorySegmentCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        NSArray *items = @[@"全部",@"商店",@"系统"];
        _segment = [[UISegmentedControl alloc] initWithItems:items];
        [_segment addTarget:self action:@selector(change:) forControlEvents:UIControlEventValueChanged];
        _segment.selectedSegmentIndex = 0;
        self.accessoryView = _segment;
    }
    return self;
}

- (void)change:(UISegmentedControl *)sender {
    [self.specifier setProperty:@(sender.selectedSegmentIndex) forKey:@"selectedCategory"];
    id target = [self.specifier target];
    if ([target respondsToSelector:@selector(setCategory:specifier:)]) {
        [target setCategory:@(sender.selectedSegmentIndex) specifier:self.specifier];
    }
}
@end
