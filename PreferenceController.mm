/*
 *  PreferencesWindowController.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 12/24/12.
 *
 */

#import "PreferenceController.h"

@implementation MVPreferenceController

-(instancetype)init
{
  self = [super initWithWindowNibName:@"Preferences"];
  return self;
}

- (IBAction)toggleUseLLVMDisassembler:(id)sender
{
  [[NSUserDefaults standardUserDefaults] setBool:(useLLVMDisassembler.state == NSControlStateValueOn)
                                         forKey:@"UseLLVMDisassembler"];
}

@end

