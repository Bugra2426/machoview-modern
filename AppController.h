/*
 *  AppController.h
 *  MachOView
 *
 *  Created by Bugra Karabudak on 15/06/2010.
 *
 */

#import <Cocoa/Cocoa.h>

@class MVPreferenceController;

@interface MVAppController : NSObject <NSApplicationDelegate,NSOpenSavePanelDelegate>
{
    MVPreferenceController * preferenceController;
}

- (IBAction)showPreferencePanel:(id)sender;

@end




