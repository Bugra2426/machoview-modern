/*
 *  PreferencesWindowController.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 12/24/12.
 *
 */

#import "PreferenceController.h"

@implementation MVPreferenceController

-(id)init
{
    if (![super initWithWindowNibName:@"Preferences"])
        return nil;
    return self;
}

@end

