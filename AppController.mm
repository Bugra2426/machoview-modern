 /*
 *  AppController.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 15/06/2010.
 *
 */

#import "Common.h"
#import "AppController.h"
#import "DataController.h"
#import "Document.h"
#import "PreferenceController.h"
#import "Attach.h"

#include "disasm.h"  // for the disassembler flags

// counters for statistics
int64_t nrow_total;  // number of rows (loaded and empty)
int64_t nrow_loaded; // number of loaded rows

//============================================================================
@implementation MVAppController

//----------------------------------------------------------------------------
- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
  return NO;
}

//----------------------------------------------------------------------------
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  return NO;
}

//----------------------------------------------------------------------------
- (IBAction)newDocument:(id)sender
{
  NSLog(@"Not yet possible");
}

//----------------------------------------------------------------------------
- (BOOL)isOnlyRunningMachOView
{
  NSProcessInfo * procInfo = [NSProcessInfo processInfo];
  NSBundle * mainBundle = [NSBundle mainBundle];
  NSString * versionString = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  
  NSUInteger numberOfInstance = 0;
  
  NSWorkspace * workspace = [NSWorkspace sharedWorkspace];
  for (NSRunningApplication * runningApplication in workspace.runningApplications)
  {
    // check if process name matches
    NSString * fileName = runningApplication.executableURL.lastPathComponent;
    if ([fileName isEqualToString: procInfo.processName] == NO)
    {
      continue;
    }

    // check if version string matches
    NSBundle * bundle = [NSBundle bundleWithURL:runningApplication.bundleURL];
    if ([versionString isEqualToString:[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]] == YES && ++numberOfInstance > 1)
    {
      return NO;
    }
  }
  
  return YES;
}

//----------------------------------------------------------------------------
/* 
 * menu item action to attach to a process and read its mach-o header
 */
