//
//  EKEventManager.m
//  EventKitTest
//
//  Created by Brendan Lynch on 13-04-11.
//  Copyright (c) 2013 Teehan+Lax. All rights reserved.
//

#import "EKEventManager.h"

NSString *const EKEventManagerAccessibleKeyPath = @"accessible";
NSString *const EKEventManagerEventsKeyPath = @"events";
NSString *const EKEventManagerNextEventKeyPath = @"nextEvent";
NSString *const EKEventManagerSourcesKeyPath = @"sources";

@interface EKEventManager ()

-(void)loadEvents;
-(void)resetSources;

@property (nonatomic, strong) NSMutableArray *events;
@property (nonatomic, strong) EKEvent *nextEvent;


@end

@implementation EKEventManager

-(id)init {
    if (!(self = [super init])) {
        return nil;
    }

    _calendar = [NSCalendar autoupdatingCurrentCalendar];
    
    _store = [[EKEventStore alloc] init];

    _sources = [[NSMutableArray alloc] initWithCapacity:0];
    _selectedCalendars = [[NSMutableArray alloc] initWithCapacity:0];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeChanged:)
                                                 name:EKEventStoreChangedNotification
                                               object:_store];

    _eventsSignal = [[RACObserve(self, events) skip:1] startWith:nil];
    _nextEventSignal = [[RACObserve(self, nextEvent) skip:1] startWith:nil];
    
    return self;
}

#pragma mark Public methods

+(EKEventManager *)sharedInstance {
    static EKEventManager *_sharedInstance = nil;
    static dispatch_once_t pred;

    dispatch_once(&pred, ^{ _sharedInstance = [[self alloc] init]; });
    return _sharedInstance;
}

-(void)promptForAccess {
    if ([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent] != EKAuthorizationStatusAuthorized) {
        [_store requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self willChangeValueForKey:EKEventManagerAccessibleKeyPath];
                _accessible = granted;
                [self didChangeValueForKey:EKEventManagerAccessibleKeyPath];
                
                if (_accessible) {
                    // need to set these to nil before resetting the store.
                    [self willChangeValueForKey:EKEventManagerEventsKeyPath];
                    _events = nil;
                    [self didChangeValueForKey:EKEventManagerEventsKeyPath];
                    [self willChangeValueForKey:EKEventManagerNextEventKeyPath];
                    _nextEvent = nil;
                    [self didChangeValueForKey:EKEventManagerNextEventKeyPath];
                    
                    // load events
                    [_store reset];
                    [self refresh];
                }
            });
        }];
    }
}

-(void)refresh {
    [self resetSources];
    [self loadEvents];
}

-(void)toggleCalendarWithIdentifier:(NSString *)calendarIdentifier {
    if ([_selectedCalendars containsObject:calendarIdentifier]) {
        [_selectedCalendars removeObject:calendarIdentifier];
    } else {
        [_selectedCalendars addObject:calendarIdentifier];
    }

    [[NSUserDefaults standardUserDefaults] setObject:[NSKeyedArchiver archivedDataWithRootObject:_selectedCalendars] forKey:@"SelectedCalendars"];
    [[NSUserDefaults standardUserDefaults] synchronize];

        [self refresh];
}

#pragma mark Internal methods

-(void)storeChanged:(EKEventStore *)store {
    NSLog(@"STORE CHANGED.");
    [self refresh];
}

