//
//  TLHeaderViewController.h
//  Layout Test
//
//  Created by Ash Furrow on 2013-04-12.
//  Copyright (c) 2013 Teehan+Lax. All rights reserved.
//

#import <UIKit/UIKit.h>

extern const CGFloat kHeaderHeight;

@interface TLHeaderViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

-(void)flashScrollBars;
-(void)scrollTableViewToTop;
-(void)hideHeaderView;
-(void)showHeaderView;
-(void)updateTimeRatio:(CGFloat)timeRatio;

@end