- (IBAction)attach:(id)sender
{
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Insert PID to attach to:";
  [alert addButtonWithTitle:@"Attach"];
  [alert addButtonWithTitle:@"Cancel"];
  NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
  input.stringValue = @"";
  alert.accessoryView = input;
  NSInteger button = [alert runModal];
  if (button == NSAlertFirstButtonReturn)
  {
    [input validateEditing];
    pid_t targetPid = input.intValue;
    NSLog(@"Attach to process %d", targetPid);
    mach_vm_address_t mainAddress = 0;
    if (find_main_binary(targetPid, &mainAddress))
    {
      NSLog(@"Failed to find main binary address!");
      return;
    }
    uint64_t aslr_slide = 0;
    uint64_t imagesize = 0;
    if ( (imagesize = get_image_size(mainAddress, targetPid, &aslr_slide)) == 0 )
    {
      NSLog(@"[ERROR] Got image file size equal to 0!");
      return;
    }
    /* allocate the buffer to contain the memory dump */
    uint8_t *readbuffer = (uint8_t*)malloc(imagesize);
    if (readbuffer == NULL)
    {
      NSLog(@"Can't allocate mem for dumping target!");
      return;
    }
    /* and finally read the sections and dump their contents to the buffer */
    if (dump_binary(mainAddress, targetPid, readbuffer, aslr_slide))
    {
      NSLog(@"Main binary memory dump failed!");
      free(readbuffer);
      return;
    }
    NSData * dump = [NSData dataWithBytesNoCopy:readbuffer length:(NSUInteger)imagesize freeWhenDone:YES];
    NSString * path = [[MVDocument temporaryDirectory] stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    if (path == nil) return;
    NSURL * url = [NSURL fileURLWithPath:path];
    NSError * error = nil;
    if (![dump writeToURL:url options:NSDataWritingAtomic error:&error])
    {
      [NSApp presentError:error];
      return;
    }
    [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:url display:YES
      completionHandler:^(NSDocument * document, BOOL alreadyOpen, NSError * openError) {
        // Opening is asynchronous: deleting immediately used to race the read.
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
        if (document == nil && openError != nil) [NSApp presentError:openError];
      }];
  }
  else if (button == NSAlertSecondButtonReturn)
  {
    /* nothing to do here */
  }
  else
  {
    NSAssert1(NO, @"Invalid input dialog button %ld", button);
  }
}

//----------------------------------------------------------------------------
- (IBAction)openDocument:(id)sender
{
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  [openPanel setTreatsFilePackagesAsDirectories:YES];
  [openPanel setAllowsMultipleSelection:YES];
  [openPanel setCanChooseDirectories:NO];
  [openPanel setCanChooseFiles:YES];
  openPanel.delegate = self; // for filtering files in open panel with shouldShowFilename
  [openPanel beginSheetModalForWindow:NSApp.modalWindow
                    completionHandler:^(NSInteger result)
                    {
                      if (result != NSModalResponseOK)
                      {
                        return;
                      }
                      [openPanel orderOut:self]; // close panel before we might present an error
                      for (NSURL * url in openPanel.URLs)
                      {
                        [self application:NSApp openFile:url.path];
                      }
                    }];
}

//----------------------------------------------------------------------------
- (BOOL)panel:(id)sender shouldEnableURL:(NSURL *)url
{
  // can enter directories
  NSNumber * isDirectory = nil;
  [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
  if (isDirectory.boolValue == YES) 
  {
    return YES;
  }

  // skip symbolic links, etc.
  NSNumber * isRegularFile = nil;
  [url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:NULL];
  if (isRegularFile.boolValue == NO) 
  {
    return NO;
  }
  
  // check for magic values at front
  NSFileHandle * fileHandle = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
  NSData * magicData = [fileHandle readDataOfLength:8];
  [fileHandle closeFile];
  
  if (magicData.length < sizeof(uint32_t))
  {
    return NO;
  }
  
  uint32_t magic;
  memcpy(&magic, magicData.bytes, sizeof(magic));
  if (magic == MH_MAGIC || magic == MH_MAGIC_64 || magic == MH_CIGAM || magic == MH_CIGAM_64 ||
      magic == FAT_CIGAM || magic == FAT_MAGIC)
  {
    return YES;
  }
  
  if (magicData.length < sizeof(uint64_t))
  {
    return NO;
  }
  
  if (memcmp(magicData.bytes, "!<arch>\n", 8) == 0)
  {
    return YES;
  }
  
  return NO;
}

//----------------------------------------------------------------------------
- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
  // disable the state resume feature, it's not very useful with MachOView
  if([[NSUserDefaults standardUserDefaults] objectForKey: @"ApplePersistenceIgnoreState"] == nil)
      [[NSUserDefaults standardUserDefaults] setBool: YES forKey:@"ApplePersistenceIgnoreState"];

  // load user's defaults for preferences
  if([[NSUserDefaults standardUserDefaults] objectForKey: @"UseLLVMDisassembler"] != nil)
    qflag = [[NSUserDefaults standardUserDefaults] boolForKey:@"UseLLVMDisassembler"];

  
  // Each process owns a private directory; another instance must never delete
  // swap files belonging to documents that are still open.
  [MVDocument temporaryDirectory];
}

//----------------------------------------------------------------------------
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification 
{
#ifdef MV_STATISTICS
  [NSThread detachNewThreadSelector:@selector(printStat) toTarget:self withObject:nil];
#endif 
  
  // if there is no document yet, then pop up an open file dialogue
  // XXX: irrelevant check, no?
  // resp: in case of drag and drop file to the MachOView it is relevant
  if ([NSDocumentController sharedDocumentController].documents.count == 0)
  {
    [self openDocument:nil];
  }
}

//----------------------------------------------------------------------------
- (void)applicationWillTerminate:(NSNotification *)aNotification
{
  NSString * directory = [MVDocument temporaryDirectory];
  if (directory != nil) [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

//----------------------------------------------------------------------------
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename
{
  NSLog (@"open file: %@", filename);
  NSDocumentController * documentController = [NSDocumentController sharedDocumentController];
  
  [documentController openDocumentWithContentsOfURL:[NSURL fileURLWithPath:filename]
                                            display:YES
                                  completionHandler:^(NSDocument * _Nullable document, BOOL documentWasAlreadyOpen, NSError * _Nullable error)
                                  {
                                    if (!document)
                                    {
                                      [NSApp presentError:error];
                                    }
                                  }];
  return YES;
}

//----------------------------------------------------------------------------
-(void) printStat
{
  for (;;)
  {
    @autoreleasepool {
      NSLog(@"stat: %lld/%lld rows in memory\n",
            __atomic_load_n(&nrow_loaded, __ATOMIC_RELAXED),
            __atomic_load_n(&nrow_total, __ATOMIC_RELAXED));
    }
    [NSThread sleepForTimeInterval:1];
  }
}

//----------------------------------------------------------------------------
- (IBAction)showPreferencePanel:(id)sender
{
    if (!preferenceController)
    {
        preferenceController = [[MVPreferenceController alloc] init];
    }
    [preferenceController showWindow:self];
}

@end