-(void)resetSources {
    [self willChangeValueForKey:EKEventManagerSourcesKeyPath];

    [_sources removeAllObjects];
    [_selectedCalendars removeAllObjects];

    BOOL hasCalendars = NO;
    NSUserDefaults *currentDefaults = [NSUserDefaults standardUserDefaults];
    NSData *dataRepresentingSavedArray = [currentDefaults objectForKey:@"SelectedCalendars"];

    if (dataRepresentingSavedArray != nil) {
        NSArray *oldSavedArray = [NSKeyedUnarchiver unarchiveObjectWithData:dataRepresentingSavedArray];

        if (oldSavedArray != nil) {
            [_selectedCalendars addObjectsFromArray:oldSavedArray];
            hasCalendars = YES;
        }
    }

    for (EKSource *source in [EKEventManager sharedInstance].store.sources) {
        NSSet *calendars = [source calendarsForEntityType:EKEntityTypeEvent];

        if ([calendars count] > 0) {
            [_sources addObject:source];

            if (!hasCalendars) {
                // load defaults
                NSArray *calendarArray = [calendars allObjects];

                for (EKCalendar *calendar in calendarArray) {
                    if (![_selectedCalendars containsObject:calendar.calendarIdentifier]) {
                        [_selectedCalendars addObject:calendar.calendarIdentifier];
                    }
                }

                // save them back to NSUserDefaults
                [[NSUserDefaults standardUserDefaults] setObject:[NSKeyedArchiver archivedDataWithRootObject:_selectedCalendars] forKey:@"SelectedCalendars"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }

    [self didChangeValueForKey:EKEventManagerSourcesKeyPath];
}

-(void)loadEvents {
    NSMutableArray *calendars = nil;
    NSUserDefaults *currentDefaults = [NSUserDefaults standardUserDefaults];
    NSData *dataRepresentingSavedArray = [currentDefaults objectForKey:@"SelectedCalendars"];

    if (dataRepresentingSavedArray != nil) {
        NSArray *oldSavedArray = [NSKeyedUnarchiver unarchiveObjectWithData:dataRepresentingSavedArray];

        if (oldSavedArray != nil) {
            calendars = [[NSMutableArray alloc] initWithCapacity:0];

            for (NSString *identifier in oldSavedArray) {
                for (EKCalendar *calendarObject in [_store calendarsForEntityType : EKEntityTypeEvent]) {
                    if ([calendarObject.calendarIdentifier isEqualToString:identifier]) {
                        [calendars addObject:calendarObject];
                    }
                }
            }
        }
    }

    NSLog(@"LOADING EVENTS.");
    
    // no calendars selected. Empty views
    if (calendars == nil || [calendars count] == 0) {
        
        [self willChangeValueForKey:EKEventManagerEventsKeyPath];
        [self willChangeValueForKey:EKEventManagerNextEventKeyPath];
        
        [_events removeAllObjects];
        _nextEvent = nil;
        
        [self didChangeValueForKey:EKEventManagerEventsKeyPath];
        [self didChangeValueForKey:EKEventManagerNextEventKeyPath];
        
        return;
    }
        
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSUInteger unitFlags = NSYearCalendarUnit | NSMonthCalendarUnit |  NSDayCalendarUnit;
        
        // start date - midnight of yesterday
        NSDateComponents *midnightDate = [[NSDateComponents alloc] init];
        midnightDate = [self.calendar components:unitFlags fromDate:[NSDate dateYesterday]];
        midnightDate.hour = 0;
        midnightDate.minute = 0;
        midnightDate.second = 0;
        NSDate *startDate = [self.calendar dateFromComponents:midnightDate];
        
        // end date - 11:59:59 of current day
        NSDateComponents *endComponents = [[NSDateComponents alloc] init];
        endComponents = [self.calendar components:unitFlags fromDate:[NSDate date]];
        endComponents.hour = 23;
        endComponents.minute = 59;
        endComponents.second = 59;
        NSDate *endDate = [self.calendar dateFromComponents:endComponents];
        
        // Create the predicate from the event store's instance method
        NSPredicate *predicate = [_store predicateForEventsWithStartDate:startDate
                                                                 endDate:endDate
                                                               calendars:calendars];
        
        // get today's events
        NSMutableArray *todaysEventsArray = [NSMutableArray arrayWithArray:[_store eventsMatchingPredicate:predicate]];
        [todaysEventsArray filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(EKEvent *evaluatedObject, NSDictionary *bindings) {
            // need the check for subtracting one second so that events that ended at midnight (technical today) don't show up.
            return ([evaluatedObject.startDate isToday] || ([evaluatedObject.endDate isToday] && ![[evaluatedObject.endDate dateByAddingTimeInterval:-1] isYesterday]));
        }]];
        [todaysEventsArray sortUsingSelector:@selector(compareStartDateWithEvent:)];
        
        
        // find next event
        NSPredicate *nextPredicate = [_store predicateForEventsWithStartDate:endDate
                                                                     endDate:[NSDate distantFuture]
                                                                   calendars:calendars];
        
        // Fetch all events that match the predicate
        NSArray *nextEventsArray = [[_store eventsMatchingPredicate:nextPredicate] sortedArrayUsingSelector:@selector(compareStartDateWithEvent:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self willChangeValueForKey:EKEventManagerEventsKeyPath];
            _events = todaysEventsArray;
            [self didChangeValueForKey:EKEventManagerNextEventKeyPath];
            
            [self willChangeValueForKey:EKEventManagerNextEventKeyPath];
            if ([nextEventsArray count] > 0) {
                _nextEvent = nextEventsArray[0];
            }
            else {
                _nextEvent = nil;
            }
            [self didChangeValueForKey:EKEventManagerEventsKeyPath];
        });
    });
}

#pragma mark Overriden methods

+(BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    BOOL automatic = NO;

    if ([key isEqualToString:EKEventManagerAccessibleKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerEventsKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerNextEventKeyPath]) {
        automatic = NO;
    } else if ([key isEqualToString:EKEventManagerSourcesKeyPath]) {
        automatic = NO;
    } else {
        automatic = [super automaticallyNotifiesObserversForKey:key];
    }

    return automatic;
}

@end